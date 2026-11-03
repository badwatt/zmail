//! A cell buffer and its ANSI encoding.
//!
//! Rendering is a pure function into this buffer; encoding is a separate step.
//! That is what makes the layout testable without a terminal, and what lets a
//! future GUI reuse the same geometry with a different painter.
//!
//! Width model: one codepoint, one cell. Wide glyphs (CJK, emoji) are a known
//! limitation until a width table lands; every character we draw ourselves is
//! narrow.

const std = @import("std");
const assert = std.debug.assert;

pub const max_columns: u16 = 240;
pub const max_rows: u16 = 80;

pub const Color = union(enum) {
    default,
    /// xterm 256-color palette index.
    ansi256: u8,
    /// Truecolor. A theme derived from the terminal's own background cannot be
    /// squeezed into a fixed palette without losing the very thing it derives.
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Attr = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _reserved: u3 = 0,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attr = .{},

    pub fn eql(a: Style, b: Style) bool {
        if (!std.meta.eql(a.fg, b.fg)) return false;
        if (!std.meta.eql(a.bg, b.bg)) return false;
        return std.meta.eql(a.attrs, b.attrs);
    }

    pub fn with_fg(self: Style, fg: Color) Style {
        var style = self;
        style.fg = fg;
        return style;
    }

    pub fn with_bg(self: Style, bg: Color) Style {
        var style = self;
        style.bg = bg;
        return style;
    }

    pub fn with_bold(self: Style) Style {
        var style = self;
        style.attrs.bold = true;
        return style;
    }

    pub fn with_dim(self: Style) Style {
        var style = self;
        style.attrs.dim = true;
        return style;
    }

    pub fn with_underline(self: Style) Style {
        var style = self;
        style.attrs.underline = true;
        return style;
    }

    pub fn with_reverse(self: Style) Style {
        var style = self;
        style.attrs.reverse = true;
        return style;
    }
};

pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},
};

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn right(self: Rect) u16 {
        return self.x + self.width -| 1;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y + self.height -| 1;
    }
};

