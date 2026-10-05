//! One-line "send to D0" input bar. Pure helpers (history, ending cycle,
//! history file location) live at the top and are unit tested; the widget
//! itself is wired into Monitor.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const types = @import("types.zig");

pub const max_history_entries: usize = 200;
pub const history_file_name = "history.txt";
// Larger files are treated as unreadable (and then left untouched).
pub const history_max_bytes: usize = 1 << 20;

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    // Index into entries while browsing with ↑/↓; null = editing the draft.
    pos: ?usize = null,
    // What the user had typed before the first ↑, restored after the newest entry.
    draft: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        self.resetNav();
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
    }

    /// Record a sent command. Empty commands and a repeat of the newest entry
    /// are skipped; the oldest entry is dropped past max_history_entries.
    pub fn push(self: *History, cmd: []const u8) !void {
        self.resetNav();
        if (cmd.len == 0) return;
        const items = self.entries.items;
        if (items.len > 0 and std.mem.eql(u8, items[items.len - 1], cmd)) return;

        const copy = try self.allocator.dupe(u8, cmd);
        errdefer self.allocator.free(copy);
        try self.entries.append(self.allocator, copy);
        if (self.entries.items.len > max_history_entries) {
            self.allocator.free(self.entries.orderedRemove(0));
        }
    }

    /// ↑: step to an older entry. `current` is the input text, saved as the
    /// draft when browsing starts. Returns null when there is no history.
    pub fn prev(self: *History, current: []const u8) !?[]const u8 {
        const n = self.entries.items.len;
        if (n == 0) return null;
        if (self.pos) |p| {
            if (p > 0) self.pos = p - 1;
        } else {
            if (self.draft) |d| self.allocator.free(d);
            self.draft = try self.allocator.dupe(u8, current);
            self.pos = n - 1;
        }
        return self.entries.items[self.pos.?];
    }

    /// ↓: step to a newer entry, then back to the draft. Returns null when not
    /// browsing. The returned slice is valid until the next History call.
    pub fn next(self: *History) ?[]const u8 {
        const p = self.pos orelse return null;
        if (p + 1 < self.entries.items.len) {
            self.pos = p + 1;
            return self.entries.items[p + 1];
        }
        self.pos = null;
        return self.draft orelse "";
    }

    pub fn resetNav(self: *History) void {
        if (self.draft) |d| self.allocator.free(d);
        self.draft = null;
        self.pos = null;
    }

    /// One command per line, LF-terminated. Caller owns the result.
    pub fn serialize(self: *const History, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.entries.items) |e| {
            try out.appendSlice(gpa, e);
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    /// Append commands from a history file. Accepts LF or CRLF; blank lines
    /// are skipped by push.
    pub fn load(self: *History, data: []const u8) !void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            try self.push(std.mem.trimEnd(u8, raw, "\r"));
        }
    }
};

/// Tab in the send bar: \r\n → \n → \r → none → \r\n.
pub fn nextEnding(t: types.Terminator) types.Terminator {
    return switch (t) {
        .crlf => .lf,
        .lf => .cr,
        .cr => .none,
        .none, .lfcr => .crlf,
    };
}

pub const EnvVars = struct {
    appdata: ?[]const u8 = null,
    home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
};

/// History directory = `base` (an existing absolute dir) + `sub` (created on
/// first save). The file inside it is history_file_name.
pub const HistoryLocation = struct {
    base: []const u8,
    sub: []const u8,
};

pub fn historyLocation(os: std.Target.Os.Tag, env: EnvVars) ?HistoryLocation {
    switch (os) {
        .windows => {
            const base = absWindows(env.appdata) orelse return null;
            return .{ .base = base, .sub = "zsm" };
        },
        .macos => {
            const home = absPosix(env.home) orelse return null;
            return .{ .base = home, .sub = "Library/Application Support/zsm" };
        },
        else => {
            if (absPosix(env.xdg_state_home)) |xdg| return .{ .base = xdg, .sub = "zsm" };
            const home = absPosix(env.home) orelse return null;
            return .{ .base = home, .sub = ".local/state/zsm" };
        },
    }
}

// Only absolute bases are usable: openDirAbsolute asserts on anything else.
fn absWindows(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (std.fs.path.isAbsoluteWindows(v)) v else null;
}

fn absPosix(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (std.fs.path.isAbsolutePosix(v)) v else null;
}

pub const KeyResult = enum { consumed, ignored, close, send };

