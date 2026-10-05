const std = @import("std");
const builtin = @import("builtin");
const zig_serial = @import("serial");

const ring_mod = @import("ring.zig");
const types = @import("types.zig");

pub const ring_capacity: usize = 1024;
pub const EventRing = ring_mod.SpscRing(types.Event, ring_capacity);

pub const tx_capacity: usize = 4096;

pub const TxFailure = enum(u8) { none, failed, timeout };

/// Bytes waiting to be written to the port. The UI thread enqueues, the
/// reader thread drains and does the actual write, so the two never contend
/// for the (synchronous) handle.
pub const TxQueue = struct {
    ring: ring_mod.SpscRing(u8, tx_capacity) = .{},
    // Last write failure, set by the reader thread, taken by the UI thread.
    failure: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(TxFailure.none)),

    /// All-or-nothing, so a command is never sent truncated.
    pub fn enqueue(self: *TxQueue, bytes: []const u8) bool {
        if (bytes.len > self.ring.freeSlots()) return false;
        for (bytes) |b| _ = self.ring.push(b);
        return true;
    }

    /// Pop up to out.len queued bytes, oldest first.
    pub fn drain(self: *TxQueue, out: []u8) []u8 {
        var n: usize = 0;
        while (n < out.len) : (n += 1) {
            out[n] = self.ring.pop() orelse break;
        }
        return out[0..n];
    }

    pub fn fail(self: *TxQueue, f: TxFailure) void {
        self.failure.store(@backingInt(f), .release);
    }

    pub fn takeFailure(self: *TxQueue) ?TxFailure {
        const f: TxFailure = @fromBackingInt(@intCast(self.failure.swap(@backingInt(TxFailure.none), .acq_rel)));
        return if (f == .none) null else f;
    }
};

pub const Port = struct {
    id: u8,
    file: std.Io.File,
    io: std.Io,
    name: []u8,
    config: zig_serial.SerialConfig,
    allocator: std.mem.Allocator,

    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(types.PortState.closed)),
    running: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    ring: *EventRing,
    tx: TxQueue = .{},

    thread: ?std.Thread = null,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        id: u8,
        name: []const u8,
        config: zig_serial.SerialConfig,
        ring: *EventRing,
    ) !*Port {
        const self = try allocator.create(Port);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        var file = try std.Io.Dir.openFileAbsolute(io, name, .{ .mode = .read_write });
        errdefer file.close(io);

        try zig_serial.configureSerialPort(file, config);
        try zig_serial.flushSerialPort(file, .input);

        try setLowLatency(file.handle);

        self.* = .{
            .id = id,
            .file = file,
            .io = io,
            .name = name_copy,
            .config = config,
            .allocator = allocator,
            .ring = ring,
        };

        self.state.store(@backingInt(types.PortState.open), .release);
        self.running.store(1, .release);
        self.thread = try std.Thread.spawn(.{}, readerThread, .{self});
        return self;
    }

    pub fn close(self: *Port) void {
        self.running.store(0, .release);
        // Unblock the reader thread immediately on Windows; otherwise it sits in
        // ReadFile for up to ReadTotalTimeoutConstant (100ms) before noticing.
        if (comptime builtin.target.os.tag == .windows) {
            _ = CancelIoEx(self.file.handle, null);
        }
        if (self.thread) |t| t.join();
        self.thread = null;
        self.file.close(self.io);
        self.state.store(@backingInt(types.PortState.closed), .release);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn getState(self: *const Port) types.PortState {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }

    pub fn droppedCount(self: *const Port) u64 {
        return self.dropped.load(.monotonic);
    }

    /// Queue bytes for the reader thread to write; never blocks. They go out
    /// before the next read, i.e. within ReadTotalTimeoutConstant (100ms).
    /// Write failures surface later via tx.takeFailure().
    pub fn send(self: *Port, bytes: []const u8) error{TxQueueFull}!void {
        if (!self.tx.enqueue(bytes)) return error.TxQueueFull;
    }

    // Reader thread only. Windows serializes I/O on a synchronous handle, so
    // writing from the thread that also reads avoids queueing behind ReadFile.
    fn flushTx(self: *Port) void {
        var chunk_buf: [256]u8 = undefined;
        while (true) {
            const chunk = self.tx.drain(&chunk_buf);
            if (chunk.len == 0) return;
            self.writeNow(chunk) catch |err| {
                self.tx.fail(if (err == error.WriteTimeout) .timeout else .failed);
            };
        }
    }

    /// Blocking write of all bytes; gives up after write_timeout_ms on Windows
    /// if the device stops accepting data.
    fn writeNow(self: *Port, bytes: []const u8) !void {
        switch (comptime builtin.target.os.tag) {
            .windows => {
                var written: std.os.windows.DWORD = 0;
                const ok = WriteFile(self.file.handle, bytes.ptr, @intCast(bytes.len), &written, null);
                if (ok == std.os.windows.BOOL.FALSE) return error.WriteFailed;
                // With a total write timeout set, a short count means it expired.
                if (written < bytes.len) return error.WriteTimeout;
            },
            else => try self.file.writeStreamingAll(self.io, bytes),
        }
    }

    fn readerThread(self: *Port) void {
        var buf: [types.event_payload_bytes]u8 = undefined;
        while (self.running.load(.acquire) == 1) {
            self.flushTx();
            const n = rawRead(self.file.handle, &buf) catch {
                self.state.store(@backingInt(types.PortState.errored), .release);
                return;
            };
            if (n == 0) continue;

            const ts: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);

            var ev: types.Event = .{
                .timestamp_ns = ts,
                .device_id = self.id,
                .len = @intCast(n),
            };
            @memcpy(ev.data[0..n], buf[0..n]);
            if (!self.ring.push(ev)) {
                _ = self.dropped.fetchAdd(1, .monotonic);
            }
        }
    }
};

