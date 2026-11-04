//! Turning the HTML part of a message into something a terminal can show.
//!
//! Not a browser: no CSS, no layout engine. What it keeps is the structure that
//! carries meaning in mail — paragraphs, lists, quotes, headings — and the
//! links, which are written next to their text so they can be seen, read, and
//! clicked. Everything is bounded by the output buffer: a hostile message
//! writes nothing it was not given room for.

const std = @import("std");
const assert = std.debug.assert;
const links = @import("links.zig");

/// What a line of the rendering is, so the reader can style it like a mail
/// client would: headings stand out, quotes recede, bullets get a marker.
pub const Kind = enum { body, heading, quote, bullet };

pub const Render = struct {
    text: []const u8 = "",
    links: []const links.Link = &.{},
    kinds: []const Kind = &.{},
    /// Anchor text and the address it points at. The address is also written
    /// into the text, but a reader clicks the words, so the words need the
    /// target too.
    anchors: []const Anchor = &.{},
};

pub const Anchor = struct {
    span: links.Link,
    target: []const u8,
};

pub const max_anchors: usize = 256;

/// Renders `html` into `out`, recording the link ranges in `link_buffer`.
pub fn render(
    html: []const u8,
    out: []u8,
    link_buffer: []links.Link,
    kind_buffer: []Kind,
    anchor_buffer: []Anchor,
) Render {
    // Blank lines never start with content, so every entry is filled in first:
    // an uninitialised kind would be read as a corrupt enum.
    if (kind_buffer.len > 0) @memset(kind_buffer, .body);

    var state = State{
        .input = html,
        .writer = std.Io.Writer.fixed(out),
        .link_buffer = link_buffer,
        .kinds = kind_buffer,
        .anchor_buffer = anchor_buffer,
    };

    while (state.index < state.input.len) {
        if (state.input[state.index] == '<') {
            state.tag();
            continue;
        }
        state.prose();
    }
    state.finish();
    const lines = state.line + @intFromBool(state.writer.buffered().len > 0);
    return .{
        .text = state.writer.buffered(),
        .links = link_buffer[0..state.link_count],
        .anchors = anchor_buffer[0..state.anchor_count],
        .kinds = kind_buffer[0..@min(lines, kind_buffer.len)],
    };
}

