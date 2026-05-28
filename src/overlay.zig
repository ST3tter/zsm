const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zig_serial = @import("serial");

const theme = @import("theme.zig");
const types = @import("types.zig");

pub const baud_rates = [_]u32{ 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600 };
const default_baud_idx: usize = 4;

pub const PortInfo = struct {
    file_name: []u8,
    display_name: []u8,
};

pub const KeyResult = enum {
    consumed,
    close,
    connect,
    disconnect,
    ignored,
};

pub const Overlay = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    ports: std.ArrayList(PortInfo) = .empty,
    cursor: usize = 0,
    baud_idx: usize = default_baud_idx,
    connected_slots: [types.max_slots]?[]u8 = .{ null, null, null, null },

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Overlay {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Overlay) void {
        self.clearPorts();
        self.ports.deinit(self.allocator);
        for (&self.connected_slots) |*slot| {
            if (slot.*) |s| self.allocator.free(s);
            slot.* = null;
        }
    }

    fn clearPorts(self: *Overlay) void {
        for (self.ports.items) |p| {
            self.allocator.free(p.file_name);
            self.allocator.free(p.display_name);
        }
        self.ports.clearRetainingCapacity();
    }

    pub fn refresh(self: *Overlay) !void {
        self.clearPorts();
        errdefer self.clearPorts();
        var it = zig_serial.list(self.io) catch return;
        while (try it.next()) |desc| {
            const fname = try self.allocator.dupe(u8, desc.file_name);
            errdefer self.allocator.free(fname);
            const dname = try self.allocator.dupe(u8, desc.display_name);
            errdefer self.allocator.free(dname);
            try self.ports.append(self.allocator, .{ .file_name = fname, .display_name = dname });
        }
        if (self.cursor >= self.ports.items.len) self.cursor = 0;
    }

    pub fn handleKey(self: *Overlay, key: vaxis.Key) KeyResult {
        if (key.matches(vaxis.Key.escape, .{})) return .close;
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            if (self.cursor > 0) self.cursor -= 1;
            return .consumed;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            if (self.cursor + 1 < self.ports.items.len) self.cursor += 1;
            return .consumed;
        }
        if (key.matches('b', .{})) {
            self.baud_idx = (self.baud_idx + 1) % baud_rates.len;
            return .consumed;
        }
        if (key.matches(vaxis.Key.enter, .{})) return .connect;
        if (key.matches('d', .{})) return .disconnect;
        return .ignored;
    }

    // Returned slice borrows from self.ports and is invalidated by the next
    // refresh() or deinit() call. Callers must consume or dupe it before
    // either runs.
    pub fn selectedFileName(self: *const Overlay) ?[]const u8 {
        if (self.ports.items.len == 0) return null;
        return self.ports.items[self.cursor].file_name;
    }

    pub fn selectedBaud(self: *const Overlay) u32 {
        return baud_rates[self.baud_idx];
    }

    pub fn setConnectedSlot(self: *Overlay, slot: u8, port_name: ?[]const u8) !void {
        if (self.connected_slots[slot]) |old| {
            self.allocator.free(old);
            self.connected_slots[slot] = null;
        }
        if (port_name) |name| {
            self.connected_slots[slot] = try self.allocator.dupe(u8, name);
        }
    }

    fn slotForFileName(self: *const Overlay, file_name: []const u8) ?u8 {
        for (self.connected_slots, 0..) |slot_name, i| {
            if (slot_name) |n| {
                if (std.mem.eql(u8, n, file_name)) return @intCast(i);
            }
        }
        return null;
    }

    pub fn cursorConnectedSlot(self: *const Overlay) ?u8 {
        if (self.cursor >= self.ports.items.len) return null;
        return self.slotForFileName(self.ports.items[self.cursor].file_name);
    }

    pub fn widget(self: *Overlay) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawFrame };
    }

    fn drawFrame(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        const inner_widget: vxfw.Widget = .{
            .userdata = self,
            .drawFn = drawInner,
        };

        const labels = try arena.alloc(vxfw.Border.BorderLabel, 1);
        labels[0] = .{ .text = " Open Port ", .alignment = .top_left };

        const border: vxfw.Border = .{
            .child = inner_widget,
            .style = theme.border,
            .labels = labels,
        };

        const ovw: u16 = @min(60, max.width -| 4);
        const ovh: u16 = @min(20, max.height -| 4);
        const ov_ctx = ctx.withConstraints(
            .{ .width = ovw, .height = ovh },
            .{ .width = ovw, .height = ovh },
        );
        const border_surf = try border.widget().draw(ov_ctx);

        const col_origin: i17 = if (max.width > border_surf.size.width)
            @intCast((max.width - border_surf.size.width) / 2)
        else
            0;
        const row_origin: i17 = if (max.height > border_surf.size.height)
            @intCast((max.height - border_surf.size.height) / 2)
        else
            0;

        const children = try arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = row_origin, .col = col_origin }, .surface = border_surf };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawInner(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Overlay = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;
        const col: u16 = 1;
        const inner_w: u16 = max.width -| col;

        var subs: std.ArrayList(vxfw.SubSurface) = .empty;
        const line_ctx = ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = inner_w, .height = 1 },
        );

        var row: u16 = 0;
        try pushLine(arena, &subs, "Available ports:", theme.title, row, col, line_ctx);
        row += 1;

        const list_top = row;
        const list_max = if (max.height > 8) max.height - 8 else 1;
        if (self.ports.items.len == 0) {
            try pushLine(arena, &subs, "  (no ports detected)", theme.subtitle, row, col, line_ctx);
            row += 1;
        } else {
            for (self.ports.items, 0..) |p, i| {
                if (row - list_top >= list_max) break;
                const marker: []const u8 = if (i == self.cursor) "> " else "  ";
                const style: vaxis.Style = if (i == self.cursor) theme.selected else theme.normal;
                const open_slot = self.slotForFileName(p.file_name);
                const status: []const u8 = if (open_slot) |s|
                    try std.fmt.allocPrint(arena, " [D{d}]", .{s})
                else
                    "";
                const line_text = try std.fmt.allocPrint(arena, "{s}{s:<10} {s}{s}", .{ marker, types.displayName(p.file_name), p.display_name, status });
                try pushLine(arena, &subs, line_text, style, row, col, line_ctx);
                row += 1;
            }
        }
        row += 1;

        const baud_text = try std.fmt.allocPrint(arena, "Baud: {d}", .{baud_rates[self.baud_idx]});
        try pushLine(arena, &subs, baud_text, theme.normal, row, col, line_ctx);
        row += 2;

        try pushLine(arena, &subs, "Connected:", theme.title, row, col, line_ctx);
        row += 1;
        for (self.connected_slots, 0..) |slot_name, i| {
            const conn_text = if (slot_name) |n|
                try std.fmt.allocPrint(arena, "  D{d} = {s}", .{ i, types.displayName(n) })
            else
                try std.fmt.allocPrint(arena, "  D{d} = (free)", .{i});
            try pushLine(arena, &subs, conn_text, theme.subtitle, row, col, line_ctx);
            row += 1;
        }

        const footer_row: u16 = if (max.height >= 1) max.height - 1 else 0;
        try pushLine(arena, &subs, "Enter:connect  d:disconnect  b:baud  Esc:done", theme.subtitle, footer_row, col, line_ctx);

        return .{
            .size = max,
            .widget = .{ .userdata = self, .drawFn = drawInner },
            .buffer = &.{},
            .children = subs.items,
        };
    }
};

fn pushLine(
    arena: std.mem.Allocator,
    subs: *std.ArrayList(vxfw.SubSurface),
    text: []const u8,
    style: vaxis.Style,
    row: u16,
    col: u16,
    line_ctx: vxfw.DrawContext,
) !void {
    const t = vxfw.Text{ .text = text, .style = style, .softwrap = false, .overflow = .clip };
    const surf = try t.draw(line_ctx);
    try subs.append(arena, .{ .origin = .{ .row = @intCast(row), .col = @intCast(col) }, .surface = surf });
}
