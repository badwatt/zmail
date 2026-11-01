//! Just enough MIME to read real mail in a terminal.
//!
//! Real messages are not "a string": they are a tree of parts, transfer-encoded
//! (base64 / quoted-printable), tagged with a charset, and often HTML-only.
//! This module turns that tree into displayable UTF-8 text with no allocation
//! and bounded buffers:
//!
//! * RFC 2047 encoded words (`=?utf-8?Q?caf=C3=A9?=`) for subjects and names.
//! * RFC 2045 transfer encodings (base64, quoted-printable).
//! * Charsets: UTF-8, ASCII, ISO-8859-1, Windows-1252.
//! * Multipart walking: prefers `text/plain`, falls back to a stripped
//!   `text/html`, ignores attachments.
//!
//! Everything is sanitized on the way out: control bytes become spaces and
//! invalid UTF-8 becomes `?`, because the reader is the last line of defence.

const std = @import("std");
const assert = std.debug.assert;

pub const max_depth = 8;

/// Decodes RFC 2047 encoded words into `out`. Text outside encoded words is
/// copied verbatim; whitespace between two adjacent encoded words is dropped,
/// as the standard requires.
pub fn decode_encoded_words(input: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    var index: usize = 0;
    var just_decoded = false;

    while (index < input.len) {
        if (std.mem.startsWith(u8, input[index..], "=?")) {
            if (decode_word(input, index)) |consumed| {
                write_word(input[index .. index + consumed], &writer) catch {};
                index += consumed;
                just_decoded = true;
                continue;
            }
        }
        const byte = input[index];
        if (just_decoded and (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n')) {
            // Whitespace between two encoded words is dropped; after the last
            // one it is ordinary text and must survive.
            var next = index;
            while (next < input.len and (input[next] == ' ' or input[next] == '\t' or
                input[next] == '\r' or input[next] == '\n')) next += 1;
            if (next < input.len and decode_word(input, next) != null) {
                index = next;
                continue;
            }
            writer.writeByte(' ') catch {};
            just_decoded = false;
            index = next;
            continue;
        }
        if (byte == '\r' or byte == '\n') {
            index += 1;
            continue;
        }
        writer.writeByte(byte) catch {};
        just_decoded = false;
        index += 1;
    }
    return writer.buffered();
}

/// Text from a header for display: valid UTF-8 passes through, and anything
/// else is read as Windows-1252 (which is what servers mean when they put raw
/// 8-bit bytes in an ENVELOPE). Without this, every accented letter became a
/// question mark.
pub fn to_display(input: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    if (std.unicode.utf8ValidateSlice(input)) {
        // Valid UTF-8 still needs the control bytes neutralized.
        stream_text(input, .utf8, &writer) catch {};
    } else {
        stream_text(input, .windows1252, &writer) catch {};
    }
    return writer.buffered();
}

/// Returns the byte length of the encoded word starting at `start`, or null.
fn decode_word(input: []const u8, start: usize) ?usize {
    // =?charset?[BbQq]?text?=
    const rest = input[start + 2 ..];
    const charset_end = std.mem.indexOfScalar(u8, rest, '?') orelse return null;
    if (charset_end == 0) return null;
    const after_charset = rest[charset_end + 1 ..];
    if (after_charset.len < 2 or after_charset[1] != '?') return null;
    const encoding = after_charset[0];
    const body = after_charset[2..];
    const text_end = std.mem.indexOf(u8, body, "?=") orelse return null;
    if (text_end == 0) return null;
    if (encoding != 'B' and encoding != 'b' and encoding != 'Q' and encoding != 'q') return null;
    return 2 + charset_end + 1 + 2 + text_end + 2;
}

/// Writes one encoded word, converting its charset to UTF-8.
fn write_word(word: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const rest = word[2..];
    const charset_end = std.mem.indexOfScalar(u8, rest, '?') orelse return;
    const charset = charset_of(rest[0..charset_end]);
    const encoding = rest[charset_end + 1];
    // "=?charset?E?payload?=": the payload starts after that prefix and ends
    // before the closing "?=".
    const payload_start = 2 + charset_end + 3;
    const body = word[payload_start .. word.len - 2];

    // 512 bytes of decoded payload is far beyond any sane encoded word; longer
    // ones are truncated rather than rejected.
    var raw: [512]u8 = undefined;
    const decoded = switch (encoding) {
        'B', 'b' => decode_base64(body, &raw),
        'Q', 'q' => decode_quoted_printable(body, &raw),
        else => return,
    };
    try stream_text(decoded, charset, writer);
}

/// Header value lookup in a header block (folding aware, case-insensitive).
pub fn header(block: []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < block.len) {
        const line_end = std.mem.indexOfScalarPos(u8, block, index, '\n') orelse block.len;
        const line = std.mem.trimEnd(u8, block[index..line_end], "\r");
        if (line.len == 0) break;

        if (line[0] != ' ' and line[0] != '\t') {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const key = std.mem.trim(u8, line[0..colon], " \t");
                if (std.ascii.eqlIgnoreCase(key, name)) {
                    var value_end = line_end;
                    var next = line_end + 1;
                    while (next < block.len) {
                        const e = std.mem.indexOfScalarPos(u8, block, next, '\n') orelse block.len;
                        const folded = std.mem.trimEnd(u8, block[next..e], "\r");
                        if (folded.len == 0 or (folded[0] != ' ' and folded[0] != '\t')) break;
                        value_end = e;
                        next = e + 1;
                    }
                    return std.mem.trim(u8, block[index + colon + 1 .. value_end], " \t\r\n");
                }
            }
        }
        index = line_end + 1;
    }
    return null;
}

