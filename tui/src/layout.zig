//! Geometry. No text, no colors: just where things go, for one terminal size.
//!
//! The layout also owns hit boxes (which tab is at column X), so mouse handling
//! and rendering cannot disagree about where a tab is.

const std = @import("std");
const assert = std.debug.assert;
const Mailbox = @import("core").mailbox.Mailbox;

pub const min_columns: u16 = 40;
pub const min_rows: u16 = 10;

pub const tab_start: u16 = 8;
pub const tab_width: u16 = 11;

pub const Layout = struct {
    columns: u16 = 0,
    rows: u16 = 0,
    too_small: bool = true,

    header_y: u16 = 0,
    top_rule_y: u16 = 1,
    body_y: u16 = 2,
    body_height: u16 = 0,
    bottom_rule_y: u16 = 0,
    footer_y: u16 = 0,

    list_rows: u16 = 0,
    /// The reader uses the whole screen: subject, metadata, rule, body.
    reader_subject_y: u16 = 0,
    reader_meta_y: u16 = 1,
    reader_rule_y: u16 = 2,
    reader_body_y: u16 = 3,
    reader_rows: u16 = 0,
    reader_text_x: u16 = 1,
    reader_text_width: u16 = 0,

    show_tabs: bool = false,
    sender_x: u16 = 3,
    sender_width: u16 = 0,
    subject_x: u16 = 0,
    subject_width: u16 = 0,
    date_x: u16 = 0,
    date_width: u16 = 5,
    flag_x: u16 = 0,
    dot_x: u16 = 1,

    pub fn compute(columns: u16, rows: u16) Layout {
        var layout: Layout = .{ .columns = columns, .rows = rows };
        layout.too_small = columns < min_columns or rows < min_rows;
        if (layout.too_small) return layout;

        layout.top_rule_y = 1;
        layout.body_y = 2;
        layout.bottom_rule_y = rows - 3;
        layout.footer_y = rows - 1;
        layout.body_height = layout.bottom_rule_y - layout.body_y;
        layout.list_rows = layout.body_height;
        layout.reader_rows = layout.bottom_rule_y -| layout.reader_body_y;
        layout.reader_text_width = columns - 2;
        layout.show_tabs = columns >= tab_start + Mailbox.all.len * tab_width + 2;

        layout.sender_width = @max(10, @min(24, columns / 4));
        layout.subject_x = layout.sender_x + layout.sender_width + 1;
        layout.flag_x = columns - 1;
        layout.date_x = layout.flag_x - 1 - layout.date_width;
        layout.subject_width = layout.date_x -| 1 -| layout.subject_x;
        assert(layout.subject_width >= 1);
        return layout;
    }

    pub fn tab_x(self: Layout, mailbox: Mailbox) u16 {
        assert(self.show_tabs);
        return tab_start + @as(u16, mailbox.index()) * tab_width;
    }

    /// Which mailbox tab is at column `x`, if any.
    pub fn mailbox_at(self: Layout, x: u16) ?Mailbox {
        if (!self.show_tabs) return null;
        if (x < tab_start) return null;
        const offset = x - tab_start;
        const position = offset / tab_width;
        if (position >= Mailbox.all.len) return null;
        return Mailbox.from_index(@intCast(position));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "compute marks tiny terminals as too small" {
    try testing.expect(Layout.compute(39, 40).too_small);
    try testing.expect(Layout.compute(80, 9).too_small);
    try testing.expect(!Layout.compute(40, 10).too_small);
}

test "compute divides the screen into header, body, and footer" {
    const layout = Layout.compute(100, 30);
    try testing.expectEqual(@as(u16, 0), layout.header_y);
    try testing.expectEqual(@as(u16, 1), layout.top_rule_y);
    try testing.expectEqual(@as(u16, 2), layout.body_y);
    try testing.expectEqual(@as(u16, 27), layout.bottom_rule_y);
    try testing.expectEqual(@as(u16, 25), layout.body_height);
    try testing.expectEqual(@as(u16, 29), layout.footer_y);
    try testing.expectEqual(@as(u16, 25), layout.list_rows);
}

test "compute keeps the list columns inside the screen" {
    const layout = Layout.compute(80, 24);
    try testing.expectEqual(@as(u16, 3), layout.sender_x);
    try testing.expectEqual(@as(u16, 20), layout.sender_width);
    try testing.expectEqual(@as(u16, 24), layout.subject_x);
    try testing.expectEqual(@as(u16, 79), layout.flag_x);
    try testing.expectEqual(@as(u16, 73), layout.date_x);
    try testing.expectEqual(@as(u16, 48), layout.subject_width);
    try testing.expect(layout.subject_x + layout.subject_width <= layout.date_x);
}

test "compute hides tabs on narrow terminals and shows them when they fit" {
    const narrow = Layout.compute(70, 24);
    try testing.expect(!narrow.show_tabs);
    try testing.expect(narrow.mailbox_at(10) == null);

    const wide = Layout.compute(76, 24);
    try testing.expect(wide.show_tabs);
}

test "tab hit boxes tile the header exactly" {
    const layout = Layout.compute(120, 30);
    for (Mailbox.all, 0..) |mailbox, position| {
        const x = tab_start + @as(u16, @intCast(position)) * tab_width;
        try testing.expectEqual(x, layout.tab_x(mailbox));
        try testing.expectEqual(mailbox, layout.mailbox_at(x).?);
        try testing.expectEqual(mailbox, layout.mailbox_at(x + tab_width - 1).?);
    }
    try testing.expect(layout.mailbox_at(tab_start - 1) == null);
    try testing.expect(layout.mailbox_at(tab_start + Mailbox.all.len * tab_width) == null);
}

test "reader geometry uses the full screen and leaves room for the body" {
    const layout = Layout.compute(60, 12);
    try testing.expectEqual(@as(u16, 0), layout.reader_subject_y);
    try testing.expectEqual(@as(u16, 1), layout.reader_meta_y);
    try testing.expectEqual(@as(u16, 2), layout.reader_rule_y);
    try testing.expectEqual(@as(u16, 3), layout.reader_body_y);
    try testing.expectEqual(@as(u16, 6), layout.reader_rows);
    try testing.expectEqual(@as(u16, 1), layout.reader_text_x);
    try testing.expectEqual(@as(u16, 58), layout.reader_text_width);
}
