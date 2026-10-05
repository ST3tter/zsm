const std = @import("std");
const builtin = @import("builtin");
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
const save_prompt_mod = @import("save_prompt.zig");
const selection = @import("selection.zig");
const send_bar_mod = @import("send_bar.zig");

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

// Columns ListView reserves for its cursor indicator (draw_cursor = true).
const list_cursor_cols: u16 = 2;

// A line row as laid out in the last frame, in Monitor-local coordinates.
// Used to map mouse positions to lines; `surface` is only valid during draw.
const VisibleLine = struct {
    row: i32,
    col: i32,
    height: u16,
    slot_idx: usize,
    seq: u64,
    surface: vxfw.Surface,
};

// Selection resolved to logical line indices, in reading order.
const SelectionRange = struct {
    start_idx: usize,
    start_col: u16,
    end_idx: usize,
    end_col: u16,
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
    save_prompt: save_prompt_mod.SavePrompt,
    save_prompt_open: bool = false,
    send_bar: send_bar_mod.SendBar,
    send_bar_open: bool = false,
    follow: bool = true,
    display_mode: DisplayMode = .string,

    // Transient feedback after pressing `e`. Shown in the TopBar in place of
    // the status text for ~3s. Fixed buffer — no allocation.
    export_message_buf: [128]u8 = undefined,
    export_message_len: usize = 0,
    export_message_until_ns: u64 = 0,
    export_message_is_error: bool = false,

    // Mouse text selection. `sel_anchor` is where the drag started, `sel_head`
    // where it is now; `sel_active` is false for a plain click (no drag yet).
    next_seq: u64 = 0,
    sel_anchor: selection.Point = .{ .seq = 0, .col = 0 },
    sel_head: selection.Point = .{ .seq = 0, .col = 0 },
    sel_active: bool = false,
    dragging: bool = false,
    visible: std.ArrayList(VisibleLine) = .empty,
    line_width: u16 = 0,

    pub fn init(self: *Monitor, allocator: std.mem.Allocator, io: std.Io, env: send_bar_mod.EnvVars) void {
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
        self.save_prompt = save_prompt_mod.SavePrompt.init(allocator, io);
        self.save_prompt_open = false;
        self.send_bar = send_bar_mod.SendBar.init(allocator, io, env);
        self.send_bar_open = false;
        self.follow = true;
        self.display_mode = .string;
        self.next_seq = 0;
        self.sel_active = false;
        self.dragging = false;
        self.visible = .empty;
        self.line_width = 0;

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
        self.save_prompt.deinit();
        self.send_bar.deinit();
        self.visible.deinit(self.allocator);
    }

    pub fn widget(self: *Monitor) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = handleEventFn, .drawFn = drawMain };
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

    // Start an export: generate the fixed filename and open the save-path
    // prompt. The actual write happens in finishExport when the user confirms.
    fn openSavePrompt(self: *Monitor) void {
        if (self.lines_count == 0) {
            self.setExportMessage("export: nothing to export", true);
            return;
        }
        const now_ns: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
        var scratch: [64]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const filename = exp.makeFilename(fba.allocator(), now_ns) catch {
            self.setExportMessage("export: out of memory", true);
            return;
        };
        self.save_prompt.open(filename) catch {
            self.setExportMessage("export: out of memory", true);
            return;
        };
        self.save_prompt_open = true;
    }

    // Export the current view to a CSV file in the directory chosen in the
    // save prompt. All formatting is in export.zig; this method just snapshots
    // lines into an arena, builds the CSV in memory, and writes the whole
    // buffer in one go. On any failure a transient error message is shown in
    // the TopBar.
    fn finishExport(self: *Monitor) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const dir_text = self.save_prompt.currentText(arena) catch {
            self.setExportMessage("export: out of memory", true);
            return;
        };
        const dir_trimmed = std.mem.trim(u8, dir_text, " ");
        const path = save_prompt_mod.joinExportPath(
            arena,
            dir_trimmed,
            self.save_prompt.filename(),
            builtin.target.os.tag == .windows,
        ) catch {
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

        const create_opts: std.Io.Dir.CreateFileOptions = .{ .read = false, .truncate = true };
        const file_or_err = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.createFileAbsolute(self.io, path, create_opts)
        else
            std.Io.Dir.cwd().createFile(self.io, path, create_opts);
        const file = file_or_err catch |err| {
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

        var buf: [192]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "exported {d} lines → {s}", .{ self.lines_count, path }) catch "export complete";
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
            if (p.tx.takeFailure()) |f| {
                var buf: [64]u8 = undefined;
                self.setExportMessage(port_mod.describeTxFailure(&buf, f), true);
                changed = true;
            }
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
        if (self.save_prompt_open) {
            const hints = try arena.alloc(KeyHint, 3);
            hints[0] = .{ .key = "Tab", .label = "complete" };
            hints[1] = .{ .key = "Enter", .label = "save" };
            hints[2] = .{ .key = "Esc", .label = "cancel" };
            return hints;
        }
        if (self.overlay_open) {
            const hints = try arena.alloc(KeyHint, 5);
            hints[0] = .{ .key = "↑↓", .label = "ports" };
            hints[1] = .{ .key = "Esc", .label = "done" };
            hints[2] = .{ .key = "Enter", .label = "connect" };
            hints[3] = .{ .key = "d", .label = "disconnect" };
            hints[4] = .{ .key = "b", .label = "baud" };
            return hints;
        }
        if (self.send_bar_open) {
            const hints = try arena.alloc(KeyHint, 4);
            hints[0] = .{ .key = "Enter", .label = "send" };
            hints[1] = .{ .key = "Tab", .label = "ending" };
            hints[2] = .{ .key = "↑↓", .label = "history" };
            hints[3] = .{ .key = "Esc", .label = "close" };
            return hints;
        }
        const follow_label: []const u8 = if (self.follow) "follow:on" else "follow:off";
        // Current mode, like follow_label (Tab switches to the next one).
        const view_label: []const u8 = switch (self.display_mode) {
            .string => "view:string",
            .string_and_hex => "view:string+hex",
            .hex_only => "view:hex",
        };
        const hints = try arena.alloc(KeyHint, if (self.sel_active) 8 else 7);
        hints[0] = .{ .key = "o", .label = "open" };
        hints[1] = .{ .key = "s", .label = "send" };
        hints[2] = .{ .key = "c", .label = "clear" };
        hints[3] = .{ .key = "e", .label = "export" };
        hints[4] = .{ .key = "f", .label = follow_label };
        hints[5] = .{ .key = "Tab", .label = view_label };
        hints[6] = .{ .key = "↑↓", .label = "select" };
        if (self.sel_active) hints[7] = .{ .key = "Ctrl+Shift+C", .label = "copy" };
        return hints;
    }

    pub fn handleKey(self: *Monitor, key: vaxis.Key, ctx: *vxfw.EventContext) !bool {
        if (self.save_prompt_open) {
            switch (self.save_prompt.handleKey(key, ctx)) {
                .cancel => {
                    self.save_prompt_open = false;
                    ctx.redraw = true;
                    return true;
                },
                .save => {
                    self.save_prompt_open = false;
                    self.finishExport();
                    ctx.redraw = true;
                    return true;
                },
                .consumed => {
                    ctx.redraw = true;
                    return true;
                },
                .ignored => return false,
            }
        }
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
        // Must precede the plain 'c' (clear) check. Legacy terminals report
        // Ctrl+Shift+C as Ctrl+C; that still falls through to quit in App.
        if (key.matches('c', .{ .ctrl = true, .shift = true }) or
            key.matches('C', .{ .ctrl = true, .shift = true }))
        {
            try self.copySelection(ctx);
            ctx.redraw = true;
            return true;
        }
        if (self.send_bar_open) {
            switch (self.send_bar.handleKey(key, ctx)) {
                .close => {
                    self.send_bar_open = false;
                    ctx.redraw = true;
                    return true;
                },
                .send => {
                    self.sendToD0();
                    ctx.redraw = true;
                    return true;
                },
                .consumed => {
                    ctx.redraw = true;
                    return true;
                },
                // Unhandled (e.g. Ctrl+C) goes to App; Monitor hotkeys stay off.
                .ignored => return false,
            }
        }
        if (self.sel_active and key.matches(vaxis.Key.escape, .{})) {
            self.sel_active = false;
            ctx.redraw = true;
            return true;
        }
        if (key.matches('s', .{})) {
            self.send_bar_open = true;
            ctx.redraw = true;
            return true;
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
            self.openSavePrompt();
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
            // Columns mean something else in the new layout.
            self.sel_active = false;
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
        self.sel_active = false;
        self.dragging = false;

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
        const now_ns: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);

        const lines_before = self.lines_count;
        const head_before = self.lines_head;
        const was_at_bottom = self.atBottom();

        const sink: line_buf.Sink = .{ .ptr = self, .push = appendLineCb };

        // Fast path: no new events. Still check each assembler in case some
        // unterminated content has been sitting in buf past the idle threshold.
        var any_data = false;
        for (&self.rings) |*ring| {
            if (ring.hasItem()) {
                any_data = true;
                break;
            }
        }
        if (!any_data) {
            for (&self.assemblers) |*asm_buf|
                try asm_buf.idleFlush(now_ns, line_buf.idle_flush_threshold_ns, sink);
            return self.maybeFollow(was_at_bottom, lines_before, head_before);
        }

        var temp: std.ArrayList(types.Event) = .empty;
        defer temp.deinit(self.allocator);

        for (&self.rings) |*ring| {
            while (ring.pop()) |ev| try temp.append(self.allocator, ev);
        }

        if (temp.items.len == 0) {
            for (&self.assemblers) |*asm_buf|
                try asm_buf.idleFlush(now_ns, line_buf.idle_flush_threshold_ns, sink);
            return self.maybeFollow(was_at_bottom, lines_before, head_before);
        }

        const C = struct {
            fn lessThan(_: void, a: types.Event, b: types.Event) bool {
                return a.timestamp_ns < b.timestamp_ns;
            }
        };
        std.mem.sort(types.Event, temp.items, {}, C.lessThan);

        for (temp.items) |ev| {
            const dev = ev.device_id;
            if (dev >= types.max_slots) continue;
            try self.assemblers[dev].feed(ev.data[0..ev.len], ev.timestamp_ns, sink);
        }
        // Pending terminators are NOT flushed here: a trailing `\r` may pair
        // with a `\n` arriving in the next drain. idleFlush ages them out.
        for (&self.assemblers) |*asm_buf|
            try asm_buf.idleFlush(now_ns, line_buf.idle_flush_threshold_ns, sink);

        if (self.follow and was_at_bottom and self.lines_count > 0) {
            self.list_view.cursor = @intCast(self.lines_count - 1);
            self.list_view.ensureScroll();
        }

        return true;
    }

    fn maybeFollow(self: *Monitor, was_at_bottom: bool, lines_before: usize, head_before: usize) bool {
        const changed = self.lines_count != lines_before or self.lines_head != head_before;
        if (changed and self.follow and was_at_bottom and self.lines_count > 0) {
            self.list_view.cursor = @intCast(self.lines_count - 1);
            self.list_view.ensureScroll();
        }
        return changed;
    }

    fn appendLineCb(ptr: *anyopaque, line: types.Line) anyerror!void {
        const self: *Monitor = @ptrCast(@alignCast(ptr));
        try self.appendLine(line);
    }

    fn appendLine(self: *Monitor, new_line: types.Line) !void {
        var line = new_line;
        line.seq = self.next_seq;
        self.next_seq += 1;

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
        // hrule + one input row, only when it fits above the footer
        const send_h: u16 = if (self.send_bar_open and max.height >= footer_h + 3) 2 else 0;

        const cursor_line: ?types.Line = if (self.lines_count > 0)
            self.lineAt(@intCast(self.list_view.cursor))
        else
            null;

        const want_inspector = !self.overlay_open and !self.save_prompt_open and cursor_line != null;
        var inspector_h: u16 = 0;
        if (want_inspector) {
            const content_h = try inspector.computeHeight(arena, cursor_line.?, max.width);
            if (content_h > 0) {
                // include 1 row hrule above inspector content
                const block_h: u16 = content_h + 1;
                if (block_h + footer_h + send_h + 1 <= max.height) {
                    inspector_h = block_h;
                }
            }
        }

        const chat_h: u16 = max.height - footer_h - inspector_h - send_h;

        const chat_ctx = ctx.withConstraints(
            .{ .width = max.width, .height = chat_h },
            .{ .width = max.width, .height = chat_h },
        );

        const chat_surf = if (self.lines_count == 0)
            try drawEmptyHint(self, chat_ctx)
        else
            try self.list_view.widget().draw(chat_ctx);

        self.line_width = max.width -| list_cursor_cols;
        self.visible.clearRetainingCapacity();
        if (self.lines_count > 0) {
            for (chat_surf.children) |child|
                try self.collectVisible(child.surface, child.origin.row, child.origin.col);
            self.highlightSelection();
        }

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

        if (send_h > 0) {
            const send_row: u16 = chat_h + inspector_h;
            const send_hrule = try drawHRule(ctx, max.width);
            try all_children.append(arena, .{ .surface = send_hrule, .origin = .{ .row = @intCast(send_row), .col = 0 }, .z_index = 0 });

            self.send_bar.d0_connected = self.ports[0] != null;
            const bar_surf = try self.send_bar.widget().draw(ctx.withConstraints(
                .{ .width = max.width, .height = 1 },
                .{ .width = max.width, .height = 1 },
            ));
            try all_children.append(arena, .{ .surface = bar_surf, .origin = .{ .row = @intCast(send_row + 1), .col = 0 }, .z_index = 0 });
        }

        if (footer_h > 0) {
            const hrule_surf = try drawHRule(ctx, max.width);
            const footer_surf = try self.drawFooter(ctx);
            const footer_origin_row: u16 = chat_h + inspector_h + send_h;
            try all_children.append(arena, .{ .surface = hrule_surf, .origin = .{ .row = @intCast(footer_origin_row), .col = 0 }, .z_index = 0 });
            try all_children.append(arena, .{ .surface = footer_surf, .origin = .{ .row = @intCast(footer_origin_row + 1), .col = 0 }, .z_index = 0 });
        }

        if (self.overlay_open) {
            const overlay_surf = try self.overlay.widget().draw(ctx);
            try all_children.append(arena, .{ .surface = overlay_surf, .origin = .{ .row = 0, .col = 0 }, .z_index = 1 });
        }

        if (self.save_prompt_open) {
            const prompt_surf = try self.save_prompt.widget().draw(ctx);
            try all_children.append(arena, .{ .surface = prompt_surf, .origin = .{ .row = 0, .col = 0 }, .z_index = 2 });
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
            const slot_text = try arena.print("D{d} ", .{i});
            if (maybe_port) |port| {
                const baud_text = try arena.print(" {d}", .{port.config.baud_rate});
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
        const dev_text = try line_render.devLabel(arena, line);
        const term_text = types.terminatorNotation(line.terminator);

        const port_idx = @min(line.port_id, types.max_slots - 1);
        const dev_style: vaxis.Style = .{ .fg = port_colors[port_idx], .bold = true };

        var surf = try switch (self.display_mode) {
            .string => line_render.drawString(arena, ctx, line, ts_text, dev_text, term_text, dev_style),
            .hex_only => line_render.drawHexOnly(arena, ctx, line, ts_text, dev_text, dev_style),
            .string_and_hex => line_render.drawStringAndHex(arena, ctx, line, ts_text, dev_text, term_text, dev_style, line_widget),
        };
        // Tag the surface with the line widget so collectVisible can find it
        // in the ListView's surface tree.
        surf.widget = line_widget;
        return surf;
    }

    fn isLineSurface(surf: vxfw.Surface) bool {
        return @intFromPtr(surf.widget.drawFn) == @intFromPtr(&drawLineFn);
    }

    // Walk the ListView surface tree and record where each line row landed.
    // The cursored line is wrapped in an extra surface, hence the recursion.
    fn collectVisible(self: *Monitor, surf: vxfw.Surface, row: i32, col: i32) std.mem.Allocator.Error!void {
        if (isLineSurface(surf)) {
            const entry: *LineEntry = @ptrCast(@alignCast(surf.widget.userdata));
            const line = self.lineAt(entry.slot_idx) orelse return;
            try self.visible.append(self.allocator, .{
                .row = row,
                .col = col,
                .height = surf.size.height,
                .slot_idx = entry.slot_idx,
                .seq = line.seq,
                .surface = surf,
            });
            return;
        }
        for (surf.children) |child|
            try self.collectVisible(child.surface, row + child.origin.row, col + child.origin.col);
    }

    fn highlightSelection(self: *Monitor) void {
        const range = self.selectionRange() orelse return;
        for (self.visible.items) |v| {
            if (v.slot_idx < range.start_idx or v.slot_idx > range.end_idx) continue;
            const from: u16 = if (v.slot_idx == range.start_idx) range.start_col else 0;
            const to: u16 = if (v.slot_idx == range.end_idx) range.end_col else std.math.maxInt(u16);
            selection.highlightRow(v.surface, 0, from, to);
        }
    }

    fn indexOfSeq(self: *const Monitor, seq: u64) ?usize {
        // Newest first: selections are usually near the bottom.
        var i: usize = self.lines_count;
        while (i > 0) {
            i -= 1;
            if (self.lineAt(i).?.seq == seq) return i;
        }
        return null;
    }

    // Resolve anchor/head to logical indices in reading order. Null when there
    // is no selection or one of its lines has been evicted.
    fn selectionRange(self: *const Monitor) ?SelectionRange {
        if (!self.sel_active) return null;
        const a_idx = self.indexOfSeq(self.sel_anchor.seq) orelse return null;
        const h_idx = self.indexOfSeq(self.sel_head.seq) orelse return null;
        const a_first = a_idx < h_idx or (a_idx == h_idx and self.sel_anchor.col <= self.sel_head.col);
        const first = if (a_first) self.sel_anchor else self.sel_head;
        const last = if (a_first) self.sel_head else self.sel_anchor;
        return .{
            .start_idx = if (a_first) a_idx else h_idx,
            .start_col = first.col,
            .end_idx = if (a_first) h_idx else a_idx,
            .end_col = last.col,
        };
    }

    // Map a Monitor-local cell to a selection point. Positions above/below the
    // drawn lines clamp to the start of the first / end of the last line.
    fn pointAt(self: *const Monitor, row: i32, col: i32) ?selection.Point {
        const items = self.visible.items;
        if (items.len == 0 or self.line_width == 0) return null;
        const max_col: i32 = self.line_width - 1;

        const first = items[0];
        if (row < first.row) return .{ .seq = first.seq, .col = 0 };
        for (items) |v| {
            if (row >= v.row and row < v.row + v.height) {
                const c = std.math.clamp(col - v.col, 0, max_col);
                return .{ .seq = v.seq, .col = @intCast(c) };
            }
        }
        const last = items[items.len - 1];
        return .{ .seq = last.seq, .col = @intCast(max_col) };
    }

    fn moveCursorToLine(self: *Monitor, seq: u64) void {
        const idx = self.indexOfSeq(seq) orelse return;
        self.list_view.cursor = @intCast(idx);
        self.list_view.ensureScroll();
        // Same as ↑: looking at an older line stops following new ones.
        if (idx + 1 < self.lines_count) self.follow = false;
    }

    fn isOnLine(self: *const Monitor, row: i32) bool {
        for (self.visible.items) |v| {
            if (row >= v.row and row < v.row + v.height) return true;
        }
        return false;
    }

    fn handleEventFn(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Monitor = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| self.handleMouse(mouse, ctx),
            else => {},
        }
    }

    fn handleMouse(self: *Monitor, mouse: vaxis.Mouse, ctx: *vxfw.EventContext) void {
        if (self.overlay_open or self.save_prompt_open) return;
        // Wheel scrolling is handled by the ListView itself.
        if (mouse.button != .left) return;
        switch (mouse.type) {
            .press => {
                // Any click drops the previous selection and starts a new one.
                self.sel_active = false;
                if (!self.isOnLine(mouse.row)) {
                    ctx.redraw = true;
                    return;
                }
                const p = self.pointAt(mouse.row, mouse.col) orelse return;
                self.sel_anchor = p;
                self.sel_head = p;
                self.dragging = true;
                ctx.consumeAndRedraw();
            },
            .drag => {
                if (!self.dragging) return;
                const p = self.pointAt(mouse.row, mouse.col) orelse return;
                self.sel_head = p;
                self.sel_active = true;
                ctx.consumeAndRedraw();
            },
            .release => {
                // A click without a drag moves the cursor (and with it the
                // inspector) to the clicked line. Done on release rather than
                // press so the inspector can't resize the layout mid-drag.
                if (self.dragging and !self.sel_active) self.moveCursorToLine(self.sel_anchor.seq);
                self.dragging = false;
                ctx.consumeAndRedraw();
            },
            .motion => {},
        }
    }

    // Queue the input plus the chosen ending for D0 and echo it as a TX line.
    // The reader thread does the write; failures show up via healthTick. If
    // the command can't be queued, the input is kept so the user can retry.
    fn sendToD0(self: *Monitor) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const text = self.send_bar.currentText(arena) catch return;
        const ending = self.send_bar.ending;
        const term = types.terminatorBytes(ending);
        if (text.len == 0 and term.len == 0) return;

        const port = self.ports[0] orelse {
            self.setExportMessage("send: D0 not connected", true);
            return;
        };
        const payload = std.mem.concat(arena, u8, &.{ text, term }) catch return;
        // Stamp before queueing so the echo always sorts before its reply.
        const now: u64 = @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
        port.send(payload) catch {
            self.setExportMessage("send: queue full, try again", true);
            return;
        };

        const owned = self.allocator.dupe(u8, text) catch return;
        self.appendLine(.{
            .port_id = 0,
            .timestamp_ns = now,
            .text = owned,
            .terminator = ending,
            .direction = .tx,
        }) catch {
            self.allocator.free(owned);
            return;
        };
        if (self.follow and self.lines_count > 0) {
            self.list_view.cursor = @intCast(self.lines_count - 1);
            self.list_view.ensureScroll();
        }
        self.send_bar.commitSent(text);
    }

    // Re-render every selected line off-screen at the current width and copy
    // exactly the selected cells, so the clipboard matches what is shown.
    fn copySelection(self: *Monitor, ctx: *vxfw.EventContext) !void {
        const range = self.selectionRange() orelse {
            self.setExportMessage("copy: nothing selected", true);
            return;
        };
        const width = self.line_width;
        if (width == 0) return;

        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const cells = try arena.alloc(vaxis.Cell, width);
        var out: std.ArrayList(u8) = .empty;

        var idx = range.start_idx;
        while (idx <= range.end_idx) : (idx += 1) {
            const draw_ctx: vxfw.DrawContext = .{
                .arena = arena,
                .min = .{ .width = width, .height = 0 },
                .max = .{ .width = width, .height = null },
                .cell_size = .{},
            };
            const surf = try drawLineFn(&self.line_entries[idx], draw_ctx);
            @memset(cells, .{ .default = true });
            selection.flattenRow(surf, 0, cells);

            const from: u16 = if (idx == range.start_idx) range.start_col else 0;
            const to: u16 = if (idx == range.end_idx) range.end_col else width - 1;
            if (idx != range.start_idx) try out.append(arena, '\n');
            try selection.appendCellText(arena, &out, cells, from, to);
        }

        try ctx.copyToClipboard(out.items);

        const n_lines = range.end_idx - range.start_idx + 1;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "copied {d} {s}", .{
            n_lines,
            if (n_lines == 1) "line" else "lines",
        }) catch "copied";
        self.setExportMessage(msg, false);
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

