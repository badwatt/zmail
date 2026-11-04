//! The terminal's own progress bar, and the thing that keeps it moving.
//!
//! Ghostty and kitty draw a bar in the window for `OSC 9;4`. Two things matter
//! from this side:
//!
//! Movement. The indeterminate state (`3`) leaves the value alone, and only some
//! terminals animate it, so what moves is a percentage that changes. A bar that
//! fills to a hundred would say "nearly done" for as long as the wait lasts -- the
//! one thing a wait cannot know -- so it swings between two values instead: always
//! moving, never claiming the end.
//!
//! Independence from the loop. The longest wait in this app blocks the event loop
//! (the first connection, and any fetch behind it), which is exactly when nothing
//! would repaint. The bar therefore has its own thread, and the session only has
//! to say when the work starts and when it ends.
//!
//! Off until the process boundary says the terminal can take it: a pipe, a log, or
//! `TERM=dumb` must not receive escape sequences.

const std = @import("std");
const core = @import("core");
const os = @import("os.zig");
const system_mod = @import("system.zig");
const System = system_mod.System;

/// Between these, by `step`, every `step_ms`: the bar's swing.
pub const floor: u8 = 8;
pub const ceiling: u8 = 92;
pub const step: u8 = 12;
pub const step_ms: i64 = 80;

var enabled: bool = false;
/// The port to write through: the session's, which is the process's.
var port: ?System = null;
var active: bool = false;
var paused: bool = false;
var percent: u8 = floor;
var rising: bool = true;
/// What the terminal was last told, so a tick that changes nothing writes nothing.
var shown: core.progress.State = .clear;
var shown_percent: u8 = floor;

var thread: ?std.Thread = null;
var stop = std.atomic.Value(bool).init(true);
var hold = std.atomic.Value(bool).init(false);

pub fn enable(value: bool) void {
    // Turning it off stops the thread: a test that enables it must not leave
    // something writing to a port that has gone out of scope.
    if (!value) {
        stop.store(true, .release);
        if (thread) |joined| {
            joined.join();
            thread = null;
        }
        active = false;
        paused = false;
        shown = .clear;
    }
    enabled = value;
}

pub fn is_enabled() bool {
    return enabled;
}

/// The state the terminal is showing, for tests and for the one place that has to
/// know whether a bar is up.
pub fn state() core.progress.State {
    return shown;
}

pub fn current_percent() u8 {
    return percent;
}

/// Puts the bar up and starts moving it. Called when work begins, from whatever
/// thread begins it -- but only ever from the session's.
pub fn begin(system: System) void {
    if (!enabled) return;
    port = system;
    if (active) {
        unpause();
        return;
    }
    active = true;
    paused = false;
    percent = floor;
    rising = true;
    write(system, .normal, percent);
    stop.store(false, .release);
    if (thread == null) thread = std.Thread.spawn(.{}, keep_moving, .{}) catch null;
}

/// Takes it down. Whatever the wait did, the bar goes: a bar left behind says
/// "busy" forever.
pub fn end() void {
    if (!active) return;
    active = false;
    stop.store(true, .release);
    if (thread) |joined| {
        joined.join();
        thread = null;
    }
    if (port) |system| write(system, .clear, 0);
}

/// Waiting for a human (a browser, an editor): the bar holds still and says so,
/// instead of spinning while nobody is working.
pub fn pause() void {
    if (!active or paused) return;
    paused = true;
    hold.store(true, .release);
    if (port) |system| write(system, .paused, 0);
}

pub fn unpause() void {
    if (!active or !paused) return;
    paused = false;
    hold.store(false, .release);
    if (port) |system| write(system, .normal, percent);
}

/// One step of the swing, exposed so the shape of the movement is testable
/// without waiting for a thread.
pub fn advance() void {
    if (rising) {
        const next = percent + step;
        if (next >= ceiling) {
            percent = ceiling;
            rising = false;
        } else {
            percent = next;
        }
    } else if (percent <= floor + step) {
        percent = floor;
        rising = true;
    } else {
        percent -= step;
    }
}