pub const SendBar = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    input: vxfw.TextField,
    ending: types.Terminator = .crlf,
    history: History,
    // Set by Monitor before each draw; only changes the prompt text.
    d0_connected: bool = false,

    // Owned copy of the base directory; null = no persistent history.
    location: ?HistoryLocation = null,
    // False after an existing history file failed to load, so a save can't
    // replace it with just this session's commands.
    history_writable: bool = true,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: EnvVars) SendBar {
        var input = vxfw.TextField.init(allocator);
        input.style = theme.normal;
        var self: SendBar = .{
            .allocator = allocator,
            .io = io,
            .input = input,
            .history = History.init(allocator),
        };
        if (historyLocation(builtin.target.os.tag, env)) |loc| {
            if (allocator.dupe(u8, loc.base)) |base| {
                self.location = .{ .base = base, .sub = loc.sub };
            } else |_| {}
        }
        self.loadHistory();
        return self;
    }

    pub fn deinit(self: *SendBar) void {
        if (self.location) |loc| self.allocator.free(loc.base);
        self.history.deinit();
        self.input.deinit();
    }

    pub fn handleKey(self: *SendBar, key: vaxis.Key, ctx: *vxfw.EventContext) KeyResult {
        if (key.matches(vaxis.Key.escape, .{})) return .close;
        if (key.matches(vaxis.Key.enter, .{})) return .send;
        if (key.matches(vaxis.Key.tab, .{})) {
            self.ending = nextEnding(self.ending);
            return .consumed;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            const current = self.currentText(self.allocator) catch return .consumed;
            defer self.allocator.free(current);
            const entry = (self.history.prev(current) catch return .consumed) orelse return .consumed;
            self.setText(entry);
            return .consumed;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (self.history.next()) |entry| self.setText(entry);
            return .consumed;
        }
        const outer_consumed = ctx.consume_event;
        ctx.consume_event = false;
        self.input.handleEvent(ctx, .{ .key_press = key }) catch {};
        const field_consumed = ctx.consume_event;
        ctx.consume_event = field_consumed or outer_consumed;
        return if (field_consumed) .consumed else .ignored;
    }

    /// Current input text (gap buffer joined). Caller owns the copy.
    pub fn currentText(self: *const SendBar, alloc: std.mem.Allocator) ![]u8 {
        return std.mem.concat(alloc, u8, &.{
            self.input.buf.firstHalf(),
            self.input.buf.secondHalf(),
        });
    }

    /// After a successful send: remember the command and clear the input.
    pub fn commitSent(self: *SendBar, text: []const u8) void {
        self.history.push(text) catch {};
        self.saveHistory();
        self.input.clearRetainingCapacity();
    }

    fn setText(self: *SendBar, text: []const u8) void {
        self.input.clearRetainingCapacity();
        self.input.insertSliceAtCursor(text) catch {};
    }

    pub fn loadHistoryFrom(self: *SendBar, dir: std.Io.Dir) void {
        const data = dir.readFileAlloc(self.io, history_file_name, self.allocator, .limited(history_max_bytes)) catch |err| {
            // No file yet is the normal first run; anything else means a file
            // exists that we couldn't read, so leave it alone.
            if (err != error.FileNotFound) self.history_writable = false;
            return;
        };
        defer self.allocator.free(data);
        self.history.load(data) catch {
            self.history_writable = false;
        };
    }

    /// Replace the history file atomically (temp file + rename), so a crash
    /// mid-write can't leave it truncated.
    pub fn saveHistoryTo(self: *SendBar, dir: std.Io.Dir) void {
        if (!self.history_writable) return;
        const data = self.history.serialize(self.allocator) catch return;
        defer self.allocator.free(data);
        var af = dir.createFileAtomic(self.io, history_file_name, .{ .replace = true }) catch return;
        defer af.deinit(self.io);
        af.file.writeStreamingAll(self.io, data) catch return;
        af.replace(self.io) catch {};
    }

    fn loadHistory(self: *SendBar) void {
        var dir = self.openHistoryDir(false) orelse return;
        defer dir.close(self.io);
        self.loadHistoryFrom(dir);
    }

    fn saveHistory(self: *SendBar) void {
        var dir = self.openHistoryDir(true) orelse return;
        defer dir.close(self.io);
        self.saveHistoryTo(dir);
    }

    fn openHistoryDir(self: *SendBar, create: bool) ?std.Io.Dir {
        const loc = self.location orelse return null;
        var base = std.Io.Dir.openDirAbsolute(self.io, loc.base, .{}) catch return null;
        defer base.close(self.io);
        if (create) return base.createDirPathOpen(self.io, loc.sub, .{}) catch null;
        return base.openDir(self.io, loc.sub, .{}) catch null;
    }

    pub fn widget(self: *SendBar) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawFn };
    }

    // One row: "D0 ❯ <input>                [\r\n]"
    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SendBar = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        const prompt: []const u8 = if (self.d0_connected) " D0 ❯ " else " D0 (not connected) ❯ ";
        const prompt_style: vaxis.Style = if (self.d0_connected) theme.title else theme.status_err;
        const notation = types.terminatorNotation(self.ending);
        const label = try arena.print(" [{s}] ", .{if (notation.len == 0) "none" else notation});

        const prompt_w: u16 = @intCast(@min(ctx.stringWidth(prompt), max.width));
        const label_w: u16 = @intCast(@min(ctx.stringWidth(label), max.width -| prompt_w));
        const field_w: u16 = max.width -| prompt_w -| label_w;

        const prompt_txt = vxfw.Text{ .text = prompt, .style = prompt_style, .softwrap = false, .overflow = .clip };
        const prompt_surf = try prompt_txt.draw(ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = prompt_w, .height = 1 },
        ));

        // The bar isn't the vxfw-focused widget, so the hardware cursor never
        // shows — paint a block cursor like SavePrompt does.
        var field_surf = try self.input.draw(ctx.withConstraints(
            .{ .width = field_w, .height = 1 },
            .{ .width = field_w, .height = 1 },
        ));
        if (field_surf.cursor) |cur| {
            if (cur.col < field_surf.size.width) {
                field_surf.buffer[cur.col].style.reverse = true;
            }
        }

        const label_txt = vxfw.Text{ .text = label, .style = theme.subtitle, .softwrap = false, .overflow = .clip };
        const label_surf = try label_txt.draw(ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = label_w, .height = 1 },
        ));

        const children = try arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = prompt_surf };
        children[1] = .{ .origin = .{ .row = 0, .col = @intCast(prompt_w) }, .surface = field_surf };
        children[2] = .{ .origin = .{ .row = 0, .col = @intCast(prompt_w + field_w) }, .surface = label_surf };

        return .{
            .size = .{ .width = max.width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const testing = std.testing;

test "push ignores empty and repeated commands" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.push("");
    try h.push("AT");
    try h.push("AT");
    try h.push("ATI");
    try h.push("AT");
    try testing.expectEqual(@as(usize, 3), h.entries.items.len);
    try testing.expectEqualStrings("AT", h.entries.items[0]);
    try testing.expectEqualStrings("ATI", h.entries.items[1]);
    try testing.expectEqualStrings("AT", h.entries.items[2]);
}

test "push caps history at max entries, dropping the oldest" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    var buf: [16]u8 = undefined;
    for (0..max_history_entries + 5) |i| {
        try h.push(try std.fmt.bufPrint(&buf, "cmd{d}", .{i}));
    }
    try testing.expectEqual(max_history_entries, h.entries.items.len);
    try testing.expectEqualStrings("cmd5", h.entries.items[0]);
}

