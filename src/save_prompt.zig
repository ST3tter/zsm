//! Modal "where do I save the export?" prompt. The directory part is
//! editable with tab completion; the filename is fixed and shown below the
//! input. Pure path/completion helpers live at the top and are unit tested;
//! the widget itself is wired into Monitor.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");

const is_windows = builtin.os.tag == .windows;
// Windows and macOS filesystems are case-insensitive by default.
const fold_case = is_windows or builtin.os.tag == .macos;
const native_sep: []const u8 = if (is_windows) "\\" else "/";

pub const KeyResult = enum { consumed, ignored, cancel, save };

pub const SavePrompt = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    input: vxfw.TextField,

    filename_buf: [64]u8 = undefined,
    filename_len: usize = 0,

    // Tab-cycling state: candidate directory names for the component we last
    // completed, plus the full input text right after our insert. Cycling
    // continues only while the buffer still equals that snapshot.
    matches: std.ArrayList([]u8) = .empty,
    match_idx: usize = 0,
    cycle_snapshot: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SavePrompt {
        var input = vxfw.TextField.init(allocator);
        input.style = theme.normal;
        return .{ .allocator = allocator, .io = io, .input = input };
    }

    pub fn deinit(self: *SavePrompt) void {
        self.resetCycle();
        self.matches.deinit(self.allocator);
        self.input.deinit();
    }

    /// Open the prompt for the given (fixed) filename. The directory input is
    /// prefilled with the cwd plus a trailing separator.
    pub fn open(self: *SavePrompt, fname: []const u8) !void {
        const len = @min(fname.len, self.filename_buf.len);
        @memcpy(self.filename_buf[0..len], fname[0..len]);
        self.filename_len = len;

        self.resetCycle();
        self.input.clearRetainingCapacity();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPath(self.io, &buf) catch 0;
        if (n > 0) {
            try self.input.insertSliceAtCursor(buf[0..n]);
            if (!isSep(buf[n - 1], is_windows))
                try self.input.insertSliceAtCursor(native_sep);
        }
    }

    pub fn filename(self: *const SavePrompt) []const u8 {
        return self.filename_buf[0..self.filename_len];
    }

    /// Current directory text (gap buffer joined). Caller owns the copy.
    pub fn currentText(self: *const SavePrompt, alloc: std.mem.Allocator) ![]u8 {
        return std.mem.concat(alloc, u8, &.{
            self.input.buf.firstHalf(),
            self.input.buf.secondHalf(),
        });
    }

    pub fn handleKey(self: *SavePrompt, key: vaxis.Key, ctx: *vxfw.EventContext) KeyResult {
        if (key.matches(vaxis.Key.escape, .{})) return .cancel;
        if (key.matches(vaxis.Key.enter, .{})) return .save;
        if (key.matches(vaxis.Key.tab, .{})) {
            self.doComplete() catch {};
            return .consumed;
        }
        // Any edit invalidates an active completion cycle.
        self.resetCycle();
        const outer_consumed = ctx.consume_event;
        ctx.consume_event = false;
        self.input.handleEvent(ctx, .{ .key_press = key }) catch {};
        const field_consumed = ctx.consume_event;
        ctx.consume_event = field_consumed or outer_consumed;
        return if (field_consumed) .consumed else .ignored;
    }

    fn resetCycle(self: *SavePrompt) void {
        for (self.matches.items) |m| self.allocator.free(m);
        self.matches.clearRetainingCapacity();
        self.match_idx = 0;
        if (self.cycle_snapshot) |s| {
            self.allocator.free(s);
            self.cycle_snapshot = null;
        }
    }

    fn storeSnapshot(self: *SavePrompt) !void {
        if (self.cycle_snapshot) |s| self.allocator.free(s);
        self.cycle_snapshot = try self.currentText(self.allocator);
    }

    fn doComplete(self: *SavePrompt) !void {
        const text = try self.currentText(self.allocator);
        defer self.allocator.free(text);
        const split = splitInput(text, is_windows);

        // Continue an active cycle while the buffer is untouched since our
        // last insert.
        if (self.cycle_snapshot) |snap| {
            if (self.matches.items.len > 1 and std.mem.eql(u8, snap, text)) {
                self.match_idx = (self.match_idx + 1) % self.matches.items.len;
                try self.replacePartial(split.partial.len, self.matches.items[self.match_idx], false);
                try self.storeSnapshot();
                return;
            }
        }
        self.resetCycle();

        try self.gatherMatches(split.parent, split.partial);
        std.mem.sort([]u8, self.matches.items, {}, nameLessThan);

        switch (completeFromMatches(self.matches.items, split.partial, fold_case)) {
            .none => {},
            .complete => |name| {
                try self.replacePartial(split.partial.len, name, true);
                self.resetCycle();
            },
            .extend => |prefix| {
                try self.replacePartial(split.partial.len, prefix, false);
                self.resetCycle();
            },
            .cycle => {
                self.match_idx = 0;
                try self.replacePartial(split.partial.len, self.matches.items[0], false);
                try self.storeSnapshot();
            },
        }
    }

    /// Delete the last `partial_bytes` of the input and insert `new` at the
    /// end (plus a separator for a unique, fully-completed directory).
    fn replacePartial(self: *SavePrompt, partial_bytes: usize, new: []const u8, add_sep: bool) !void {
        self.input.buf.moveGapRight(self.input.buf.secondHalf().len);
        self.input.buf.growGapLeft(partial_bytes);
        try self.input.insertSliceAtCursor(new);
        if (add_sep) try self.input.insertSliceAtCursor(native_sep);
    }

    fn gatherMatches(self: *SavePrompt, parent: []const u8, partial: []const u8) !void {
        const open_opts: std.Io.Dir.OpenOptions = .{ .iterate = true };
        var dir = blk: {
            if (parent.len == 0)
                break :blk std.Io.Dir.cwd().openDir(self.io, ".", open_opts) catch return;
            if (std.fs.path.isAbsolute(parent))
                break :blk std.Io.Dir.openDirAbsolute(self.io, parent, open_opts) catch return;
            break :blk std.Io.Dir.cwd().openDir(self.io, parent, open_opts) catch return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!matchesPrefix(entry.name, partial, fold_case)) continue;
            const copy = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(copy);
            try self.matches.append(self.allocator, copy);
        }
    }

    fn nameLessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn widget(self: *SavePrompt) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawFrame };
    }

    fn drawFrame(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SavePrompt = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;

        const inner_widget: vxfw.Widget = .{ .userdata = self, .drawFn = drawInner };

        const labels = try arena.alloc(vxfw.Border.BorderLabel, 1);
        labels[0] = .{ .text = " Export ", .alignment = .top_left };

        const border: vxfw.Border = .{
            .child = inner_widget,
            .style = theme.border,
            .labels = labels,
        };

        const ovw: u16 = @min(70, max.width -| 4);
        const ovh: u16 = @min(8, max.height -| 4);
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
        const self: *SavePrompt = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        const arena = ctx.arena;
        const col: u16 = 1;
        const inner_w: u16 = max.width -| (2 * col);

        var subs: std.ArrayList(vxfw.SubSurface) = .empty;
        const line_ctx = ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = inner_w, .height = 1 },
        );

        const title = vxfw.Text{ .text = "Save to directory:", .style = theme.title, .softwrap = false, .overflow = .clip };
        try subs.append(arena, .{ .origin = .{ .row = 0, .col = col }, .surface = try title.draw(line_ctx) });

        // Editable directory input. The prompt isn't the vxfw-focused widget,
        // so the hardware cursor never shows — paint a block cursor instead.
        const field_ctx = ctx.withConstraints(
            .{ .width = inner_w, .height = 1 },
            .{ .width = inner_w, .height = 1 },
        );
        var field_surf = try self.input.draw(field_ctx);
        if (field_surf.cursor) |cur| {
            if (cur.col < field_surf.size.width) {
                field_surf.buffer[cur.col].style.reverse = true;
            }
        }
        try subs.append(arena, .{ .origin = .{ .row = 1, .col = col }, .surface = field_surf });

        const file_text = try std.fmt.allocPrint(arena, "File: {s}", .{self.filename()});
        const file_line = vxfw.Text{ .text = file_text, .style = theme.subtitle, .softwrap = false, .overflow = .clip };
        try subs.append(arena, .{ .origin = .{ .row = 3, .col = col }, .surface = try file_line.draw(line_ctx) });

        const footer_row: u16 = if (max.height >= 1) max.height - 1 else 0;
        const footer = vxfw.Text{ .text = "Tab:complete  Enter:save  Esc:cancel", .style = theme.subtitle, .softwrap = false, .overflow = .clip };
        try subs.append(arena, .{ .origin = .{ .row = @intCast(footer_row), .col = col }, .surface = try footer.draw(line_ctx) });

        return .{
            .size = max,
            .widget = .{ .userdata = self, .drawFn = drawInner },
            .buffer = &.{},
            .children = subs.items,
        };
    }
};