pub const Screen = struct {
    columns: u16 = 0,
    rows: u16 = 0,
    cells: [max_rows][max_columns]Cell = undefined,
    /// The last frame written to the terminal. Flushing only the rows that
    /// differ keeps a ticking spinner to one row instead of a full repaint,
    /// which is what made the header flicker.
    previous: [max_rows][max_columns]Cell = undefined,
    /// Nothing has been written yet: the next flush must paint every row.
    pristine: bool = true,

    pub fn init(columns: u16, rows: u16) Screen {
        var screen: Screen = .{};
        screen.resize(columns, rows);
        return screen;
    }

    pub fn resize(self: *Screen, columns: u16, rows: u16) void {
        const bounded_columns = @min(columns, max_columns);
        const bounded_rows = @min(rows, max_rows);
        // Called on every frame; resizing to the same size must not throw away
        // the previous frame (that would repaint everything and flicker).
        if (bounded_columns == self.columns and bounded_rows == self.rows) return;
        self.columns = bounded_columns;
        self.rows = bounded_rows;
        self.clear();
        self.pristine = true;
    }

    /// True when this row differs from what the terminal already shows.
    pub fn row_changed(self: *const Screen, row: u16) bool {
        assert(row < self.rows);
        if (self.pristine) return true;
        var x: u16 = 0;
        while (x < self.columns) : (x += 1) {
            const now = self.cells[row][x];
            const before = self.previous[row][x];
            if (now.ch != before.ch) return true;
            if (!Style.eql(now.style, before.style)) return true;
        }
        return false;
    }

    /// True when any row needs to be written.
    pub fn dirty_any(self: *const Screen) bool {
        if (self.pristine) return self.rows > 0;
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            if (self.row_changed(row)) return true;
        }
        return false;
    }

    /// Remembers the frame as written.
    pub fn commit(self: *Screen) void {
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            @memcpy(self.previous[row][0..self.columns], self.cells[row][0..self.columns]);
        }
        self.pristine = false;
    }

    pub fn clear(self: *Screen) void {
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.columns) : (x += 1) {
                self.cells[y][x] = .{};
            }
        }
    }

    pub fn put(self: *Screen, x: u16, y: u16, ch: u21, style: Style) void {
        if (x >= self.columns) return;
        if (y >= self.rows) return;
        self.cells[y][x] = .{ .ch = safeCodepoint(ch), .style = style };
    }

    /// Marks a cell as the second half of a wide glyph: it holds no codepoint of
    /// its own and is never written out, because the terminal already advanced
    /// past it.
    fn put_covered(self: *Screen, x: u16, y: u16, style: Style) void {
        if (x >= self.columns) return;
        if (y >= self.rows) return;
        self.cells[y][x] = .{ .ch = 0, .style = style };
    }

    /// Writes `text` and returns how many cells it used. Stops at `width`.
    ///
    /// Invalid UTF-8 becomes '?' one byte at a time, so a corrupt body can
    /// never smuggle a partial sequence into the cell buffer.
    pub fn put_text(self: *Screen, x: u16, y: u16, text: []const u8, width: u16, style: Style) u16 {
        var cell_x = x;
        var written: u16 = 0;
        var index: usize = 0;
        while (index < text.len and written < width) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
            if (sequence_len == 0) {
                self.put(cell_x, y, '?', style);
                cell_x += 1;
                written += 1;
                index += 1;
                continue;
            }
            if (sequence_len > text.len - index) {
                self.put(cell_x, y, '?', style);
                written += 1;
                break;
            }
            const span: usize = sequence_len;
            const ch = std.unicode.utf8Decode(text[index..][0..span]) catch {
                self.put(cell_x, y, '?', style);
                cell_x += 1;
                written += 1;
                index += 1;
                continue;
            };
            const cells = cell_width(ch);
            if (cells == 0) {
                // A combining mark belongs to the character before it.
                index += span;
                continue;
            }
            if (written + cells > width) break;
            self.put(cell_x, y, ch, style);
            // A wide glyph covers the cell after it. It is marked, not written:
            // sending a space there would push the terminal one column further.
            if (cells == 2) self.put_covered(cell_x + 1, y, style);
            cell_x += cells;
            written += cells;
            index += span;
        }
        return written;
    }

    /// Writes as much as fits, ending with an ellipsis when it had to cut.
    pub fn put_text_truncated(self: *Screen, x: u16, y: u16, text: []const u8, width: u16, style: Style) void {
        if (width == 0) return;
        if (text_columns(text) <= width) {
            _ = self.put_text(x, y, text, width, style);
            return;
        }
        if (width == 1) {
            self.put(x, y, '…', style);
            return;
        }
        _ = self.put_text(x, y, text, width - 1, style);
        self.put(x + width - 1, y, '…', style);
    }

    pub fn hline(self: *Screen, x: u16, y: u16, width: u16, ch: u21, style: Style) void {
        var index: u16 = 0;
        while (index < width) : (index += 1) {
            self.put(x + index, y, ch, style);
        }
    }

    pub fn vline(self: *Screen, x: u16, y: u16, height: u16, ch: u21, style: Style) void {
        var index: u16 = 0;
        while (index < height) : (index += 1) {
            self.put(x, y + index, ch, style);
        }
    }

    pub fn fill_rect(self: *Screen, rect: Rect, ch: u21, style: Style) void {
        var row: u16 = 0;
        while (row < rect.height) : (row += 1) {
            self.hline(rect.x, rect.y + row, rect.width, ch, style);
        }
    }

    /// A card: an empty panel with a rounded border, ready for a title.
    pub fn card(self: *Screen, rect: Rect, fill: Style, border: Style) void {
        self.fill_rect(rect, ' ', fill);
        self.box(rect, border);
    }

    /// Rounded box, drawn inside `rect`.
    pub fn box(self: *Screen, rect: Rect, style: Style) void {
        if (rect.width < 2) return;
        if (rect.height < 2) return;

        self.put(rect.x, rect.y, '╭', style);
        self.put(rect.right(), rect.y, '╮', style);
        self.put(rect.x, rect.bottom(), '╰', style);
        self.put(rect.right(), rect.bottom(), '╯', style);
        self.hline(rect.x + 1, rect.y, rect.width - 2, '─', style);
        self.hline(rect.x + 1, rect.bottom(), rect.width - 2, '─', style);
        self.vline(rect.x, rect.y + 1, rect.height - 2, '│', style);
        self.vline(rect.right(), rect.y + 1, rect.height - 2, '│', style);
    }

    /// Encodes one row with style runs. No newline: the caller decides how rows
    /// are separated, which lets the session stream a frame row by row.
    pub fn encode_row(self: *const Screen, row: u16, writer: *std.Io.Writer, colored: bool) std.Io.Writer.Error!void {
        assert(row < self.rows);
        // The terminal keeps its attributes across rows, so the first cell of a
        // row must always emit an SGR: starting from `Style{}` and comparing
        // would let a selected row bleed into the next one.
        var current: ?Style = null;
        var column: u16 = 0;
        while (column < self.columns) : (column += 1) {
            const cell = self.cells[row][column];
            if (cell.ch == 0) continue; // the right half of a wide glyph
            if (current == null or !cell.style.eql(current.?)) {
                try write_sgr(writer, cell.style, colored);
                current = cell.style;
            }
            try write_glyph(writer, cell.ch);
        }
    }

    /// Encodes the whole frame with style runs, cursor home first.
    ///
    /// No clear-screen: rows are written fully, so the terminal never shows an
    /// intermediate blank frame.
    pub fn write_frame(self: *const Screen, writer: *std.Io.Writer, colored: bool) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b[H");
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            try self.encode_row(row, writer, colored);
            if (row + 1 < self.rows) try writer.writeAll("\r\n");
        }
        try writer.writeAll("\x1b[0m");
    }

    /// Extracts a row as text, trimming trailing spaces. Test hook and useful
    /// for logging a frame shape without a terminal.
    pub fn row_text(self: *const Screen, y: u16, buffer: []u8) []const u8 {
        if (y >= self.rows) return "";
        var length: usize = 0;
        var end: usize = 0;
        var column: u16 = 0;
        while (column < self.columns) : (column += 1) {
            const ch = self.cells[y][column].ch;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(ch, &encoded) catch continue;
            if (length + encoded_len > buffer.len) break;
            @memcpy(buffer[length..][0..encoded_len], encoded[0..encoded_len]);
            length += encoded_len;
            if (ch != ' ') end = length;
        }
        return buffer[0..end];
    }
};

