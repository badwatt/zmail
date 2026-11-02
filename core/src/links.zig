//! Finding the links inside the text of a message.
//!
//! The reader draws plain text; a click has to know what was under it. Both the
//! highlighter and the hit test use this scan, over the same bytes, so they can
//! never disagree about where a link starts and ends.

const std = @import("std");
const assert = std.debug.assert;

/// A newsletter can carry a hundred tracking links and put the unsubscribe one
/// at the very end: a cap that is too low silently drops the links a reader is
/// most likely to want.
pub const max_links = 256;

/// A byte range in the scanned text. The URL is the text itself.
pub const Link = struct {
    start: u32,
    end: u32,

    pub fn text(self: Link, source: []const u8) []const u8 {
        assert(self.start <= self.end);
        assert(self.end <= source.len);
        return source[self.start..self.end];
    }

    /// The address as one string: the line breaks the wrapper added are not
    /// part of it.
    pub fn url(self: Link, source: []const u8, out: []u8) []const u8 {
        assert(self.start <= self.end);
        assert(self.end <= source.len);
        var length: usize = 0;
        for (self.text(source)) |byte| {
            // A line break inside an address is not part of it. (A space never
            // is: flowed text is unfolded before it gets here.)
            if (byte == '\r' or byte == '\n') continue;
            if (length == out.len) break;
            out[length] = byte;
            length += 1;
        }
        return out[0..length];
    }
};

const prefixes = [_][]const u8{ "https://", "http://", "www.", "mailto:" };

/// Records the links in `text`, in order. Returns how many were written; links
/// beyond `out.len` are dropped rather than truncated.
pub fn scan(text: []const u8, out: []Link) usize {
    var count: usize = 0;
    var index: usize = 0;

    while (index < text.len) {
        const found = next_link(text, index) orelse break;
        var end = found.end;

        // Trailing punctuation belongs to the sentence, not to the URL, and an
        // unbalanced closing bracket is the writer's, not the link's.
        while (end > found.start) {
            const last = text[end - 1];
            if (last == '.' or last == ',' or last == ';' or last == ':' or
                last == '!' or last == '?' or last == '>' or last == '"' or last == '\'')
            {
                end -= 1;
                continue;
            }
            if (last == ')' and excess_closings(text[found.start..end])) {
                end -= 1;
                continue;
            }
            break;
        }

        if (end > found.start + prefixes[0].len and count < out.len) {
            out[count] = .{ .start = @intCast(found.start), .end = @intCast(end) };
            count += 1;
        }
        index = if (end > found.start) end else found.start + 1;
    }
    return count;
}

const Candidate = struct { start: usize, end: usize };

/// The first link at or after `from`, extended over URL-ish bytes.
fn next_link(text: []const u8, from: usize) ?Candidate {
    var index = from;
    while (index < text.len) : (index += 1) {
        // A link must start at a boundary: "xhttp://" is not a link.
        if (index > 0 and is_url_byte(text[index - 1]) and text[index - 1] != ' ') continue;
        for (prefixes) |prefix| {
            if (!std.ascii.startsWithIgnoreCase(text[index..], prefix)) continue;
            var end = index + prefix.len;
            while (end < text.len and is_url_byte(text[end])) end += 1;
            // Mail wraps long addresses at the margin, and half the time it
            // wraps them in the middle of the URL. If the line ends inside the
            // address and the next one carries on with URL characters, it is
            // still one address.
            while (end < text.len) {
                if (continuation(text, index, end)) |step| {
                    end = step;
                    while (end < text.len and is_url_byte(text[end])) end += 1;
                    continue;
                }
                break;
            }
            return .{ .start = index, .end = end };
        }
    }
    return null;
}