// A write gives up after this long, so a device that stops draining its RX
// buffer can't freeze the UI thread inside WriteFile.
const write_timeout_ms: std.os.windows.DWORD = 1000;

fn commTimeouts() COMMTIMEOUTS {
    return .{
        .ReadIntervalTimeout = std.math.maxInt(std.os.windows.DWORD),
        .ReadTotalTimeoutMultiplier = std.math.maxInt(std.os.windows.DWORD),
        .ReadTotalTimeoutConstant = 100,
        .WriteTotalTimeoutMultiplier = 0,
        .WriteTotalTimeoutConstant = write_timeout_ms,
    };
}

fn setLowLatency(handle: std.posix.fd_t) !void {
    switch (comptime builtin.target.os.tag) {
        .windows => {
            var t = commTimeouts();
            if (SetCommTimeouts(handle, &t) == std.os.windows.BOOL.FALSE) return error.SetCommTimeoutsFailed;
        },
        .linux, .macos => {
            var settings = try std.posix.tcgetattr(handle);
            settings.cc[@backingInt(std.posix.V.MIN)] = 0;
            settings.cc[@backingInt(std.posix.V.TIME)] = 1;
            try std.posix.tcsetattr(handle, .NOW, settings);
        },
        else => @compileError("unsupported OS"),
    }
}

fn rawRead(handle: std.posix.fd_t, buf: []u8) !usize {
    switch (comptime builtin.target.os.tag) {
        .windows => {
            var bytes_read: std.os.windows.DWORD = 0;
            const ok = ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
            if (ok == std.os.windows.BOOL.FALSE) return error.ReadFailed;
            return bytes_read;
        },
        else => return try std.posix.read(handle, buf),
    }
}

const COMMTIMEOUTS = extern struct {
    ReadIntervalTimeout: std.os.windows.DWORD,
    ReadTotalTimeoutMultiplier: std.os.windows.DWORD,
    ReadTotalTimeoutConstant: std.os.windows.DWORD,
    WriteTotalTimeoutMultiplier: std.os.windows.DWORD,
    WriteTotalTimeoutConstant: std.os.windows.DWORD,
};

extern "kernel32" fn SetCommTimeouts(
    hFile: std.os.windows.HANDLE,
    lpCommTimeouts: *const COMMTIMEOUTS,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn ReadFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: std.os.windows.DWORD,
    lpNumberOfBytesRead: *std.os.windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn WriteFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: std.os.windows.DWORD,
    lpNumberOfBytesWritten: *std.os.windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn CancelIoEx(
    hFile: std.os.windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) std.os.windows.BOOL;

test "serial writes time out instead of blocking forever" {
    // All-zero write fields mean "no timeout": a device that stops draining
    // its RX buffer would then freeze the UI thread inside WriteFile.
    const t = commTimeouts();
    try std.testing.expect(t.WriteTotalTimeoutConstant > 0);
    try std.testing.expect(t.WriteTotalTimeoutConstant <= 2000);
}

test "TxQueue enqueues whole commands or nothing" {
    var q: TxQueue = .{};
    const big: [tx_capacity]u8 = @splat('x');
    try std.testing.expect(!q.enqueue(&big));
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), q.drain(&out).len);

    try std.testing.expect(q.enqueue("AT\r\n"));
    try std.testing.expectEqualStrings("AT\r\n", q.drain(&out));
    try std.testing.expectEqual(@as(usize, 0), q.drain(&out).len);
}

test "TxQueue drains in order in chunks of the buffer size" {
    var q: TxQueue = .{};
    try std.testing.expect(q.enqueue("abc"));
    try std.testing.expect(q.enqueue("def"));
    var out: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", q.drain(&out));
    try std.testing.expectEqualStrings("ef", q.drain(&out));
}

test "TxQueue failure is reported once" {
    var q: TxQueue = .{};
    try std.testing.expect(q.takeFailure() == null);
    q.fail(.timeout);
    try std.testing.expectEqual(TxFailure.timeout, q.takeFailure().?);
    try std.testing.expect(q.takeFailure() == null);
}