/// Extracts the displayable text of a full message (headers and body).
pub fn text_body(raw: []const u8, out: []u8, scratch: []u8) []const u8 {
    if (out.len == 0 or scratch.len < 2) return "";
    var writer = std.Io.Writer.fixed(out);

    const root = split_part(raw);
    const root_type = content_type(header(root.headers, "content-type"));

    switch (root_type.media) {
        .multipart => {
            var found = Found{};
            scan_multipart(root.body, root_type.boundary, 0, &found);
            if (found.plain) |part| {
                write_part(part, false, scratch, &writer);
            } else if (found.html) |part| {
                write_part(part, true, scratch, &writer);
            }
        },
        .html => write_part(root, true, scratch, &writer),
        .plain => write_part(root, false, scratch, &writer),
        .other => {},
    }
    return writer.buffered();
}

const Media = enum { plain, html, multipart, other };

const Type = struct {
    media: Media = .plain,
    charset: Charset = .utf8,
    boundary: []const u8 = "",
};

fn content_type(value: ?[]const u8) Type {
    const text = value orelse return .{};

    var result = Type{ .media = .other };
    var index: usize = 0;

    const media_end = std.mem.indexOfScalar(u8, text, ';') orelse text.len;
    const media = std.mem.trim(u8, text[0..media_end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "text/html")) {
        result.media = .html;
    } else if (std.ascii.startsWithIgnoreCase(media, "text/")) {
        result.media = .plain;
    } else if (std.ascii.startsWithIgnoreCase(media, "multipart/")) {
        result.media = .multipart;
    }
    index = media_end;

    while (index < text.len) {
        index += 1; // skip ';'
        skip_space(text, &index);
        const name_start = index;
        while (index < text.len and text[index] != '=' and text[index] != ';') index += 1;
        const name = std.mem.trim(u8, text[name_start..index], " \t");
        if (index >= text.len or text[index] != '=') continue;
        index += 1;
        skip_space(text, &index);

        var value_start = index;
        var value_end: usize = index;
        if (index < text.len and text[index] == '"') {
            index += 1;
            value_start = index;
            while (index < text.len and text[index] != '"') index += 1;
            value_end = index;
            if (index < text.len) index += 1;
        } else {
            while (index < text.len and text[index] != ';') index += 1;
            value_end = index;
        }
        const param = std.mem.trim(u8, text[value_start..value_end], " \t");

        if (std.ascii.eqlIgnoreCase(name, "charset")) {
            result.charset = charset_of(param);
        } else if (std.ascii.eqlIgnoreCase(name, "boundary")) {
            result.boundary = param;
        }
    }
    return result;
}

