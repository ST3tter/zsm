const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const types = @import("types.zig");
const fmt = @import("fmt.zig");

const inspector_min_body_w: u16 = 16;

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
    try pushBodySpans(arena, &spans, line.text);
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
    try buildHexSpans(arena, &spans, line.text);
    const term_bytes = types.terminatorBytes(line.terminator);
    if (line.text.len > 0 and term_bytes.len > 0) {
        try spans.append(arena, .{ .text = " ", .style = theme.subtitle });
    }
    try buildHexSpans(arena, &spans, term_bytes);

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
    try pushBodySpans(arena, &left_spans, line.text);
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
    try buildHexSpans(arena, &right_spans, line.text);
    const term_bytes = types.terminatorBytes(line.terminator);
    if (line.text.len > 0 and term_bytes.len > 0) {
        try right_spans.append(arena, .{ .text = " ", .style = theme.subtitle });
    }
    try buildHexSpans(arena, &right_spans, term_bytes);

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
) !void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!fmt.isControlByte(text[i])) continue;
        if (i > run_start) {
            try list.append(arena, .{
                .text = text[run_start..i],
                .style = theme.normal,
            });
        }
        const esc = try fmt.escapeOne(arena, text[i]);
        try list.append(arena, .{ .text = esc, .style = theme.subtitle });
        run_start = i + 1;
    }
    if (text.len > run_start) {
        try list.append(arena, .{
            .text = text[run_start..],
            .style = theme.normal,
        });
    }
}

fn buildHexSpans(
    arena: std.mem.Allocator,
    list: *std.ArrayList(vxfw.RichText.TextSpan),
    text: []const u8,
) !void {
    for (text, 0..) |b, i| {
        if (i > 0) {
            try list.append(arena, .{ .text = " ", .style = theme.subtitle });
        }
        const hex = try fmt.hexRepr(arena, b);
        const style: vaxis.Style = if (fmt.isControlByte(b)) theme.subtitle else theme.normal;
        try list.append(arena, .{ .text = hex, .style = style });
    }
}
