//! The terminal's own progress bar: "busy", and nothing more.
//!
//! `OSC 9;4` gives a program four states, and the only honest one for work whose
//! length is unknown is *indeterminate*. The terminal draws a fill for a
//! percentage, so sending a number would be an animation drawn as a measurement --
//! and the number that moves would only ever be a clock. What actually moves in
//! this app is the shimmer on the screen, which it draws itself; this is the flag
//! the window shows, so the tab says "working" even when the terminal has focus
//! somewhere else.
//!
//! Off until the process boundary says the terminal can take it: a pipe, a log, or
//! `TERM=dumb` must not receive escape sequences.

const std = @import("std");
const core = @import("core");
const system_mod = @import("system.zig");
const System = system_mod.System;

/// Ghostty resets a progress state it has not heard about for about fifteen
/// seconds, so a long wait repeats itself. Ten leaves room for a missed tick.
pub const repeat_ms: i64 = 10_000;

var enabled: bool = false;
/// The port to write through: the session's, which is the process's.
var port: ?System = null;
var active: bool = false;
/// What the terminal was last told.
var shown: core.progress.State = .clear;
var shown_at_ms: i64 = 0;

pub fn enable(value: bool) void {
    enabled = value;
    // A module turned off and on again has told the terminal nothing.
    shown = .clear;
    shown_at_ms = 0;
    if (!value) active = false;
}

pub fn is_enabled() bool {
    return enabled;
}

/// The state the terminal is showing, for tests and for the one place that has to
/// know whether a bar is up.
pub fn state() core.progress.State {
    return shown;
}

/// Puts the bar up, once, for as long as the work lasts.
pub fn begin(system: System, now_ms: i64) void {
    if (!enabled) return;
    port = system;
    if (active) return;
    active = true;
    write(system, .indeterminate, now_ms, false);
}

/// Takes it down. Whatever the wait did, the bar goes: a bar left behind says
/// "busy" forever.
pub fn end() void {
    if (!active) return;
    active = false;
    if (port) |system| write(system, .clear, 0, false);
}

/// Waiting for a human (a browser, an editor): the bar holds still and says so,
/// instead of claiming work that is not happening.
pub fn pause() void {
    if (!active) return;
    if (port) |system| write(system, .paused, 0, false);
}

pub fn unpause() void {
    if (!active) return;
    if (port) |system| write(system, .indeterminate, 0, false);
}

/// Takes the bar down without touching the port's lifetime: the one caller is the
/// Ctrl+C handler, which cannot wait for anything. The process ends right after, so
/// there is nothing to leave tidy.
pub fn abandon(system: System) void {
    active = false;
    write(system, .clear, 0, false);
}

/// Repeats the bar for a wait that outlives the terminal's memory of it.
pub fn keep_alive(now_ms: i64) void {
    if (!active or shown == .clear) return;
    if (now_ms - shown_at_ms < repeat_ms) return;
    // Said again even though nothing changed: that is the whole point of it.
    if (port) |system| write(system, shown, now_ms, true);
}

fn write(system: System, next: core.progress.State, now_ms: i64, force: bool) void {
    if (!force and next == shown and next != .clear) return;

    var buffer: [core.progress.max_sequence]u8 = undefined;
    const bytes = core.progress.sequence(next, 0, &buffer);
    if (bytes.len == 0) return;
    system.write(bytes) catch return;
    shown = next;
    shown_at_ms = now_ms;
}

const testing = std.testing;

test "nothing is written until the terminal is known to take it" {
    var fake: system_mod.Fake = .{};
    enable(false);
    begin(fake.system(), 0);
    pause();
    unpause();
    keep_alive(60_000);
    end();
    try testing.expectEqualStrings("", fake.output_text());
    try testing.expectEqual(core.progress.State.clear, state());
    try testing.expect(!is_enabled());
}

test "the bar goes up once, holds, and comes down once" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system(), 0);
    try testing.expectEqualStrings("\x1b]9;4;3;0\x1b\\", fake.output_text());
    try testing.expectEqual(core.progress.State.indeterminate, state());

    // Work already in progress: nothing more to say.
    begin(fake.system(), 10);
    try testing.expectEqualStrings("\x1b]9;4;3;0\x1b\\", fake.output_text());

    end();
    try testing.expectEqual(core.progress.State.clear, state());
    try testing.expect(std.mem.endsWith(u8, fake.output_text(), "\x1b]9;4;0;0\x1b\\"));

    // Nothing to take down is not an escape sequence.
    fake.output_len = 0;
    end();
    try testing.expectEqualStrings("", fake.output_text());
}

test "a human in a browser holds the bar, and a long wait repeats it" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system(), 1_000);
    fake.output_len = 0;

    pause();
    try testing.expectEqual(core.progress.State.paused, state());
    try testing.expectEqualStrings("\x1b]9;4;4\x1b\\", fake.output_text());

    fake.output_len = 0;
    unpause();
    try testing.expectEqual(core.progress.State.indeterminate, state());

    // Inside the window the terminal still remembers: silence.
    fake.output_len = 0;
    keep_alive(5_000);
    try testing.expectEqualStrings("", fake.output_text());

    // Past it, the bar is said again.
    keep_alive(1_000 + repeat_ms);
    try testing.expectEqualStrings("\x1b]9;4;3;0\x1b\\", fake.output_text());
}

test "a terminal that refuses the escape does not stop the work" {
    var fake: system_mod.Fake = .{ .write_failure = error.IoError };
    enable(true);
    defer enable(false);

    begin(fake.system(), 0);
    try testing.expectEqual(core.progress.State.clear, state());
    abandon(fake.system());
    try testing.expectEqual(core.progress.State.clear, state());
}
