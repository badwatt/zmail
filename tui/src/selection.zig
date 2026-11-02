//! Copying what the mouse selected.
//!
//! Selecting text with the mouse should put it on the clipboard, like every
//! other terminal program. The text is taken from the body the reader already
//! has, using the wrapped lines it already computed, so nothing is fetched and
//! nothing is guessed: the cells under the pointer are the bytes that get
//! copied.

const std = @import("std");
const assert = std.debug.assert;
const wrap = @import("wrap.zig");

/// One cell of the reader's body: a wrapped line and a column in it.
pub const Cell = struct {
    line: u32 = 0,
    column: u16 = 0,
};

pub const Selection = struct {
    anchor: Cell = .{},
    cursor: Cell = .{},

    pub fn start(cell: Cell) Selection {
        return .{ .anchor = cell, .cursor = cell };
    }

    pub fn dragTo(self: *Selection, cell: Cell) void {
        self.cursor = cell;
    }

    /// True when the selection covers more than the cell it started on: that is
    /// the difference between a click and a drag.
    pub fn isDrag(self: *const Selection) bool {
        return self.anchor.line != self.cursor.line or
            self.anchor.column + 1 < self.cursor.column or
            self.cursor.column + 1 < self.anchor.column;
    }

    /// Anchor and cursor in reading order, so a drag upwards copies the same as
    /// one downwards.
    pub fn ordered(self: *const Selection) struct { first: Cell, last: Cell } {
        if (self.anchor.line != self.cursor.line) {
            if (self.anchor.line < self.cursor.line) {
                return .{ .first = self.anchor, .last = self.cursor };
            }
            return .{ .first = self.cursor, .last = self.anchor };
        }
        if (self.anchor.column <= self.cursor.column) {
            return .{ .first = self.anchor, .last = self.cursor };
        }
        return .{ .first = self.cursor, .last = self.anchor };
    }
};

/// The selected text, lines joined the way the eye sees them: a line the
/// wrapper broke mid-sentence joins without a newline, a real paragraph keeps
/// one.
pub fn extract(selection: Selection, wrapped: *const wrap.Wrapped, body: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    if (wrapped.len == 0) return writer.buffered();

    const range = selection.ordered();
    const last_line = @min(range.last.line, wrapped.len - 1);
    var line_index = @min(range.first.line, last_line);

    while (line_index <= last_line) : (line_index += 1) {
        const line = wrapped.lines[line_index];
        const from = if (line_index == @min(range.first.line, last_line))
            @min(@as(usize, range.first.column), line.end - line.start)
        else
            0;
        const to = if (line_index == last_line)
            @min(@as(usize, range.last.column) + 1, line.end - line.start)
        else
            line.end - line.start;
        if (to > from) writer.writeAll(body[line.start + from .. line.start + to]) catch break;

        if (line_index == last_line) break;
        // A soft wrap continues the same sentence: no newline belongs there.
        // The wrapper drops the space it broke at, so the test is whether the
        // gap between the two lines holds a newline, not whether they touch.
        const next = wrapped.lines[line_index + 1];
        const gap = if (next.start > line.end) body[line.end..next.start] else body[0..0];
        const soft = std.mem.indexOfScalar(u8, gap, '\n') == null;
        if (!soft) writer.writeByte('\n') catch break;
    }
    return writer.buffered();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a single line copies from the first column to the last" {
    var wrapped: wrap.Wrapped = .{};
    const body = "hello world";
    wrap.wrap(body, 40, &wrapped);

    var out: [64]u8 = undefined;
    const selection = Selection{
        .anchor = .{ .line = 0, .column = 6 },
        .cursor = .{ .line = 0, .column = 10 },
    };
    try testing.expectEqualStrings("world", extract(selection, &wrapped, body, &out));
}

test "a drag upwards copies in reading order, like one downwards" {
    var wrapped: wrap.Wrapped = .{};
    const body = "one\ntwo\nthree";
    wrap.wrap(body, 40, &wrapped);

    var out: [64]u8 = undefined;
    const upwards = Selection{
        .anchor = .{ .line = 2, .column = 2 },
        .cursor = .{ .line = 0, .column = 1 },
    };
    // The selection runs from column 1 of the first line to column 2 of the
    // last, whichever way the drag went.
    try testing.expectEqualStrings("ne\ntwo\nthr", extract(upwards, &wrapped, body, &out));

    const downwards = Selection{
        .anchor = .{ .line = 0, .column = 1 },
        .cursor = .{ .line = 2, .column = 2 },
    };
    try testing.expectEqualStrings("ne\ntwo\nthr", extract(downwards, &wrapped, body, &out));
}

test "a wrapped line joins without a newline, a paragraph keeps one" {
    var wrapped: wrap.Wrapped = .{};
    const body = "aaaa bbbb cccc\ndddd";
    wrap.wrap(body, 10, &wrapped);
    try testing.expect(wrapped.len >= 3);

    var out: [64]u8 = undefined;
    // From the first line into its continuation: no newline is inserted, the
    // sentence reads as one.
    const within = Selection{ .anchor = .{ .line = 0, .column = 0 }, .cursor = .{ .line = 1, .column = 3 } };
    const text = extract(within, &wrapped, body, &out);
    try testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    try testing.expect(std.mem.startsWith(u8, text, "aaaa bbbb"));
    try testing.expect(std.mem.endsWith(u8, text, "cccc"));

    // A real paragraph break does keep its newline.
    const across = Selection{ .anchor = .{ .line = 0, .column = 0 }, .cursor = .{ .line = 2, .column = 3 } };
    try testing.expect(std.mem.indexOfScalar(u8, extract(across, &wrapped, body, &out), '\n') != null);
}

test "a click is not a drag" {
    const click = Selection.start(.{ .line = 4, .column = 7 });
    try testing.expect(!click.isDrag());

    var drag = Selection.start(.{ .line = 4, .column = 7 });
    drag.dragTo(.{ .line = 4, .column = 9 });
    try testing.expect(drag.isDrag());

    var lines = Selection.start(.{ .line = 4, .column = 7 });
    lines.dragTo(.{ .line = 6, .column = 2 });
    try testing.expect(lines.isDrag());
}

test "extract never reads past the wrapped lines" {
    var wrapped: wrap.Wrapped = .{};
    const body = "short";
    wrap.wrap(body, 40, &wrapped);

    var out: [64]u8 = undefined;
    const far = Selection{ .anchor = .{ .line = 0, .column = 0 }, .cursor = .{ .line = 99, .column = 99 } };
    try testing.expectEqualStrings("short", extract(far, &wrapped, body, &out));

    var empty: [8]u8 = undefined;
    var no_lines: wrap.Wrapped = .{};
    try testing.expectEqualStrings("", extract(far, &no_lines, body, &empty));
    _ = &empty;
}