const State = struct {
    input: []const u8,
    writer: std.Io.Writer,
    index: usize = 0,
    /// At most one open anchor: nesting them is not a thing mail does.
    anchor: ?[]const u8 = null,
    anchor_text_start: usize = 0,
    link_buffer: []links.Link,
    anchor_buffer: []Anchor,
    anchor_count: usize = 0,
    link_count: usize = 0,
    kinds: []Kind = &.{},
    /// Line being written, and what kind of line it is.
    line: usize = 0,
    kind: Kind = .body,
    /// Quotes indent two spaces per level, capped so a mad message cannot eat
    /// the whole line width.
    quote_depth: u8 = 0,
    /// A newline is pending until something is actually written: blank runs
    /// collapse instead of piling up.
    pending_breaks: u8 = 0,
    at_line_start: bool = true,
    pending_space: bool = false,
    in_pre: bool = false,
    skip_until: ?[]const u8 = null,

    fn written(self: *State) usize {
        return self.writer.buffered().len;
    }

    fn write(self: *State, bytes: []const u8) void {
        self.writer.writeAll(bytes) catch {};
    }

    fn break_lines(self: *State, count: u8) void {
        self.pending_breaks = @min(2, @max(self.pending_breaks, count));
        self.pending_space = false;
    }

    fn newline(self: *State) void {
        self.write("\n");
        self.line += 1;
        self.at_line_start = true;
    }

    /// Remembers what this line is, once, when it starts.
    fn note_kind(self: *State) void {
        if (self.line < self.kinds.len) self.kinds[self.line] = self.kind;
    }

    fn flush_breaks(self: *State) void {
        if (self.pending_breaks == 0) return;
        if (self.written() == 0) {
            // Nothing written yet: a block tag at the top must not open with
            // blank lines.
            self.pending_breaks = 0;
            self.at_line_start = true;
            self.pending_space = false;
            return;
        }
        var count: u8 = 0;
        while (count < self.pending_breaks) : (count += 1) self.newline();
        self.pending_breaks = 0;
        self.at_line_start = true;
        self.pending_space = false;
    }

    fn indent(self: *State) void {
        var level: u8 = 0;
        while (level < @min(self.quote_depth, 4)) : (level += 1) self.write("  ");
    }

    fn prose(self: *State) void {
        const next = std.mem.indexOfScalarPos(u8, self.input, self.index, '<') orelse self.input.len;
        const chunk = self.input[self.index..next];
        self.index = next;
        self.emit(chunk);
    }

    fn emit(self: *State, chunk: []const u8) void {
        if (self.skip_until != null) return;

        var index: usize = 0;
        while (index < chunk.len) : (index += 1) {
            const byte = chunk[index];
            if (byte == '&') {
                if (entity(chunk, index)) |decoded| {
                    index += decoded.consumed - 1;
                    if (decoded.space) {
                        self.pending_space = true;
                    } else {
                        self.writeCodepoint(decoded.codepoint);
                    }
                    continue;
                }
            }
            if (self.in_pre) {
                if (byte == '\n') {
                    self.newline();
                    self.pending_space = false;
                    continue;
                }
                self.flush_breaks();
                self.pending_space = false;
                self.writeRaw(byte);
                continue;
            }
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c) {
                self.pending_space = true;
                continue;
            }
            self.writeByte(byte);
        }
    }

    fn writeCodepoint(self: *State, codepoint: u21) void {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch {
            self.writeByte('?');
            return;
        };
        self.flush_breaks();
        if (self.at_line_start) self.note_kind();
        if (self.pending_space and !self.at_line_start) self.write(" ");
        self.pending_space = false;
        self.at_line_start = false;
        self.write(buffer[0..length]);
    }

    /// Writes one byte with no spacing rules: used inside <pre>.
    fn writeRaw(self: *State, byte: u8) void {
        var single = [1]u8{byte};
        self.write(&single);
        self.at_line_start = false;
    }

    fn writeByte(self: *State, byte: u8) void {
        self.flush_breaks();
        if (self.at_line_start) {
            self.note_kind();
            self.indent();
            // A list marker was written before the break: do not indent twice.
            self.at_line_start = false;
        } else if (self.pending_space) {
            self.write(" ");
        }
        self.pending_space = false;
        var single = [1]u8{byte};
        self.write(&single);
    }

    fn tag(self: *State) void {
        const close = std.mem.indexOfScalarPos(u8, self.input, self.index, '>') orelse {
            self.index = self.input.len;
            return;
        };
        const inside = self.input[self.index + 1 .. close];
        self.index = close + 1;

        if (inside.len == 0) return;
        const closing = inside[0] == '/';
        const body = if (closing) inside[1..] else inside;
        const name_end = std.mem.indexOfAny(u8, body, " \t\r\n/") orelse body.len;
        const name = body[0..name_end];

        if (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style")) {
            // Their contents are not prose.
            if (!closing) {
                const closing_tag = if (std.ascii.eqlIgnoreCase(name, "script"))
                    "</script"
                else
                    "</style";
                self.skip_until = closing_tag;
                self.break_lines(1);
                self.index = indexOfIgnoreCase(self.input, self.index, closing_tag) orelse self.input.len;
                if (self.index < self.input.len) {
                    const end = std.mem.indexOfScalarPos(u8, self.input, self.index, '>') orelse self.input.len;
                    self.index = @min(self.input.len, end + 1);
                }
                self.skip_until = null;
            }
            return;
        }

        if (std.ascii.eqlIgnoreCase(name, "a")) {
            self.anchor_tag(body, closing);
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "br")) {
            self.break_lines(1);
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "li")) {
            if (closing) {
                self.break_lines(1);
                return;
            }
            self.break_lines(1);
            self.flush_breaks();
            self.kind = .bullet;
            self.note_kind();
            self.write("• ");
            self.at_line_start = false;
            self.pending_space = false;
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "ul") or std.ascii.eqlIgnoreCase(name, "ol")) {
            self.break_lines(2);
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "blockquote")) {
            self.quote_depth = if (closing) self.quote_depth -| 1 else @min(2, self.quote_depth + 1);
            self.break_lines(1);
            self.kind = if (self.quote_depth > 0) .quote else .body;
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "pre")) {
            self.in_pre = !closing;
            self.break_lines(if (closing) 2 else 2);
            return;
        }
        if (is_block(name)) {
            // Paragraphs and headings start a new block; table cells and the
            // like are just a new line.
            if (is_heading(name) or std.ascii.eqlIgnoreCase(name, "p")) {
                self.break_lines(2);
            } else {
                self.break_lines(1);
            }
            // A heading styles its own line; leaving it returns to body text,
            // which also ends a list item.
            self.kind = if (is_heading(name) and !closing) .heading else .body;
            return;
        }
        // Everything else (span, b, i, font, td…) only carries style.
    }

    fn anchor_tag(self: *State, body: []const u8, closing: bool) void {
        if (!closing) {
            self.anchor = href_of(body);
            self.anchor_text_start = self.written();
            return;
        }
        const target = self.anchor orelse return;
        self.anchor = null;
        if (target.len == 0) return;

        const text_start = self.anchor_text_start;
        if (self.written() <= text_start) return;

        // The words are the link. The address is not written into the text: it
        // would sit after every "read more", and the reader shows it on demand
        // instead, when the pointer is over the words with ctrl held.
        if (self.link_count < self.link_buffer.len) {
            self.link_buffer[self.link_count] = .{
                .start = @intCast(text_start),
                .end = @intCast(self.written()),
            };
            self.link_count += 1;
        }
        if (self.anchor_count < self.anchor_buffer.len) {
            self.anchor_buffer[self.anchor_count] = .{
                .span = .{ .start = @intCast(text_start), .end = @intCast(self.written()) },
                .target = target,
            };
            self.anchor_count += 1;
        }
    }

    fn finish(self: *State) void {
        const written_text = self.writer.buffered();
        // Trailing blank lines are noise in a reader.
        var end = written_text.len;
        while (end > 0 and (written_text[end - 1] == '\n' or written_text[end - 1] == ' ')) end -= 1;
        self.writer.end = end;
        if (self.writer.end == 0) {
            // Keep the slice honest even when everything was markup.
            self.writer.end = 0;
        }
    }
};