fn isSep(c: u8, windows: bool) bool {
    return c == '/' or (windows and c == '\\');
}

pub const SplitResult = struct {
    parent: []const u8, // up to and including the last separator ("" if none)
    partial: []const u8, // the component being typed after it
};

/// Split the prompt input into the already-complete parent directory and the
/// partial component under the cursor. On Windows both '/' and '\' separate.
pub fn splitInput(input: []const u8, windows: bool) SplitResult {
    var i: usize = input.len;
    while (i > 0) : (i -= 1) {
        if (isSep(input[i - 1], windows)) break;
    }
    return .{ .parent = input[0..i], .partial = input[i..] };
}

/// Does `name` start with `partial`? ASCII case-insensitive when requested
/// (Windows/macOS filesystems are case-insensitive by default).
pub fn matchesPrefix(name: []const u8, partial: []const u8, case_insensitive: bool) bool {
    if (partial.len > name.len) return false;
    return if (case_insensitive)
        std.ascii.startsWithIgnoreCase(name, partial)
    else
        std.mem.startsWith(u8, name, partial);
}

/// Longest common prefix of all names; bytes are taken from the first name.
/// Comparison is optionally ASCII case-insensitive.
pub fn longestCommonPrefix(names: []const []const u8, case_insensitive: bool) []const u8 {
    if (names.len == 0) return "";
    var len = names[0].len;
    for (names[1..]) |name| {
        var i: usize = 0;
        const limit = @min(len, name.len);
        while (i < limit) : (i += 1) {
            const a = names[0][i];
            const b = name[i];
            const eq = if (case_insensitive)
                std.ascii.toLower(a) == std.ascii.toLower(b)
            else
                a == b;
            if (!eq) break;
        }
        len = i;
    }
    return names[0][0..len];
}