const Charset = enum { utf8, latin1, windows1252 };

fn charset_of(name: []const u8) Charset {
    const trimmed = std.mem.trim(u8, name, " \t\"'");
    const end = std.mem.indexOfAny(u8, trimmed, "*;") orelse trimmed.len;
    const bare = trimmed[0..end];
    if (std.ascii.eqlIgnoreCase(bare, "iso-8859-1") or
        std.ascii.eqlIgnoreCase(bare, "latin1") or
        std.ascii.eqlIgnoreCase(bare, "latin-1") or
        std.ascii.eqlIgnoreCase(bare, "iso8859-1"))
    {
        return .latin1;
    }
    if (std.ascii.eqlIgnoreCase(bare, "windows-1252") or std.ascii.eqlIgnoreCase(bare, "cp1252")) {
        return .windows1252;
    }
    return .utf8;
}

const Part = struct {
    headers: []const u8,
    body: []const u8,
};

const Found = struct {
    plain: ?Part = null,
    html: ?Part = null,
};

fn split_part(region: []const u8) Part {
    if (std.mem.indexOf(u8, region, "\r\n\r\n")) |at| {
        return .{ .headers = region[0..at], .body = region[at + 4 ..] };
    }
    if (std.mem.indexOf(u8, region, "\n\n")) |at| {
        return .{ .headers = region[0..at], .body = region[at + 2 ..] };
    }
    // No body separator: headers only, or a body that starts immediately.
    if (std.mem.indexOfScalar(u8, region, ':') != null and
        std.mem.indexOfScalar(u8, region[0..@min(region.len, 64)], '\n') != null)
    {
        return .{ .headers = region, .body = "" };
    }
    return .{ .headers = "", .body = region };
}

fn scan_multipart(body: []const u8, boundary: []const u8, depth: u8, found: *Found) void {
    if (depth >= max_depth or boundary.len == 0) return;
    if (found.plain != null) return;

    var index: usize = 0;
    var part_start: ?usize = null;

    while (index < body.len) {
        const line_end = std.mem.indexOfScalarPos(u8, body, index, '\n') orelse body.len;
        const line = std.mem.trimEnd(u8, body[index..line_end], "\r");

        if (std.mem.startsWith(u8, line, "--") and std.mem.eql(u8, line[2..], boundary)) {
            if (part_start) |start| {
                scan_part(trim_part_end(body[start..index]), depth, found);
                if (found.plain != null) return;
            }
            part_start = @min(line_end + 1, body.len);
        } else if (is_closing_delimiter(line, boundary)) {
            if (part_start) |start| scan_part(trim_part_end(body[start..index]), depth, found);
            return;
        }
        if (line_end == body.len) break;
        index = line_end + 1;
    }
    if (part_start) |start| {
        if (start < body.len) scan_part(trim_part_end(body[start..]), depth, found);
    }
}

fn skip_space(text: []const u8, index: *usize) void {
    while (index.* < text.len) : (index.* += 1) {
        switch (text[index.*]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        }
    }
}

/// The newline before a boundary belongs to the delimiter, not to the part.
fn trim_part_end(region: []const u8) []const u8 {
    if (std.mem.endsWith(u8, region, "\r\n")) return region[0 .. region.len - 2];
    if (std.mem.endsWith(u8, region, "\n")) return region[0 .. region.len - 1];
    return region;
}

fn is_closing_delimiter(line: []const u8, boundary: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "--")) return false;
    const rest = line[2..];
    if (!std.mem.startsWith(u8, rest, boundary)) return false;
    return std.mem.eql(u8, rest[boundary.len..], "--");
}

fn scan_part(region: []const u8, depth: u8, found: *Found) void {
    if (found.plain != null) return;
    const part = split_part(region);
    const kind = content_type(header(part.headers, "content-type"));
    switch (kind.media) {
        .multipart => scan_multipart(part.body, kind.boundary, depth + 1, found),
        .plain => if (found.plain == null) {
            found.plain = part;
        },
        .html => if (found.html == null) {
            found.html = part;
        },
        .other => {},
    }
}

