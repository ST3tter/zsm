const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const zig_serial = @import("serial");

const theme = @import("theme.zig");
const types = @import("types.zig");
const line_buf = @import("line_buf.zig");
const port_mod = @import("port.zig");
const overlay_mod = @import("overlay.zig");
const fmt = @import("fmt.zig");
const inspector = @import("inspector.zig");
const line_render = @import("line_render.zig");
const exp = @import("export.zig");

pub const max_history: usize = 10000;

pub const DisplayMode = enum { string, string_and_hex, hex_only };

pub const Status = enum { idle, connected, warning };

pub const KeyHint = struct {
    key: []const u8,
    label: []const u8,
};

pub const port_colors = [_]vaxis.Color{
    .{ .rgb = .{ 120, 220, 255 } },
    .{ .rgb = .{ 255, 180, 60 } },
    .{ .rgb = .{ 120, 220, 130 } },
    .{ .rgb = .{ 240, 130, 220 } },
};

const LineEntry = struct {
    monitor: *Monitor,
    slot_idx: usize,
};

pub const Monitor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    ports: [types.max_slots]?*port_mod.Port = .{ null, null, null, null },
    rings: [types.max_slots]port_mod.EventRing,
    assemblers: [types.max_slots]line_buf.LineBuffer,

    // Snapshot of each slot's dropped counter at the last `c` (or 0 since open).
    // Warning triggers when current dropped > baseline.
    dropped_baseline: [types.max_slots]u64 = .{ 0, 0, 0, 0 },
    // Set on `c` if the slot is currently errored; suppresses re-warning for
    // that already-acknowledged failure. Reset on (dis)connect.
    errored_acked: [types.max_slots]bool = .{ false, false, false, false },

    // Counter for healthTick's periodic re-enumeration. Wraps freely.
    health_counter: u32 = 0,

    lines: [max_history]types.Line = undefined,
    lines_head: usize = 0,
    lines_count: usize = 0,

    line_entries: [max_history]LineEntry = undefined,
    line_widgets: [max_history]vxfw.Widget = undefined,

    list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },
    overlay: overlay_mod.Overlay,
    overlay_open: bool = false,
    follow: bool = true,
    display_mode: DisplayMode = .string,

    // Transient feedback after pressing `e`. Shown in the TopBar in place of
    // the status text for ~3s. Fixed buffer — no allocation.
    export_message_buf: [128]u8 = undefined,
    export_message_len: usize = 0,
    export_message_until_ns: u64 = 0,
    export_message_is_error: bool = false,

    pub fn init(self: *Monitor, allocator: std.mem.Allocator, io: std.Io) void {
        self.allocator = allocator;
        self.io = io;
        self.ports = .{ null, null, null, null };
        self.rings = .{ .{}, .{}, .{}, .{} };
        self.assemblers = .{
            line_buf.LineBuffer.init(allocator, 0),
            line_buf.LineBuffer.init(allocator, 1),
            line_buf.LineBuffer.init(allocator, 2),
            line_buf.LineBuffer.init(allocator, 3),
        };
        self.dropped_baseline = .{ 0, 0, 0, 0 };
        self.errored_acked = .{ false, false, false, false };
        self.health_counter = 0;
        self.export_message_len = 0;
        self.export_message_until_ns = 0;
        self.export_message_is_error = false;
        self.lines_head = 0;
        self.lines_count = 0;
        self.overlay = overlay_mod.Overlay.init(allocator, io);
        self.overlay_open = false;
        self.follow = true;
        self.display_mode = .string;

        for (0..max_history) |i| {
            self.line_entries[i] = .{ .monitor = self, .slot_idx = i };
            self.line_widgets[i] = .{ .userdata = &self.line_entries[i], .drawFn = drawLineFn };
        }

        self.list_view = .{
            .children = .{ .slice = self.line_widgets[0..0] },
            .draw_cursor = true,
        };
    }

    pub fn deinit(self: *Monitor) void {
        for (&self.ports) |*slot| {
            if (slot.*) |p| {
                p.close();
                slot.* = null;
            }
        }
        for (&self.assemblers) |*asm_buf| asm_buf.deinit();
        for (0..self.lines_count) |i| {
            const idx = (self.lines_head + i) % max_history;
            self.allocator.free(self.lines[idx].text);
        }
        self.lines_count = 0;
        self.overlay.deinit();
    }

    pub fn widget(self: *Monitor) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawMain };
    }

    pub fn anyConnected(self: *const Monitor) bool {
        for (self.ports) |p| if (p != null) return true;
        return false;
    }

    pub fn statusSummary(self: *const Monitor) Status {
        var any_open = false;
        for (self.ports, 0..) |maybe_port, i| {
            const p = maybe_port orelse continue;
            any_open = true;
            if (p.getState() == .errored and !self.errored_acked[i]) return .warning;
            if (p.droppedCount() > self.dropped_baseline[i]) return .warning;
        }
        return if (any_open) .connected else .idle;
    }

    pub const ExportMessage = struct { text: []const u8, is_error: bool };

    pub fn getExportMessage(self: *const Monitor) ?ExportMessage {
        if (self.export_message_len == 0) return null;
        const now: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
        if (now >= self.export_message_until_ns) return null;
        return .{
            .text = self.export_message_buf[0..self.export_message_len],
            .is_error = self.export_message_is_error,
        };
    }

    fn setExportMessage(self: *Monitor, msg: []const u8, is_error: bool) void {
        const len = @min(msg.len, self.export_message_buf.len);
        @memcpy(self.export_message_buf[0..len], msg[0..len]);
        self.export_message_len = len;
        self.export_message_is_error = is_error;
        const now: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
        self.export_message_until_ns = now + 3 * std.time.ns_per_s;
    }

    // Export the current view to a CSV file in cwd. All formatting is in
    // export.zig; this method just snapshots lines into an arena, builds the
    // CSV in memory, and writes the whole buffer in one go. On any failure
    // a transient error message is shown in the TopBar.
    pub fn runExport(self: *Monitor) void {
        if (self.lines_count == 0) {
            self.setExportMessage("export: nothing to export", true);
            return;
        }

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ns: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
        const filename = exp.makeFilename(arena, now_ns) catch {
            self.setExportMessage("export: out of memory", true);
            return;
        };

        const snapshot = arena.alloc(types.Line, self.lines_count) catch {
            self.setExportMessage("export: out of memory", true);
            return;
        };
        for (0..self.lines_count) |i| snapshot[i] = self.lineAt(i).?;

        const csv = exp.buildCsv(arena, snapshot) catch {
            self.setExportMessage("export: out of memory", true);
            return;
        };

        const cwd = std.Io.Dir.cwd();
        const file = cwd.createFile(self.io, filename, .{ .read = false, .truncate = true }) catch |err| {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "export failed: {s}", .{@errorName(err)}) catch "export failed";
            self.setExportMessage(m, true);
            return;
        };
        defer file.close(self.io);

        file.writePositionalAll(self.io, csv, 0) catch |err| {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "export failed: {s}", .{@errorName(err)}) catch "export failed";
            self.setExportMessage(m, true);
            return;
        };

        var buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "exported {d} lines → {s}", .{ self.lines_count, filename }) catch "export complete";
        self.setExportMessage(m, false);
    }

    // Period (in ticks) for the slow enumeration pass. The app ticks at 33ms,
    // so 30 ≈ 1 second between OS-level port-list polls.
    const health_enum_period: u32 = 30;

    // Auto-disconnect dead slots so the UI reflects unplugs without user
    // action. Two paths: (1) fast — react to reader-set .errored on the next
    // tick; (2) slow — every ~1s re-enumerate available ports and disconnect
    // any open slot whose name has vanished (catches the Windows case where
    // ReadFile keeps returning 0 bytes on an unplugged USB-serial).
    pub fn healthTick(self: *Monitor) bool {
        self.health_counter +%= 1;

        var changed = false;
        for (0..self.ports.len) |i| {
            const p = self.ports[i] orelse continue;
            if (p.getState() == .errored) {
                self.disconnectSlot(@intCast(i));
                changed = true;
            }
        }

        if (self.health_counter % health_enum_period == 0) {
            if (self.disconnectVanishedPorts()) changed = true;
        }

        // Clear expired export-feedback message so the TopBar reverts to status.
        if (self.export_message_len > 0) {
            const now: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
            if (now >= self.export_message_until_ns) {
                self.export_message_len = 0;
                changed = true;
            }
        }

        return changed;
    }

    fn disconnectVanishedPorts(self: *Monitor) bool {
        var any_open = false;
        for (self.ports) |p| if (p != null) {
            any_open = true;
            break;
        };
        if (!any_open) return false;

        var available: std.ArrayList([]u8) = .empty;
        defer {
            for (available.items) |s| self.allocator.free(s);
            available.deinit(self.allocator);
        }

        var it = zig_serial.list(self.io) catch return false;
        while (true) {
            const maybe_desc = it.next() catch return false;
            const desc = maybe_desc orelse break;
            const copy = self.allocator.dupe(u8, desc.file_name) catch continue;
            available.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                continue;
            };
        }

        var changed = false;
        for (self.ports, 0..) |maybe_port, i| {
            const p = maybe_port orelse continue;
            var found = false;
            for (available.items) |name| {
                if (std.mem.eql(u8, name, p.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.disconnectSlot(@intCast(i));
                changed = true;
            }
        }
        return changed;
    }

    fn nextDisplayMode(self: *const Monitor) DisplayMode {
        return switch (self.display_mode) {
            .string => .string_and_hex,
            .string_and_hex => .hex_only,
            .hex_only => .string,
        };
    }

    pub fn keyHints(self: *const Monitor, arena: std.mem.Allocator) ![]const KeyHint {
        if (self.overlay_open) {
            const hints = try arena.alloc(KeyHint, 5);
            hints[0] = .{ .key = "↑↓", .label = "ports" };
            hints[1] = .{ .key = "Esc", .label = "done" };
            hints[2] = .{ .key = "Enter", .label = "connect" };
            hints[3] = .{ .key = "d", .label = "disconnect" };
            hints[4] = .{ .key = "b", .label = "baud" };
            return hints;
        }
        const follow_label: []const u8 = if (self.follow) "follow:on" else "follow:off";
        const view_label: []const u8 = switch (self.display_mode) {
            .string => "view:string+hex",
            .string_and_hex => "view:hex",
            .hex_only => "view:string",
        };
        const hints = try arena.alloc(KeyHint, 6);
        hints[0] = .{ .key = "o", .label = "open" };
        hints[1] = .{ .key = "c", .label = "clear" };
        hints[2] = .{ .key = "e", .label = "export" };
        hints[3] = .{ .key = "f", .label = follow_label };
        hints[4] = .{ .key = "Tab", .label = view_label };
        hints[5] = .{ .key = "↑↓", .label = "select" };
        return hints;
    }

    pub fn handleKey(self: *Monitor, key: vaxis.Key, ctx: *vxfw.EventContext) !bool {
        if (self.overlay_open) {
            const result = self.overlay.handleKey(key);
            switch (result) {
                .close => {
                    self.overlay_open = false;
                    ctx.redraw = true;
                    return true;
                },
                .consumed => {
                    ctx.redraw = true;
                    return true;
                },
                .connect => {
                    self.connectFromOverlay() catch {};
                    ctx.redraw = true;
                    return true;
                },
                .disconnect => {
                    if (self.overlay.cursorConnectedSlot()) |slot| {
                        self.disconnectSlot(slot);
                        self.overlay.setConnectedSlot(slot, null) catch {};
                    }
                    ctx.redraw = true;
                    return true;
                },
                .ignored => return false,
            }
        }
        if (key.matches('o', .{})) {
            try self.openOverlay();
            ctx.redraw = true;
            return true;
        }
        if (key.matches('c', .{})) {
            self.clear();
            ctx.redraw = true;
            return true;
        }
        if (key.matches('e', .{})) {
            self.runExport();
            ctx.redraw = true;
            return true;
        }
        if (key.matches('f', .{})) {
            self.follow = !self.follow;
            if (self.follow and self.lines_count > 0) {
                self.list_view.cursor = @intCast(self.lines_count - 1);
                self.list_view.ensureScroll();
            }
            ctx.redraw = true;
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.display_mode = self.nextDisplayMode();
            ctx.redraw = true;
            return true;
        }
        if (self.lines_count > 0) {
            const page: u32 = 10;
            const last: u32 = @intCast(self.lines_count - 1);
            if (key.matches(vaxis.Key.up, .{})) {
                self.list_view.cursor -|= 1;
                self.list_view.ensureScroll();
                self.follow = false;
                ctx.redraw = true;
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self.list_view.cursor = @min(self.list_view.cursor + 1, last);
                self.list_view.ensureScroll();
                ctx.redraw = true;
                return true;
            }
            if (key.matches(vaxis.Key.page_up, .{})) {
                self.list_view.cursor -|= page;
                self.list_view.ensureScroll();
                self.follow = false;
                ctx.redraw = true;
                return true;
            }
            if (key.matches(vaxis.Key.page_down, .{})) {
                self.list_view.cursor = @min(self.list_view.cursor + page, last);
                self.list_view.ensureScroll();
                ctx.redraw = true;
                return true;
            }
            if (key.matches(vaxis.Key.home, .{})) {
                self.list_view.cursor = 0;
                self.list_view.ensureScroll();
                self.follow = false;
                ctx.redraw = true;
                return true;
            }
            if (key.matches(vaxis.Key.end, .{})) {
                self.list_view.cursor = last;
                self.list_view.ensureScroll();
                ctx.redraw = true;
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *Monitor) void {
        for (0..self.lines_count) |i| {
            const idx = (self.lines_head + i) % max_history;
            self.allocator.free(self.lines[idx].text);
        }
        self.lines_head = 0;
        self.lines_count = 0;
        self.list_view.cursor = 0;

        // Acknowledge current warnings: snapshot dropped counters and mark
        // already-errored slots as acked. Future drops or new errors re-fire.
        for (self.ports, 0..) |maybe_port, i| {
            if (maybe_port) |p| {
                self.dropped_baseline[i] = p.droppedCount();
                self.errored_acked[i] = (p.getState() == .errored);
            } else {
                self.dropped_baseline[i] = 0;
                self.errored_acked[i] = false;
            }
        }
    }

    fn openOverlay(self: *Monitor) !void {
        try self.overlay.refresh();
        for (self.ports, 0..) |p, i| {
            const name: ?[]const u8 = if (p) |port| port.name else null;
            try self.overlay.setConnectedSlot(@intCast(i), name);
        }
        self.overlay_open = true;
    }

    fn connectFromOverlay(self: *Monitor) !void {
        const fname = self.overlay.selectedFileName() orelse return error.NoPortSelected;
        const baud = self.overlay.selectedBaud();
        const slot = self.firstFreeSlot() orelse return error.NoFreeSlot;

        const config: zig_serial.SerialConfig = .{
            .baud_rate = baud,
            .word_size = .eight,
            .parity = .none,
            .stop_bits = .one,
            .handshake = .none,
        };

        self.ports[slot] = try port_mod.Port.open(
            self.allocator,
            self.io,
            @intCast(slot),
            fname,
            config,
            &self.rings[slot],
        );
        self.dropped_baseline[slot] = 0;
        self.errored_acked[slot] = false;
        self.overlay.setConnectedSlot(@intCast(slot), fname) catch {};
    }

    fn firstFreeSlot(self: *const Monitor) ?usize {
        for (self.ports, 0..) |p, i| {
            if (p == null) return i;
        }
        return null;
    }

    fn disconnectSlot(self: *Monitor, slot: u8) void {
        if (slot >= types.max_slots) return;
        if (self.ports[slot]) |p| {
            p.close();
            self.ports[slot] = null;
            self.assemblers[slot].reset();
            self.dropped_baseline[slot] = 0;
            self.errored_acked[slot] = false;
        }
    }

    pub fn drainAndUpdate(self: *Monitor) !bool {
        // Idle fast path: avoid the ArrayList allocation when every ring is empty.
        var any_data = false;
        for (&self.rings) |*ring| {
            if (ring.hasItem()) {
                any_data = true;
                break;
            }
        }
        if (!any_data) return false;

        var temp: std.ArrayList(types.Event) = .empty;
        defer temp.deinit(self.allocator);

        for (&self.rings) |*ring| {
            while (ring.pop()) |ev| try temp.append(self.allocator, ev);
        }

        if (temp.items.len == 0) return false;

        const C = struct {
            fn lessThan(_: void, a: types.Event, b: types.Event) bool {
                return a.timestamp_ns < b.timestamp_ns;
            }
        };
        std.mem.sort(types.Event, temp.items, {}, C.lessThan);

        const was_at_bottom = self.atBottom();

        const sink: line_buf.Sink = .{ .ptr = self, .push = appendLineCb };
        for (temp.items) |ev| {
            const dev = ev.device_id;
            if (dev >= types.max_slots) continue;
            try self.assemblers[dev].feed(ev.data[0..ev.len], ev.timestamp_ns, sink);
        }
        for (&self.assemblers) |*asm_buf| try asm_buf.flushPending(sink);

        if (self.follow and was_at_bottom and self.lines_count > 0) {
            self.list_view.cursor = @intCast(self.lines_count - 1);
            self.list_view.ensureScroll();
        }

        return true;
    }

    fn appendLineCb(ptr: *anyopaque, line: types.Line) anyerror!void {
        const self: *Monitor = @ptrCast(@alignCast(ptr));
        try self.appendLine(line);
    }

    fn appendLine(self: *Monitor, line: types.Line) !void {
        if (self.lines_count == max_history) {
            self.allocator.free(self.lines[self.lines_head].text);
            self.lines[self.lines_head] = line;
            self.lines_head = (self.lines_head + 1) % max_history;
            // Head advance shifts every logical position down by 1; track the same line.
            self.list_view.cursor -|= 1;
        } else {
            const idx = (self.lines_head + self.lines_count) % max_history;
            self.lines[idx] = line;
            self.lines_count += 1;
        }

        // A line's timestamp is the time of its first byte, which may predate
        // lines from other ports that finished assembling earlier. Bubble the
        // freshly appended line backward (newest visible index → older) until
        // it sits in chronological order.
        if (self.lines_count < 2) return;
        var i: usize = self.lines_count - 1;
        while (i > 0) : (i -= 1) {
            const cur_phys = (self.lines_head + i) % max_history;
            const prev_phys = (self.lines_head + i - 1) % max_history;
            if (self.lines[prev_phys].timestamp_ns <= self.lines[cur_phys].timestamp_ns) break;
            const tmp = self.lines[prev_phys];
            self.lines[prev_phys] = self.lines[cur_phys];
            self.lines[cur_phys] = tmp;
        }

        // Bubble pushed items at logical [dest..lines_count-2] forward by one;
        // bump the cursor if it lived in that range so it tracks the same line.
        const dest: u32 = @intCast(i);
        if (dest <= self.list_view.cursor and self.list_view.cursor + 1 < self.lines_count) {
            self.list_view.cursor += 1;
        }
    }

    fn atBottom(self: *const Monitor) bool {
        if (self.lines_count == 0) return true;
        return self.list_view.cursor + 1 >= self.lines_count;
    }

    fn lineAt(self: *const Monitor, slot_idx: usize) ?types.Line {
        if (slot_idx >= self.lines_count) return null;
        const physical = (self.lines_head + slot_idx) % max_history;
        return self.lines[physical];
    }

    fn drawMain(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Monitor = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        self.list_view.children = .{ .slice = self.line_widgets[0..self.lines_count] };
        self.list_view.item_count = @intCast(self.lines_count);

        const footer_h: u16 = if (max.height >= 3) 2 else 0;

        const cursor_line: ?types.Line = if (self.lines_count > 0)
            self.lineAt(@intCast(self.list_view.cursor))
        else
            null;

        const want_inspector = !self.overlay_open and cursor_line != null;
        var inspector_h: u16 = 0;
        if (want_inspector) {
            const content_h = try inspector.computeHeight(arena, cursor_line.?, max.width);
            if (content_h > 0) {
                // include 1 row hrule above inspector content
                const block_h: u16 = content_h + 1;
                if (block_h + footer_h + 1 <= max.height) {
                    inspector_h = block_h;
                }
            }
        }

        const chat_h: u16 = max.height - footer_h - inspector_h;

        const chat_ctx = ctx.withConstraints(
            .{ .width = max.width, .height = chat_h },
            .{ .width = max.width, .height = chat_h },
        );

        const chat_surf = if (self.lines_count == 0)
            try drawEmptyHint(self, chat_ctx)
        else
            try self.list_view.widget().draw(chat_ctx);

        var all_children: std.ArrayList(vxfw.SubSurface) = .empty;
        try all_children.append(arena, .{ .surface = chat_surf, .origin = .{ .row = 0, .col = 0 }, .z_index = 0 });

        if (inspector_h > 0) {
            const insp_hrule = try drawHRule(ctx, max.width);
            try all_children.append(arena, .{ .surface = insp_hrule, .origin = .{ .row = @intCast(chat_h), .col = 0 }, .z_index = 0 });

            const insp_ctx = ctx.withConstraints(
                .{ .width = max.width, .height = inspector_h - 1 },
                .{ .width = max.width, .height = inspector_h - 1 },
            );
            const insp_surf = try inspector.draw(insp_ctx, cursor_line.?, self.widget());
            try all_children.append(arena, .{ .surface = insp_surf, .origin = .{ .row = @intCast(chat_h + 1), .col = 0 }, .z_index = 0 });
        }

        if (footer_h > 0) {
            const hrule_surf = try drawHRule(ctx, max.width);
            const footer_surf = try self.drawFooter(ctx);
            const footer_origin_row: u16 = chat_h + inspector_h;
            try all_children.append(arena, .{ .surface = hrule_surf, .origin = .{ .row = @intCast(footer_origin_row), .col = 0 }, .z_index = 0 });
            try all_children.append(arena, .{ .surface = footer_surf, .origin = .{ .row = @intCast(footer_origin_row + 1), .col = 0 }, .z_index = 0 });
        }

        if (self.overlay_open) {
            const overlay_surf = try self.overlay.widget().draw(ctx);
            try all_children.append(arena, .{ .surface = overlay_surf, .origin = .{ .row = 0, .col = 0 }, .z_index = 1 });
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = all_children.items,
        };
    }

    fn drawFooter(self: *Monitor, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const arena = ctx.arena;
        const max = ctx.max.size();

        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        try spans.append(arena, .{ .text = " ", .style = theme.subtitle });

        for (self.ports, 0..) |maybe_port, i| {
            if (i > 0) {
                try spans.append(arena, .{ .text = " │ ", .style = theme.subtitle });
            }
            const slot_text = try std.fmt.allocPrint(arena, "D{d} ", .{i});
            if (maybe_port) |port| {
                const baud_text = try std.fmt.allocPrint(arena, " {d}", .{port.config.baud_rate});
                const port_idx = @min(i, types.max_slots - 1);
                // Dot reflects per-slot health: errored → red, fresh drops → orange,
                // healthy → slot's native identity color.
                const dot_color: vaxis.Color = if (port.getState() == .errored)
                    theme.err_c
                else if (port.droppedCount() > self.dropped_baseline[i])
                    theme.warn_c
                else
                    port_colors[port_idx];
                try spans.append(arena, .{ .text = "● ", .style = .{ .fg = dot_color, .bold = true } });
                try spans.append(arena, .{ .text = slot_text, .style = theme.normal });
                try spans.append(arena, .{ .text = types.displayName(port.name), .style = theme.normal });
                try spans.append(arena, .{ .text = baud_text, .style = theme.subtitle });
            } else {
                try spans.append(arena, .{ .text = "● ", .style = theme.subtitle });
                try spans.append(arena, .{ .text = slot_text, .style = theme.subtitle });
                try spans.append(arena, .{ .text = "─", .style = theme.subtitle });
            }
        }

        const rt = try arena.create(vxfw.RichText);
        rt.* = .{
            .text = spans.items,
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };

        const inner_ctx = ctx.withConstraints(
            .{ .width = max.width, .height = 1 },
            .{ .width = max.width, .height = 1 },
        );
        return try rt.draw(inner_ctx);
    }

    fn drawEmptyHint(self: *Monitor, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
        const arena = ctx.arena;

        const hint_text: []const u8 = if (self.anyConnected())
            "(no lines yet)"
        else
            "press 'o' to open a port";

        const hint = vxfw.Text{
            .text = hint_text,
            .style = theme.subtitle,
            .text_align = .center,
            .width_basis = .parent,
            .softwrap = false,
        };
        const surf = try hint.draw(ctx.withConstraints(
            .{ .width = max.width, .height = 1 },
            .{ .width = max.width, .height = 1 },
        ));

        const sub = try arena.alloc(vxfw.SubSurface, 1);
        const mid_row: i17 = if (max.height >= 2) @intCast(max.height / 2) else 0;
        sub[0] = .{ .origin = .{ .row = mid_row, .col = 0 }, .surface = surf };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = sub,
        };
    }

    fn drawLineFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const entry: *LineEntry = @ptrCast(@alignCast(ptr));
        const self = entry.monitor;
        const arena = ctx.arena;

        const line_widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawLineFn };
        const line = self.lineAt(entry.slot_idx) orelse return vxfw.Surface.empty(line_widget);

        const ts_text = try fmt.formatTimestamp(arena, line.timestamp_ns);
        const dev_text = try std.fmt.allocPrint(arena, " [D{d}] ", .{line.port_id});
        const term_text: []const u8 = switch (line.terminator) {
            .lf => "\\n",
            .cr => "\\r",
            .crlf => "\\r\\n",
            .lfcr => "\\n\\r",
        };

        const port_idx = @min(line.port_id, types.max_slots - 1);
        const dev_style: vaxis.Style = .{ .fg = port_colors[port_idx], .bold = true };

        return switch (self.display_mode) {
            .string => line_render.drawString(arena, ctx, line, ts_text, dev_text, term_text, dev_style),
            .hex_only => line_render.drawHexOnly(arena, ctx, line, ts_text, dev_text, dev_style),
            .string_and_hex => line_render.drawStringAndHex(arena, ctx, line, ts_text, dev_text, term_text, dev_style, line_widget),
        };
    }
};

fn drawHRule(ctx: vxfw.DrawContext, width: u16) std.mem.Allocator.Error!vxfw.Surface {
    const arena = ctx.arena;
    const dash = "─";
    const w: usize = if (width == 0) 0 else width;
    const buf = try arena.alloc(u8, w * dash.len);
    var i: usize = 0;
    while (i < w) : (i += 1) {
        @memcpy(buf[i * dash.len ..][0..dash.len], dash);
    }
    const t = vxfw.Text{
        .text = buf,
        .style = theme.border,
        .softwrap = false,
        .overflow = .clip,
    };
    return try t.draw(ctx.withConstraints(
        .{ .width = width, .height = 1 },
        .{ .width = width, .height = 1 },
    ));
}