fn safeCodepoint(ch: u21) u21 {
    if (ch == 0) return ' ';
    if (ch < 0x20) return ' ';
    if (ch == 0x7f) return ' ';
    return ch;
}

fn write_glyph(writer: *std.Io.Writer, ch: u21) std.Io.Writer.Error!void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(ch, &encoded) catch blk: {
        encoded[0] = '?';
        break :blk 1;
    };
    try writer.writeAll(encoded[0..length]);
}

/// Number of cells `text` occupies, counting codepoints, bounded by its length.
/// Cells a codepoint occupies. A terminal lays out an emoji or a CJK glyph in
/// two, and a combining mark in none: counting every codepoint as one is what
/// pushes a column out of line and lets a row spill into the next one.
pub fn cell_width(codepoint: u21) u16 {
    if (codepoint == 0) return 0;
    // Zero width: combining marks, joiners, variation selectors.
    if (codepoint < 0x20) return 0;
    if (codepoint >= 0x0300 and codepoint <= 0x036f) return 0;
    if (codepoint >= 0x200b and codepoint <= 0x200f) return 0;
    if (codepoint >= 0xfe00 and codepoint <= 0xfe0f) return 0;
    if (codepoint == 0xfeff) return 0;

    // Wide: the East Asian blocks, and emoji, which terminals double.
    if (codepoint >= 0x1100 and codepoint <= 0x115f) return 2;
    if (codepoint >= 0x2e80 and codepoint <= 0xa4cf) return 2;
    if (codepoint >= 0xac00 and codepoint <= 0xd7a3) return 2;
    if (codepoint >= 0xf900 and codepoint <= 0xfaff) return 2;
    if (codepoint >= 0xfe30 and codepoint <= 0xfe6f) return 2;
    if (codepoint >= 0xff00 and codepoint <= 0xff60) return 2;
    if (codepoint >= 0xffe0 and codepoint <= 0xffe6) return 2;
    if (codepoint >= 0x1f300 and codepoint <= 0x1f64f) return 2;
    if (codepoint >= 0x1f900 and codepoint <= 0x1f9ff) return 2;
    if (codepoint >= 0x1f680 and codepoint <= 0x1f6ff) return 2;
    if (codepoint >= 0x1f000 and codepoint <= 0x1f02f) return 2;
    if (codepoint >= 0x1fa70 and codepoint <= 0x1faff) return 2;
    if (codepoint >= 0x20000 and codepoint <= 0x3fffd) return 2;
    return 1;
}

