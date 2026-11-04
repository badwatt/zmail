//! IMAP `BODYSTRUCTURE`: which part of a message holds the words.
//!
//! A certificate as a PDF attachment turns two paragraphs into a megabyte of
//! base64. Asking for the whole message means downloading the attachment to
//! throw it away -- and paying for it twice when the text is behind it. The
//! server already knows the shape of the message; `BODYSTRUCTURE` is it, and
//! `BODY.PEEK[<part>]` then fetches only the part a reader wants.
//!
//! The shape arrives as nested lists:
//!
//! ```text
//! ("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 120 4 NIL NIL NIL NIL)
//! (("TEXT" "PLAIN" ...)("TEXT" "HTML" ...) "ALTERNATIVE" ...)
//! ```
//!
//! A body part whose first element is another list is a multipart; its children
//! are numbered from one, and a child that is itself a multipart lends its number
//! as a prefix to its own children (`1`, then `1.1`, `1.2`). The root is the
//! exception: a multipart root has no number of its own.
//!
//! This is a pure function over the bytes the server sent. No allocation, no
//! recursion, and a bound on both depth and part count, because the message is
//! written by whoever sent it.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub const Error = error{
    Malformed,
    TooManyParts,
    TooDeep,
};

pub const max_parts: u8 = 32;
pub const max_depth: u8 = 4;
const max_id_len: u8 = 8;

