//! zmail TUI: the terminal adapter.
//!
//! Layering, from the outside in:
//!   `run`      process entry (argv -> intent)
//!   `session`  terminal lifecycle and the event loop
//!   `input`    bytes -> keys, `keymap` keys -> core commands
//!   `render`   application state -> cells, `screen` cells -> ANSI
//!   `os`       the only place that talks to termios, fds, and ioctl
//!
//! Only `session` and `render` know about `core`; `input`, `keymap`, `screen`
//! are pure and know nothing about mail.

const std = @import("std");

pub const cli = @import("cli.zig");
pub const screen = @import("screen.zig");
pub const theme = @import("theme.zig");
pub const wrap = @import("wrap.zig");
pub const graphics = @import("graphics.zig");
pub const halfblocks = @import("halfblocks.zig");
pub const selection = @import("selection.zig");
pub const clipboard = @import("clipboard.zig");
pub const layout = @import("layout.zig");
pub const input = @import("input.zig");
pub const keymap = @import("keymap.zig");
pub const render = @import("render.zig");
pub const system = @import("system.zig");
pub const os = @import("os.zig");
pub const progress = @import("progress.zig");
pub const splash_painter = @import("splash_painter.zig");
pub const session = @import("session.zig");
pub const refresh = @import("refresh.zig");
pub const setup_session = @import("setup_session.zig");
pub const launch = @import("launch.zig");
pub const run = @import("run.zig");

test {
    _ = @import("cli.zig");
    _ = @import("screen.zig");
    _ = @import("theme.zig");
    _ = @import("wrap.zig");
    _ = @import("graphics.zig");
    _ = @import("halfblocks.zig");
    _ = @import("selection.zig");
    _ = @import("clipboard.zig");
    _ = @import("layout.zig");
    _ = @import("input.zig");
    _ = @import("keymap.zig");
    _ = @import("render.zig");
    _ = @import("system.zig");
    _ = @import("os.zig");
    _ = @import("progress.zig");
    _ = @import("splash_painter.zig");
    _ = @import("session.zig");
    _ = @import("setup_session.zig");
    _ = @import("run.zig");
}
