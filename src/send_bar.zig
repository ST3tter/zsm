//! One-line "send to D0" input bar. Pure helpers (history, ending cycle,
//! history file location) live at the top and are unit tested; the widget
//! itself is wired into Monitor.

const std = @import("std");
const types = @import("types.zig");

pub const max_history_entries: usize = 200;
pub const history_file_name = "history.txt";

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
            const base = nonEmpty(env.appdata) orelse return null;
            return .{ .base = base, .sub = "zsm" };
        },
        .macos => {
            const home = nonEmpty(env.home) orelse return null;
            return .{ .base = home, .sub = "Library/Application Support/zsm" };
        },
        else => {
            if (nonEmpty(env.xdg_state_home)) |xdg| {
                if (std.fs.path.isAbsolutePosix(xdg)) return .{ .base = xdg, .sub = "zsm" };
            }
            const home = nonEmpty(env.home) orelse return null;
            return .{ .base = home, .sub = ".local/state/zsm" };
        },
    }
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

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