test "prev and next walk history and restore the draft" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.push("one");
    try h.push("two");

    try testing.expectEqualStrings("two", (try h.prev("draft")).?);
    try testing.expectEqualStrings("one", (try h.prev("two")).?);
    // Stays on the oldest entry.
    try testing.expectEqualStrings("one", (try h.prev("one")).?);
    try testing.expectEqualStrings("two", h.next().?);
    try testing.expectEqualStrings("draft", h.next().?);
    // Past the draft: nothing more.
    try testing.expect(h.next() == null);
}

test "navigation on empty history is a no-op" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try testing.expect((try h.prev("typed")) == null);
    try testing.expect(h.next() == null);
}

test "push resets navigation" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.push("one");
    _ = try h.prev("draft");
    try h.push("two");
    try testing.expect(h.next() == null);
    try testing.expectEqualStrings("two", (try h.prev("")).?);
}

test "serialize writes one command per line" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.push("AT");
    try h.push("AT+GMR");
    const data = try h.serialize(testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("AT\nAT+GMR\n", data);
}

test "load tolerates CRLF and blank lines" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.load("AT\r\n\r\nATI\r\n\n");
    try testing.expectEqual(@as(usize, 2), h.entries.items.len);
    try testing.expectEqualStrings("AT", h.entries.items[0]);
    try testing.expectEqualStrings("ATI", h.entries.items[1]);
}

