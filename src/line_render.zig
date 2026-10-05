const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const types = @import("types.zig");
const fmt = @import("fmt.zig");

const inspector_min_body_w: u16 = 16;

/// Device tag between timestamp and body, e.g. " [D0] ". Identical for sent
/// and received lines so columns line up; TX lines get pushTxMarker instead.
pub fn devLabel(arena: std.mem.Allocator, line: types.Line) ![]const u8 {
    return arena.print(" [D{d}] ", .{line.port_id});
}

// Leading "→ " on commands we sent, in the TX accent.
fn pushTxMarker(arena: std.mem.Allocator, list: *std.ArrayList(vxfw.RichText.TextSpan), line: types.Line) !void {
    if (line.direction == .tx) try list.append(arena, .{ .text = "→ ", .style = theme.tx });
}

fn bodyStyle(line: types.Line) vaxis.Style {
    return if (line.direction == .tx) theme.tx else theme.normal;
}

pub fn drawString(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    line: types.Line,
    ts_text: []const u8,
    dev_text: []const u8,
    term_text: []const u8,
    dev_style: vaxis.Style,
) std.mem.Allocator.Error!vxfw.Surface {
    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = ts_text, .style = theme.subtitle });
    try spans.append(arena, .{ .text = dev_text, .style = dev_style });
    try pushTxMarker(arena, &spans, line);
    try pushBodySpans(arena, &spans, line.text, bodyStyle(line));
    try spans.append(arena, .{ .text = term_text, .style = theme.subtitle });

    const rt = try arena.create(vxfw.RichText);
    rt.* = .{
        .text = spans.items,
        .softwrap = false,
        .overflow = .clip,
        .width_basis = .parent,
    };
    return rt.draw(ctx);
}

pub fn drawHexOnly(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    line: types.Line,
    ts_text: []const u8,
    dev_text: []const u8,
    dev_style: vaxis.Style,
) std.mem.Allocator.Error!vxfw.Surface {
    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = ts_text, .style = theme.subtitle });
    try spans.append(arena, .{ .text = dev_text, .style = dev_style });
    try pushTxMarker(arena, &spans, line);
    try buildHexSpans(arena, &spans, line.text, bodyStyle(line));
    const term_bytes = types.terminatorBytes(line.terminator);
    if (line.text.len > 0 and term_bytes.len > 0) {
        try spans.append(arena, .{ .text = " ", .style = theme.subtitle });
    }
    try buildHexSpans(arena, &spans, term_bytes, theme.subtitle);

    const rt = try arena.create(vxfw.RichText);
    rt.* = .{
        .text = spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    return rt.draw(ctx);
}

