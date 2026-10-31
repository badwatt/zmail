//! amail TUI: the terminal adapter.
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
pub const run = @import("run.zig");
pub const session = @import("session.zig");

test {
    _ = @import("cli.zig");
}