const Decoded = struct {
    codepoint: u21 = ' ',
    /// Set for the kinds of space HTML has: they separate words, they are not
    /// characters in their own right.
    space: bool = false,
    consumed: usize = 0,
};

/// Reads one entity at `index`, which must point at '&'.
fn entity(text: []const u8, index: usize) ?Decoded {
    const semicolon = std.mem.indexOfScalarPos(u8, text, index, ';') orelse return null;
    if (semicolon - index > 12) return null;
    const body = text[index + 1 .. semicolon];
    if (body.len == 0) return null;
    const consumed = semicolon - index + 1;

    if (body[0] == '#') {
        const digits = body[1..];
        const value = if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X'))
            std.fmt.parseInt(u21, digits[1..], 16) catch return null
        else
            std.fmt.parseInt(u21, digits, 10) catch return null;
        if (value == 0 or value > 0x10ffff) return null;
        return .{ .codepoint = value, .space = value == 0xa0, .consumed = consumed };
    }

    const named = [_]struct { name: []const u8, codepoint: u21 }{
        .{ .name = "amp", .codepoint = '&' },
        .{ .name = "lt", .codepoint = '<' },
        .{ .name = "gt", .codepoint = '>' },
        .{ .name = "quot", .codepoint = '"' },
        .{ .name = "apos", .codepoint = '\'' },
        .{ .name = "nbsp", .codepoint = 0xa0 },
        .{ .name = "ndash", .codepoint = 0x2013 },
        .{ .name = "mdash", .codepoint = 0x2014 },
        .{ .name = "hellip", .codepoint = 0x2026 },
        .{ .name = "euro", .codepoint = 0x20ac },
    };
    for (named) |candidate| {
        if (!std.mem.eql(u8, body, candidate.name)) continue;
        return .{
            .codepoint = candidate.codepoint,
            .space = candidate.codepoint == 0xa0,
            .consumed = consumed,
        };
    }
    return null;
}

/// Replaces every `<img>` with a marker the reader can find after the layout:
/// `[IMG:cid]` for an image that came inside the message, `[IMG:url]` for one
/// fetched from the network. The reader paints the first kind in the terminal
/// and prints what it knows about the second.
/// How many pictures with an address the reader keeps track of. A newsletter has
/// more than a handful: the footer of one is a row of social icons, and past the cap
/// they stop being markers and become the words "image: Brave Reddit".
pub const max_remote_images = 16;

