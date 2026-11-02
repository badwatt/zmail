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
};

/// Renders `html` into `out`, recording the link ranges in `link_buffer`.
pub fn render(html: []const u8, out: []u8, link_buffer: []links.Link, kind_buffer: []Kind) Render {
    var state = State{
        .input = html,
        .writer = std.Io.Writer.fixed(out),
        .link_buffer = link_buffer,
        .kinds = kind_buffer,
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

        // Write the address after the text, so it can be read and clicked even
        // when the anchor text says "click here".
        const text_start = self.anchor_text_start;
        const anchor_text = self.writer.buffered()[text_start..self.written()];
        // The text is already the address: writing it again would be noise.
        if (std.mem.eql(u8, std.mem.trim(u8, anchor_text, " "), target)) {
            if (self.link_count < self.link_buffer.len) {
                self.link_buffer[self.link_count] = .{
                    .start = @intCast(text_start),
                    .end = @intCast(self.written()),
                };
                if (self.written() > text_start) self.link_count += 1;
            }
            return;
        }

        self.pending_space = true;
        self.writeByte('(');
        const url_start = self.written();
        self.write(target);
        const url_end = self.written();
        self.write(")");
        self.at_line_start = false;

        if (self.link_count < self.link_buffer.len and url_end > url_start) {
            self.link_buffer[self.link_count] = .{ .start = @intCast(url_start), .end = @intCast(url_end) };
            self.link_count += 1;
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
        if (value >= 0xd800 and value <= 0xdfff) return null;
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

/// Replaces every `<img>` with the text a terminal can show: its alt text when
/// it has one, `[imagen]` when it does not. A text browser draws words, not
/// pictures, and an image nobody mentions is worse than a placeholder.
pub fn label_images(html: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    var index: usize = 0;

    while (index < html.len) {
        const start = std.mem.indexOfScalarPos(u8, html, index, '<') orelse {
            writer.writeAll(html[index..]) catch {};
            break;
        };
        writer.writeAll(html[index..start]) catch {};
        const end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse {
            writer.writeAll(html[start..]) catch {};
            break;
        };
        const tag = html[start + 1 .. end];
        index = end + 1;

        const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/") orelse tag.len;
        if (!std.ascii.eqlIgnoreCase(tag[0..name_end], "img")) {
            writer.writeAll(html[start .. end + 1]) catch {};
            continue;
        }

        const alt = attribute(tag, "alt");
        if (alt.len > 0) {
            writer.print("[{s}]", .{alt}) catch {};
        } else {
            writer.writeAll("[imagen]") catch {};
        }
    }
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
    const rendered = render(html, &out, &link_buffer, &.{});
    try testing.expectEqualStrings(
        "Hello\n\nFirst line\nsecond line\n\n• one\n• two\n\n  keep\n   this",
        rendered.text,
    );
    try testing.expectEqual(@as(usize, 0), rendered.links.len);
}

test "a link keeps its address, visible and recorded" {
    var out: [256]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html = "<p>Read <a href=\"https://example.com/a\">the docs</a> today.</p>";
    const rendered = render(html, &out, &link_buffer, &.{});
    try testing.expectEqualStrings("Read the docs (https://example.com/a) today.", rendered.text);
    try testing.expectEqual(@as(usize, 1), rendered.links.len);
    try testing.expectEqualStrings(
        "https://example.com/a",
        rendered.links[0].text(rendered.text),
    );
}

test "an anchor whose text is the address is not written twice" {
    var out: [256]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html = "<a href='https://example.com/'>https://example.com/</a>";
    const rendered = render(html, &out, &link_buffer, &.{});
    try testing.expectEqualStrings("https://example.com/", rendered.text);
    try testing.expectEqualStrings("https://example.com/", rendered.links[0].text(rendered.text));
}

test "an image becomes words: its alt text, or a placeholder" {
    var out: [256]u8 = undefined;
    const html = "<p>a<img src=\"x.png\" alt=\"Foto\">b<img src=\"y.png\">c</p>";
    try testing.expectEqualStrings("<p>a[Foto]b[imagen]c</p>", label_images(html, &out));
}

test "entities become their characters, and nbsp is a space" {
    var out: [128]u8 = undefined;
    var link_buffer: [2]links.Link = undefined;
    const rendered = render("<p>Hello&nbsp;<b>world</b> &amp; friends &lt;3 &#233;</p>", &out, &link_buffer, &.{});
    try testing.expectEqualStrings("Hello world & friends <3 é", rendered.text);
}

test "script content is dropped, not shown" {
    var out: [256]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    const html = "<p>before</p><script>alert('boom')</script><p>after</p>";
    const rendered = render(html, &out, &link_buffer, &.{});
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
    const rendered = render(document, &out, &link_buffer, &.{});
    try testing.expect(rendered.text.len <= out.len);
    try testing.expectEqualStrings("xxxxxxxxxxxxxxxx", rendered.text);
}

test "each line carries what it is, so the reader can style it" {
    var out: [512]u8 = undefined;
    var link_buffer: [4]links.Link = undefined;
    var kinds: [16]Kind = undefined;
    const rendered = render(
        "<h2>Title</h2><p>body text</p><blockquote>quoted</blockquote><ul><li>item</li></ul>",
        &out,
        &link_buffer,
        &kinds,
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
