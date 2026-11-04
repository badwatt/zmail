//! Putting text on the clipboard without leaving the terminal.
//!
//! OSC 52 is the one way to do it that needs no helper process and no display
//! connection: the terminal itself sets the selection. It is capped, because a
//! terminal asked to hold megabytes of base64 will either truncate it or hang,
//! and neither is a good way to find out.

const std = @import("std");
const assert = std.debug.assert;
const system_mod = @import("system.zig");
const System = system_mod.System;

/// Longest text copied in one go. Mail selection is paragraphs, not megabytes.
pub const max_text: usize = 16 * 1024;

/// Base64 is 4 bytes per 3, plus the sequence around it.
pub const max_encoded: usize = max_text / 3 * 4 + 8;

/// What the terminal should set. Both are sent: "copy" in one app is "paste" in
/// the next only if the primary selection has it too.
pub const targets = [_]u8{ 'c', 'p' };

/// Copies `text` to the clipboard and the primary selection. Returns the number
/// of bytes copied, which is `text.len` unless it was too long.
pub fn copy(system: System, text: []const u8, encoded_out: []u8) usize {
    assert(encoded_out.len >= max_encoded);
    if (text.len == 0) return 0;

    const kept = @min(text.len, max_text);
    const encoded = std.base64.standard.Encoder.encode(encoded_out, text[0..kept]);

    var header: [16]u8 = undefined;
    for (targets) |target| {
        const start = std.fmt.bufPrint(&header, "\x1b]52;{c};", .{target}) catch return 0;
        system.write(start) catch return 0;
        system.write(encoded) catch return 0;
        system.write("\x1b\\") catch return 0;
    }
    return kept;
}

const testing = std.testing;

test "copy sends the clipboard sequence for both selections" {
    var fake: system_mod.Fake = .{};
    var encoded: [max_encoded]u8 = undefined;

    const copied = copy(fake.system(), "hello", &encoded);
    try testing.expectEqual(@as(usize, 5), copied);

    const written = fake.output_text();
    try testing.expectEqualStrings(
        "\x1b]52;c;aGVsbG8=\x1b\\\x1b]52;p;aGVsbG8=\x1b\\",
        written,
    );
}

test "copy caps a huge selection instead of flooding the terminal" {
    var fake: system_mod.Fake = .{};
    var encoded: [max_encoded]u8 = undefined;
    var big: [max_text * 2]u8 = undefined;
    @memset(&big, 'x');

    try testing.expectEqual(max_text, copy(fake.system(), &big, &encoded));
    try testing.expect(fake.output_len > max_text);
}

test "copy of nothing touches nothing" {
    var fake: system_mod.Fake = .{};
    var encoded: [max_encoded]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), copy(fake.system(), "", &encoded));
    try testing.expectEqualStrings("", fake.output_text());
}