test "hotkeys are typed into the send bar while it is open" {
    const m = try std.testing.allocator.create(Monitor);
    defer std.testing.allocator.destroy(m);
    m.init(std.testing.allocator, std.testing.io, .{});
    defer m.deinit();

    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);

    try std.testing.expect(try m.handleKey(.{ .codepoint = 's', .text = "s" }, &ctx));
    try std.testing.expect(m.send_bar_open);

    inline for ("coef") |ch| {
        try std.testing.expect(try m.handleKey(.{ .codepoint = ch, .text = &[_]u8{ch} }, &ctx));
    }
    try std.testing.expect(try m.handleKey(.{ .codepoint = vaxis.Key.tab }, &ctx));

    // None of the hotkeys fired...
    try std.testing.expect(!m.overlay_open);
    try std.testing.expect(!m.save_prompt_open);
    try std.testing.expect(m.follow);
    try std.testing.expectEqual(DisplayMode.string, m.display_mode);
    // ...they went into the bar, and Tab changed the ending instead of the view.
    const text = try m.send_bar.currentText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("coef", text);
    try std.testing.expectEqual(types.Terminator.lf, m.send_bar.ending);

    // Ctrl+C is not consumed, so App still quits.
    try std.testing.expect(!try m.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }, &ctx));

    // Esc closes the bar; then 'f' is a hotkey again.
    try std.testing.expect(try m.handleKey(.{ .codepoint = vaxis.Key.escape }, &ctx));
    try std.testing.expect(!m.send_bar_open);
    try std.testing.expect(try m.handleKey(.{ .codepoint = 'f', .text = "f" }, &ctx));
    try std.testing.expect(!m.follow);
}

