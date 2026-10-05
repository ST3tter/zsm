const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// A selection endpoint: a line, identified by its stable sequence number so
/// the selection survives scrolling, eviction and reordering, plus a cell
/// column within that line's rendered row.
pub const Point = struct {
    seq: u64,
    col: u16,
};

/// Copy a single-row surface tree into `out` (one Cell per column), placing
/// children at their origins the same way Surface.render does.
pub fn flattenRow(surf: vxfw.Surface, col_off: i32, out: []vaxis.Cell) void {
    if (surf.size.height > 0 and surf.buffer.len > 0) {
        for (0..surf.size.width) |c| {
            const dst = col_off + @as(i32, @intCast(c));
            if (dst < 0 or dst >= out.len) continue;
            out[@intCast(dst)] = surf.buffer[c];
        }
    }
    for (surf.children) |child| {
        if (child.origin.row != 0) continue;
        flattenRow(child.surface, col_off + child.origin.col, out);
    }
}

/// Reverse-video every written cell of a single-row surface tree whose
/// column falls within [from, to]. Unwritten (default) cells are left alone
/// so the highlight ends where the text ends.
pub fn highlightRow(surf: vxfw.Surface, col_off: i32, from: u16, to: u16) void {
    if (surf.size.height > 0 and surf.buffer.len > 0) {
        for (surf.buffer[0..surf.size.width], 0..) |*cell, c| {
            const col = col_off + @as(i32, @intCast(c));
            if (col < from or col > to) continue;
            if (cell.default) continue;
            cell.style.reverse = true;
        }
    }
    for (surf.children) |child| {
        if (child.origin.row != 0) continue;
        highlightRow(child.surface, col_off + child.origin.col, from, to);
    }
}

/// Append the text of cells [from, to] to `out`. Wide graphemes are emitted
/// once (their trailing cells are skipped), unwritten cells become spaces,
/// and trailing spaces are trimmed.
pub fn appendCellText(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cells: []const vaxis.Cell,
    from: u16,
    to: u16,
) !void {
    if (cells.len == 0 or from >= cells.len) return;
    const start_len = out.items.len;
    const last: usize = @min(to, cells.len - 1);
    var skip: usize = 0;
    var c: usize = from;
    while (c <= last) : (c += 1) {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        const cell = cells[c];
        if (cell.default) {
            try out.append(gpa, ' ');
            continue;
        }
        try out.appendSlice(gpa, cell.char.grapheme);
        if (cell.char.width > 1) skip = cell.char.width - 1;
    }
    var end = out.items.len;
    while (end > start_len and out.items[end - 1] == ' ') end -= 1;
    out.shrinkRetainingCapacity(end);
}

fn testCell(g: []const u8, w: u8) vaxis.Cell {
    return .{ .char = .{ .grapheme = g, .width = w } };
}

test "appendCellText trims trailing blanks and honors range" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const cells = [_]vaxis.Cell{
        testCell("a", 1), testCell("b", 1), testCell(" ", 1), testCell("c", 1),
        .{ .default = true }, .{ .default = true },
    };
    try appendCellText(gpa, &out, &cells, 1, 5);
    try std.testing.expectEqualStrings("b c", out.items);
}

test "appendCellText emits wide graphemes once" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const cells = [_]vaxis.Cell{
        testCell("x", 1), testCell("日", 2), .{ .default = true }, testCell("y", 1),
    };
    try appendCellText(gpa, &out, &cells, 0, 3);
    try std.testing.expectEqualStrings("x日y", out.items);
}

test "flattenRow places children at their origins" {
    var a_buf = [_]vaxis.Cell{ testCell("a", 1), testCell("b", 1) };
    var c_buf = [_]vaxis.Cell{testCell("c", 1)};
    const dummy: vxfw.Widget = .{ .userdata = undefined, .drawFn = undefined };
    var children = [_]vxfw.SubSurface{
        .{ .origin = .{ .row = 0, .col = 0 }, .surface = .{
            .size = .{ .width = 2, .height = 1 },
            .widget = dummy,
            .buffer = &a_buf,
            .children = &.{},
        } },
        .{ .origin = .{ .row = 0, .col = 3 }, .surface = .{
            .size = .{ .width = 1, .height = 1 },
            .widget = dummy,
            .buffer = &c_buf,
            .children = &.{},
        } },
    };
    const root: vxfw.Surface = .{
        .size = .{ .width = 4, .height = 1 },
        .widget = dummy,
        .buffer = &.{},
        .children = &children,
    };
    var out: [4]vaxis.Cell = @splat(.{ .default = true });
    flattenRow(root, 0, &out);
    try std.testing.expectEqualStrings("a", out[0].char.grapheme);
    try std.testing.expectEqualStrings("b", out[1].char.grapheme);
    try std.testing.expect(out[2].default);
    try std.testing.expectEqualStrings("c", out[3].char.grapheme);

    highlightRow(root, 0, 1, 3);
    try std.testing.expect(!a_buf[0].style.reverse);
    try std.testing.expect(a_buf[1].style.reverse);
    try std.testing.expect(c_buf[0].style.reverse);
}