pub fn text_columns(text: []const u8) u16 {
    var count: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const span = @min(@as(usize, sequence_len), text.len - index);
        const codepoint = std.unicode.utf8Decode(text[index..][0..span]) catch '?';
        count += cell_width(codepoint);
        index += span;
    }
    return count;
}

fn write_sgr(writer: *std.Io.Writer, style: Style, colored: bool) std.Io.Writer.Error!void {
    try writer.writeAll("\x1b[0");
    if (style.attrs.bold) try writer.writeAll(";1");
    if (style.attrs.dim) try writer.writeAll(";2");
    if (style.attrs.italic) try writer.writeAll(";3");
    if (style.attrs.underline) try writer.writeAll(";4");
    if (style.attrs.reverse) try writer.writeAll(";7");
    if (colored) {
        switch (style.fg) {
            .default => {},
            .ansi256 => |index| try writer.print(";38;5;{d}", .{index}),
            .rgb => |c| try writer.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        }
        switch (style.bg) {
            .default => {},
            .ansi256 => |index| try writer.print(";48;5;{d}", .{index}),
            .rgb => |c| try writer.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        }
    }
    try writer.writeAll("m");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn row_at(screen: *const Screen, y: u16, buffer: []u8) []const u8 {
    return screen.row_text(y, buffer);
}

test "Style: copies with modifiers and compares structurally" {
    const plain = Style{};
    const accent = plain.with_fg(.{ .ansi256 = 74 });
    try testing.expect(!plain.eql(accent));
    try testing.expect(accent.eql(plain.with_fg(.{ .ansi256 = 74 })));
    try testing.expect(!accent.eql(accent.with_bg(.{ .ansi256 = 1 })));
    try testing.expect(plain.with_bold().attrs.bold);
    try testing.expect(plain.with_dim().attrs.dim);
    try testing.expect(plain.with_underline().attrs.underline);
    try testing.expect(plain.with_reverse().attrs.reverse);
}

test "Screen: resize clamps to the maximum and clears" {
    var screen = Screen.init(10, 3);
    screen.put(0, 0, 'x', .{});
    screen.resize(2000, 2000);
    try testing.expectEqual(max_columns, screen.columns);
    try testing.expectEqual(max_rows, screen.rows);

    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("", screen.row_text(0, &buffer));
}

test "Screen: writes outside the buffer are ignored" {
    var screen = Screen.init(4, 2);
    screen.put(4, 0, 'x', .{});
    screen.put(0, 2, 'x', .{});
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("", screen.row_text(0, &buffer));
    try testing.expectEqualStrings("", screen.row_text(1, &buffer));
}

test "Screen: put_text writes, truncates at width, and reports the count" {
    var screen = Screen.init(12, 2);
    const written = screen.put_text(0, 0, "hello", 5, .{});
    try testing.expectEqual(@as(u16, 5), written);

    const clipped = screen.put_text(0, 1, "hello", 3, .{});
    try testing.expectEqual(@as(u16, 3), clipped);

    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", row_at(&screen, 0, &buffer));
    try testing.expectEqualStrings("hel", row_at(&screen, 1, &buffer));
}

test "Screen: put_text handles multibyte text and invalid bytes" {
    var screen = Screen.init(12, 2);
    _ = screen.put_text(0, 0, "olá", 4, .{});
    _ = screen.put_text(0, 1, "a\xffb", 4, .{});
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("olá", row_at(&screen, 0, &buffer));
    try testing.expectEqualStrings("a?b", row_at(&screen, 1, &buffer));
}

test "Screen: put_text replaces an invalid continuation byte" {
    var screen = Screen.init(8, 1);
    _ = screen.put_text(0, 0, "a\xc3(b", 6, .{});
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("a?(b", row_at(&screen, 0, &buffer));
}

test "Screen: put_text stops at a truncated multibyte sequence" {
    var screen = Screen.init(12, 1);
    _ = screen.put_text(0, 0, "a\xc3", 4, .{});
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("a?", row_at(&screen, 0, &buffer));
}

test "Screen: put_text_truncated fits the text unchanged when it can" {
    var screen = Screen.init(12, 1);
    screen.put_text_truncated(0, 0, "short", 10, .{});
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("short", row_at(&screen, 0, &buffer));
}

test "Screen: put_text_truncated cuts and marks the cut with an ellipsis" {
    var screen = Screen.init(12, 1);
    screen.put_text_truncated(0, 0, "a long subject line", 8, .{});
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("a long …", row_at(&screen, 0, &buffer));
}

test "Screen: put_text_truncated with one column writes only the ellipsis" {
    var screen = Screen.init(4, 1);
    screen.put_text_truncated(0, 0, "hello", 1, .{});
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("…", row_at(&screen, 0, &buffer));
}

test "Screen: put_text_truncated with zero columns writes nothing" {
    var screen = Screen.init(4, 1);
    screen.put_text_truncated(0, 0, "hello", 0, .{});
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("", row_at(&screen, 0, &buffer));
}

test "Screen: hline and vline draw exactly the requested span" {
    var screen = Screen.init(8, 4);
    screen.hline(1, 0, 3, '─', .{});
    screen.vline(0, 1, 3, '│', .{});
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(" ───", row_at(&screen, 0, &buffer));
    try testing.expectEqualStrings("│", row_at(&screen, 1, &buffer));
    try testing.expectEqualStrings("│", row_at(&screen, 2, &buffer));
    try testing.expectEqualStrings("│", row_at(&screen, 3, &buffer));
}

test "Screen: box draws rounded corners and edges" {
    var screen = Screen.init(6, 4);
    screen.box(.{ .x = 0, .y = 0, .width = 6, .height = 4 }, .{});
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("╭────╮", row_at(&screen, 0, &buffer));
    try testing.expectEqualStrings("│    │", row_at(&screen, 1, &buffer));
    try testing.expectEqualStrings("╰────╯", row_at(&screen, 3, &buffer));
}

test "Screen: box refuses rects too small to hold corners" {
    var screen = Screen.init(4, 4);
    screen.box(.{ .x = 0, .y = 0, .width = 1, .height = 2 }, .{});
    screen.box(.{ .x = 0, .y = 0, .width = 2, .height = 1 }, .{});
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("", row_at(&screen, 0, &buffer));
}

test "Screen: fill_rect paints every cell of the rect" {
    var screen = Screen.init(6, 3);
    screen.fill_rect(.{ .x = 1, .y = 1, .width = 3, .height = 1 }, '.', .{});
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(" ...", row_at(&screen, 1, &buffer));
}

test "Screen: write_frame emits home, rows, style runs, and a reset" {
    var screen = Screen.init(3, 2);
    _ = screen.put_text(0, 0, "ab", 3, .{ .fg = .{ .ansi256 = 74 }, .bg = .{ .ansi256 = 237 } });
    _ = screen.put_text(0, 1, "cd", 3, .{});

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try screen.write_frame(&writer, true);
    const output = writer.buffered();

    try testing.expect(std.mem.startsWith(u8, output, "\x1b[H"));
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[0;38;5;74;48;5;237mab") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cd") != null);
    try testing.expect(std.mem.endsWith(u8, output, "\x1b[0m"));
}

