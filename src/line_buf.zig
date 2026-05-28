const std = @import("std");
const types = @import("types.zig");

// How long a line can sit in `buf` without a terminator before `idleFlush`
// will emit it with terminator `.none`. Has to clear one tick (33ms) plus
// typical USB-serial batching latency (~16ms) so a line arriving in chunks
// across ticks doesn't fragment; short enough that an unterminated line
// still appears nearly-instantly to the user.
pub const idle_flush_threshold_ns: u64 = 50 * std.time.ns_per_ms;

pub const Sink = struct {
    ptr: *anyopaque,
    push: *const fn (*anyopaque, types.Line) anyerror!void,
};

pub const LineBuffer = struct {
    allocator: std.mem.Allocator,
    port_id: u8,
    buf: std.ArrayList(u8) = .empty,
    start_ts: ?u64 = null,
    pending_terminator: ?types.Terminator = null,

    pub fn init(allocator: std.mem.Allocator, port_id: u8) LineBuffer {
        return .{ .allocator = allocator, .port_id = port_id };
    }

    pub fn deinit(self: *LineBuffer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn reset(self: *LineBuffer) void {
        self.buf.clearAndFree(self.allocator);
        self.start_ts = null;
        self.pending_terminator = null;
    }

    pub fn feed(self: *LineBuffer, bytes: []const u8, timestamp_ns: u64, sink: Sink) !void {
        for (bytes) |b| {
            if (b == '\r' or b == '\n') {
                if (self.pending_terminator) |pt| {
                    const is_pair = (pt == .cr and b == '\n') or (pt == .lf and b == '\r');
                    if (is_pair) {
                        self.pending_terminator = if (pt == .cr) .crlf else .lfcr;
                        try self.emitPending(sink);
                    } else {
                        try self.emitPending(sink);
                        self.pending_terminator = if (b == '\r') .cr else .lf;
                    }
                } else {
                    self.pending_terminator = if (b == '\r') .cr else .lf;
                }
            } else {
                if (self.pending_terminator != null) try self.emitPending(sink);
                if (self.start_ts == null) self.start_ts = timestamp_ns;
                try self.buf.append(self.allocator, b);
            }
        }
    }

    pub fn flushPending(self: *LineBuffer, sink: Sink) !void {
        if (self.pending_terminator != null) try self.emitPending(sink);
    }

    // Emit any unterminated content that has been sitting in `buf` for longer
    // than `threshold_ns`. The terminator-pairing path (`flushPending`) only
    // fires once at least one `\r`/`\n` has been seen; without this method,
    // bytes emitted by the device with no trailing terminator stay buffered
    // indefinitely until the next `\r`/`\n` arrives (which can be a separate
    // transmission entirely).
    pub fn idleFlush(self: *LineBuffer, now_ns: u64, threshold_ns: u64, sink: Sink) !void {
        if (self.pending_terminator != null) return;
        const ts = self.start_ts orelse return;
        if (self.buf.items.len == 0) return;
        if (now_ns -% ts <= threshold_ns) return;

        const text = try self.allocator.dupe(u8, self.buf.items);
        errdefer self.allocator.free(text);

        self.buf.clearRetainingCapacity();
        self.start_ts = null;

        try sink.push(sink.ptr, .{
            .port_id = self.port_id,
            .timestamp_ns = ts,
            .text = text,
            .terminator = .none,
        });
    }

    fn emitPending(self: *LineBuffer, sink: Sink) !void {
        const ts = self.start_ts orelse {
            self.pending_terminator = null;
            return;
        };
        const term = self.pending_terminator orelse .lf;
        const text = try self.allocator.dupe(u8, self.buf.items);
        errdefer self.allocator.free(text);

        // Reset local state before calling out so a sink error does not leave
        // half-flushed bytes that would merge into the next line.
        self.buf.clearRetainingCapacity();
        self.start_ts = null;
        self.pending_terminator = null;

        try sink.push(sink.ptr, .{
            .port_id = self.port_id,
            .timestamp_ns = ts,
            .text = text,
            .terminator = term,
        });
    }
};

test "assembles a single line on LF" {
    var emitted: std.ArrayList(types.Line) = .empty;
    defer {
        for (emitted.items) |line| std.testing.allocator.free(line.text);
        emitted.deinit(std.testing.allocator);
    }
    const sink: Sink = .{
        .ptr = &emitted,
        .push = struct {
            fn p(ptr: *anyopaque, line: types.Line) anyerror!void {
                const list: *std.ArrayList(types.Line) = @ptrCast(@alignCast(ptr));
                try list.append(std.testing.allocator, line);
            }
        }.p,
    };

    var lb = LineBuffer.init(std.testing.allocator, 1);
    defer lb.deinit();
    try lb.feed("hello\n", 100, sink);
    try lb.flushPending(sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqualStrings("hello", emitted.items[0].text);
    try std.testing.expectEqual(@as(u64, 100), emitted.items[0].timestamp_ns);
    try std.testing.expectEqual(@as(u8, 1), emitted.items[0].port_id);
    try std.testing.expectEqual(types.Terminator.lf, emitted.items[0].terminator);
}

test "coalesces CRLF" {
    var emitted: std.ArrayList(types.Line) = .empty;
    defer {
        for (emitted.items) |line| std.testing.allocator.free(line.text);
        emitted.deinit(std.testing.allocator);
    }
    const sink: Sink = .{
        .ptr = &emitted,
        .push = struct {
            fn p(ptr: *anyopaque, line: types.Line) anyerror!void {
                const list: *std.ArrayList(types.Line) = @ptrCast(@alignCast(ptr));
                try list.append(std.testing.allocator, line);
            }
        }.p,
    };

    var lb = LineBuffer.init(std.testing.allocator, 0);
    defer lb.deinit();
    try lb.feed("a\r\nb\r\n", 1, sink);
    try std.testing.expectEqual(@as(usize, 2), emitted.items.len);
    try std.testing.expectEqualStrings("a", emitted.items[0].text);
    try std.testing.expectEqualStrings("b", emitted.items[1].text);
    try std.testing.expectEqual(types.Terminator.crlf, emitted.items[0].terminator);
    try std.testing.expectEqual(types.Terminator.crlf, emitted.items[1].terminator);
}

test "emits line ending with CR on flushPending" {
    var emitted: std.ArrayList(types.Line) = .empty;
    defer {
        for (emitted.items) |line| std.testing.allocator.free(line.text);
        emitted.deinit(std.testing.allocator);
    }
    const sink: Sink = .{
        .ptr = &emitted,
        .push = struct {
            fn p(ptr: *anyopaque, line: types.Line) anyerror!void {
                const list: *std.ArrayList(types.Line) = @ptrCast(@alignCast(ptr));
                try list.append(std.testing.allocator, line);
            }
        }.p,
    };

    var lb = LineBuffer.init(std.testing.allocator, 2);
    defer lb.deinit();
    try lb.feed("hello\r", 100, sink);
    try lb.flushPending(sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqualStrings("hello", emitted.items[0].text);
    try std.testing.expectEqual(@as(u64, 100), emitted.items[0].timestamp_ns);
    try std.testing.expectEqual(@as(u8, 2), emitted.items[0].port_id);
    try std.testing.expectEqual(types.Terminator.cr, emitted.items[0].terminator);
}

test "idleFlush emits unterminated content after threshold" {
    var emitted: std.ArrayList(types.Line) = .empty;
    defer {
        for (emitted.items) |line| std.testing.allocator.free(line.text);
        emitted.deinit(std.testing.allocator);
    }
    const sink: Sink = .{
        .ptr = &emitted,
        .push = struct {
            fn p(ptr: *anyopaque, line: types.Line) anyerror!void {
                const list: *std.ArrayList(types.Line) = @ptrCast(@alignCast(ptr));
                try list.append(std.testing.allocator, line);
            }
        }.p,
    };

    // Test-local threshold so this test doesn't depend on the production constant.
    const threshold: u64 = 100 * std.time.ns_per_ms;

    var lb = LineBuffer.init(std.testing.allocator, 0);
    defer lb.deinit();
    try lb.feed("1777", 1000, sink);

    // Below threshold: nothing emitted yet.
    try lb.idleFlush(1000 + 50 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);

    // Past threshold: content flushed with .none.
    try lb.idleFlush(1000 + 200 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqualStrings("1777", emitted.items[0].text);
    try std.testing.expectEqual(@as(u64, 1000), emitted.items[0].timestamp_ns);
    try std.testing.expectEqual(types.Terminator.none, emitted.items[0].terminator);

    // Calling again is a no-op (state was cleared).
    try lb.idleFlush(1000 + 500 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
}

test "idleFlush leaves pending-terminator lines alone" {
    var emitted: std.ArrayList(types.Line) = .empty;
    defer {
        for (emitted.items) |line| std.testing.allocator.free(line.text);
        emitted.deinit(std.testing.allocator);
    }
    const sink: Sink = .{
        .ptr = &emitted,
        .push = struct {
            fn p(ptr: *anyopaque, line: types.Line) anyerror!void {
                const list: *std.ArrayList(types.Line) = @ptrCast(@alignCast(ptr));
                try list.append(std.testing.allocator, line);
            }
        }.p,
    };

    const threshold: u64 = 100 * std.time.ns_per_ms;

    var lb = LineBuffer.init(std.testing.allocator, 0);
    defer lb.deinit();
    // Pending .cr — could pair with a future \n. idleFlush must not steal it.
    try lb.feed("done\r", 1000, sink);
    try lb.idleFlush(1000 + 500 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);

    // flushPending still emits it normally with .cr.
    try lb.flushPending(sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqual(types.Terminator.cr, emitted.items[0].terminator);
}
