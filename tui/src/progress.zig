//! The terminal's own progress bar: "busy", and nothing more.
//!
//! `OSC 9;4` gives a program four states, and the only honest one for work whose
//! length is unknown is *indeterminate*: the terminal draws a fill for a
//! percentage, so a moving number would be an animation drawn as a measurement.
//!
//! What makes the indeterminate bar move is the repetition: Ghostty animates it
//! from the updates themselves, and forgets a state it has not heard about, so the
//! state is sent every 100ms while the work lasts -- the same thing zix does.
//! Measured in a pty: six updates and a clear in the first second.
//!
//! Off until the process boundary says the terminal can take it: a pipe, a log, or
//! `TERM=dumb` must not receive escape sequences.

const std = @import("std");
const core = @import("core");
const os = @import("os.zig");
const system_mod = @import("system.zig");
const System = system_mod.System;

/// Ghostty animates an indeterminate bar from the updates themselves and forgets a
/// state it has not heard about for about fifteen seconds, so a bar that is sent
/// once stands still. zix sends this every 100ms; so does this.
pub const repeat_ms: i64 = 100;

var enabled: bool = false;
/// The port to write through: the session's, which is the process's.
var port: ?System = null;
var active: bool = false;
/// What the terminal was last told.
var shown: core.progress.State = .clear;
var shown_at_ms: i64 = 0;

var thread: ?std.Thread = null;
var stop = std.atomic.Value(bool).init(true);
var hold = std.atomic.Value(bool).init(false);

pub fn enable(value: bool) void {
    enabled = value;
    // A module turned off and on again has told the terminal nothing.
    shown = .clear;
    shown_at_ms = 0;
    if (!value) {
        active = false;
        join();
    }
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
    hold.store(false, .release);
    write(system, .indeterminate, now_ms);
    stop.store(false, .release);
    if (thread == null) thread = std.Thread.spawn(.{}, keep_moving, .{}) catch null;
}

/// Takes it down. Whatever the wait did, the bar goes: a bar left behind says
/// "busy" forever.
pub fn end() void {
    if (!active) return;
    active = false;
    join();
    if (port) |system| write(system, .clear, 0);
}

fn join() void {
    stop.store(true, .release);
    if (thread) |joined| {
        joined.join();
        thread = null;
    }
}

/// Waiting for a human (a browser, an editor): the bar holds still and says so,
/// instead of claiming work that is not happening.
pub fn pause() void {
    if (!active) return;
    hold.store(true, .release);
    if (port) |system| write(system, .paused, 0);
}

pub fn unpause() void {
    if (!active) return;
    hold.store(false, .release);
    if (port) |system| write(system, .indeterminate, 0);
}

/// Takes the bar down without touching the port's lifetime: the one caller is the
/// Ctrl+C handler, which cannot wait for anything. The process ends right after, so
/// there is nothing to leave tidy.
pub fn abandon(system: System) void {
    active = false;
    write(system, .clear, 0);
}

/// Repeats the bar while the work goes on: that repetition is what the terminal
/// animates, and what stops it forgetting. Sliced, so stopping joins in one slice.
fn keep_moving() void {
    while (true) {
        var waited: i64 = 0;
        while (waited < repeat_ms and !stop.load(.acquire)) : (waited += 10) os.sleep_ms(10);
        if (stop.load(.acquire)) return;
        if (hold.load(.acquire)) continue;
        if (port) |system| write_now(system, .indeterminate, 0);
    }
}

fn write(system: System, next: core.progress.State, now_ms: i64) void {
    // Already saying it: only a repeat says it again.
    if (next == shown and next != .clear) return;
    write_now(system, next, now_ms);
}

/// The one path to the terminal. `shown` only moves when the bytes went out, so a
/// terminal that refuses them keeps being asked.
fn write_now(system: System, next: core.progress.State, now_ms: i64) void {
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

test "a human in a browser holds the bar, and the thread keeps it moving" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system(), 1_000);
    fake.output_len = 0;

    pause();
    try testing.expectEqual(core.progress.State.paused, state());
    try testing.expectEqualStrings("\x1b]9;4;4\x1b\\", fake.output_text());

    // Nothing *keeps* moving while a human is reading: at most the write that was
    // already in flight, and none after it.
    os.sleep_ms(repeat_ms * 2);
    const settled = std.mem.count(u8, fake.output_text(), "\x1b]9;4;3;0");
    os.sleep_ms(repeat_ms * 4);
    try testing.expectEqual(settled, std.mem.count(u8, fake.output_text(), "\x1b]9;4;3;0"));

    const before_resume = std.mem.count(u8, fake.output_text(), "\x1b]9;4;3;0");
    unpause();
    try testing.expectEqual(core.progress.State.indeterminate, state());
    try testing.expect(std.mem.count(u8, fake.output_text(), "\x1b]9;4;3;0") > before_resume);
}

test "the bar is repeated while the work goes on, because that is what animates it" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system(), 0);
    // The loop is blocked here: no tick of it reaches this module.
    os.sleep_ms(repeat_ms * 3 + 40);
    end();

    // At least twice in a third of a second: the point is that the module writes
    // without being ticked, not that a loaded runner manages exactly three.
    const written = fake.output_text();
    try testing.expect(std.mem.count(u8, written, "\x1b]9;4;3;0") >= 2);
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
