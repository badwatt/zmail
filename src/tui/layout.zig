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
/// The count is drawn right after the title, left-aligned in this many cells,
/// so it always reads as part of its own mailbox ("Inbox 3", never "3  Sent").
pub const tab_count_width: u16 = 3;
pub const tab_gap: u16 = 2;

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
    account_x: u16 = 3,
    /// Width of the account label column (0 when the view is one account).
    account_width: u16 = 0,
    account_tags: bool = false,
    sender_x: u16 = 3,
    sender_width: u16 = 0,
    subject_x: u16 = 0,
    subject_width: u16 = 0,
    date_x: u16 = 0,
    date_width: u16 = 5,
    flag_x: u16 = 0,
    dot_x: u16 = 1,

    /// `label_width` is the longest account label (0 = single account, no
    /// column): the column sizes itself to the names, bounded.
    pub fn compute(columns: u16, rows: u16, label_width: u8) Layout {
        const account_tags = label_width > 0;
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
        layout.show_tabs = columns >= tab_start + tabs_width() + 1;

        layout.account_tags = account_tags;
        layout.account_width = if (account_tags)
            @min(@max(@as(u16, label_width), 2), @min(10, columns / 6))
        else
            0;
        layout.account_x = layout.dot_x + 2;
        layout.sender_x = if (account_tags) layout.account_x + layout.account_width + 1 else 3;
        layout.sender_width = @max(8, @min(24, columns / 4) - @as(u16, if (account_tags) 2 else 0));
        layout.subject_x = layout.sender_x + layout.sender_width + 1;
        layout.flag_x = columns - 1;
        layout.date_x = layout.flag_x - 1 - layout.date_width;
        layout.subject_width = layout.date_x -| 1 -| layout.subject_x;
        assert(layout.subject_width >= 1);
        return layout;
    }

    pub fn tab_x(self: Layout, mailbox: Mailbox) u16 {
        assert(self.show_tabs);
        var x: u16 = tab_start;
        for (Mailbox.all, 0..) |candidate, index| {
            if (index == mailbox.index()) break;
            x += tab_span(candidate);
        }
        return x;
    }

    /// First cell of the count that belongs to `mailbox`.
    pub fn tab_count_x(self: Layout, mailbox: Mailbox) u16 {
        return self.tab_x(mailbox) + title_width(mailbox) + 1;
    }

    /// Which mailbox tab is at column `x`, if any. The gap after a tab belongs
    /// to no mailbox, so a click there does nothing.
    pub fn mailbox_at(self: Layout, x: u16) ?Mailbox {
        if (!self.show_tabs) return null;
        for (Mailbox.all) |mailbox| {
            const start = self.tab_x(mailbox);
            if (x >= start and x < start + tab_hit_width(mailbox)) return mailbox;
        }
        return null;
    }
};

pub fn title_width(mailbox: Mailbox) u16 {
    return @intCast(mailbox.title().len);
}

/// Cells one tab occupies: title, one space, the count area, and a gap.
pub fn tab_span(mailbox: Mailbox) u16 {
    return title_width(mailbox) + 1 + tab_count_width + tab_gap;
}

/// Cells that respond to a click: the title and its count, not the gap.
pub fn tab_hit_width(mailbox: Mailbox) u16 {
    return title_width(mailbox) + 1 + tab_count_width;
}

pub fn tabs_width() u16 {
    var total: u16 = 0;
    for (Mailbox.all) |mailbox| total += tab_span(mailbox);
    return total;
}

const testing = std.testing;

test "compute marks tiny terminals as too small" {
    try testing.expect(Layout.compute(39, 40, 0).too_small);
    try testing.expect(Layout.compute(80, 9, 0).too_small);
    try testing.expect(!Layout.compute(40, 10, 0).too_small);
}

