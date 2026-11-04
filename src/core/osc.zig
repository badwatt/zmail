//! The little bit of OSC this client asks the terminal about.
//!
//! One question, one answer: `OSC 11` asks what colour the terminal paints
//! behind the text, and the answer is what a generated theme is derived from.
//! Parsing lives here, in core, so the shape of the reply is a unit test and the
//! adapter that reads stdin stays thin.

const std = @import("std");
const Rgb = @import("oklch.zig").Rgb;

const query_prefix = "\x1b]11;rgb:";

/// The reply to an `OSC 11` query, or null when the bytes are not one.
///
/// Accepts what terminals actually send: `rgb:RRRR/GGGG/BBBB` (the xterm form,
/// 16 bits per channel), shorter forms such as `rgb:RR/GG/BB`, and either
/// terminator -- `ESC \` or BEL. Anything before the reply is skipped, because
/// the answer shares the input stream with whatever else the terminal had to say.
pub fn parse_background(bytes: []const u8) ?Rgb {
    const marker = std.mem.indexOf(u8, bytes, query_prefix) orelse return null;
    var rest = bytes[marker + query_prefix.len ..];

    const end = end_of_reply(rest) orelse return null;
    rest = rest[0..end];

    var channels: [3]u8 = undefined;
    var index: usize = 0;
    var parts = std.mem.splitScalar(u8, rest, '/');
    while (parts.next()) |part| {
        if (index == channels.len) return null;
        // A trailing bit such as `rgb:1a1a/1b1b/2525 ` with spaces is still a
        // colour: trailing blanks are common and harmless.
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0 or trimmed.len > 4) return null;
        const value = std.fmt.parseInt(u16, trimmed, 16) catch return null;
        const max: u32 = (@as(u32, 1) << @intCast(trimmed.len * 4)) - 1;
        channels[index] = @intCast((@as(u32, value) * 255 + max / 2) / max);
        index += 1;
    }
    if (index != channels.len) return null;

    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
}

/// Where the reply stops: the standard terminator, or BEL for terminals that
/// still answer with it.
fn end_of_reply(bytes: []const u8) ?usize {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == 0x07) return index;
        if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') return index;
    }
    return null;
}

/// The bytes that ask the question.
pub fn background_query() []const u8 {
    return "\x1b]11;?\x1b\\";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "osc: the xterm form, 16 bits per channel" {
    const reply = "\x1b]11;rgb:1a1a/1b1b/2525\x1b\\";
    const colour = parse_background(reply).?;
    try testing.expectEqual(@as(u8, 0x1a), colour.r);
    try testing.expectEqual(@as(u8, 0x1b), colour.g);
    try testing.expectEqual(@as(u8, 0x25), colour.b);
}

test "osc: eight-bit channels, and a BEL terminator" {
    const colour = parse_background("\x1b]11;rgb:00/80/ff\x07").?;
    try testing.expectEqual(@as(u8, 0), colour.r);
    try testing.expectEqual(@as(u8, 128), colour.g);
    try testing.expectEqual(@as(u8, 255), colour.b);
}

test "osc: a reply that arrives behind other output is still found" {
    const noisy = "\x1b_Gi=31;OK\x1b\\some noise\x1b]11;rgb:ffff/ffff/ffff\x1b\\";
    const colour = parse_background(noisy).?;
    try testing.expectEqual(@as(u8, 255), colour.r);
    try testing.expectEqual(@as(u8, 255), colour.g);
    try testing.expectEqual(@as(u8, 255), colour.b);
}

test "osc: anything that is not a whole reply is refused" {
    try testing.expect(parse_background("") == null);
    try testing.expect(parse_background("\x1b]11;rgb:1a1a/1b1b/2525") == null); // no terminator
    try testing.expect(parse_background("\x1b]11;rgb:1a1a/1b1b\x1b\\") == null); // two channels
    try testing.expect(parse_background("\x1b]11;rgb:1a1a/1b1b/2525/9999\x1b\\") == null);
    try testing.expect(parse_background("\x1b]11;rgb:zz/1b1b/2525\x1b\\") == null);
    try testing.expect(parse_background("\x1b]11;rgb:123456/1b1b/2525\x1b\\") == null);
    try testing.expect(parse_background("\x1b]10;rgb:1a1a/1b1b/2525\x1b\\") == null); // foreground, not background
}

test "osc: the query is the standard one" {
    try testing.expectEqualStrings("\x1b]11;?\x1b\\", background_query());
}