fn write_part(part: Part, as_html: bool, scratch: []u8, writer: *std.Io.Writer) void {
    const kind = content_type(header(part.headers, "content-type"));
    const encoding = transfer_encoding(header(part.headers, "content-transfer-encoding"));

    const half = scratch.len / 2;
    const decoded = transfer_decode(part.body, encoding, scratch[0..half]);
    if (as_html) {
        const converted = convert_charset(decoded, kind.charset, scratch[half..]);
        strip_html(converted, writer);
    } else {
        stream_text(decoded, kind.charset, writer) catch {};
    }
}

const Encoding = enum { seven, eight, binary, base64, quoted_printable };

fn transfer_encoding(value: ?[]const u8) Encoding {
    const text = std.mem.trim(u8, value orelse return .seven, " \t");
    if (std.ascii.startsWithIgnoreCase(text, "base64")) return .base64;
    if (std.ascii.startsWithIgnoreCase(text, "quoted-printable")) return .quoted_printable;
    if (std.ascii.startsWithIgnoreCase(text, "8bit")) return .eight;
    if (std.ascii.startsWithIgnoreCase(text, "binary")) return .binary;
    return .seven;
}

fn transfer_decode(input: []const u8, encoding: Encoding, out: []u8) []const u8 {
    if (out.len == 0) return "";
    return switch (encoding) {
        .base64 => decode_base64(input, out),
        .quoted_printable => decode_quoted_printable(input, out),
        else => input[0..@min(input.len, out.len)],
    };
}

fn decode_base64(input: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    var accumulator: u32 = 0;
    var bits: u5 = 0;

    for (input) |byte| {
        const value: u32 = switch (byte) {
            'A'...'Z' => byte - 'A',
            'a'...'z' => byte - 'a' + 26,
            '0'...'9' => byte - '0' + 52,
            '+' => 62,
            '/' => 63,
            '=' => break,
            ' ', '\t', '\r', '\n' => continue,
            else => continue,
        };
        accumulator = (accumulator << 6) | value;
        bits +|= 6;
        if (bits >= 8) {
            const shift: u5 = @intCast(bits - 8);
            const decoded: u8 = @truncate(accumulator >> shift);
            writer.writeByte(decoded) catch break;
            bits -= 8;
        }
    }
    return writer.buffered();
}

fn decode_quoted_printable(input: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '=') {
            if (index + 1 < input.len and input[index + 1] == '\n') {
                index += 2;
                continue;
            }
            if (index + 2 < input.len and input[index + 1] == '\r' and input[index + 2] == '\n') {
                index += 3;
                continue;
            }
            if (index + 2 < input.len) {
                if (std.fmt.parseInt(u8, input[index + 1 .. index + 3], 16)) |value| {
                    writer.writeByte(value) catch break;
                    index += 3;
                    continue;
                } else |_| {}
            }
            writer.writeByte(byte) catch break;
            index += 1;
            continue;
        }
        writer.writeByte(if (byte == '_') ' ' else byte) catch break;
        index += 1;
    }
    return writer.buffered();
}

/// Copies bytes as UTF-8, sanitizing control characters and invalid sequences.
fn stream_text(input: []const u8, charset: Charset, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (charset) {
        .latin1 => for (input) |byte| try write_codepoint(writer, byte),
        .windows1252 => for (input) |byte| try write_codepoint(writer, cp1252(byte)),
        .utf8 => {
            var index: usize = 0;
            while (index < input.len) {
                const length = std.unicode.utf8ByteSequenceLength(input[index]) catch {
                    try writer.writeByte('?');
                    index += 1;
                    continue;
                };
                if (index + length > input.len) {
                    try writer.writeByte('?');
                    break;
                }
                const codepoint = std.unicode.utf8Decode(input[index .. index + length]) catch {
                    try writer.writeByte('?');
                    index += 1;
                    continue;
                };
                try write_codepoint(writer, codepoint);
                index += length;
            }
        },
    }
}

