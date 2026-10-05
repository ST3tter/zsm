const vaxis = @import("vaxis");

pub const accent = vaxis.Color{ .rgb = .{ 0, 200, 220 } };
pub const dim_fg = vaxis.Color{ .index = 244 };
pub const ok_c = vaxis.Color{ .rgb = .{ 80, 200, 120 } };
pub const warn_c = vaxis.Color{ .rgb = .{ 240, 180, 40 } };
pub const err_c = vaxis.Color{ .rgb = .{ 220, 80, 80 } };
// Sent (TX) lines. Violet: the widest hue gap left by the four device
// colours (cyan, orange, green, pink) and the status red/yellow/green.
pub const tx_c = vaxis.Color{ .rgb = .{ 170, 140, 255 } };

pub const border: vaxis.Style = .{ .fg = accent };
pub const title: vaxis.Style = .{ .fg = accent, .bold = true };
pub const subtitle: vaxis.Style = .{ .fg = dim_fg };
pub const selected: vaxis.Style = .{ .fg = accent, .bold = true };
pub const normal: vaxis.Style = .{};
pub const tx: vaxis.Style = .{ .fg = tx_c };
pub const tx_tag: vaxis.Style = .{ .fg = tx_c, .bold = true };

pub const status_idle: vaxis.Style = .{ .fg = dim_fg };
pub const status_ok: vaxis.Style = .{ .fg = ok_c };
pub const status_warn: vaxis.Style = .{ .fg = warn_c, .bold = true };
pub const status_err: vaxis.Style = .{ .fg = err_c, .bold = true };