/// Where the address picks up again after a line break, if it does.
///
/// Mail wraps long addresses at the margin, which splits them in the middle.
/// The two things that tell that apart from ordinary prose are the margin
/// (the line the address started on was full) and the next line having no word
/// break near its start.
fn continuation(text: []const u8, link_start: usize, end: usize) ?usize {
    var index = end;
    if (index < text.len and text[index] == '\r') index += 1;
    if (index >= text.len or text[index] != '\n') return null;
    index += 1;
    if (index >= text.len or !is_url_byte(text[index])) return null;
    // A fresh address on the next line is a new link, not a continuation.
    if (std.mem.startsWith(u8, text[index..], "http://")) return null;
    if (std.mem.startsWith(u8, text[index..], "https://")) return null;
    if (std.mem.startsWith(u8, text[index..], "www.")) return null;

    const line_start = std.mem.lastIndexOfScalar(u8, text[0..end], '\n') orelse 0;
    const line_length = end - line_start;
    if (line_length < wrapped_at) return null;

    // Prose carries on with words; a wrapped address carries on without a
    // space for a good while.
    var next_space = index;
    while (next_space < text.len and text[next_space] != ' ' and text[next_space] != '\n') next_space += 1;
    if (next_space - index < 12 and next_space < text.len) return null;

    _ = link_start;
    return index;
}

/// A line this long was wrapped at a margin, not ended by a full stop.
const wrapped_at: usize = 60;

fn is_url_byte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '<', '>', '"', '\'', '`', '|', '^', '{', '}' => false,
        else => byte >= 0x21 and byte < 0x7f,
    };
}

/// True when there is one closing bracket too many: that one belongs to the
/// sentence ("(see https://…(planet))"), and the ones that balance stay.
fn excess_closings(candidate: []const u8) bool {
    var opening: u32 = 0;
    var closing: u32 = 0;
    for (candidate) |byte| {
        if (byte == '(') opening += 1;
        if (byte == ')') closing += 1;
    }
    return closing > opening;
}

/// Copies `text` with the line breaks inside addresses removed. Mail wraps at
/// the margin and splits a long address in the middle; the reader then shows one
/// unbroken address, so the highlight is continuous and a click anywhere opens
/// the whole of it. Nothing else changes: prose keeps its line breaks.
pub fn unwrap_urls(text: []const u8, out: []u8) []const u8 {
    var buffer: [max_links]Link = undefined;
    const count = scan(text, &buffer);
    if (count == 0) {
        const length = @min(text.len, out.len);
        @memcpy(out[0..length], text[0..length]);
        return out[0..length];
    }

    var writer = std.Io.Writer.fixed(out);
    var cursor: usize = 0;
    for (buffer[0..count]) |link| {
        writer.writeAll(text[cursor..link.start]) catch return writer.buffered();
        const url = link.text(text);
        for (url) |byte| {
            if (byte == '\r' or byte == '\n') continue;
            writer.writeByte(byte) catch return writer.buffered();
        }
        cursor = link.end;
    }
    writer.writeAll(text[cursor..]) catch {};
    return writer.buffered();
}