fn convert_charset(input: []const u8, charset: Charset, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    stream_text(input, charset, &writer) catch {};
    return writer.buffered();
}

fn write_codepoint(writer: *std.Io.Writer, codepoint: u21) std.Io.Writer.Error!void {
    if (codepoint == '\n') return writer.writeByte('\n');
    if (codepoint == '\t') return writer.writeByte('\t');
    if (codepoint == '\r') return;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
        return writer.writeByte(' ');
    }
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return writer.writeByte('?');
    try writer.writeAll(buffer[0..length]);
}

fn cp1252(byte: u8) u21 {
    return switch (byte) {
        0x80 => 0x20AC,
        0x82 => 0x201A,
        0x83 => 0x0192,
        0x84 => 0x201E,
        0x85 => 0x2026,
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02C6,
        0x89 => 0x2030,
        0x8A => 0x0160,
        0x8B => 0x2039,
        0x8C => 0x0152,
        0x8E => 0x017D,
        0x91 => 0x2018,
        0x92 => 0x2019,
        0x93 => 0x201C,
        0x94 => 0x201D,
        0x95 => 0x2022,
        0x96 => 0x2013,
        0x97 => 0x2014,
        0x98 => 0x02DC,
        0x99 => 0x2122,
        0x9A => 0x0161,
        0x9B => 0x203A,
        0x9C => 0x0153,
        0x9E => 0x017E,
        0x9F => 0x0178,
        else => byte,
    };
}

fn strip_html(input: []const u8, writer: *std.Io.Writer) void {
    var index: usize = 0;
    var pending_space = false;

    while (index < input.len) {
        if (input[index] == '<') {
            const close = std.mem.indexOfScalarPos(u8, input, index, '>') orelse {
                index = input.len;
                break;
            };
            const tag = input[index + 1 .. close];
            const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/") orelse tag.len;
            const name = tag[0..name_end];

            if (std.ascii.eqlIgnoreCase(name, "style") or std.ascii.eqlIgnoreCase(name, "script")) {
                // Skip the element and its content: CSS and JS are not prose.
                const closing = if (std.ascii.eqlIgnoreCase(name, "style")) "</style" else "</script";
                const found = indexOfIgnoreCase(input, close + 1, closing) orelse input.len;
                index = if (found < input.len) found + closing.len else input.len;
                while (index < input.len and input[index] != '>') index += 1;
                if (index < input.len) index += 1;
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "br") or
                std.ascii.eqlIgnoreCase(name, "p") or
                std.ascii.eqlIgnoreCase(name, "div") or
                std.ascii.eqlIgnoreCase(name, "tr") or
                std.ascii.eqlIgnoreCase(name, "li") or
                std.ascii.eqlIgnoreCase(name, "h1") or
                std.ascii.eqlIgnoreCase(name, "h2") or
                std.ascii.eqlIgnoreCase(name, "h3"))
            {
                writer.writeByte('\n') catch return;
                if (std.ascii.eqlIgnoreCase(name, "li")) writer.writeAll("  ") catch return;
                pending_space = false;
            }
            index = close + 1;
            continue;
        }
        if (input[index] == '&') {
            if (decode_entity(input, index)) |entity| {
                writer.writeAll(entity.text) catch return;
                index += entity.consumed;
                pending_space = false;
                continue;
            }
        }
        const byte = input[index];
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
            if (!pending_space) {
                writer.writeByte(' ') catch return;
                pending_space = true;
            }
            index += 1;
            continue;
        }
        writer.writeByte(byte) catch return;
        pending_space = false;
        index += 1;
    }
}

fn indexOfIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

const Entity = struct {
    text: []const u8,
    consumed: usize,
};

