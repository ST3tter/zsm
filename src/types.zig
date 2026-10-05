const std = @import("std");

pub const max_slots: usize = 4;
pub const event_payload_bytes: usize = 256;

pub const Event = extern struct {
    timestamp_ns: u64,
    device_id: u8,
    _reserved: u8 = 0,
    len: u16,
    data: [event_payload_bytes]u8 = @splat(0),
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

pub const Direction = enum { rx, tx };

pub const Line = struct {
    port_id: u8,
    timestamp_ns: u64,
    text: []u8,
    terminator: Terminator = .lf,
    // Assigned by Monitor.appendLine; stable identity for mouse selection.
    seq: u64 = 0,
    // .tx lines are commands we sent (echoed into the log), not device output.
    direction: Direction = .rx,
};

/// Escaped notation used in the UI and export (e.g. "\\r\\n"); "" for none.
pub fn terminatorNotation(t: Terminator) []const u8 {
    return switch (t) {
        .none => "",
        .lf => "\\n",
        .cr => "\\r",
        .crlf => "\\r\\n",
        .lfcr => "\\n\\r",
    };
}

pub const PortState = enum {
    closed,
    open,
    errored,
};

pub fn displayName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "\\\\.\\")) return name[4..];
    return name;
}