/// Join the prompt's directory text with the fixed filename, inserting the
/// native separator only when needed. Empty dir means "cwd".
pub fn joinExportPath(
    arena: std.mem.Allocator,
    dir: []const u8,
    filename: []const u8,
    windows: bool,
) ![]const u8 {
    if (dir.len == 0) return arena.dupe(u8, filename);
    if (isSep(dir[dir.len - 1], windows))
        return std.mem.concat(arena, u8, &.{ dir, filename });
    const sep: []const u8 = if (windows) "\\" else "/";
    return std.mem.concat(arena, u8, &.{ dir, sep, filename });
}

pub const CompletionAction = union(enum) {
    none,
    /// single match: replace the partial with this and append a separator
    complete: []const u8,
    /// several matches with a longer shared prefix: replace the partial, no separator
    extend: []const u8,
    /// several matches, partial already at the shared prefix: cycle through them
    cycle,
};

/// Decide what Tab should do given the matching directory names. `matches`
/// must all start with `partial` (under the same case rule).
pub fn completeFromMatches(
    matches: []const []const u8,
    partial: []const u8,
    case_insensitive: bool,
) CompletionAction {
    if (matches.len == 0) return .none;
    if (matches.len == 1) return .{ .complete = matches[0] };
    const lcp = longestCommonPrefix(matches, case_insensitive);
    if (lcp.len > partial.len) return .{ .extend = lcp };
    return .cycle;
}