fn decode_entity(input: []const u8, start: usize) ?Entity {
    const end = std.mem.indexOfScalarPos(u8, input, start, ';') orelse return null;
    if (end > start + 10) return null;
    const body = input[start + 1 .. end];
    const consumed = end - start + 1;

    if (std.mem.eql(u8, body, "amp")) return .{ .text = "&", .consumed = consumed };
    if (std.mem.eql(u8, body, "lt")) return .{ .text = "<", .consumed = consumed };
    if (std.mem.eql(u8, body, "gt")) return .{ .text = ">", .consumed = consumed };
    if (std.mem.eql(u8, body, "quot")) return .{ .text = "\"", .consumed = consumed };
    if (std.mem.eql(u8, body, "apos")) return .{ .text = "'", .consumed = consumed };
    if (std.mem.eql(u8, body, "nbsp")) return .{ .text = " ", .consumed = consumed };
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encoded words: Q and B, with the charset converted" {
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "café=? not a word",
        decode_encoded_words("=?utf-8?Q?caf=C3=A9?= =?utf-8?Q?=3D=3F?= not a word", &out),
    );
    try testing.expectEqualStrings("café", decode_encoded_words("=?UTF-8?B?Y2Fmw6k=?=", &out));
    try testing.expectEqualStrings("plain subject", decode_encoded_words("plain subject", &out));
    // Adjacent words lose the whitespace between them.
    try testing.expectEqualStrings("ab", decode_encoded_words("=?utf-8?Q?a?= =?utf-8?Q?b?=", &out));
    // Invalid or unknown encodings are left alone.
    try testing.expectEqualStrings("=?utf-8?X?abc?=", decode_encoded_words("=?utf-8?X?abc?=", &out));
    try testing.expectEqualStrings("=?utf-8?Q?unterminated", decode_encoded_words("=?utf-8?Q?unterminated", &out));
}

test "encoded words: latin-1 payload becomes UTF-8" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("café", decode_encoded_words("=?iso-8859-1?Q?caf=E9?=", &out));
}

test "header: finds a folded, case-insensitive value" {
    const block =
        "From: Alice\r\n" ++
        "content-TYPE: text/plain;\r\n" ++
        " charset=\"iso-8859-1\"\r\n" ++
        "\r\n";
    try testing.expectEqualStrings("Alice", header(block, "from").?);
    const value = header(block, "Content-Type").?;
    try testing.expect(std.mem.indexOf(u8, value, "text/plain") != null);
    try testing.expect(header(block, "subject") == null);
}

test "text_body: a simple message keeps its lines" {
    const raw =
        "Subject: Hi\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "\r\n" ++
        "Hello\r\nSecond line\r\n";
    var out: [256]u8 = undefined;
    var scratch: [512]u8 = undefined;
    try testing.expectEqualStrings("Hello\nSecond line\n", text_body(raw, &out, &scratch));
}

test "text_body: quoted-printable soft breaks and hex escapes" {
    const raw =
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "Content-Transfer-Encoding: quoted-printable\r\n" ++
        "\r\n" ++
        "caf=C3=A9 and a very long=\r\n line\r\n";
    var out: [256]u8 = undefined;
    var scratch: [512]u8 = undefined;
    try testing.expectEqualStrings("café and a very long line\n", text_body(raw, &out, &scratch));
}

test "text_body: base64 bodies decode" {
    const raw =
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "\r\n" ++
        "SGVsbG8sIHdvcmxkIQ==\r\n";
    var out: [128]u8 = undefined;
    var scratch: [512]u8 = undefined;
    try testing.expectEqualStrings("Hello, world!", text_body(raw, &out, &scratch));
}

test "text_body: latin-1 is converted, control bytes are spaces" {
    const raw =
        "Content-Type: text/plain; charset=iso-8859-1\r\n" ++
        "\r\n" ++
        "caf\xe9\x01ok\r\n";
    var out: [128]u8 = undefined;
    var scratch: [512]u8 = undefined;
    try testing.expectEqualStrings("café ok\n", text_body(raw, &out, &scratch));
}

