const std = @import("std");
const types = @import("types.zig");
const fmt = @import("fmt.zig");

const csv_eol = "\r\n";

/// Build a "zsm-export-YYYYMMDD-HHMMSS.csv" filename from a wall-clock ns
/// timestamp. The timestamp math is naive (no TZ conversion) so filename
/// hour-minute-second matches what the UI/export shows.
pub fn makeFilename(arena: std.mem.Allocator, ts_ns: u64) ![]const u8 {
    const sec_total: u64 = ts_ns / std.time.ns_per_s;
    const ep_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(sec_total) };
    const day = ep_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = ep_secs.getDaySeconds();
    return std.fmt.allocPrint(arena, "zsm-export-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.csv", .{
        @as(u32, year_day.year),
        @as(u32, @intFromEnum(month_day.month)),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Build the full CSV body in memory. Columns: timestamp, port, len, term,
/// string, hex. CRLF line endings (Excel-friendly). The string and hex columns
/// cover the line body only; the terminator bytes are reported via the term
/// column.
pub fn buildCsv(arena: std.mem.Allocator, lines: []const types.Line) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "timestamp,port,len,term,string,hex" ++ csv_eol);
    for (lines) |line| try appendRow(arena, &out, line);
    return out.items;
}

fn appendRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), line: types.Line) !void {
    const ts = try fmt.formatIso8601(arena, line.timestamp_ns);
    try out.appendSlice(arena, ts);
    try out.append(arena, ',');

    var num_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&num_buf, "{d}", .{line.port_id});
    try out.appendSlice(arena, port_str);
    try out.append(arena, ',');

    const len_str = try std.fmt.bufPrint(&num_buf, "{d}", .{line.text.len});
    try out.appendSlice(arena, len_str);
    try out.append(arena, ',');

    // term column — the same notation the UI uses (\n, \r, \r\n, \n\r)
    try out.append(arena, '"');
    try out.appendSlice(arena, terminatorNotation(line.terminator));
    try out.append(arena, '"');
    try out.append(arena, ',');

    // string column — control bytes and 0x80+ escaped, embedded " doubled
    try out.append(arena, '"');
    try appendStringField(arena, out, line.text);
    try out.append(arena, '"');
    try out.append(arena, ',');

    // hex column — space-separated 2-digit pairs (e.g. "48 65 6c 6c 6f")
    try out.append(arena, '"');
    try appendHexField(arena, out, line.text);
    try out.append(arena, '"');

    try out.appendSlice(arena, csv_eol);
}

fn terminatorNotation(t: types.Terminator) []const u8 {
    return switch (t) {
        .none => "",
        .lf => "\\n",
        .cr => "\\r",
        .crlf => "\\r\\n",
        .lfcr => "\\n\\r",
    };
}

fn appendStringField(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |b| {
        if (b == '"') {
            try out.appendSlice(arena, "\"\"");
        } else if (fmt.isControlByte(b)) {
            const esc = try fmt.escapeOne(arena, b);
            try out.appendSlice(arena, esc);
        } else if (b >= 0x80) {
            const esc = try std.fmt.allocPrint(arena, "\\x{x:0>2}", .{b});
            try out.appendSlice(arena, esc);
        } else {
            try out.append(arena, b);
        }
    }
}

fn appendHexField(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text, 0..) |b, i| {
        if (i > 0) try out.append(arena, ' ');
        const hex = try fmt.hexRepr(arena, b);
        try out.appendSlice(arena, hex);
    }
}

test "buildCsv header only when no lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const csv = try buildCsv(arena, &.{});
    try std.testing.expectEqualStrings("timestamp,port,len,term,string,hex\r\n", csv);
}

test "buildCsv escapes control bytes and quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = [_]u8{ 'H', 'i', 0x01, '"', 0xFF };
    const lines = [_]types.Line{.{
        .port_id = 2,
        .timestamp_ns = 0,
        .text = &text,
        .terminator = .crlf,
    }};

    const csv = try buildCsv(arena, &lines);
    // Header + one row. We just check the row substring matches.
    const expected_row = "1970-01-01T00:00:00.000,2,5,\"\\r\\n\",\"Hi\\x01\"\"\\xff\",\"48 69 01 22 ff\"\r\n";
    try std.testing.expect(std.mem.indexOf(u8, csv, expected_row) != null);
}