test "Screen: write_frame replaces a codepoint that cannot be encoded" {
    var screen = Screen.init(1, 1);
    screen.put(0, 0, 0xd800, .{});

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try screen.write_frame(&writer, true);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "?\x1b[0m"));
}

test "Screen: each row opens with an SGR so styles never bleed across rows" {
    var screen = Screen.init(4, 2);
    // Row 0 is a fully painted selection; row 1 is plain.
    screen.fill_rect(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, ' ', .{ .bg = .{ .ansi256 = 237 } });
    _ = screen.put_text(0, 1, "next", 4, .{});

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try screen.write_frame(&writer, true);
    const output = writer.buffered();

    const second_row = std.mem.indexOf(u8, output, "\r\n") orelse return error.TestExpectedRows;
    try testing.expect(std.mem.startsWith(u8, output[second_row + 2 ..], "\x1b[0m"));
}

test "truecolor is written as 38;2 and 48;2" {
    var screen = Screen.init(8, 2);
    screen.put(0, 0, 'x', .{ .fg = .{ .rgb = .{ .r = 156, .g = 162, .b = 200 } } });
    screen.put(1, 0, 'y', .{
        .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .bg = .{ .rgb = .{ .r = 25, .g = 25, .b = 37 } },
    });

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try screen.encode_row(0, &writer, true);
    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "38;2;156;162;200") != null);
    try testing.expect(std.mem.indexOf(u8, output, "38;2;1;2;3") != null);
    try testing.expect(std.mem.indexOf(u8, output, "48;2;25;25;37") != null);

    // Without color, neither form appears.
    writer = std.Io.Writer.fixed(&buffer);
    try screen.encode_row(0, &writer, false);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;2") == null);
}

