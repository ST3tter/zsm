const std = @import("std");

pub fn isControlByte(b: u8) bool {
    return b < 0x20 or b == 0x7F;
}

pub fn escapeOne(arena: std.mem.Allocator, b: u8) ![]const u8 {
    return switch (b) {
        0x00 => "\\0",
        0x07 => "\\a",
        0x08 => "\\b",
        0x09 => "\\t",
        0x0A => "\\n",
        0x0B => "\\v",
        0x0C => "\\f",
        0x0D => "\\r",
        0x1B => "\\e",
        else => try std.fmt.allocPrint(arena, "\\x{x:0>2}", .{b}),
    };
}

pub fn byteRepr(arena: std.mem.Allocator, b: u8) ![]const u8 {
    if (isControlByte(b)) return escapeOne(arena, b);
    if (b >= 0x80) return try std.fmt.allocPrint(arena, "\\x{x:0>2}", .{b});
    const buf = try arena.alloc(u8, 1);
    buf[0] = b;
    return buf;
}

pub fn hexRepr(arena: std.mem.Allocator, b: u8) ![]const u8 {
    return try std.fmt.allocPrint(arena, "{x:0>2}", .{b});
}

pub fn padRight(arena: std.mem.Allocator, s: []const u8, width: u16) ![]const u8 {
    if (s.len >= width) return s;
    const buf = try arena.alloc(u8, width);
    @memcpy(buf[0..s.len], s);
    @memset(buf[s.len..], ' ');
    return buf;
}

pub fn formatTimestamp(arena: std.mem.Allocator, ts_ns: u64) ![]u8 {
    const ms_total: u64 = ts_ns / 1_000_000;
    const sec_total: u64 = ms_total / 1000;
    const ms = ms_total % 1000;
    const ep_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(sec_total) };
    const day_secs = ep_secs.getDaySeconds();
    return std.fmt.allocPrint(arena, "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}]", .{
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms,
    });
}

// Naive ISO 8601 (no timezone suffix). Same epoch math as formatTimestamp:
// the bytes are derived directly from the Unix timestamp without TZ conversion,
// so this matches what the UI displays.
pub fn formatIso8601(arena: std.mem.Allocator, ts_ns: u64) ![]u8 {
    const ms_total: u64 = ts_ns / 1_000_000;
    const sec_total: u64 = ms_total / 1000;
    const ms = ms_total % 1000;
    const ep_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(sec_total) };
    const day = ep_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = ep_secs.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        @as(u32, year_day.year),
        @as(u32, @intFromEnum(month_day.month)),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms,
    });
}
