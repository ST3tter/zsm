const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const monitor_mod = @import("monitor.zig");

const Monitor = monitor_mod.Monitor;

pub const App = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    monitor: Monitor = undefined,

    top_bar: TopBar = .{},
    bottom_bar: BottomBar = .{},
    hrule: HRule = .{},

    pub fn init(self: *App, allocator: std.mem.Allocator, io: std.Io) void {
        self.allocator = allocator;
        self.io = io;
        self.monitor.init(allocator, io);
        self.top_bar.app = self;
        self.bottom_bar.app = self;
    }

    pub fn deinit(self: *App) void {
        self.monitor.deinit();
    }

    pub fn widget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = App.typeErasedEventHandler,
            .drawFn = App.drawApp,
        };
    }

    fn innerWidget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = App.drawInner,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init, .focus_in => {
                try ctx.requestFocus(self.widget());
                try ctx.tick(33, self.widget());
                return;
            },
            .tick => {
                const data_changed = try self.monitor.drainAndUpdate();
                const health_changed = self.monitor.healthTick();
                if (data_changed or health_changed) ctx.redraw = true;
                try ctx.tick(33, self.widget());
                return;
            },
            .key_press => |key| {
                const consumed = self.monitor.handleKey(key, ctx) catch false;
                if (consumed) return;
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    fn drawApp(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *App = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;

        const labels = try arena.alloc(vxfw.Border.BorderLabel, 2);
        labels[0] = .{ .text = " zsm ", .alignment = .top_left };
        labels[1] = .{ .text = " v0.1.0 ", .alignment = .top_right };

        const border: vxfw.Border = .{
            .child = self.innerWidget(),
            .style = theme.border,
            .labels = labels,
        };

        const border_surf = try border.widget().draw(ctx);

        const children = try arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .surface = border_surf, .origin = .{ .row = 0, .col = 0 } };

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawInner(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *App = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;
        const max = ctx.max.size();

        if (max.height < 4 or max.width == 0) {
            return .{
                .size = max,
                .widget = self.innerWidget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        const body_h: u16 = max.height - 4;

        const single_line_ctx = ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = max.width, .height = 1 },
        );
        const body_ctx = ctx.withConstraints(
            .{ .width = max.width, .height = body_h },
            .{ .width = max.width, .height = body_h },
        );

        const top_surf = try self.top_bar.widget().draw(single_line_ctx);
        const hr1_surf = try self.hrule.widget().draw(single_line_ctx);
        const body_surf = try self.monitor.widget().draw(body_ctx);
        const hr2_surf = try self.hrule.widget().draw(single_line_ctx);
        const bot_surf = try self.bottom_bar.widget().draw(single_line_ctx);

        const children = try arena.alloc(vxfw.SubSurface, 5);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = top_surf };
        children[1] = .{ .origin = .{ .row = 1, .col = 0 }, .surface = hr1_surf };
        children[2] = .{ .origin = .{ .row = 2, .col = 0 }, .surface = body_surf };
        children[3] = .{ .origin = .{ .row = @intCast(max.height - 2), .col = 0 }, .surface = hr2_surf };
        children[4] = .{ .origin = .{ .row = @intCast(max.height - 1), .col = 0 }, .surface = bot_surf };

        return .{
            .size = max,
            .widget = self.innerWidget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const TopBar = struct {
    app: *App = undefined,

    pub fn widget(self: *TopBar) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TopBar = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        const display_text: []const u8 = blk: {
            if (self.app.monitor.getExportMessage()) |m| break :blk m.text;
            break :blk switch (self.app.monitor.statusSummary()) {
                .idle => "idle",
                .connected => "connected",
                .warning => "warning",
            };
        };
        const display_style: vaxis.Style = blk: {
            if (self.app.monitor.getExportMessage()) |m|
                break :blk if (m.is_error) theme.status_err else theme.status_ok;
            break :blk switch (self.app.monitor.statusSummary()) {
                .idle => theme.status_idle,
                .connected => theme.status_ok,
                .warning => theme.status_warn,
            };
        };

        const txt = vxfw.Text{
            .text = display_text,
            .style = display_style,
            .softwrap = false,
            .overflow = .clip,
        };
        const one_line: vxfw.DrawContext = ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = max.width, .height = 1 },
        );
        const txt_surf = try txt.draw(one_line);

        const txt_w: u16 = txt_surf.size.width;
        const col: i17 = if (max.width > txt_w)
            @intCast((max.width - txt_w) / 2)
        else
            0;

        const children = try arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = col }, .surface = txt_surf };

        return .{
            .size = .{ .width = max.width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const BottomBar = struct {
    app: *App = undefined,

    pub fn widget(self: *BottomBar) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *BottomBar = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        const hints = try self.app.monitor.keyHints(arena);
        const key_style: vaxis.Style = .{ .bold = true };

        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        for (hints, 0..) |hint, i| {
            if (i > 0) try spans.append(arena, .{ .text = "  │  ", .style = theme.subtitle });
            try spans.append(arena, .{ .text = hint.key, .style = key_style });
            try spans.append(arena, .{ .text = " ", .style = theme.subtitle });
            try spans.append(arena, .{ .text = hint.label, .style = theme.subtitle });
        }

        const rt = try arena.create(vxfw.RichText);
        rt.* = .{
            .text = spans.items,
            .softwrap = false,
            .overflow = .clip,
        };

        const surf = try rt.draw(ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = max.width, .height = 1 },
        ));

        const children = try arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 1 }, .surface = surf };

        return .{
            .size = .{ .width = max.width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const HRule = struct {
    pub fn widget(self: *HRule) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *HRule = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        if (max.width == 0) {
            return .{
                .size = .{ .width = 0, .height = 1 },
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        const dash = "─";
        const buf = try arena.alloc(u8, @as(usize, max.width) * dash.len);
        var i: usize = 0;
        while (i < max.width) : (i += 1) {
            @memcpy(buf[i * dash.len ..][0..dash.len], dash);
        }

        const t = vxfw.Text{
            .text = buf,
            .style = theme.border,
            .softwrap = false,
            .overflow = .clip,
        };
        const surf = try t.draw(ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = max.width, .height = 1 },
        ));

        const children = try arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = surf };

        return .{
            .size = .{ .width = max.width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