pub fn drawStringAndHex(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    line: types.Line,
    ts_text: []const u8,
    dev_text: []const u8,
    term_text: []const u8,
    dev_style: vaxis.Style,
    line_widget: vxfw.Widget,
) std.mem.Allocator.Error!vxfw.Surface {
    const max_w = ctx.max.width orelse 0;
    const ts_w: u16 = @intCast(ctx.stringWidth(ts_text));
    const dev_w: u16 = @intCast(ctx.stringWidth(dev_text));
    const prefix_w: u16 = ts_w + dev_w;
    const sep_w: u16 = 3; // " │ "

    if (max_w < prefix_w + sep_w + inspector_min_body_w) {
        return drawString(arena, ctx, line, ts_text, dev_text, term_text, dev_style);
    }

    const remaining = max_w - prefix_w - sep_w;
    const left_body_w = remaining / 2;
    const right_w = remaining - left_body_w;
    const left_w = prefix_w + left_body_w;

    var left_spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try left_spans.append(arena, .{ .text = ts_text, .style = theme.subtitle });
    try left_spans.append(arena, .{ .text = dev_text, .style = dev_style });
    try pushTxMarker(arena, &left_spans, line);
    try pushBodySpans(arena, &left_spans, line.text, bodyStyle(line));
    try left_spans.append(arena, .{ .text = term_text, .style = theme.subtitle });

    const left_rt = try arena.create(vxfw.RichText);
    left_rt.* = .{
        .text = left_spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    const left_surf = try left_rt.draw(ctx.withConstraints(
        .{ .width = left_w, .height = 1 },
        .{ .width = left_w, .height = 1 },
    ));

    var right_spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try buildHexSpans(arena, &right_spans, line.text, bodyStyle(line));
    const term_bytes = types.terminatorBytes(line.terminator);
    if (line.text.len > 0 and term_bytes.len > 0) {
        try right_spans.append(arena, .{ .text = " ", .style = theme.subtitle });
    }
    try buildHexSpans(arena, &right_spans, term_bytes, theme.subtitle);

    const right_rt = try arena.create(vxfw.RichText);
    right_rt.* = .{
        .text = right_spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
    };
    const right_surf = try right_rt.draw(ctx.withConstraints(
        .{ .width = right_w, .height = 1 },
        .{ .width = right_w, .height = 1 },
    ));

    const sep_spans = try arena.alloc(vxfw.RichText.TextSpan, 1);
    sep_spans[0] = .{ .text = " │ ", .style = theme.subtitle };
    const sep_rt = try arena.create(vxfw.RichText);
    sep_rt.* = .{
        .text = sep_spans,
        .softwrap = false,
        .overflow = .clip,
        .width_basis = .parent,
    };
    const sep_surf = try sep_rt.draw(ctx.withConstraints(
        .{ .width = sep_w, .height = 1 },
        .{ .width = sep_w, .height = 1 },
    ));

    const children = try arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = left_surf };
    children[1] = .{ .origin = .{ .row = 0, .col = @intCast(left_w) }, .surface = sep_surf };
    children[2] = .{ .origin = .{ .row = 0, .col = @intCast(left_w + sep_w) }, .surface = right_surf };

    return .{
        .size = .{ .width = max_w, .height = 1 },
        .widget = line_widget,
        .buffer = &.{},
        .children = children,
    };
}

fn pushBodySpans(
    arena: std.mem.Allocator,
    list: *std.ArrayList(vxfw.RichText.TextSpan),
    text: []const u8,
    body_style: vaxis.Style,
) !void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!fmt.isControlByte(text[i])) continue;
        if (i > run_start) {
            try list.append(arena, .{
                .text = text[run_start..i],
                .style = body_style,
            });
        }
        const esc = try fmt.escapeOne(arena, text[i]);
        try list.append(arena, .{ .text = esc, .style = theme.subtitle });
        run_start = i + 1;
    }
    if (text.len > run_start) {
        try list.append(arena, .{
            .text = text[run_start..],
            .style = body_style,
        });
    }
}

fn buildHexSpans(
    arena: std.mem.Allocator,
    list: *std.ArrayList(vxfw.RichText.TextSpan),
    text: []const u8,
    body_style: vaxis.Style,
) !void {
    for (text, 0..) |b, i| {
        if (i > 0) {
            try list.append(arena, .{ .text = " ", .style = theme.subtitle });
        }
        const hex = try fmt.hexRepr(arena, b);
        const style: vaxis.Style = if (fmt.isControlByte(b)) theme.subtitle else body_style;
        try list.append(arena, .{ .text = hex, .style = style });
    }
}

const selection = @import("selection.zig");

fn renderedText(arena: std.mem.Allocator, surf: vxfw.Surface, width: u16) ![]const u8 {
    const cells = try arena.alloc(vaxis.Cell, width);
    @memset(cells, .{ .default = true });
    selection.flattenRow(surf, 0, cells);
    var out: std.ArrayList(u8) = .empty;
    try selection.appendCellText(arena, &out, cells, 0, width - 1);
    return out.items;
}

fn testCtx(arena: std.mem.Allocator, width: u16) vxfw.DrawContext {
    return .{
        .arena = arena,
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = width, .height = null },
        .cell_size = .{},
    };
}