test "completeFromMatches picks the right tab action" {
    // no candidates: nothing to do
    try std.testing.expectEqual(CompletionAction.none, completeFromMatches(&.{}, "x", false));

    // single candidate: complete it fully (caller appends the separator)
    {
        const m = [_][]const u8{"Documents"};
        const action = completeFromMatches(&m, "Doc", false);
        try std.testing.expectEqualStrings("Documents", action.complete);
    }

    // several candidates sharing a longer prefix: extend to that prefix
    {
        const m = [_][]const u8{ "Documents", "Downloads" };
        const action = completeFromMatches(&m, "D", false);
        try std.testing.expectEqualStrings("Do", action.extend);
    }

    // several candidates, partial already at the common prefix: cycle
    {
        const m = [_][]const u8{ "Documents", "Downloads" };
        try std.testing.expectEqual(CompletionAction.cycle, completeFromMatches(&m, "Do", false));
    }

    // case-insensitive: "do" counts as already-at-prefix "Do"
    {
        const m = [_][]const u8{ "Documents", "Downloads" };
        try std.testing.expectEqual(CompletionAction.cycle, completeFromMatches(&m, "do", true));
    }
}

test "splitInput separates parent and partial component" {
    // plain component, no separator: everything is partial
    var r = splitInput("doc", false);
    try std.testing.expectEqualStrings("", r.parent);
    try std.testing.expectEqualStrings("doc", r.partial);

    // posix path
    r = splitInput("/home/tm/do", false);
    try std.testing.expectEqualStrings("/home/tm/", r.parent);
    try std.testing.expectEqualStrings("do", r.partial);

    // trailing separator: empty partial
    r = splitInput("/home/tm/", false);
    try std.testing.expectEqualStrings("/home/tm/", r.parent);
    try std.testing.expectEqualStrings("", r.partial);

    // empty input
    r = splitInput("", false);
    try std.testing.expectEqualStrings("", r.parent);
    try std.testing.expectEqualStrings("", r.partial);
}

test "splitInput accepts both separators on windows" {
    var r = splitInput("C:\\Users\\tm", true);
    try std.testing.expectEqualStrings("C:\\Users\\", r.parent);
    try std.testing.expectEqualStrings("tm", r.partial);

    r = splitInput("C:\\Users/tm", true);
    try std.testing.expectEqualStrings("C:\\Users/", r.parent);
    try std.testing.expectEqualStrings("tm", r.partial);

    // backslash is NOT a separator on posix
    r = splitInput("a\\b", false);
    try std.testing.expectEqualStrings("", r.parent);
    try std.testing.expectEqualStrings("a\\b", r.partial);
}

test "matchesPrefix respects case sensitivity flag" {
    try std.testing.expect(matchesPrefix("Documents", "Doc", false));
    try std.testing.expect(!matchesPrefix("Documents", "doc", false));
    try std.testing.expect(matchesPrefix("Documents", "doc", true));
    try std.testing.expect(!matchesPrefix("Documents", "docx", true));
    // empty partial matches everything
    try std.testing.expect(matchesPrefix("Documents", "", true));
    // partial longer than name never matches
    try std.testing.expect(!matchesPrefix("Do", "Documents", true));
}

test "longestCommonPrefix over candidate names" {
    const a = [_][]const u8{ "Documents", "Downloads", "Docker" };
    try std.testing.expectEqualStrings("Do", longestCommonPrefix(&a, false));

    const b = [_][]const u8{"Music"};
    try std.testing.expectEqualStrings("Music", longestCommonPrefix(&b, false));

    const c = [_][]const u8{ "abc", "xyz" };
    try std.testing.expectEqualStrings("", longestCommonPrefix(&c, false));

    // case-insensitive: length decided ignoring case, bytes from first name
    const d = [_][]const u8{ "DOCS", "docs-old" };
    try std.testing.expectEqualStrings("DOCS", longestCommonPrefix(&d, true));

    const e = [_][]const u8{};
    try std.testing.expectEqualStrings("", longestCommonPrefix(&e, false));
}

test "joinExportPath builds full target path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // empty dir: filename goes to cwd as-is
    try std.testing.expectEqualStrings(
        "out.csv",
        try joinExportPath(arena, "", "out.csv", false),
    );
    // trailing separator already present
    try std.testing.expectEqualStrings(
        "/tmp/out.csv",
        try joinExportPath(arena, "/tmp/", "out.csv", false),
    );
    // native separator inserted
    try std.testing.expectEqualStrings(
        "C:\\data\\out.csv",
        try joinExportPath(arena, "C:\\data", "out.csv", true),
    );
    // windows: a trailing forward slash also counts as a separator
    try std.testing.expectEqualStrings(
        "C:/data/out.csv",
        try joinExportPath(arena, "C:/data/", "out.csv", true),
    );
}
