//! Geometry. No text, no colors: just where things go, for one terminal size.
//!
//! The layout also owns hit boxes (which tab is at column X), so mouse handling
//! and rendering cannot disagree about where a tab is.

const std = @import("std");
const assert = std.debug.assert;
const Mailbox = @import("core").mailbox.Mailbox;

pub const min_columns: u16 = 40;
pub const min_rows: u16 = 10;

/// The folder sidebar: its width, and the terminal width below which it would
/// take more than it gives.
pub const sidebar_width: u16 = 22;
pub const sidebar_min_columns: u16 = 84;

pub const tab_start: u16 = 8;
/// The count is drawn right after the title, left-aligned in this many cells,
/// so it always reads as part of its own mailbox ("Inbox 3", never "3  Sent").
pub const tab_count_width: u16 = 3;
pub const tab_gap: u16 = 2;

pub const Layout = struct {
    columns: u16 = 0,
    rows: u16 = 0,
    too_small: bool = true,

    /// Columns of the full terminal, and how far the content is pushed right by
    /// the sidebar. Every coordinate in this struct is content-relative: the
    /// screen adds `shift` when it paints, so no renderer has to know.
    shift: u16 = 0,
    sidebar: bool = false,
    /// Cells the sidebar itself occupies, rule excluded.
    sidebar_width: u16 = 0,
    /// The bar above the list: the tabs, or the one-line header on a narrow
    /// terminal. With folders on the left it says what the sidebar already
    /// says, so it is not drawn at all.
    show_header: bool = true,

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
        return compute_with(columns, rows, label_width, false);
    }

    /// `sidebar` asks for the folder column on the left. It is granted only when
    /// the terminal can afford it: a sidebar that leaves no list is a decoration.
    pub fn compute_with(columns: u16, rows: u16, label_width: u8, sidebar: bool) Layout {
        const wanted: u16 = if (sidebar and columns >= sidebar_min_columns) sidebar_width else 0;
        // The rule belongs to the sidebar, the space to the content.
        const shift: u16 = if (wanted > 0) wanted + 2 else 0;
        const content_columns = columns -| shift;
        const account_tags = label_width > 0;
        var layout: Layout = .{
            .columns = content_columns,
            .rows = rows,
            .shift = shift,
            .sidebar = wanted > 0,
            .sidebar_width = wanted,
        };
        layout.too_small = content_columns < min_columns or rows < min_rows;
        if (layout.too_small) return layout;

        // Without a header the list owns the top of the screen, the way the
        // reader already does.
        layout.show_header = shift == 0;
        layout.top_rule_y = 1;
        layout.body_y = if (layout.show_header) 2 else 0;
        layout.bottom_rule_y = rows - 3;
        layout.footer_y = rows - 1;
        layout.body_height = layout.bottom_rule_y - layout.body_y;
        layout.list_rows = layout.body_height;
        layout.reader_rows = layout.bottom_rule_y -| layout.reader_body_y;
        layout.reader_text_width = content_columns - 2;
        // With folders on the left, tabs would be the same list twice.
        layout.show_tabs = layout.shift == 0 and layout.columns >= tab_start + tabs_width() + 1;

        layout.account_tags = account_tags;
        // The full account label ("work", "personal") when it fits, at least
        // two characters so accounts stay distinguishable.
        layout.account_width = if (account_tags)
            @min(@max(@as(u16, label_width), 2), @min(10, layout.columns / 6))
        else
            0;
        // A space after the unread dot and another after the label.
        layout.account_x = layout.dot_x + 2;
        layout.sender_x = if (account_tags) layout.account_x + layout.account_width + 1 else 3;
        layout.sender_width = @max(8, @min(24, layout.columns / 4) - @as(u16, if (account_tags) 2 else 0));
        layout.subject_x = layout.sender_x + layout.sender_width + 1;
        layout.flag_x = layout.columns - 1;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

    // Narrow: the label column shrinks but never disappears.
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

test "a sidebar takes its columns from the content, and only when there is room" {
    const wide = Layout.compute_with(120, 30, 4, true);
    try testing.expect(wide.sidebar);
    try testing.expectEqual(sidebar_width, wide.sidebar_width);
    // The rule and one space belong to the sidebar, not to the list.
    try testing.expectEqual(sidebar_width + 2, wide.shift);
    try testing.expectEqual(120 - (sidebar_width + 2), wide.columns);
    try testing.expect(wide.subject_width > 20);
    // Folders on the left, so the tab row would be the same list twice.
    try testing.expect(!wide.show_tabs);

    // A terminal with no columns to spare keeps its tabs and its list.
    const narrow = Layout.compute_with(80, 24, 4, true);
    try testing.expect(!narrow.sidebar);
    try testing.expectEqual(@as(u16, 0), narrow.shift);
    try testing.expectEqual(Layout.compute(80, 24, 4), narrow);
}