test "load keeps newest entries" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(testing.allocator);
    var buf: [16]u8 = undefined;
    for (0..max_history_entries + 10) |i| {
        try data.appendSlice(testing.allocator, try std.fmt.bufPrint(&buf, "c{d}\n", .{i}));
    }
    try h.load(data.items);
    try testing.expectEqual(max_history_entries, h.entries.items.len);
    try testing.expectEqualStrings("c10", h.entries.items[0]);
}

test "nextEnding cycles crlf, lf, cr, none" {
    try testing.expectEqual(types.Terminator.lf, nextEnding(.crlf));
    try testing.expectEqual(types.Terminator.cr, nextEnding(.lf));
    try testing.expectEqual(types.Terminator.none, nextEnding(.cr));
    try testing.expectEqual(types.Terminator.crlf, nextEnding(.none));
    try testing.expectEqual(types.Terminator.crlf, nextEnding(.lfcr));
}

test "historyLocation per OS" {
    const env: EnvVars = .{
        .appdata = "C:\\Users\\me\\AppData\\Roaming",
        .home = "/home/me",
        .xdg_state_home = "/home/me/.xdg-state",
    };
    const win = historyLocation(.windows, env).?;
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming", win.base);
    try testing.expectEqualStrings("zsm", win.sub);

    const mac = historyLocation(.macos, env).?;
    try testing.expectEqualStrings("/home/me", mac.base);
    try testing.expectEqualStrings("Library/Application Support/zsm", mac.sub);

    const linux = historyLocation(.linux, env).?;
    try testing.expectEqualStrings("/home/me/.xdg-state", linux.base);
    try testing.expectEqualStrings("zsm", linux.sub);
}

test "historyLocation falls back and handles missing vars" {
    // Relative or empty XDG_STATE_HOME is ignored per the XDG spec.
    const linux = historyLocation(.linux, .{ .home = "/home/me", .xdg_state_home = "rel/path" }).?;
    try testing.expectEqualStrings("/home/me", linux.base);
    try testing.expectEqualStrings(".local/state/zsm", linux.sub);

    try testing.expect(historyLocation(.windows, .{ .appdata = "" }) == null);
    try testing.expect(historyLocation(.macos, .{}) == null);
    try testing.expect(historyLocation(.linux, .{}) == null);
}

test "historyLocation rejects relative base dirs" {
    // openDirAbsolute asserts on relative paths, so these must not get through.
    try testing.expect(historyLocation(.windows, .{ .appdata = "C:foo" }) == null);
    try testing.expect(historyLocation(.windows, .{ .appdata = "AppData" }) == null);
    try testing.expect(historyLocation(.macos, .{ .home = "rel" }) == null);
    try testing.expect(historyLocation(.linux, .{ .home = "tmp" }) == null);
    try testing.expect(historyLocation(.linux, .{ .home = "tmp", .xdg_state_home = "rel" }) == null);
}

test "history survives save and load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var a = SendBar.init(testing.allocator, testing.io, .{});
    defer a.deinit();
    try a.history.push("AT");
    try a.history.push("Grüße");
    a.saveHistoryTo(tmp.dir);

    var b = SendBar.init(testing.allocator, testing.io, .{});
    defer b.deinit();
    b.loadHistoryFrom(tmp.dir);
    try testing.expectEqual(@as(usize, 2), b.history.entries.items.len);
    try testing.expectEqualStrings("AT", b.history.entries.items[0]);
    try testing.expectEqualStrings("Grüße", b.history.entries.items[1]);
}

test "loading a missing history file leaves history empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bar = SendBar.init(testing.allocator, testing.io, .{});
    defer bar.deinit();
    bar.loadHistoryFrom(tmp.dir);
    try testing.expectEqual(@as(usize, 0), bar.history.entries.items.len);
}

test "a history file that failed to load is not overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Bigger than the load limit, so loading fails with StreamTooLong.
    const big = try testing.allocator.alloc(u8, history_max_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = history_file_name, .data = big });

    var bar = SendBar.init(testing.allocator, testing.io, .{});
    defer bar.deinit();
    bar.loadHistoryFrom(tmp.dir);
    try bar.history.push("AT");
    bar.saveHistoryTo(tmp.dir);

    const after = try tmp.dir.readFileAlloc(testing.io, history_file_name, testing.allocator, .limited(history_max_bytes * 2));
    defer testing.allocator.free(after);
    try testing.expectEqual(big.len, after.len);
}