test "devLabel is the same width for TX and RX" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = "x".*;
    const rx: types.Line = .{ .port_id = 2, .timestamp_ns = 0, .text = &text };
    const tx: types.Line = .{ .port_id = 0, .timestamp_ns = 0, .text = &text, .direction = .tx };
    try std.testing.expectEqualStrings(" [D2] ", try devLabel(arena, rx));
    try std.testing.expectEqualStrings(" [D0] ", try devLabel(arena, tx));
}

test "TX arrow is drawn in the accent style" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = "AT".*;
    const line: types.Line = .{ .port_id = 0, .timestamp_ns = 0, .text = &text, .terminator = .none, .direction = .tx };
    const dev_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .bold = true };
    const surf = try drawString(arena, testCtx(arena, 30), line, "00:00:00.000", try devLabel(arena, line), "", dev_style);
    const cells = try arena.alloc(vaxis.Cell, 30);
    @memset(cells, .{ .default = true });
    selection.flattenRow(surf, 0, cells);
    // 12-cell timestamp + 6-cell " [D0] " label, then the arrow.
    try std.testing.expectEqualStrings("→", cells[18].char.grapheme);
    try std.testing.expectEqual(theme.tx.fg, cells[18].style.fg);
}

fn separatorCol(arena: std.mem.Allocator, line: types.Line, width: u16) !usize {
    const surf = try drawStringAndHex(arena, testCtx(arena, width), line, "00:00:00.000", try devLabel(arena, line), types.terminatorNotation(line.terminator), .{}, undefined);
    const cells = try arena.alloc(vaxis.Cell, width);
    @memset(cells, .{ .default = true });
    selection.flattenRow(surf, 0, cells);
    for (cells, 0..) |c, i| {
        if (!c.default and std.mem.eql(u8, c.char.grapheme, "│")) return i;
    }
    return error.NoSeparator;
}

test "string+hex separator lines up for TX and RX rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = "AT".*;
    const rx: types.Line = .{ .port_id = 0, .timestamp_ns = 0, .text = &text };
    const tx: types.Line = .{ .port_id = 0, .timestamp_ns = 0, .text = &text, .direction = .tx };
    try std.testing.expectEqual(try separatorCol(arena, rx, 100), try separatorCol(arena, tx, 100));
}

test "TX line renders with marker and accent body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = "AT+GMR".*;
    const line: types.Line = .{
        .port_id = 0,
        .timestamp_ns = 0,
        .text = &text,
        .terminator = .crlf,
        .direction = .tx,
    };
    const dev = try devLabel(arena, line);
    const surf = try drawString(arena, testCtx(arena, 40), line, "00:00:00.000", dev, types.terminatorNotation(line.terminator), .{});
    try std.testing.expectEqualStrings("00:00:00.000 [D0] → AT+GMR\\r\\n", try renderedText(arena, surf, 40));

    // 'A' sits after the 12-cell timestamp and the 8-cell " [D0] → " label.
    const cells = try arena.alloc(vaxis.Cell, 40);
    @memset(cells, .{ .default = true });
    selection.flattenRow(surf, 0, cells);
    try std.testing.expectEqualStrings("A", cells[20].char.grapheme);
    try std.testing.expectEqual(theme.tx.fg, cells[20].style.fg);
}

test "RX line body keeps the normal style" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text = "OK".*;
    const line: types.Line = .{ .port_id = 0, .timestamp_ns = 0, .text = &text, .terminator = .none };
    const dev = try devLabel(arena, line);
    const surf = try drawString(arena, testCtx(arena, 30), line, "00:00:00.000", dev, "", .{});
    const cells = try arena.alloc(vaxis.Cell, 30);
    @memset(cells, .{ .default = true });
    selection.flattenRow(surf, 0, cells);
    // 12-cell timestamp + 6-cell " [D0] " label.
    try std.testing.expectEqualStrings("O", cells[18].char.grapheme);
    try std.testing.expectEqual(theme.normal.fg, cells[18].style.fg);
}