test "compute divides the screen into header, body, and footer" {
    const layout = Layout.compute(100, 30, 0);
    try testing.expectEqual(@as(u16, 0), layout.header_y);
    try testing.expectEqual(@as(u16, 1), layout.top_rule_y);
    try testing.expectEqual(@as(u16, 2), layout.body_y);
    try testing.expectEqual(@as(u16, 27), layout.bottom_rule_y);
    try testing.expectEqual(@as(u16, 25), layout.body_height);
    try testing.expectEqual(@as(u16, 29), layout.footer_y);
    try testing.expectEqual(@as(u16, 25), layout.list_rows);
}

test "compute keeps the list columns inside the screen" {
    const layout = Layout.compute(80, 24, 0);
    try testing.expectEqual(@as(u16, 3), layout.sender_x);
    try testing.expectEqual(@as(u16, 20), layout.sender_width);
    try testing.expectEqual(@as(u16, 24), layout.subject_x);
    try testing.expectEqual(@as(u16, 79), layout.flag_x);
    try testing.expectEqual(@as(u16, 73), layout.date_x);
    try testing.expectEqual(@as(u16, 48), layout.subject_width);
    try testing.expect(layout.subject_x + layout.subject_width <= layout.date_x);
}

test "compute hides tabs on narrow terminals and shows them when they fit" {
    const narrow = Layout.compute(74, 24, 0);
    try testing.expect(!narrow.show_tabs);
    try testing.expect(narrow.mailbox_at(10) == null);

    const wide = Layout.compute(76, 24, 0);
    try testing.expect(wide.show_tabs);
}

test "tab geometry puts each count right after its own title" {
    const layout = Layout.compute(120, 30, 0);

    try testing.expectEqual(@as(u16, 8), layout.tab_x(.inbox));
    try testing.expectEqual(@as(u16, 14), layout.tab_count_x(.inbox));
    try testing.expectEqual(@as(u16, 19), layout.tab_x(.sent));
    try testing.expectEqual(@as(u16, 29), layout.tab_x(.drafts));
    try testing.expectEqual(@as(u16, 41), layout.tab_x(.archive));
    try testing.expectEqual(@as(u16, 54), layout.tab_x(.trash));
    try testing.expectEqual(@as(u16, 65), layout.tab_x(.junk));

    for (Mailbox.all) |mailbox| {
        const start = layout.tab_x(mailbox);
        try testing.expectEqual(mailbox, layout.mailbox_at(start).?);
        try testing.expectEqual(mailbox, layout.mailbox_at(start + tab_hit_width(mailbox) - 1).?);
        try testing.expect(layout.mailbox_at(start + tab_hit_width(mailbox)) == null);
    }
    try testing.expect(layout.mailbox_at(tab_start - 1) == null);
    try testing.expect(layout.mailbox_at(tab_start + tabs_width()) == null);
}

test "account tags shift the sender column right" {
    const plain = Layout.compute(100, 30, 0);
    try testing.expectEqual(@as(u16, 3), plain.sender_x);
    try testing.expectEqual(@as(u16, 24), plain.sender_width);

    const tagged = Layout.compute(100, 30, 8);
    try testing.expect(tagged.account_tags);
    try testing.expectEqual(@as(u16, 8), tagged.account_width);
    try testing.expectEqual(@as(u16, 3), tagged.account_x);
    try testing.expectEqual(@as(u16, 12), tagged.sender_x);
    try testing.expectEqual(@as(u16, 22), tagged.sender_width);

    const narrow = Layout.compute(60, 30, 8);
    try testing.expectEqual(@as(u16, 8), narrow.account_width);
    try testing.expectEqual(@as(u16, 12), narrow.sender_x);
}

test "reader geometry uses the full screen and leaves room for the body" {
    const layout = Layout.compute(60, 12, 0);
    try testing.expectEqual(@as(u16, 0), layout.reader_subject_y);
    try testing.expectEqual(@as(u16, 1), layout.reader_meta_y);
    try testing.expectEqual(@as(u16, 2), layout.reader_rule_y);
    try testing.expectEqual(@as(u16, 3), layout.reader_body_y);
    try testing.expectEqual(@as(u16, 6), layout.reader_rows);
    try testing.expectEqual(@as(u16, 1), layout.reader_text_x);
    try testing.expectEqual(@as(u16, 58), layout.reader_text_width);
}