pub const Part = struct {
    id: [max_id_len]u8 = undefined,
    id_len: u8 = 0,
    text: bool = false,
    html: bool = false,
    attachment: bool = false,

    /// The section to fetch: `"1"`, `"1.2"`, ...
    pub fn section(self: *const Part) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const Structure = struct {
    parts: [max_parts]Part = undefined,
    count: u8 = 0,

    /// The part a reader wants: plain text before HTML, never an attachment.
    /// `null` means the message is not shaped the way this understands, and the
    /// caller should fall back to fetching the whole of it.
    pub fn reading_part(self: *const Structure) ?[]const u8 {
        var html: ?[]const u8 = null;
        for (self.parts[0..self.count]) |*part| {
            if (!part.text or part.attachment) continue;
            if (!part.html) return part.section();
            if (html == null) html = part.section();
        }
        return html;
    }
};

/// One open list on the way down: the id it hands to its children, and how many
/// children it has had.
const Frame = struct {
    id: [max_id_len]u8 = undefined,
    id_len: u8 = 0,
    next_child: u8 = 0,
    /// Parenthesis depth of this body list.
    parens: u32 = 0,
    /// Index into `Structure.parts` when this body is a single part, not a
    /// multipart container.
    part: ?u8 = null,
    /// A multipart lists its children first and its own subtype after them, so
    /// once a value has been read at this level no more children may open. That
    /// is what keeps `("CHARSET" "UTF-8")` from being mistaken for a body.
    children_done: bool = false,
};

pub fn parse(input: []const u8, out: *Structure) Error!void {
    out.count = 0;
    var tokens = tokenizer.Tokenizer.init(input);
    var stack: [max_depth]Frame = undefined;
    var depth: usize = 0;
    var parens: u32 = 0;

    while (true) {
        const next = tokens.next() catch return error.Malformed;
        const token = next orelse break;

        switch (token) {
            .open_paren => {
                parens += 1;
                if (depth != 0) {
                    const parent = &stack[depth - 1];
                    if (parent.part != null or parent.children_done) continue;
                }
                if (depth == max_depth) return error.TooDeep;

                var frame = Frame{ .parens = parens };
                try nameChild(if (depth == 0) null else &stack[depth - 1], &frame);

                if (try peek(&tokens) == .open_paren) {
                    if (depth == 0) frame.id_len = 0;
                } else {
                    const media = try value(&tokens);
                    const subtype = try value(&tokens);
                    frame.part = try record(out, &frame, media, subtype);
                }

                stack[depth] = frame;
                depth += 1;
            },
            .close_paren => {
                if (parens == 0) return error.Malformed;
                parens -= 1;
                while (depth > 0 and parens < stack[depth - 1].parens) depth -= 1;
            },
            .atom, .quoted, .literal => {
                if (depth == 0) continue;
                const top = &stack[depth - 1];
                if (top.part == null) {
                    top.children_done = true;
                    continue;
                }
                const text = switch (token) {
                    .atom => |text| text,
                    .quoted => |text| text,
                    .literal => |text| text,
                    else => unreachable,
                };
                if (std.ascii.eqlIgnoreCase(text, "attachment")) {
                    out.parts[top.part.?].attachment = true;
                }
            },
        }
    }

    if (depth != 0 or parens != 0) return error.Malformed;
}

/// Children are numbered from one, and carry their parent's number as a prefix.
/// The root, which has no parent, is simply part one.
fn nameChild(parent: ?*Frame, frame: *Frame) Error!void {
    const of = parent orelse {
        frame.id[0] = '1';
        frame.id_len = 1;
        return;
    };
    if (of.next_child == max_parts) return error.TooManyParts;
    of.next_child += 1;

    @memcpy(frame.id[0..of.id_len], of.id[0..of.id_len]);
    frame.id_len = of.id_len;
    if (of.id_len > 0) {
        frame.id[frame.id_len] = '.';
        frame.id_len += 1;
    }
    if (of.next_child >= 10) {
        if (frame.id_len + 2 > max_id_len) return error.TooDeep;
        frame.id[frame.id_len] = '0' + of.next_child / 10;
        frame.id_len += 1;
    }
    if (frame.id_len == max_id_len) return error.TooDeep;
    frame.id[frame.id_len] = '0' + of.next_child % 10;
    frame.id_len += 1;
}

fn record(out: *Structure, frame: *const Frame, media: []const u8, subtype: []const u8) Error!u8 {
    if (out.count == max_parts) return error.TooManyParts;
    const index = out.count;
    out.parts[index] = .{
        .id = frame.id,
        .id_len = frame.id_len,
        .text = std.ascii.eqlIgnoreCase(media, "text"),
    };
    out.parts[index].html = out.parts[index].text and std.ascii.eqlIgnoreCase(subtype, "html");
    out.count += 1;
    return index;
}

fn peek(tokens: *tokenizer.Tokenizer) Error!tokenizer.Token {
    const saved = tokens.index;
    defer tokens.index = saved;
    const next = tokens.next() catch return error.Malformed;
    return next orelse error.Malformed;
}

fn value(tokens: *tokenizer.Tokenizer) Error![]const u8 {
    const next = tokens.next() catch return error.Malformed;
    return switch (next orelse return error.Malformed) {
        .atom => |atom| if (std.ascii.eqlIgnoreCase(atom, "NIL")) "" else atom,
        .quoted => |quoted| quoted,
        .literal => |payload| payload,
        else => error.Malformed,
    };
}

const testing = std.testing;

/// The wire has no line breaks inside a FETCH response: the test inputs are
/// wrapped for reading, and joined here so they are what the server sends.
fn parse_test(wrapped: []const u8, buffer: []u8) Error!Structure {
    var len: usize = 0;
    for (wrapped) |byte| {
        if (byte == '\n') continue;
        buffer[len] = byte;
        len += 1;
    }
    var structure = Structure{};
    try parse(buffer[0..len], &structure);
    return structure;
}

test "a message with one text part is read from part one" {
    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(
        \\("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 120 4 NIL NIL NIL NIL)
    , &buffer);
    try testing.expectEqual(@as(u8, 1), structure.count);
    try testing.expectEqualStrings("1", structure.reading_part().?);
}

test "the text of a mixed message is inside the alternative, not next to it" {
    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(
        \\((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 40 2 NIL NIL NIL NIL)
        \\("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 90 3 NIL NIL NIL NIL)
        \\"ALTERNATIVE" ("BOUNDARY" "b1") NIL NIL NIL)
        \\("APPLICATION" "PDF" ("NAME" "SUPLEMENTO_VIDA.pdf") NIL NIL "BASE64" 900000 NIL
        \\("ATTACHMENT" ("FILENAME" "SUPLEMENTO_VIDA.pdf")) NIL NIL) "MIXED" ("BOUNDARY" "b2") NIL NIL NIL)
    , &buffer);
    try testing.expectEqual(@as(u8, 3), structure.count);
    try testing.expectEqualStrings("1.1", structure.reading_part().?);
    try testing.expect(structure.parts[2].attachment);
}

test "html is read when there is no plain text" {
    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(
        \\(("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 900 30 NIL NIL NIL NIL)
        \\"MIXED" ("BOUNDARY" "b") NIL NIL NIL)
    , &buffer);
    try testing.expectEqualStrings("1", structure.reading_part().?);
}

test "a text part that is an attachment is not the words" {
    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(
        \\(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 40 2 NIL NIL NIL NIL)
        \\("TEXT" "PLAIN" ("CHARSET" "UTF-8" "NAME" "log.txt") NIL NIL "7BIT" 900 30 NIL
        \\("ATTACHMENT" ("FILENAME" "log.txt")) NIL NIL) "MIXED" ("BOUNDARY" "b") NIL NIL NIL)
    , &buffer);
    try testing.expectEqual(@as(u8, 2), structure.count);
    try testing.expect(structure.parts[1].attachment);
    try testing.expectEqualStrings("1", structure.reading_part().?);
}

test "a forwarded message is not opened to look for words in it" {
    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(
        \\(("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 5000 NIL
        \\("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 40 2 NIL NIL NIL NIL)
        \\("ATTACHMENT" ("FILENAME" "original.eml")) NIL NIL)
        \\"MIXED" ("BOUNDARY" "b") NIL NIL NIL)
    , &buffer);
    try testing.expectEqual(@as(?[]const u8, null), structure.reading_part());
}

test "a structure that is cut off is not a structure" {
    var buffer: [64]u8 = undefined;
    try testing.expectError(error.Malformed, parse_test("((\"TEXT\" \"PLAIN\"", &buffer));
    try testing.expectError(error.Malformed, parse_test(")", &buffer));
}

test "a body that claims a thousand parts is refused, not followed" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.writeAll("(");
    for (0..max_parts + 1) |_| try text.writer.writeAll("(\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 1 1 NIL NIL NIL NIL)");
    try text.writer.writeAll(" \"MIXED\" NIL NIL NIL)");
    var buffer: [4096]u8 = undefined;
    try testing.expectError(error.TooManyParts, parse_test(text.written(), &buffer));
}

test "a multipart with more than nine children numbers them in two digits" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.writeAll("(");
    for (0..11) |_| try text.writer.writeAll("(\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 1 1 NIL NIL NIL NIL)");
    try text.writer.writeAll(" \"MIXED\" NIL NIL NIL)");

    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(text.written(), &buffer);
    try testing.expectEqual(@as(u8, 11), structure.count);
    try testing.expectEqualStrings("1", structure.reading_part().?);
    try testing.expectEqualStrings("11", structure.parts[10].section());
}

test "a nested message with no text at all falls back to the whole message" {
    var buffer: [1024]u8 = undefined;
    const structure = try parse_test(
        \\("APPLICATION" "PDF" NIL NIL NIL "BASE64" 900000 NIL NIL NIL NIL)
    , &buffer);
    try testing.expectEqual(@as(?[]const u8, null), structure.reading_part());
}
