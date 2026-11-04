//! Splitting a command line written in a config file or an environment
//! variable into the argv list that will be executed.
//!
//! There is no shell anywhere in zmail: the program that runs is exactly the
//! one named, with exactly the arguments written. That is what keeps a value in
//! a config file (or in `$EDITOR`) from becoming a script. The cost is that a
//! path with a space in it cannot be expressed, which is the honest limit of
//! this shortcut.

const std = @import("std");
const assert = std.debug.assert;

/// Words in a command: enough for `gopass show -o mail/work` plus a path.
pub const max: u8 = 8;

/// A command line split into arguments. The slices point into the text that was
/// split, so they live as long as that buffer does.
pub const Argv = struct {
    items: [max][]const u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Argv) []const []const u8 {
        assert(self.len <= max);
        return self.items[0..self.len];
    }
};

pub const Error = error{TooManyArguments};

/// Splits `value` on runs of spaces. More words than `max` is an error rather
/// than a silent truncation into a different command.
pub fn split(value: []const u8, out: *Argv) Error!void {
    out.len = 0;
    var rest = value;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " ");
        if (rest.len == 0) return;
        if (out.len == max) return error.TooManyArguments;
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        out.items[out.len] = rest[0..end];
        out.len += 1;
        rest = rest[end..];
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "split: runs of spaces are one separator, and the ends are trimmed" {
    var argv: Argv = .{};
    try split("  pass   show  mail  ", &argv);
    try testing.expectEqual(@as(usize, 3), argv.slice().len);
    try testing.expectEqualStrings("pass", argv.slice()[0]);
    try testing.expectEqualStrings("mail", argv.slice()[2]);
}

test "split: an empty value is no arguments, and re-splitting starts fresh" {
    var argv: Argv = .{};
    try split("   ", &argv);
    try testing.expectEqual(@as(usize, 0), argv.slice().len);
    try split("vi", &argv);
    try testing.expectEqualStrings("vi", argv.slice()[0]);
    try testing.expectEqual(@as(usize, 1), argv.slice().len);
}

test "split: more words than the bound is an error, not a shorter command" {
    var argv: Argv = .{};
    try testing.expectError(error.TooManyArguments, split("a b c d e f g h i", &argv));
}
