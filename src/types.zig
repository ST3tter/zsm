const std = @import("std");

pub const max_slots: usize = 4;
pub const event_payload_bytes: usize = 256;

pub const Event = extern struct {
    timestamp_ns: u64,
    device_id: u8,
    _reserved: u8 = 0,
    len: u16,
    data: [event_payload_bytes]u8 = [_]u8{0} ** event_payload_bytes,
};

comptime {
    if (@sizeOf(Event) != 272) {
        @compileError(std.fmt.comptimePrint("Event must be 272 bytes, got {d}", .{@sizeOf(Event)}));
    }
}

pub const Terminator = enum {
    none,
    lf,
    cr,
    crlf,
    lfcr,
};

pub fn terminatorBytes(t: Terminator) []const u8 {
    return switch (t) {
        .none => "",
        .lf => "\n",
        .cr => "\r",
        .crlf => "\r\n",
        .lfcr => "\n\r",
    };
}

pub const Line = struct {
    port_id: u8,
    timestamp_ns: u64,
    text: []u8,
    terminator: Terminator = .lf,
};

pub const PortState = enum {
    closed,
    open,
    errored,
};

pub fn displayName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "\\\\.\\")) return name[4..];
    return name;
}