/// The addresses of the images the message does not carry, in the order they
/// appear. Their markers in the text are `[IMG:r0]`, `[IMG:r1]`, … so the URL
/// never has to be printed in the body to be found again.
/// A tag of the document: where it sits, and what is inside the angle brackets.
const Tag = struct {
    start: usize,
    end: usize,
    body: []const u8,

    /// The tag's name, lower than the attributes: "img", "a", "/p".
    fn name(self: Tag) []const u8 {
        const name_end = std.mem.indexOfAny(u8, self.body, " \t\r\n/") orelse self.body.len;
        return self.body[0..name_end];
    }

    fn is(self: Tag, wanted: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name(), wanted);
    }
};

/// Walks the tags of a document, in order. Text between them is the caller's.
const Tags = struct {
    html: []const u8,
    index: usize = 0,

    fn next(self: *Tags) ?Tag {
        while (self.index < self.html.len) {
            const start = std.mem.indexOfScalarPos(u8, self.html, self.index, '<') orelse return null;
            const end = std.mem.indexOfScalarPos(u8, self.html, start, '>') orelse return null;
            self.index = end + 1;
            return .{ .start = start, .end = end, .body = self.html[start + 1 .. end] };
        }
        return null;
    }
};

pub fn remote_images(html: []const u8, out: *[max_remote_images][]const u8) usize {
    var count: usize = 0;
    var tags = Tags{ .html = html };
    while (count < out.len) {
        const tag = tags.next() orelse break;
        if (!tag.is("img")) continue;
        const source = attribute(tag.body, "src");
        if (source.len == 0 or std.ascii.startsWithIgnoreCase(source, "cid:")) continue;
        out[count] = source;
        count += 1;
    }
    return count;
}

/// Drops the entities a text browser does not know, which it would otherwise
/// print as `&zwj;` in the middle of a sentence. The zero-width ones go away;
/// the rest become the character they stand for.
pub fn clean_entities(html: []const u8, out: []u8) []const u8 {
    const replacements = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "&zwj;", .to = "" },
        .{ .from = "&zwnj;", .to = "" },
        .{ .from = "&shy;", .to = "" },
        .{ .from = "&lrm;", .to = "" },
        .{ .from = "&rlm;", .to = "" },
        .{ .from = "&rsquo;", .to = "\'" },
        .{ .from = "&lsquo;", .to = "\'" },
        .{ .from = "&rdquo;", .to = "\"" },
        .{ .from = "&ldquo;", .to = "\"" },
        .{ .from = "&nbsp;", .to = " " },
        // Spacing entities: mail uses them to indent, and a terminal has no
        // width to spare for the difference between one and four spaces.
        .{ .from = "&emsp;", .to = " " },
        .{ .from = "&ensp;", .to = " " },
        .{ .from = "&thinsp;", .to = " " },
        .{ .from = "&hairsp;", .to = " " },
        .{ .from = "&bull;", .to = "*" },
        .{ .from = "&middot;", .to = "-" },
        .{ .from = "&sect;", .to = "S" },
        .{ .from = "&para;", .to = "P" },
        .{ .from = "&deg;", .to = "deg" },
        .{ .from = "&plusmn;", .to = "+/-" },
        .{ .from = "&times;", .to = "x" },
        .{ .from = "&divide;", .to = "/" },
        .{ .from = "&minus;", .to = "-" },
        .{ .from = "&euro;", .to = "EUR" },
        .{ .from = "&pound;", .to = "GBP" },
        .{ .from = "&yen;", .to = "JPY" },
        .{ .from = "&cent;", .to = "c" },
        .{ .from = "&laquo;", .to = "<<" },
        .{ .from = "&raquo;", .to = ">>" },
        .{ .from = "&dagger;", .to = "+" },
        .{ .from = "&frac12;", .to = "1/2" },
        .{ .from = "&frac14;", .to = "1/4" },
        .{ .from = "&frac34;", .to = "3/4" },
        .{ .from = "&sup2;", .to = "^2" },
        .{ .from = "&sup3;", .to = "^3" },
        .{ .from = "&mdash;", .to = "-" },
        .{ .from = "&ndash;", .to = "-" },
        .{ .from = "&hellip;", .to = "..." },
        .{ .from = "&trade;", .to = "(TM)" },
        .{ .from = "&reg;", .to = "(R)" },
        .{ .from = "&copy;", .to = "(C)" },
        .{ .from = "&amp;", .to = "&" },
        .{ .from = "&lt;", .to = "<" },
        .{ .from = "&gt;", .to = ">" },
        .{ .from = "&quot;", .to = "\"" },
    };

    var writer = std.Io.Writer.fixed(out);
    var index: usize = 0;
    while (index < html.len) {
        if (html[index] == '&') {
            var replaced = false;
            for (replacements) |replacement| {
                if (!std.mem.startsWith(u8, html[index..], replacement.from)) continue;
                writer.writeAll(replacement.to) catch {};
                index += replacement.from.len;
                replaced = true;
                break;
            }
            if (replaced) continue;

            // A numbered entity is a codepoint, not a name: "&#8203;" is a
            // zero-width space, and printing it is printing "&#8203;".
            if (numeric_entity(html[index..])) |number| {
                write_entity(&writer, number.codepoint);
                index += number.length;
                continue;
            }
        }
        writer.writeByte(html[index]) catch {};
        index += 1;
    }
    return writer.buffered();
}

