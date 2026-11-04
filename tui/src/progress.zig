//! Whether this terminal gets a progress bar, and which state it is in.
//!
//! Loading is everywhere in this app -- the first screen, a refresh, a body, a
//! send -- and every one of them is the same thing to a terminal: work. The state
//! lives here so a wait cannot raise a bar that nothing takes down, and a tick
//! cannot write the same eight bytes sixty times a second.
//!
//! The clock is the caller's. That keeps this module testable and keeps the
//! "how long has this been up" question with the thing that owns the loop.

const std = @import("std");
const core = @import("core");
const system_mod = @import("system.zig");
const System = system_mod.System;

/// Off until the process boundary says the terminal can take it: a pipe, a log,
/// or `TERM=dumb` must not receive escape sequences.
var enabled: bool = false;

/// What the terminal was last told. `clear` means "nothing on screen", which is
/// also the state after a failed write: best effort, and the next tick retries.
var shown: core.progress.State = .clear;

/// The percent last sent, and when: a bar that moves is redrawn, one that does
/// not is not, and one that sits for a long wait is repeated.
var shown_percent: u8 = 0;
var shown_at_ms: i64 = 0;

/// How often a bar is repeated while the work goes on. Ghostty animates the
/// indeterminate bar from the updates themselves, so a bar that is sent once
/// stands still: the number here is the animation's frame rate, not a timeout.
/// 100ms is what zix sends, and it is what the tab needs to move.
pub const repeat_ms: i64 = 100;

pub fn enable(value: bool) void {
    enabled = value;
    shown = .clear;
    shown_percent = 0;
    shown_at_ms = 0;
}

pub fn is_enabled() bool {
    return enabled;
}

/// The state the terminal is showing, for tests and for the one place that has to
/// know whether a bar is up.
pub fn state() core.progress.State {
    return shown;
}

/// Tells the terminal what is happening. Silence when the terminal does not speak
/// this, and silence when it is already saying the same thing.
pub fn show(system: System, next: core.progress.State, percent: u8, now_ms: i64) void {
    if (!enabled) return;
    const done: u8 = @min(percent, 100);
    if (next == shown) {
        // A percent only moves the bar where the terminal reads one.
        if (!carries_percent(next) or done == shown_percent) return;
    }

    write(system, next, done, now_ms);
}

/// Writes and remembers. The only path to the terminal, so the state and the
/// screen cannot disagree.
fn write(system: System, next: core.progress.State, percent: u8, now_ms: i64) void {
    var buffer: [core.progress.max_sequence]u8 = undefined;
    const bytes = core.progress.sequence(next, percent, &buffer);
    if (bytes.len == 0) return;
    system.write(bytes) catch return;
    shown = next;
    shown_percent = percent;
    shown_at_ms = now_ms;
}

/// Takes the bar down, whatever it was showing.
pub fn clear(system: System) void {
    show(system, .clear, 0, 0);
}

/// Repeats a bar that has been up for a while, so a long wait does not lose it.
pub fn keep_alive(system: System, now_ms: i64) void {
    if (!enabled or shown == .clear) return;
    if (now_ms - shown_at_ms < repeat_ms) return;
    // Sent whether or not the state changed: repeating it is the whole point.
    write(system, shown, shown_percent, now_ms);
}

/// The two states whose sequence carries a number.
fn carries_percent(value: core.progress.State) bool {
    return value == .normal or value == .failure;
}

const testing = std.testing;

test "nothing is written until the terminal is known to take it" {
    var fake: system_mod.Fake = .{};
    enable(false);
    show(fake.system(), .indeterminate, 0, 0);
    clear(fake.system());
    keep_alive(fake.system(), 60_000);
    try testing.expectEqualStrings("", fake.output_text());
    try testing.expectEqual(core.progress.State.clear, state());
    try testing.expect(!is_enabled());
}

test "a state is written once, and the bar is taken down at the end" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);
    try testing.expect(is_enabled());

    show(fake.system(), .indeterminate, 0, 0);
    try testing.expectEqualStrings("\x1b]9;4;3;0\x1b\\", fake.output_text());
    try testing.expectEqual(core.progress.State.indeterminate, state());

    // The loop ticks many times a second: the same state is not re-sent.
    fake.output_len = 0;
    show(fake.system(), .indeterminate, 0, 10);
    show(fake.system(), .indeterminate, 0, 20);
    try testing.expectEqualStrings("", fake.output_text());

    // The percent is what changes when there is one.
    show(fake.system(), .normal, 40, 30);
    show(fake.system(), .normal, 80, 40);
    show(fake.system(), .normal, 80, 50);
    try testing.expectEqualStrings("\x1b]9;4;1;40\x1b\\\x1b]9;4;1;80\x1b\\", fake.output_text());

    fake.output_len = 0;
    clear(fake.system());
    try testing.expectEqualStrings("\x1b]9;4;0;0\x1b\\", fake.output_text());
    clear(fake.system());
    try testing.expectEqualStrings("\x1b]9;4;0;0\x1b\\", fake.output_text());
}

test "a wait that goes on repeats its bar, which is what animates it" {
    var fake: system_mod.Fake = .{};
    enable(true);
    defer enable(false);

    show(fake.system(), .indeterminate, 0, 1_000);
    fake.output_len = 0;

    // Inside the window: nothing, or the bar would be sent a hundred times a
    // second by a busy loop.
    keep_alive(fake.system(), 1_000 + repeat_ms - 1);
    try testing.expectEqualStrings("", fake.output_text());

    // Past it: said again, with the state that was up.
    keep_alive(fake.system(), 1_000 + repeat_ms);
    try testing.expectEqualStrings("\x1b]9;4;3;0\x1b\\", fake.output_text());

    // Down means no bar to keep alive.
    fake.output_len = 0;
    clear(fake.system());
    fake.output_len = 0;
    keep_alive(fake.system(), 1_000 + repeat_ms * 3);
    try testing.expectEqualStrings("", fake.output_text());
}

test "a terminal that refuses the escape does not stop the work" {
    var fake: system_mod.Fake = .{ .write_failure = error.IoError };
    enable(true);
    defer enable(false);

    show(fake.system(), .indeterminate, 0, 0);
    // Nothing was said, so it will be tried again: the state only moves when the
    // terminal has been told.
    try testing.expectEqual(core.progress.State.clear, state());
    keep_alive(fake.system(), 60_000);
    try testing.expectEqual(core.progress.State.clear, state());
}