/// Takes the bar down without joining the thread: the one caller is the Ctrl+C
/// handler, which cannot wait for anything. The process ends right afterwards, so
/// there is nothing to leave tidy.
pub fn abandon(system: System) void {
    stop.store(true, .release);
    active = false;
    write(system, .clear, 0);
}

fn keep_moving() void {
    while (!stop.load(.acquire)) {
        // Sliced sleep: stopping joins in one slice, not in a whole step.
        var waited: i64 = 0;
        while (waited < step_ms and !stop.load(.acquire)) : (waited += 10) os.sleep_ms(10);
        if (stop.load(.acquire)) return;
        if (hold.load(.acquire)) continue;

        advance();
        // A twenty-byte write to a terminal is one syscall, so it lands between
        // frames and not inside one: the two threads do not need a lock to keep
        // the escape sequences whole.
        if (port) |system| write(system, .normal, percent);
    }
}

fn write(system: System, next: core.progress.State, value: u8) void {
    const same = next == shown and (next != .normal and next != .failure or value == shown_percent);
    if (same) return;

    var buffer: [core.progress.max_sequence]u8 = undefined;
    const bytes = core.progress.sequence(next, value, &buffer);
    if (bytes.len == 0) return;
    system.write(bytes) catch return;
    shown = next;
    shown_percent = value;
}

const testing = std.testing;

test "nothing is written until the terminal is known to take it" {
    var fake: system_mod.Fake = .{};
    enable(false);
    begin(fake.system());
    end();
    pause();
    unpause();
    try testing.expectEqualStrings("", fake.output_text());
    try testing.expectEqual(core.progress.State.clear, state());
    try testing.expect(!is_enabled());
}

test "the bar goes up, swings, and comes down" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system());
    try testing.expectEqualStrings("\x1b]9;4;1;8\x1b\\", fake.output_text());
    try testing.expectEqual(core.progress.State.normal, state());
    try testing.expectEqual(@as(u8, 8), current_percent());

    // The swing: up to the ceiling, then back, and never a hundred.
    fake.output_len = 0;
    var highest: u8 = 0;
    var lowest: u8 = 100;
    var steps: u32 = 0;
    while (steps < 40) : (steps += 1) {
        advance();
        highest = @max(highest, current_percent());
        lowest = @min(lowest, current_percent());
    }
    try testing.expectEqual(ceiling, highest);
    try testing.expectEqual(floor, lowest);
    try testing.expect(highest < 100);

    end();
    try testing.expectEqual(core.progress.State.clear, state());
    // The last thing the terminal hears is the bar going away.
    try testing.expect(std.mem.endsWith(u8, fake.output_text(), "\x1b]9;4;0;0\x1b\\"));
}

test "the thread moves the bar with the loop blocked" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system());
    // Nothing ticks here: this is the blocking wait the bar exists for.
    os.sleep_ms(step_ms * 3 + 40);
    end();

    const written = fake.output_text();
    var count: usize = 0;
    var rest = written;
    while (std.mem.indexOf(u8, rest, "\x1b]9;4;1;")) |at| {
        count += 1;
        rest = rest[at + 8 ..];
    }
    try testing.expect(count >= 3);
}

test "waiting for a human holds the bar still" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    begin(fake.system());
    pause();
    const after_pause = fake.output_len;
    try testing.expectEqual(core.progress.State.paused, state());

    // Held: the thread keeps its hands off.
    os.sleep_ms(step_ms * 2);
    try testing.expectEqual(after_pause, fake.output_len);

    unpause();
    try testing.expectEqual(core.progress.State.normal, state());
    end();
}

test "a terminal that refuses the escape does not stop the work" {
    var fake: system_mod.Fake = .{ .write_failure = error.IoError };
    enable(true);
    defer enable(false);

    begin(fake.system());
    try testing.expectEqual(core.progress.State.clear, state());
    end();
}

test "turning it off stops the thread even in the middle of a wait" {
    var fake: system_mod.Fake = .{};
    enable(true);
    begin(fake.system());
    os.sleep_ms(step_ms + 20);

    // No end(): disabling has to stop the thread itself, or it outlives the port
    // it writes to.
    enable(false);
    try testing.expect(!is_enabled());
    try testing.expectEqual(core.progress.State.clear, state());
}
