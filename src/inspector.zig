const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const types = @import("types.zig");
const fmt = @import("fmt.zig");

pub const max_pairs: u16 = 3;

const ByteCell = struct {
    char_repr: []const u8,
    hex_repr: []const u8,
    col_w: u16,
    is_control: bool,
};

const RowPlan = struct {
    cells: []const ByteCell,
};

/// Height in rows the inspector pane will occupy for `line` at the given width,
/// or 0 if it would be empty.
pub fn computeHeight(arena: std.mem.Allocator, line: types.Line, max_width: u16) std.mem.Allocator.Error!u16 {
    if (max_width == 0) return 0;

    const term_bytes = types.terminatorBytes(line.terminator);
    const total = line.text.len + term_bytes.len;
    if (total == 0) return 0;

    const all_bytes = try arena.alloc(u8, total);
    @memcpy(all_bytes[0..line.text.len], line.text);
    @memcpy(all_bytes[line.text.len..], term_bytes);

    const rows = try packBytes(arena, all_bytes, max_width -| 1);
    if (rows.len == 0) return 0;

    const num_pairs: u16 = @intCast(@min(rows.len, max_pairs));
    return 1 + 2 * num_pairs; // label + char/hex pairs
}

/// Render the inspector pane for `line` into the given draw context. Returns
/// an empty surface (zero children) if there is nothing to show.
pub fn draw(
    ctx: vxfw.DrawContext,
    line: types.Line,
    widget: vxfw.Widget,
) std.mem.Allocator.Error!vxfw.Surface {
    const max = ctx.max.size();
    const arena = ctx.arena;

    const term_bytes = types.terminatorBytes(line.terminator);
    const total = line.text.len + term_bytes.len;
    if (total == 0) return vxfw.Surface.empty(widget);

    const all_bytes = try arena.alloc(u8, total);
    @memcpy(all_bytes[0..line.text.len], line.text);
    @memcpy(all_bytes[line.text.len..], term_bytes);

    const rows = try packBytes(arena, all_bytes, max.width -| 1);
    const num_pairs: u16 = @intCast(@min(rows.len, max_pairs));
    const truncated = rows.len > max_pairs;

    var children: std.ArrayList(vxfw.SubSurface) = .empty;

    // Label row
    const ts_text = try fmt.formatTimestamp(arena, line.timestamp_ns);
    const label_text = try std.fmt.allocPrint(arena, " D{d} @ {s}  ({d} bytes)", .{ line.port_id, ts_text, total });
    const label_spans = try arena.alloc(vxfw.RichText.TextSpan, 1);
    label_spans[0] = .{ .text = label_text, .style = theme.subtitle };
    const label_rt = try arena.create(vxfw.RichText);
    label_rt.* = .{
        .text = label_spans,
        .softwrap = false,
        .overflow = .clip,
        .width_basis = .parent,
    };
    const label_surf = try label_rt.draw(ctx.withConstraints(
        .{ .width = max.width, .height = 1 },
        .{ .width = max.width, .height = 1 },
    ));
    try children.append(arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = label_surf });

    // Char + hex rows
    var row_offset: u16 = 1;
    for (rows[0..num_pairs], 0..) |row, idx| {
        const is_last_truncated = truncated and idx == num_pairs - 1;

        var char_spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        var hex_spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;

        try char_spans.append(arena, .{ .text = " ", .style = theme.subtitle });
        try hex_spans.append(arena, .{ .text = " ", .style = theme.subtitle });

        for (row.cells) |cell| {
            const char_padded = try fmt.padRight(arena, cell.char_repr, cell.col_w);
            const hex_padded = try fmt.padRight(arena, cell.hex_repr, cell.col_w);
            const ch_style: vaxis.Style = if (cell.is_control) theme.subtitle else theme.normal;
            try char_spans.append(arena, .{ .text = char_padded, .style = ch_style });
            try hex_spans.append(arena, .{ .text = hex_padded, .style = theme.subtitle });
        }

        if (is_last_truncated) {
            try char_spans.append(arena, .{ .text = "…", .style = theme.subtitle });
            try hex_spans.append(arena, .{ .text = "…", .style = theme.subtitle });
        }

        const char_rt = try arena.create(vxfw.RichText);
        char_rt.* = .{
            .text = char_spans.items,
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };
        const char_surf = try char_rt.draw(ctx.withConstraints(
            .{ .width = max.width, .height = 1 },
            .{ .width = max.width, .height = 1 },
        ));

        const hex_rt = try arena.create(vxfw.RichText);
        hex_rt.* = .{
            .text = hex_spans.items,
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };
        const hex_surf = try hex_rt.draw(ctx.withConstraints(
            .{ .width = max.width, .height = 1 },
            .{ .width = max.width, .height = 1 },
        ));

        try children.append(arena, .{ .origin = .{ .row = @intCast(row_offset), .col = 0 }, .surface = char_surf });
        try children.append(arena, .{ .origin = .{ .row = @intCast(row_offset + 1), .col = 0 }, .surface = hex_surf });
        row_offset += 2;
    }

    return .{
        .size = .{ .width = max.width, .height = row_offset },
        .widget = widget,
        .buffer = &.{},
        .children = children.items,
    };
}

