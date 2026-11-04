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
            // Neither a line break nor the spaces a wrap left behind are part
            // of an address: flowed text is unfolded before it gets here, and
            // senders that break long addresses keep the space in the middle.
            if (byte == '\r' or byte == '\n' or byte == ' ') continue;
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

/// Where the address picks up after the break a sender left in it: spaces, a
/// line break, or both. Mailing lists wrap addresses in the middle and keep the
/// spaces, so "…?p=0vDm 1780192 7260070" and "…&ems\nl=1055472" are one address.
///
/// Two things must hold, or prose would be swallowed: the address already has a
/// query (that is where wrapping happens), and what follows reads as data — a
/// word does not carry digits, capitals or URL punctuation.
fn continuation(text: []const u8, link_start: usize, end: usize) ?usize {
    if (std.mem.indexOfAny(u8, text[link_start..end], "?%") == null) return null;

    var index = end;
    var spaces: u8 = 0;
    while (index < text.len and text[index] == ' ') : (spaces += 1) {
        if (spaces == 2) return null;
        index += 1;
    }
    if (index < text.len and text[index] == '\r') index += 1;
    var crossed_line = false;
    if (index < text.len and text[index] == '\n') {
        index += 1;
        crossed_line = true;
        // A blank line is a paragraph, not a wrap.
        if (index < text.len and text[index] == '\n') return null;
    }
    if (!crossed_line and spaces == 0) return null;
    while (index < text.len and text[index] == ' ') index += 1;
    if (index >= text.len or !is_url_byte(text[index])) return null;
    if (std.mem.startsWith(u8, text[index..], "http://")) return null;
    if (std.mem.startsWith(u8, text[index..], "https://")) return null;
    if (std.mem.startsWith(u8, text[index..], "www.")) return null;

    const token = text[index..token_end(text, index)];
    if (token.len == 0 or !is_url_token(token)) return null;
    if (!looks_like_data(token)) return null;
    return index;
}

/// Whether a token reads as data rather than as a word.
///
/// One capital is how a sentence starts ("That is all."), so it takes two of
/// them, a digit, or URL punctuation to say "this is an encoded fragment".
fn looks_like_data(token: []const u8) bool {
    var capitals: u8 = 0;
    for (token) |byte| {
        if (std.ascii.isDigit(byte)) return true;
        if (std.ascii.isUpper(byte)) {
            capitals += 1;
            continue;
        }
        switch (byte) {
            '%', '=', '&', '+', '/', '_', '~', '#', '@' => return true,
            else => {},
        }
    }
    if (capitals >= 2) return true;
    // A long fragment with one capital is still more likely encoded than prose.
    return token.len >= 16 and capitals >= 1;
}

/// End of the run of URL bytes starting at `start`.
fn token_end(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and is_url_byte(text[index])) index += 1;
    return index;
}

/// Only the characters an address is made of. A word with a full stop or a
/// comma in it is prose.
fn is_url_token(token: []const u8) bool {
    for (token) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or switch (byte) {
            '%', '&', '=', '+', '/', '_', '-', '~', '.', '?', '#', ':', '@', '!', '$', '\'' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

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
            // The breaks a sender left inside the address are not part of it.
            if (byte == '\r' or byte == '\n' or byte == ' ') continue;
            writer.writeByte(byte) catch return writer.buffered();
        }
        cursor = link.end;
    }
    writer.writeAll(text[cursor..]) catch {};
    return writer.buffered();
}

/// The address behind a numbered reference, as a text browser writes them at
/// the end of a page: "[3] https://example.com/x".
pub fn reference_url(text: []const u8, number: u32, out: []u8) ?[]const u8 {
    var marker_buffer: [16]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "[{d}]", .{number}) catch return null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimStart(u8, raw_line, " ");
        if (!std.mem.startsWith(u8, line, marker)) continue;
        const rest = std.mem.trimStart(u8, line[marker.len..], " ");
        if (!std.mem.startsWith(u8, rest, "http")) continue;
        const end = std.mem.indexOfAny(u8, rest, " \t\r") orelse rest.len;
        if (end > out.len) return null;
        @memcpy(out[0..end], rest[0..end]);
        return out[0..end];
    }
    return null;
}

/// The reference number under `offset`, when the click landed on one.
pub fn reference_at(text: []const u8, offset: u32) ?u32 {
    if (offset >= text.len) return null;
    var start = offset;
    while (start > 0 and offset - start < 5 and text[start] != '[') start -= 1;
    if (text[start] != '[') return null;
    var end = offset;
    while (end < text.len and end - start < 6 and text[end] != ']') end += 1;
    if (end >= text.len or text[end] != ']') return null;

    const digits = text[start + 1 .. end];
    if (digits.len == 0) return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
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

test "an address broken with spaces, the way mailing lists do it" {
    const text = "Unsubscribe\n\n" ++
        "https://unsubscribe.resend.com/?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ5IjoiZEdWemRDNWpiMjBp\n" ++
        "J9.OMhLWsKF3hmlXYLL  HCfTeCMkde0KpicLd  N9Gel7DRw\n";

    var buffer: [max_links]Link = undefined;
    try testing.expectEqual(@as(usize, 1), scan(text, &buffer));

    var url_buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "https://unsubscribe.resend.com/?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ5IjoiZEdWemRDNWpiMjBp" ++
            "J9.OMhLWsKF3hmlXYLLHCfTeCMkde0KpicLdN9Gel7DRw",
        buffer[0].url(text, &url_buffer),
    );
}

test "the emarsys shape: short numeric chunks inside the query" {
    const text = "the link below.\n" ++
        "https://www1.emarsys.net/u/nrd.php?p=0vDm90jZvy 1780192 7260070 1 893&ems\n" ++
        "l=1055472&d=MTM5M2E1MzU0OTM3MDc1M2FhNDY2YWNlYjNjQmNzM2Mx\n" ++
        "esuh= 11\n" ++
        "37309c913b494fc9c187884e7ad403d2c23ce045ffd732017232e92daac0476f\n";

    var buffer: [max_links]Link = undefined;
    const count = scan(text, &buffer);
    try testing.expectEqual(@as(usize, 1), count);

    var url_buffer: [512]u8 = undefined;
    const url = buffer[0].url(text, &url_buffer);
    try testing.expect(std.mem.startsWith(u8, url, "https://www1.emarsys.net/u/nrd.php?p=0vDm90jZvy178019272600701893&ems"));
    try testing.expect(std.mem.endsWith(u8, url, "esuh=1137309c913b494fc9c187884e7ad403d2c23ce045ffd732017232e92daac0476f"));
}

test "prose after an address is not swallowed" {
    const text = "see https://example.com/a-really-long-address/that-keeps-going and documentation here";
    var buffer: [max_links]Link = undefined;
    const count = scan(text, &buffer);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("https://example.com/a-really-long-address/that-keeps-going", buffer[0].text(text));
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

test "a numbered reference finds its address" {
    const text = "Hello [1]the docs\n\nReferences:\n\n[1] https://example.com/a\n[2] https://b.example\n";
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("https://example.com/a", reference_url(text, 1, &out).?);
    try testing.expectEqualStrings("https://b.example", reference_url(text, 2, &out).?);
    try testing.expect(reference_url(text, 3, &out) == null);

    // A click on the number is a click on the reference.
    const at_number = std.mem.indexOf(u8, text, "[1]").? + 1;
    try testing.expectEqual(@as(u32, 1), reference_at(text, @intCast(at_number)).?);
    try testing.expect(reference_at(text, 0) == null);
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
