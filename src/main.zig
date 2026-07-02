const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const App = @import("app.zig").App;

comptime {
    _ = @import("monitor.zig");
    _ = @import("inspector.zig");
    _ = @import("line_buf.zig");
    _ = @import("ring.zig");
    _ = @import("export.zig");
    _ = @import("save_prompt.zig");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, alloc, init.environ_map, &buffer);
    defer app.deinit();

    const model = try alloc.create(App);
    defer alloc.destroy(model);
    model.* = .{};
    model.init(alloc, io);
    defer model.deinit();

    try app.run(model.widget(), .{});
}