fn hueDegrees(c: vaxis.Color) f32 {
    const rgb = c.rgb;
    const r: f32 = @as(f32, @floatFromInt(rgb[0])) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(rgb[1])) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(rgb[2])) / 255.0;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const d = max - min;
    if (d == 0) return 0;
    var h: f32 = if (max == r)
        @mod((g - b) / d, 6.0)
    else if (max == g)
        (b - r) / d + 2.0
    else
        (r - g) / d + 4.0;
    h *= 60.0;
    return if (h < 0) h + 360.0 else h;
}

test "TX colour stands apart from every device colour" {
    const tx_hue = hueDegrees(theme.tx.fg);
    for (port_colors) |c| {
        const diff = @abs(tx_hue - hueDegrees(c));
        const dist = @min(diff, 360.0 - diff);
        try std.testing.expect(dist >= 40.0);
    }
    try std.testing.expectEqual(theme.tx.fg, theme.tx_tag.fg);
}

// Monitor with three lines, drawn once so `visible` maps rows to lines.
fn testMonitorWithLines(arena: std.mem.Allocator) !*Monitor {
    const m = try std.testing.allocator.create(Monitor);
    m.init(std.testing.allocator, std.testing.io, .{});
    for ([_][]const u8{ "one", "two", "three" }, 0..) |t, i| {
        try m.appendLine(.{
            .port_id = 0,
            .timestamp_ns = @intCast(i),
            .text = try std.testing.allocator.dupe(u8, t),
        });
    }
    m.list_view.cursor = 2;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{ .width = 80, .height = 20 },
        .max = .{ .width = 80, .height = 20 },
        .cell_size = .{},
    };
    _ = try m.widget().draw(ctx);
    return m;
}

