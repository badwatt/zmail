//! Greedy word wrap into fixed line ranges.
//!
//! Bodies are plain text (M1 generates them; M2 sanitizes them on ingress).
//! Wrapping is pure, bounded, and reports the line ranges so the renderer can
//! scroll without re-wrapping per row.

const std = @import("std");
const assert = std.debug.assert;

pub const max_lines: u32 = 512;

pub const Line = struct {
    start: u32,
    end: u32,

    pub fn text(self: Line, source: []const u8) []const u8 {
        assert(self.start <= self.end);
        assert(self.end <= source.len);
        return source[self.start..self.end];
    }
};

pub const Wrapped = struct {
    lines: [max_lines]Line = undefined,
    len: u32 = 0,

    pub fn at(self: *const Wrapped, index: u32, source: []const u8) []const u8 {
        assert(index < self.len);
        return self.lines[index].text(source);
    }
};

/// Splits `text` into lines of at most `width` cells. Breaks at spaces when
/// possible, hard-breaks a word that is longer than the width, and preserves
/// blank lines. At most `max_lines` lines are recorded.
pub fn wrap(text: []const u8, width: u16, out: *Wrapped) void {
    out.len = 0;
    const limit: u32 = @max(1, width);

    var start: u32 = 0;
    while (out.len < max_lines) {
        if (start >= text.len) break;

        const end = next_line_end(text, start, limit);
        assert(end > start or text[start] == '\n' or text[start] == '\r');
        assert(end <= text.len);

        out.lines[out.len] = .{ .start = start, .end = end };
        out.len += 1;

        if (end >= text.len) break;
        if (text[end] == '\n' or text[end] == '\r') {
            start = end + 1;
        } else if (text[end] == ' ') {
            start = end + 1;
        } else {
            start = end;
        }
    }
}

/// Returns the exclusive end of the line that starts at `start`. The byte at
/// the returned index is a newline, a space (the break), or past the end.
fn next_line_end(text: []const u8, start: u32, width: u32) u32 {
    var index = start;
    var columns: u32 = 0;
    var last_space: ?u32 = null;

    while (index < text.len) {
        const byte = text[index];
        // Both line endings end a line, so neither byte ends up in a range.
        if (byte == '\n' or byte == '\r') return index;
        if (byte == ' ') last_space = index;

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        index += @min(@as(u32, sequence_len), @as(u32, @intCast(text.len)) - index);
        columns += 1;

        if (columns == width) {
            if (last_space) |space| {
                if (space > start) return space;
            }
            return index;
        }
    }
    return @intCast(text.len);
}

/// Counts the wrapped lines without storing them, for when only the total is
/// needed.
pub fn line_count(text: []const u8, width: u16) u32 {
    var wrapped: Wrapped = .{};
    wrap(text, width, &wrapped);
    return wrapped.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn lines_of(text: []const u8, width: u16, buffer: [][]const u8) ![]const []const u8 {
    var wrapped: Wrapped = .{};
    wrap(text, width, &wrapped);
    var count: usize = 0;
    while (count < wrapped.len) : (count += 1) {
        buffer[count] = wrapped.at(@intCast(count), text);
    }
    return buffer[0..count];
}

test "wrap: empty text produces no lines" {
    var wrapped: Wrapped = .{};
    wrap("", 10, &wrapped);
    try testing.expectEqual(@as(u32, 0), wrapped.len);
    try testing.expectEqual(@as(u32, 0), line_count("", 10));
}

test "wrap: short text is one line" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("hello", 10, &buffer);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("hello", lines[0]);
}

test "wrap: breaks at the last space that fits" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("the quick brown fox", 10, &buffer);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("the quick", lines[0]);
    try testing.expectEqualStrings("brown fox", lines[1]);
}

test "wrap: preserves blank lines and explicit newlines" {
    var buffer: [8][]const u8 = undefined;
    const lines = try lines_of("a\n\nb", 10, &buffer);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("", lines[1]);
    try testing.expectEqualStrings("b", lines[2]);
}

test "wrap: a single long word is hard-broken at the width" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("abcdefghij", 4, &buffer);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("abcd", lines[0]);
    try testing.expectEqualStrings("efgh", lines[1]);
    try testing.expectEqualStrings("ij", lines[2]);
}

test "wrap: a space at the start of a line is not repeated" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("aaaa bbbb", 4, &buffer);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("aaaa", lines[0]);
    try testing.expectEqualStrings("bbbb", lines[1]);
}

test "wrap: a trailing space does not create an empty final line" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("hello ", 10, &buffer);
    try testing.expectEqual(@as(usize, 1), lines.len);
}

test "wrap: text ending in a newline keeps the completed line only" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("a\n", 10, &buffer);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("a", lines[0]);
}

test "wrap: counts columns by codepoint, not bytes" {
    var buffer: [8][]const u8 = undefined;
    const lines = try lines_of("olá mundo", 7, &buffer);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("olá", lines[0]);
    try testing.expectEqualStrings("mundo", lines[1]);
}

test "wrap: carriage returns end a line and are not part of it" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("ab\rcd", 4, &buffer);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("ab", lines[0]);
    try testing.expectEqualStrings("cd", lines[1]);
}

test "wrap: stops at the declared line bound" {
    const text: [max_lines * 2]u8 = @splat('\n');
    var wrapped: Wrapped = .{};
    wrap(&text, 4, &wrapped);
    try testing.expectEqual(max_lines, wrapped.len);
}

test "wrap: a zero width is treated as one column" {
    var buffer: [8][]const u8 = undefined;
    const lines = try lines_of("ab", 0, &buffer);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("b", lines[1]);
}

test "wrap: an invalid utf-8 byte counts as one cell" {
    var buffer: [4][]const u8 = undefined;
    const lines = try lines_of("a\xffb", 2, &buffer);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("a\xff", lines[0]);
    try testing.expectEqualStrings("b", lines[1]);
}

test "wrap: line_count matches wrap" {
    const text = "one two three four five six seven";
    var wrapped: Wrapped = .{};
    wrap(text, 8, &wrapped);
    try testing.expectEqual(wrapped.len, line_count(text, 8));
}