test "text_body: multipart picks the plain part at any depth" {
    const raw =
        "Content-Type: multipart/mixed; boundary=\"outer\"\r\n" ++
        "\r\n" ++
        "--outer\r\n" ++
        "Content-Type: multipart/alternative; boundary=inner\r\n" ++
        "\r\n" ++
        "--inner\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "\r\n" ++
        "The plain text\r\n" ++
        "--inner\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "\r\n" ++
        "<p>The <b>html</b></p>\r\n" ++
        "--inner--\r\n" ++
        "--outer\r\n" ++
        "Content-Type: application/pdf; name=file.pdf\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "\r\n" ++
        "JVBERi0xLjQ=\r\n" ++
        "--outer--\r\n";
    var out: [256]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    try testing.expectEqualStrings("The plain text", text_body(raw, &out, &scratch));
}

test "text_body: html-only mail is stripped, entities decoded" {
    const raw =
        "Content-Type: multipart/alternative; boundary=b\r\n" ++
        "\r\n" ++
        "--b\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "\r\n" ++
        "<html><head><style>p{color:red}</style></head><body>" ++
        "<p>Hello&nbsp;<b>world</b> &amp; friends</p><div>Second</div>" ++
        "</body></html>\r\n" ++
        "--b--\r\n";
    var out: [256]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const text = text_body(raw, &out, &scratch);
    try testing.expect(std.mem.indexOf(u8, text, "Hello world & friends") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Second") != null);
    try testing.expect(std.mem.indexOf(u8, text, "color:red") == null);
    try testing.expect(std.mem.indexOf(u8, text, "<b>") == null);
}

test "text_body: a non-text root has no text" {
    const raw =
        "Content-Type: application/pdf\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "\r\n" ++
        "JVBERi0xLjQ=\r\n";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("", text_body(raw, &out, &scratch));
}

test "text_body: an empty body and a bare body degrade gracefully" {
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("", text_body("", &out, &scratch));
    try testing.expectEqualStrings("just text", text_body("just text", &out, &scratch));
    try testing.expectEqualStrings("", text_body("Subject: x\r\n\r\n", &out, &scratch));
}

test "text_body: small buffers truncate instead of overflowing" {
    const raw = "Content-Type: text/plain\r\n\r\n" ++ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    var out: [16]u8 = undefined;
    var scratch: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), text_body(raw, &out, &scratch).len);
}

test "text_body: invalid UTF-8 becomes question marks" {
    const raw = "Content-Type: text/plain; charset=utf-8\r\n\r\n" ++ "ok\xffbad";
    var out: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    try testing.expectEqualStrings("ok?bad", text_body(raw, &out, &scratch));
}

test "to_display: UTF-8 is kept, 8-bit headers are read as Windows-1252" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("café", to_display("café", &out));

    // Raw 0xE9 is not valid UTF-8: it is "é" in Windows-1252.
    try testing.expectEqualStrings("café", to_display("caf\xe9", &out));
    try testing.expectEqualStrings("\u{201C}hi\u{201D}", to_display("\x93hi\x94", &out));
    // Control bytes stay out of the list.
    try testing.expectEqualStrings("a b", to_display("a\x01b", &out));
}

test "encoded words: bare CRLF is dropped" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("ab", decode_encoded_words("a\r\nb", &out));
}