test "Screen: write_frame omits colors in monochrome mode" {
    var screen = Screen.init(1, 1);
    screen.put(0, 0, 'x', .{ .fg = .{ .ansi256 = 74 }, .bg = .{ .ansi256 = 1 }, .attrs = .{ .bold = true } });

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try screen.write_frame(&writer, false);
    const output = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, output, "38;5") == null);
    try testing.expect(std.mem.indexOf(u8, output, "48;5") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[0;1m") != null);
}

test "Screen: control codepoints are painted as spaces" {
    var screen = Screen.init(2, 1);
    screen.put(0, 0, 0x1b, .{});
    const cell = screen.cells[0][0];
    try testing.expectEqual(@as(u21, ' '), cell.ch);
}

test "text_columns counts codepoints, not bytes" {
    try testing.expectEqual(@as(u16, 3), text_columns("olá"));
    try testing.expectEqual(@as(u16, 0), text_columns(""));
    try testing.expectEqual(@as(u16, 2), text_columns("a\xff"));
}

test "an emoji takes two cells and a combining mark none" {
    try testing.expectEqual(@as(u16, 1), cell_width('a'));
    try testing.expectEqual(@as(u16, 2), cell_width(0x1f389)); // 🎉
    try testing.expectEqual(@as(u16, 0), cell_width(0x0301)); // combining acute
    try testing.expectEqual(@as(u16, 2), cell_width(0x4e00)); // 一
}

test "a row with an emoji occupies the same columns as one without" {
    var screen: Screen = .{};
    screen.resize(20, 2);
    const plain = Style{};

    // "🎉[11.11" is seven codepoints but eight cells.
    _ = screen.put_text(0, 0, "🎉[11.11", 20, plain);
    _ = screen.put_text(0, 1, "ab", 20, plain);

    try testing.expectEqual(@as(u16, 8), text_columns("🎉[11.11"));
    // Whatever is written after the emoji starts one cell later than the naive
    // count would say, and nothing spills into the next row.
    _ = screen.put_text(0, 1, "1234567", 20, plain);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("1234567", std.mem.trimEnd(u8, screen.row_text(1, &buffer), " "));
}

test "a wide glyph is sent once, without an extra cell after it" {
    var screen: Screen = .{};
    screen.resize(20, 1);

    // "🎉ab" is four cells: the emoji, its covered half, then a and b.
    _ = screen.put_text(0, 0, "🎉ab", 20, .{});

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try screen.encode_row(0, &writer, false);
    const encoded = writer.buffered();

    // The emoji appears once and the covered cell sends nothing at all: the
    // text after it follows immediately, and the row is padded to its width.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, encoded, "🎉"));
    const body = std.mem.trimStart(u8, encoded, "\x1b[0m");
    const glyphs = std.mem.trimEnd(u8, body, " ");
    try testing.expect(std.mem.endsWith(u8, glyphs, "🎉ab"));
    // Emoji (two cells) + a and b is four, so sixteen spaces pad the rest.
    try testing.expectEqual(@as(usize, 16), body.len - glyphs.len);
}
