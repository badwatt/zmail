//! Terminal lifecycle and the demo account. This is the process boundary: it
//! sets raw mode, switches to the alternate screen, enables mouse reporting,
//! and hands control to the session. Covered by the end-to-end PTY test.

const std = @import("std");
const core = @import("core");

const os = @import("os.zig");
const session_mod = @import("session.zig");
const theme_mod = @import("theme.zig");

const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h";
const leave_screen = "\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l";

pub fn run(gpa: std.mem.Allocator, io: std.Io) !u8 {
    _ = io; // The session writes through the System port.

    var posix = os.Posix.init(std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    const system = posix.system();

    try system.enter_raw();
    defer system.leave_raw() catch {};
    try system.write(enter_screen);
    defer system.write(leave_screen) catch {};

    var mail = core.memory_mail.MemoryMail.init();
    try core.demo.seed(&mail, os.now_unix());

    var session: session_mod.Session = undefined;
    try session.init(gpa, .{
        .mail = mail.mail(),
        .system = system,
        .theme = theme_for_environment(),
        .now = os.now_unix,
    });
    defer session.deinit();

    session.loop();
    return 0;
}

fn theme_for_environment() theme_mod.Theme {
    if (os.env("NO_COLOR") != null) return theme_mod.Theme.mono();
    if (os.env("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return theme_mod.Theme.mono();
    }
    return theme_mod.Theme.dark();
}
