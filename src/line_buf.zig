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
    // When the pending terminator byte arrived; drives its idleFlush aging.
    pending_ts: ?u64 = null,

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
        self.pending_ts = null;
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
                        // emitPending cleared start_ts; this terminator starts
                        // a new (possibly empty) line, so it owns the timestamp.
                        self.pending_terminator = if (b == '\r') .cr else .lf;
                        self.start_ts = timestamp_ns;
                        self.pending_ts = timestamp_ns;
                    }
                } else {
                    if (self.start_ts == null) self.start_ts = timestamp_ns;
                    self.pending_terminator = if (b == '\r') .cr else .lf;
                    self.pending_ts = timestamp_ns;
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

    // Age out state that has been sitting for longer than `threshold_ns`:
    // - A pending terminator waits that long for a pairing partner (the `\n`
    //   of a `\r\n` split across two reads), then the line is emitted as-is.
    //   Emitting it immediately would misreport a split CRLF as a `.cr` line
    //   plus a spurious empty `.lf` line.
    // - Unterminated content is emitted with `.none`; without this, bytes sent
    //   by the device with no trailing terminator would stay buffered until
    //   the next `\r`/`\n` arrives (which can be a separate transmission).
    // Timestamps come from the reader thread and can be newer than `now_ns`,
    // so age is computed with ordered comparisons, never wrapping subtraction.
    pub fn idleFlush(self: *LineBuffer, now_ns: u64, threshold_ns: u64, sink: Sink) !void {
        if (self.pending_terminator != null) {
            const pts = self.pending_ts orelse return;
            if (now_ns <= pts or now_ns - pts <= threshold_ns) return;
            try self.emitPending(sink);
            return;
        }
        const ts = self.start_ts orelse return;
        if (self.buf.items.len == 0) return;
        if (now_ns <= ts or now_ns - ts <= threshold_ns) return;

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
        // `feed` sets start_ts whenever it sets pending_terminator, so this
        // fallback chain should never get past start_ts; it exists so a broken
        // invariant degrades to a slightly-off timestamp, not a dropped line.
        const ts = self.start_ts orelse self.pending_ts orelse {
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
        self.pending_ts = null;

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

test "idleFlush emits pending terminator only after threshold" {
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
    // Pending .cr — could pair with a future \n, so it must survive below the
    // threshold and only age out once no partner arrived in time.
    try lb.feed("done\r", 1000, sink);
    try lb.idleFlush(1000 + 50 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);

    try lb.idleFlush(1000 + 200 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqualStrings("done", emitted.items[0].text);
    try std.testing.expectEqual(@as(u64, 1000), emitted.items[0].timestamp_ns);
    try std.testing.expectEqual(types.Terminator.cr, emitted.items[0].terminator);

    // Calling again is a no-op (state was cleared).
    try lb.idleFlush(1000 + 500 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
}

test "consecutive LFs emit empty lines" {
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
    try lb.feed("a\n\nb\n", 100, sink);
    try std.testing.expectEqual(@as(usize, 2), emitted.items.len);
    try std.testing.expectEqualStrings("a", emitted.items[0].text);
    try std.testing.expectEqual(types.Terminator.lf, emitted.items[0].terminator);
    try std.testing.expectEqualStrings("", emitted.items[1].text);
    try std.testing.expectEqual(types.Terminator.lf, emitted.items[1].terminator);
    try std.testing.expectEqual(@as(u64, 100), emitted.items[1].timestamp_ns);

    // Trailing "b\n" ages out via idleFlush.
    try lb.idleFlush(100 + 200 * std.time.ns_per_ms, 100 * std.time.ns_per_ms, sink);
    try std.testing.expectEqual(@as(usize, 3), emitted.items.len);
    try std.testing.expectEqualStrings("b", emitted.items[2].text);
    try std.testing.expectEqual(types.Terminator.lf, emitted.items[2].terminator);
}

test "back-to-back CRLF emits empty crlf lines" {
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
    try lb.feed("\r\n\r\n", 100, sink);
    try std.testing.expectEqual(@as(usize, 2), emitted.items.len);
    try std.testing.expectEqualStrings("", emitted.items[0].text);
    try std.testing.expectEqual(types.Terminator.crlf, emitted.items[0].terminator);
    try std.testing.expectEqualStrings("", emitted.items[1].text);
    try std.testing.expectEqual(types.Terminator.crlf, emitted.items[1].terminator);
    try std.testing.expectEqual(@as(u64, 100), emitted.items[1].timestamp_ns);
}

test "terminator as first stream byte emits empty line after threshold" {
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
    try lb.feed("\n", 100, sink);
    try lb.idleFlush(100 + 50 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);

    try lb.idleFlush(100 + 200 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqualStrings("", emitted.items[0].text);
    try std.testing.expectEqual(@as(u64, 100), emitted.items[0].timestamp_ns);
    try std.testing.expectEqual(types.Terminator.lf, emitted.items[0].terminator);
}

test "CRLF split across feeds pairs within threshold" {
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

    const threshold: u64 = 50 * std.time.ns_per_ms;

    var lb = LineBuffer.init(std.testing.allocator, 0);
    defer lb.deinit();
    try lb.feed("hello\r", 1000, sink);
    // One tick (33ms) later, still below threshold: pairing window stays open.
    try lb.idleFlush(1000 + 33 * std.time.ns_per_ms, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);

    try lb.feed("\n", 1000 + 33 * std.time.ns_per_ms, sink);
    try std.testing.expectEqual(@as(usize, 1), emitted.items.len);
    try std.testing.expectEqualStrings("hello", emitted.items[0].text);
    try std.testing.expectEqual(types.Terminator.crlf, emitted.items[0].terminator);
    // Line keeps the timestamp of its first content byte.
    try std.testing.expectEqual(@as(u64, 1000), emitted.items[0].timestamp_ns);
}

test "idleFlush tolerates now earlier than timestamps" {
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

    // Events are timestamped on the reader thread, which can be later than the
    // `now` captured at the start of a drain. That must not look like old age.
    var lb = LineBuffer.init(std.testing.allocator, 0);
    defer lb.deinit();
    try lb.feed("abc", 1000, sink);
    try lb.idleFlush(500, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);

    var lb2 = LineBuffer.init(std.testing.allocator, 0);
    defer lb2.deinit();
    try lb2.feed("x\r", 1000, sink);
    try lb2.idleFlush(500, threshold, sink);
    try std.testing.expectEqual(@as(usize, 0), emitted.items.len);
}