fn testMouse(row: i32, col: i32, kind: vaxis.Mouse.Type) vaxis.Mouse {
    return .{ .row = @intCast(row), .col = @intCast(col), .button = .left, .mods = .{}, .type = kind };
}

test "clicking a line moves the cursor (and inspector) to it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try testMonitorWithLines(arena_state.allocator());
    defer std.testing.allocator.destroy(m);
    defer m.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);

    const row = m.visible.items[0].row;
    m.handleMouse(testMouse(row, 20, .press), &ctx);
    m.handleMouse(testMouse(row, 20, .release), &ctx);
    try std.testing.expectEqual(@as(u32, 0), m.list_view.cursor);
    // Like ↑: browsing older lines stops following new ones.
    try std.testing.expect(!m.follow);
}

test "dragging selects text without moving the cursor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try testMonitorWithLines(arena_state.allocator());
    defer std.testing.allocator.destroy(m);
    defer m.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);

    const row = m.visible.items[0].row;
    m.handleMouse(testMouse(row, 20, .press), &ctx);
    m.handleMouse(testMouse(row, 24, .drag), &ctx);
    m.handleMouse(testMouse(row, 24, .release), &ctx);
    try std.testing.expect(m.sel_active);
    try std.testing.expectEqual(@as(u32, 2), m.list_view.cursor);
    try std.testing.expect(m.follow);
}

fn hintLabel(hints: []const KeyHint, key: []const u8) ?[]const u8 {
    for (hints) |h| {
        if (std.mem.eql(u8, h.key, key)) return h.label;
    }
    return null;
}

test "footer hints show the current view mode, like follow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m = try std.testing.allocator.create(Monitor);
    defer std.testing.allocator.destroy(m);
    m.init(std.testing.allocator, std.testing.io, .{});
    defer m.deinit();

    const expected = [_]struct { mode: DisplayMode, label: []const u8 }{
        .{ .mode = .string, .label = "view:string" },
        .{ .mode = .string_and_hex, .label = "view:string+hex" },
        .{ .mode = .hex_only, .label = "view:hex" },
    };
    for (expected) |e| {
        m.display_mode = e.mode;
        try std.testing.expectEqualStrings(e.label, hintLabel(try m.keyHints(arena), "Tab").?);
    }
    try std.testing.expectEqualStrings("follow:on", hintLabel(try m.keyHints(arena), "f").?);
}
