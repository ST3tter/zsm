const std = @import("std");
const builtin = @import("builtin");
const zig_serial = @import("serial");

const ring_mod = @import("ring.zig");
const types = @import("types.zig");

pub const ring_capacity: usize = 1024;
pub const EventRing = ring_mod.SpscRing(types.Event, ring_capacity);

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

    /// Blocking write of all bytes, called from the UI thread. On Windows the
    /// handle is non-overlapped, so this can wait up to ReadTotalTimeoutConstant
    /// (100ms) behind the reader thread's pending ReadFile, and gives up after
    /// write_timeout_ms if the device stops accepting data.
    pub fn write(self: *Port, bytes: []const u8) !void {
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