const NumericEntity = struct { codepoint: u21, length: usize };

/// `&#8203;` or `&#x200B;`: the codepoint and how many bytes it took.
fn numeric_entity(text: []const u8) ?NumericEntity {
    if (text.len < 4) return null;
    if (text[0] != '&' or text[1] != '#') return null;

    var index: usize = 2;
    var base: u8 = 10;
    if (index < text.len and (text[index] == 'x' or text[index] == 'X')) {
        base = 16;
        index += 1;
    }
    const digits_start = index;
    while (index < text.len and text[index] != ';' and index - digits_start < 8) : (index += 1) {
        const digit = std.fmt.charToDigit(text[index], base) catch return null;
        _ = digit;
    }
    if (index >= text.len or text[index] != ';') return null;
    const digits = text[digits_start..index];
    if (digits.len == 0) return null;

    const codepoint = std.fmt.parseInt(u21, digits, base) catch return null;
    // Surrogates and out-of-range values are not characters.
    if (codepoint > 0x10ffff) return null;
    if (codepoint >= 0xd800 and codepoint <= 0xdfff) return null;
    return .{ .codepoint = codepoint, .length = index + 1 };
}

/// Spaces and invisible marks become what they are; everything else is written
/// as the character it names.
fn write_entity(writer: *std.Io.Writer, codepoint: u21) void {
    // Zero-width joiners, directional marks, BOM: nothing to show.
    if (codepoint == 0xfeff or (codepoint >= 0x200b and codepoint <= 0x200f)) return;
    if (codepoint == 0x2060) return;
    // Every kind of space is one space in a terminal.
    if (codepoint == 0x00a0 or (codepoint >= 0x2000 and codepoint <= 0x200a)) {
        writer.writeByte(' ') catch {};
        return;
    }
    if (codepoint == 0x3000) {
        writer.writeByte(' ') catch {};
        return;
    }
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return;
    writer.writeAll(encoded[0..length]) catch {};
}

/// Invisible and spacing entities, removed from a text that is not HTML. A mail
/// whose text part was generated from its HTML arrives with "&emsp;" and
/// "&#8203;" inside the prose: they are never meant as words.
pub fn clean_spacing(text: []const u8, out: []u8) []const u8 {
    const named = [_][]const u8{
        "&nbsp;", "&emsp;", "&ensp;", "&thinsp;", "&hairsp;",
        "&zwj;",  "&zwnj;", "&shy;",  "&lrm;",    "&rlm;",
    };

    var writer = std.Io.Writer.fixed(out);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '&') {
            var replaced = false;
            for (named) |name| {
                if (!std.mem.startsWith(u8, text[index..], name)) continue;
                writer.writeByte(' ') catch {};
                index += name.len;
                replaced = true;
                break;
            }
            if (replaced) continue;
            if (numeric_entity(text[index..])) |number| {
                write_entity(&writer, number.codepoint);
                index += number.length;
                continue;
            }
        }
        writer.writeByte(text[index]) catch {};
        index += 1;
    }
    return writer.buffered();
}