/// The link under `offset`, if any.
pub fn at(text: []const u8, offset: u32) ?Link {
    var buffer: [max_links]Link = undefined;
    const count = scan(text, &buffer);
    for (buffer[0..count]) |link| {
        if (offset >= link.start and offset < link.end) return link;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "scan finds the links in a paragraph" {
    var buffer: [max_links]Link = undefined;
    const text = "See https://example.com/a?b=1 and www.example.org, or write to " ++
        "mailto:alice@example.com.";
    const count = scan(text, &buffer);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("https://example.com/a?b=1", buffer[0].text(text));
    // The comma is punctuation, not part of the address.
    try testing.expectEqualStrings("www.example.org", buffer[1].text(text));
    try testing.expectEqualStrings("mailto:alice@example.com", buffer[2].text(text));
}

test "scan keeps balancing brackets and drops stray ones" {
    var buffer: [max_links]Link = undefined;
    const text = "(see https://en.wikipedia.org/wiki/Mercury_(planet))";
    const count = scan(text, &buffer);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Mercury_(planet)", buffer[0].text(text));
}

test "scan needs a boundary before the scheme" {
    var buffer: [max_links]Link = undefined;
    try testing.expectEqual(@as(usize, 0), scan("xhttps://example.com", &buffer));
    try testing.expectEqual(@as(usize, 1), scan("https://example.com", &buffer));
    try testing.expectEqual(@as(usize, 0), scan("no links here", &buffer));
}

test "scan stops at the buffer limit instead of overflowing" {
    var buffer: [1]Link = undefined;
    try testing.expectEqual(@as(usize, 1), scan("http://a.example http://b.example", &buffer));
}

test "the last link of a long newsletter is still found" {
    var text: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    var index: usize = 0;
    while (index < 100) : (index += 1) {
        writer.print("https://example.com/{d} ", .{index}) catch unreachable;
    }
    var buffer: [max_links]Link = undefined;
    const count = scan(writer.buffered(), &buffer);
    try testing.expectEqual(@as(usize, 100), count);
    try testing.expectEqualStrings("https://example.com/99", buffer[99].text(writer.buffered()));
}

test "at reports the link under an offset" {
    const text = "go to https://example.com now";
    var url_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("https://example.com", at(text, 10).?.url(text, &url_buffer));
    try testing.expect(at(text, 3) == null);
    try testing.expect(at(text, text.len - 1) == null);
}

test "an address wrapped by the sender is still one address" {
    // What a mailing list does at 76 columns: a newline in the middle.
    // 66 columns of address, then the rest on the next line: what a mailing
    // list does when it wraps at 76.
    const text = "unsubscribe here:\n" ++
        "https://www1.ema.rsys.net/u/nrd.php?p=0vDm90jZvy_1780192_7260070\n" ++
        "l=1055472&d=MTM5M2E1MzU0OTM3&ems\n";
    var buffer: [max_links]Link = undefined;
    const count = scan(text, &buffer);
    try testing.expectEqual(@as(usize, 1), count);

    var url_buffer: [256]u8 = undefined;
    const url = buffer[0].url(text, &url_buffer);
    try testing.expectEqualStrings(
        "https://www1.ema.rsys.net/u/nrd.php?p=0vDm90jZvy_1780192_7260070l=1055472&d=MTM5M2E1MzU0OTM3&ems",
        url,
    );

    // A click anywhere on it, including the wrapped lines, finds the link.
    try testing.expect(at(text, 40) != null);
    try testing.expect(at(text, text.len - 6) != null);
}

test "prose on the next line is not swallowed by the link" {
    var buffer: [max_links]Link = undefined;
    // A short sentence ends well before the margin: the next line is prose.
    const text = "see https://example.com/a\nThanks for reading";
    try testing.expectEqual(@as(usize, 1), scan(text, &buffer));
    try testing.expectEqualStrings("https://example.com/a", buffer[0].text(text));
}

test "unwrap_urls joins a wrapped address and leaves the prose alone" {
    const text = "unsubscribe here:\n" ++
        "https://www1.ema.rsys.net/u/nrd.php?p=0vDm90jZvy_1780192_7260070\n" ++
        "l=1055472&d=MTM5M2E1MzU0OTM3&ems\n" ++
        "That is all.";
    var out: [512]u8 = undefined;
    const shown = unwrap_urls(text, &out);
    try testing.expectEqualStrings(
        "unsubscribe here:\nhttps://www1.ema.rsys.net/u/nrd.php?p=0vDm90jZvy_1780192_7260070l=1055472&d=MTM5M2E1MzU0OTM3&ems\nThat is all.",
        shown,
    );

    // The address is now one link in the text the reader is given.
    var buffer: [max_links]Link = undefined;
    try testing.expectEqual(@as(usize, 1), scan(shown, &buffer));
}

test "unwrap_urls copies text with no links unchanged" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("just words\nhere", unwrap_urls("just words\nhere", &out));
}

test "a new address on the next line is a new link, not a continuation" {
    var buffer: [max_links]Link = undefined;
    const text = "https://a.example\nhttps://b.example";
    try testing.expectEqual(@as(usize, 2), scan(text, &buffer));
}