fn packBytes(
    arena: std.mem.Allocator,
    text: []const u8,
    max_width: u16,
) ![]const RowPlan {
    if (max_width == 0 or text.len == 0) return &.{};

    var cells: std.ArrayList(ByteCell) = .empty;
    try cells.ensureTotalCapacity(arena, text.len);
    for (text) |b| {
        const ch = try fmt.byteRepr(arena, b);
        const hex = try fmt.hexRepr(arena, b);
        const ch_w: u16 = @intCast(ch.len);
        const col_w: u16 = @max(ch_w, 2) + 1;
        try cells.append(arena, .{
            .char_repr = ch,
            .hex_repr = hex,
            .col_w = col_w,
            .is_control = fmt.isControlByte(b),
        });
    }

    var rows: std.ArrayList(RowPlan) = .empty;
    var start: usize = 0;
    var width_acc: u16 = 0;
    for (cells.items, 0..) |cell, i| {
        if (width_acc != 0 and width_acc + cell.col_w > max_width) {
            try rows.append(arena, .{ .cells = cells.items[start..i] });
            start = i;
            width_acc = 0;
        }
        width_acc += cell.col_w;
    }
    if (start < cells.items.len) {
        try rows.append(arena, .{ .cells = cells.items[start..] });
    }
    return rows.items;
}

test "packBytes single byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try packBytes(arena, "H", 10);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 1), rows[0].cells.len);
    try std.testing.expectEqualStrings("H", rows[0].cells[0].char_repr);
    try std.testing.expectEqualStrings("48", rows[0].cells[0].hex_repr);
    try std.testing.expectEqual(@as(u16, 3), rows[0].cells[0].col_w);
}

test "packBytes exact fit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // "Hi!" — 3 printable bytes, each 3 cells wide, total 9
    const rows = try packBytes(arena, "Hi!", 9);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].cells.len);
}

test "packBytes overflow wraps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 4 bytes of 3 cells each = 12; max 9 → wraps after 3
    const rows = try packBytes(arena, "Hi!?", 9);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].cells.len);
    try std.testing.expectEqual(@as(usize, 1), rows[1].cells.len);
}

test "packBytes mixed printable and wide escape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 'A' (3 cells), 0x01 (\x01 = 4 chars → 5 cells), 'B' (3 cells). Total 11.
    // max 10 → row 1: A + 0x01 (= 8 cells); row 2: B (= 3 cells)
    const rows = try packBytes(arena, "A\x01B", 10);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("A", rows[0].cells[0].char_repr);
    try std.testing.expectEqualStrings("\\x01", rows[0].cells[1].char_repr);
    try std.testing.expectEqualStrings("B", rows[1].cells[0].char_repr);
    try std.testing.expectEqual(@as(u16, 5), rows[0].cells[1].col_w);
}

test "packBytes oversized single byte still fits its own row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 0x01 alone needs 5 cells. max=3 — single byte still occupies its own row.
    const rows = try packBytes(arena, "\x01", 3);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 1), rows[0].cells.len);
}