pub fn mark_images(html: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    var index: usize = 0;
    var remote: usize = 0;

    var tags = Tags{ .html = html };
    while (tags.next()) |tag| {
        writer.writeAll(html[index..tag.start]) catch {};
        index = tag.end + 1;

        if (!tag.is("img")) {
            writer.writeAll(html[tag.start .. tag.end + 1]) catch {};
            continue;
        }

        const source = attribute(tag.body, "src");
        const alt = attribute(tag.body, "alt");

        // An image inside the message gets a marker the reader can paint over.
        // One from the network cannot be drawn here; it is named, not fetched.
        if (std.ascii.startsWithIgnoreCase(source, "cid:")) {
            writer.print("[IMG:{s}]", .{source["cid:".len..]}) catch {};
            if (alt.len > 0) writer.print(" {s}", .{alt}) catch {};
        } else if (remote < max_remote_images) {
            // Numbered, so the address stays out of the reading and the reader
            // can still find it.
            writer.print("[IMG:r{d}]", .{remote}) catch {};
            remote += 1;
            if (alt.len > 0) writer.print(" {s}", .{alt}) catch {};
        } else if (alt.len > 0) {
            writer.print("[image: {s}]", .{alt}) catch {};
        } else {
            writer.writeAll("[image]") catch {};
        }
    }
    // Whatever follows the last tag is text too.
    if (index < html.len) writer.writeAll(html[index..]) catch {};
    return writer.buffered();
}

