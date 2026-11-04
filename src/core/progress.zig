//! OSC 9;4: the progress bar a terminal draws for someone else's work.
//!
//! Ghostty shows a bar in the tab and kitty in its title, when the program says
//! it is busy. The sequence is four numbers, and the percent only means
//! something for `normal` and `failure`: it is written where the reader uses it,
//! not as a zero that reads like a stalled bar.
//!
//! Nothing here is required: a terminal that does not speak it ignores the bytes,
//! which is why this is best effort everywhere it is used.

const std = @import("std");

pub const State = enum(u8) {
    /// Take it down: the work is over.
    clear = 0,
    /// How far along, in percent.
    normal = 1,
    /// It ended badly, at this percent.
    failure = 2,
    /// Working, with no idea how long it will take.
    indeterminate = 3,
    /// Waiting for the user: a browser, an editor.
    paused = 4,
};

/// Longest sequence this can produce is `ESC ] 9 ; 4 ; 2 ; 100 ESC \`.
pub const max_sequence = 20;

/// The escape for `state`, written into `out`.
pub fn sequence(state: State, percent: u8, out: []u8) []const u8 {
    const done: u8 = @min(percent, 100);
    return switch (state) {
        .clear => std.fmt.bufPrint(out, "\x1b]9;4;0;0\x1b\\", .{}) catch "",
        .indeterminate => std.fmt.bufPrint(out, "\x1b]9;4;3;0\x1b\\", .{}) catch "",
        .paused => std.fmt.bufPrint(out, "\x1b]9;4;4\x1b\\", .{}) catch "",
        .normal => std.fmt.bufPrint(out, "\x1b]9;4;1;{d}\x1b\\", .{done}) catch "",
        .failure => std.fmt.bufPrint(out, "\x1b]9;4;2;{d}\x1b\\", .{done}) catch "",
    };
}

const testing = std.testing;

test "each state has one sequence, and the percent only where it is read" {
    var buffer: [max_sequence]u8 = undefined;
    try testing.expectEqualStrings("\x1b]9;4;0;0\x1b\\", sequence(.clear, 42, &buffer));
    try testing.expectEqualStrings("\x1b]9;4;3;0\x1b\\", sequence(.indeterminate, 42, &buffer));
    try testing.expectEqualStrings("\x1b]9;4;4\x1b\\", sequence(.paused, 42, &buffer));
    try testing.expectEqualStrings("\x1b]9;4;1;37\x1b\\", sequence(.normal, 37, &buffer));
    try testing.expectEqualStrings("\x1b]9;4;2;80\x1b\\", sequence(.failure, 80, &buffer));
}

test "a percent above a hundred is a hundred, not a bar that overflows" {
    var buffer: [max_sequence]u8 = undefined;
    try testing.expectEqualStrings("\x1b]9;4;1;100\x1b\\", sequence(.normal, 200, &buffer));
    try testing.expectEqualStrings("\x1b]9;4;2;100\x1b\\", sequence(.failure, 255, &buffer));
}

test "a buffer too small for the sequence yields nothing, not half of it" {
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", sequence(.normal, 50, &tiny));
}