test "text_body: a text/html root is stripped too" {
    const raw =
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "\r\n" ++
        "<p>Only <i>html</i></p>";
    var out: [128]u8 = undefined;
    var scratch: [256]u8 = undefined;
    const text = text_body(raw, &out, &scratch);
    try testing.expect(std.mem.indexOf(u8, text, "Only html") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<i>") == null);
}

test "text_body: windows-1252 and latin-1 names are converted" {
    const raw =
        "Content-Type: text/plain; charset=windows-1252\r\n" ++
        "\r\n" ++
        "\x93quoted\x94 \x80";
    var out: [128]u8 = undefined;
    var scratch: [256]u8 = undefined;
    try testing.expectEqualStrings("\u{201C}quoted\u{201D} \u{20AC}", text_body(raw, &out, &scratch));
}

test "text_body: 8bit, binary, and unknown encodings pass through" {
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("eight", text_body(
        "Content-Type: text/plain\r\nContent-Transfer-Encoding: 8bit\r\n\r\neight",
        &out,
        &scratch,
    ));
    try testing.expectEqualStrings("binary", text_body(
        "Content-Type: text/plain\r\nContent-Transfer-Encoding: binary\r\n\r\nbinary",
        &out,
        &scratch,
    ));
    try testing.expectEqualStrings("plain", text_body(
        "Content-Type: text/plain\r\nContent-Transfer-Encoding: x-uuencode\r\n\r\nplain",
        &out,
        &scratch,
    ));
}

test "text_body: quoted-printable tolerates LF breaks and broken escapes" {
    const raw =
        "Content-Type: text/plain\r\n" ++
        "Content-Transfer-Encoding: quoted-printable\r\n" ++
        "\r\n" ++
        "a=\nb =ZZ c_d";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("ab =ZZ c d", text_body(raw, &out, &scratch));
}

test "text_body: multipart without a closing delimiter still finds the part" {
    const raw =
        "Content-Type: multipart/mixed; boundary=b\r\n" ++
        "\r\n" ++
        "--b\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "last part\r\n";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("last part", text_body(raw, &out, &scratch));
}

test "text_body: LF-only multipart works" {
    const raw =
        "Content-Type: multipart/mixed; boundary=b\n" ++
        "\n" ++
        "--b\n" ++
        "Content-Type: text/plain\n" ++
        "\n" ++
        "unix part\n" ++
        "--b--\n";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("unix part", text_body(raw, &out, &scratch));
}

test "text_body: an invalid UTF-8 continuation becomes a question mark" {
    const raw = "Content-Type: text/plain; charset=utf-8\r\n\r\nok\xc3(bad";
    var out: [32]u8 = undefined;
    var scratch: [64]u8 = undefined;
    try testing.expectEqualStrings("ok?(bad", text_body(raw, &out, &scratch));
}

test "text_body: a final part with no trailing newline survives" {
    const raw =
        "Content-Type: multipart/mixed; boundary=b\r\n" ++
        "\r\n" ++
        "--b\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "no newline";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("no newline", text_body(raw, &out, &scratch));
}

test "text_body: a truncated UTF-8 sequence becomes a question mark" {
    const raw = "Content-Type: text/plain; charset=utf-8\r\n\r\nok\xc3";
    var out: [32]u8 = undefined;
    var scratch: [64]u8 = undefined;
    try testing.expectEqualStrings("ok?", text_body(raw, &out, &scratch));
}

test "strip_html: unterminated tags, unknown entities, and long entities" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    strip_html("a <b>bold</b> &bogus; &verylongentity; <unterminated", &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "bogus") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "bold") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "unterminated") == null);

    var small: [64]u8 = undefined;
    var writer2 = std.Io.Writer.fixed(&small);
    strip_html("a & amp &amp", &writer2);
    try testing.expect(std.mem.indexOf(u8, writer2.buffered(), "&") != null);

    var style: [64]u8 = undefined;
    var writer3 = std.Io.Writer.fixed(&style);
    strip_html("<style>never closed", &writer3);
    try testing.expectEqualStrings("", writer3.buffered());
}

test "text_body: a style element without a closing tag eats no text" {
    const raw =
        "Content-Type: text/html\r\n" ++
        "\r\n" ++
        "<style>p{}";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("", text_body(raw, &out, &scratch));
}

test "text_body: a message with a header-like first line and no blank line" {
    const raw = "Content-Type: text/plain\r\n";
    var out: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("", text_body(raw, &out, &scratch));
}

test "text_body: zero-length buffers are refused" {
    try testing.expectEqualStrings("", text_body("x", &[_]u8{}, &[_]u8{}));
}

test "content_type: parses media, charset, and quoted boundary" {
    const kind = content_type("multipart/alternative; boundary=\"a b\"; charset=latin1");
    try testing.expectEqual(Media.multipart, kind.media);
    try testing.expectEqualStrings("a b", kind.boundary);
    try testing.expectEqual(Charset.latin1, kind.charset);
    try testing.expectEqual(Media.plain, content_type(null).media);
    try testing.expectEqual(Media.other, content_type("image/png").media);
}