/// The value of one attribute in a tag body, unquoted.
fn attribute(tag: []const u8, name: []const u8) []const u8 {
    var index: usize = 0;
    while (index + name.len <= tag.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(tag[index..][0..name.len], name)) continue;
        if (index > 0 and std.ascii.isAlphanumeric(tag[index - 1])) continue;
        var cursor = index + name.len;
        while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t')) cursor += 1;
        if (cursor >= tag.len or tag[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t')) cursor += 1;
        if (cursor >= tag.len) return "";
        if (tag[cursor] == '"' or tag[cursor] == '\'') {
            const quote = tag[cursor];
            const close = std.mem.indexOfScalarPos(u8, tag, cursor + 1, quote) orelse return "";
            return tag[cursor + 1 .. close];
        }
        const stop = std.mem.indexOfAnyPos(u8, tag, cursor, " \t\r\n") orelse tag.len;
        return tag[cursor..stop];
    }
    return "";
}

fn href_of(body: []const u8) []const u8 {
    const marker = indexOfIgnoreCase(body, 0, "href") orelse return "";
    var index = marker + "href".len;
    while (index < body.len and (body[index] == ' ' or body[index] == '\t')) index += 1;
    if (index >= body.len or body[index] != '=') return "";
    index += 1;
    while (index < body.len and (body[index] == ' ' or body[index] == '\t')) index += 1;
    if (index >= body.len) return "";
    if (body[index] == '"' or body[index] == '\'') {
        const quote = body[index];
        const end = std.mem.indexOfScalarPos(u8, body, index + 1, quote) orelse return "";
        return body[index + 1 .. end];
    }
    const end = std.mem.indexOfAnyPos(u8, body, index, " \t\r\n") orelse body.len;
    return body[index..end];
}

fn is_block(name: []const u8) bool {
    const blocks = [_][]const u8{
        "p",  "div",   "tr",    "table",   "hr",      "ul",     "ol",     "dl",
        "dd", "dt",    "form",  "h1",      "h2",      "h3",     "h4",     "h5",
        "h6", "thead", "tbody", "section", "article", "header", "footer", "center",
    };
    for (blocks) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn is_heading(name: []const u8) bool {
    if (name.len != 2 or name[0] != 'h' and name[0] != 'H') return false;
    return name[1] >= '1' and name[1] <= '6';
}

fn indexOfIgnoreCase(haystack: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or from >= haystack.len) return null;
    var index = from;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return index;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "paragraphs, lists and headings become readable text" {
    var out: [512]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html =
        \\<html><head><style>p { color: red }</style></head>
        \\<body><h1>Hello</h1><p>First line<br>second line</p>
        \\<ul><li>one</li><li>two</li></ul>
        \\<pre>  keep
        \\   this</pre></body></html>
    ;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(html, &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expectEqualStrings(
        "Hello\n\nFirst line\nsecond line\n\n• one\n• two\n\n  keep\n   this",
        rendered.text,
    );
    try testing.expectEqual(@as(usize, 0), rendered.links.len);
}

test "a link is its words, and its address is kept, not printed" {
    var out: [256]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html = "<p>Read <a href=\"https://example.com/a\">the docs</a> today.</p>";
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(html, &out, &link_buffer, &.{}, &anchor_buffer);
    // Nothing is added to the sentence: the reader shows the address on demand.
    try testing.expectEqualStrings("Read the docs today.", rendered.text);
    try testing.expectEqual(@as(usize, 1), rendered.links.len);
    try testing.expectEqualStrings("the docs", std.mem.trim(u8, rendered.links[0].text(rendered.text), " "));
    try testing.expectEqualStrings("https://example.com/a", rendered.anchors[0].target);
}

test "an anchor whose text is the address stays one span" {
    var out: [256]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html = "<a href='https://example.com/'>https://example.com/</a>";
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(html, &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expectEqualStrings("https://example.com/", rendered.text);
    try testing.expectEqualStrings("https://example.com/", rendered.links[0].text(rendered.text));
}

test "entities a text browser would print raw are cleaned first" {
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "Brave logo & more - \"quoted\"",
        clean_entities("Brave&zwj; logo &amp; more &mdash; &ldquo;quoted&rdquo;", &out),
    );
    try testing.expectEqualStrings("a b", clean_entities("a&nbsp;b", &out));
}

test "an image becomes a marker the reader can find" {
    var out: [256]u8 = undefined;
    const html = "<p>a<img src=\"cid:logo@x\" alt=\"Logo\">b<img src=\"https://x/y.png\">c</p>";
    try testing.expectEqualStrings("<p>a[IMG:logo@x] Logob[IMG:r0]c</p>", mark_images(html, &out));

    // The address is kept, in order, so the reader can fetch it.
    var sources: [max_remote_images][]const u8 = undefined;
    const count = remote_images(html, &sources);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("https://x/y.png", sources[0]);
}

test "entities become their characters, and nbsp is a space" {
    var out: [128]u8 = undefined;
    var link_buffer: [2]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render("<p>Hello&nbsp;<b>world</b> &amp; friends &lt;3 &#233;</p>", &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expectEqualStrings("Hello world & friends <3 é", rendered.text);
}

test "an entity that cannot be encoded is visible, not dropped" {
    var out: [64]u8 = undefined;
    var link_buffer: [2]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    // A surrogate is not a character. Printing '?' says so; dropping it silently
    // would leave a hole where the sender wrote something.
    const rendered = render("<p>&#xD800;x</p>", &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expectEqualStrings("?x", rendered.text);
}

test "an entity that is not one is left as it was written" {
    var out: [128]u8 = undefined;
    var link_buffer: [2]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(
        "<p>&#xzz; &#zz; &bogus; &amp;</p>",
        &out,
        &link_buffer,
        &.{},
        &anchor_buffer,
    );
    try testing.expectEqualStrings("&#xzz; &#zz; &bogus; &", rendered.text);
}

test "every kind of space is one space, including the ideographic one" {
    var out: [32]u8 = undefined;
    // The text part of a mail written from HTML carries these as entities, and a
    // terminal has one space.
    try testing.expectEqualStrings(
        "a b c",
        clean_spacing("a&#x3000;b&emsp;c", &out),
    );
}

test "an unterminated tag is dropped, not printed" {
    var out: [64]u8 = undefined;
    var link_buffer: [2]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render("<p>text</p><div", &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expectEqualStrings("text", rendered.text);
}

test "more images than the reader can name are still mentioned" {
    var out: [2048]u8 = undefined;
    var html_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&html_buffer);
    for (0..max_remote_images + 1) |index| {
        try writer.print("<img src=\"https://x/{d}.png\" alt=\"pic{d}\">", .{ index, index });
    }
    const marked = mark_images(writer.buffered(), &out);
    try testing.expect(std.mem.indexOf(u8, marked, "[image: pic16]") != null);
}

test "an attribute that runs to the end of the tag is still an attribute" {
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("<p>[IMG:r0] logo</p>", mark_images("<p><img alt=logo></p>", &out));

    // The same for a link whose address is unquoted and last in the tag.
    var link_buffer: [2]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    try testing.expectEqualStrings(
        "go",
        render("<p><a href=https://x>go</a></p>", &out, &link_buffer, &.{}, &anchor_buffer).text,
    );
}

test "script content is dropped, not shown" {
    var out: [256]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html = "<p>before</p><script>alert('boom')</script><p>after</p>";
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(html, &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expectEqualStrings("before\n\nafter", rendered.text);
}

test "a huge message is bounded by the output buffer" {
    var out: [16]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    var html: [208]u8 = undefined;
    @memset(&html, 'x');
    html[0] = '<';
    html[1] = 'p';
    html[2] = '>';
    html[203] = '<';
    html[204] = '/';
    html[205] = 'p';
    html[206] = '>';
    const document = html[0..207];
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(document, &out, &link_buffer, &.{}, &anchor_buffer);
    try testing.expect(rendered.text.len <= out.len);
    try testing.expectEqualStrings("xxxxxxxxxxxxxxxx", rendered.text);
}

test "each line carries what it is, so the reader can style it" {
    var out: [512]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    var kinds: [16]Kind = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(
        "<h2>Title</h2><p>body text</p><blockquote>quoted</blockquote><ul><li>item</li></ul>",
        &out,
        &link_buffer,
        &kinds,
        &anchor_buffer,
    );

    var lines = std.mem.splitScalar(u8, rendered.text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (line.len == 0) continue;
        const kind = if (index < rendered.kinds.len) rendered.kinds[index] else .body;
        if (std.mem.startsWith(u8, line, "Title")) try testing.expectEqual(Kind.heading, kind);
        if (std.mem.startsWith(u8, line, "body text")) try testing.expectEqual(Kind.body, kind);
        if (std.mem.startsWith(u8, line, "quoted")) try testing.expectEqual(Kind.quote, kind);
        if (std.mem.startsWith(u8, line, "• item")) try testing.expectEqual(Kind.bullet, kind);
    }
}

test "the words of an anchor are a link, with the address it points at" {
    var out: [512]u8 = undefined;
    var links_buffer: [4]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(
        "<p>See <a href=\"https://example.com/x\">the notes</a> for more</p>",
        &out,
        &links_buffer,
        &.{},
        &anchor_buffer,
    );

    try testing.expectEqual(@as(usize, 1), rendered.anchors.len);
    const anchor = rendered.anchors[0];
    try testing.expectEqualStrings("the notes", std.mem.trim(u8, rendered.text[anchor.span.start..anchor.span.end], " "));
    try testing.expectEqualStrings("https://example.com/x", anchor.target);
    // The sentence is untouched: no address is appended to it.
    try testing.expectEqualStrings("See the notes for more", rendered.text);
}

test "an anchor whose text is the address is one link, not two" {
    var out: [512]u8 = undefined;
    var links_buffer: [4]links.Link = undefined;
    var anchor_buffer: [max_anchors]Anchor = undefined;
    const rendered = render(
        "<a href=\"https://example.com/x\">https://example.com/x</a>",
        &out,
        &links_buffer,
        &.{},
        &anchor_buffer,
    );

    try testing.expectEqual(@as(usize, 1), rendered.anchors.len);
    try testing.expect(!std.mem.endsWith(u8, rendered.text, ")"));
}

test "a spacing entity is a space, not its own name" {
    var out: [128]u8 = undefined;
    // "&emsp;" is what a mail uses to indent: it must never reach the reader.
    const cleaned = clean_entities("a&emsp;b&ensp;c&thinsp;d&nbsp;e", &out);
    try testing.expectEqualStrings("a b c d e", cleaned);
}

test "a numbered entity is the character it names" {
    var out: [128]u8 = undefined;
    // Zero-width space and BOM: invisible, so nothing to show.
    try testing.expectEqualStrings("ab", clean_entities("a&#8203;b", &out));
    try testing.expectEqualStrings("ab", clean_entities("a&#x200B;b", &out));
    try testing.expectEqualStrings("ab", clean_entities("a&#65279;b", &out));
    // A non-breaking space is a space, in decimal and in hex.
    try testing.expectEqualStrings("a b", clean_entities("a&#160;b", &out));
    try testing.expectEqualStrings("a b", clean_entities("a&#xA0;b", &out));
    // A real character is decoded to its own text.
    try testing.expectEqualStrings("a—b", clean_entities("a&#8212;b", &out));
    // Something that is not an entity is left alone.
    try testing.expectEqualStrings("&#nope;", clean_entities("&#nope;", &out));
    try testing.expectEqualStrings("a&b", clean_entities("a&b", &out));
}

test "a text part made from HTML loses its spacing entities" {
    var out: [128]u8 = undefined;
    // What a sender's "text version" looks like after it has been flattened.
    try testing.expectEqualStrings("  Hola mundo ", clean_spacing("&emsp;&#8203;&nbsp;Hola mundo&nbsp;", &out));
    // Only spacing and invisible marks go: the words stay exactly as written.
    try testing.expectEqualStrings("a & b", clean_spacing("a & b", &out));
    try testing.expectEqualStrings("AT&T", clean_spacing("AT&T", &out));
}
