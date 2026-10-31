//! Application state: what the user is looking at, and where.
//!
//! One aggregate, mutated only by `update`. Views are a small closed set, and
//! `visible` is a list of store indexes rebuilt after any change, so rendering
//! never has to filter or sort.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../limits.zig");
const Text = @import("../domain/text.zig").Text;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const MessageId = @import("../domain/id.zig").MessageId;
const Store = @import("../domain/store.zig").Store;

pub const View = enum { list, reader, help };
pub const Mode = enum { normal, search };

pub const State = struct {
    view: View = .list,
    mode: Mode = .normal,
    mailbox: Mailbox = .inbox,

    /// Applied filter. Empty means "everything in this mailbox".
    query: Text(limits.filter_max) = .{},
    /// Filter being typed while `mode == .search`.
    draft: Text(limits.filter_max) = .{},

    /// Store indexes of the rows currently visible, in store order.
    visible: [limits.messages_max]u32 = undefined,
    visible_len: u32 = 0,

    /// Index into `visible`, and the first visible row.
    cursor: u32 = 0,
    offset: u32 = 0,
    list_rows: u16 = 1,

    opened: MessageId = .unknown,
    reader_scroll: u32 = 0,
    reader_rows: u16 = 1,
    body_rows: u32 = 0,

    /// Where to return when the help overlay closes.
    help_return: View = .list,

    status: Text(limits.status_max) = .{},
    quit: bool = false,

    /// Recomputes the visible rows from the store. Called after any mutation
    /// that can change the list: mailbox switch, filter, archive, refresh.
    pub fn rebuild(self: *State, store: *const Store) void {
        self.visible_len = 0;
        var index: u32 = 0;
        while (index < store.len) : (index += 1) {
            const message = store.at_const(index);
            if (message.mailbox != self.mailbox) continue;
            if (!message.matches(self.query.slice())) continue;
            assert(self.visible_len < limits.messages_max);
            self.visible[self.visible_len] = index;
            self.visible_len += 1;
        }
        self.clamp_cursor();
        self.scroll_into_view();
    }

    pub fn clamp_cursor(self: *State) void {
        if (self.visible_len == 0) {
            self.cursor = 0;
            self.offset = 0;
            return;
        }
        if (self.cursor >= self.visible_len) self.cursor = self.visible_len - 1;
    }

    /// Keeps the cursor in the window: scroll by the minimum needed, and never
    /// leave blank rows at the bottom of the list.
    pub fn scroll_into_view(self: *State) void {
        if (self.visible_len == 0) {
            self.offset = 0;
            return;
        }

        const rows: u32 = @max(1, self.list_rows);
        if (self.cursor < self.offset) self.offset = self.cursor;
        if (self.cursor >= self.offset + rows) self.offset = self.cursor + 1 - rows;

        const max_offset = self.visible_len -| rows;
        if (self.offset > max_offset) self.offset = max_offset;
        assert(self.offset <= self.cursor);
    }

    pub fn row_count(self: *const State) u16 {
        if (self.offset >= self.visible_len) return 0;
        const remaining = self.visible_len - self.offset;
        return @intCast(@min(@as(u32, self.list_rows), remaining));
    }

    pub fn selected_index(self: *const State, store: *const Store) ?u32 {
        if (self.visible_len == 0) return null;
        assert(self.cursor < self.visible_len);
        const store_index = self.visible[self.cursor];
        assert(store_index < store.len);
        return store_index;
    }

    pub fn selected(self: *State, store: *Store) ?*Message {
        const index = self.selected_index(store) orelse return null;
        return store.at(index);
    }

    pub fn selected_const(self: *const State, store: *const Store) ?*const Message {
        const index = self.selected_index(store) orelse return null;
        return store.at_const(index);
    }

    pub fn max_reader_scroll(self: *const State) u32 {
        return self.body_rows -| self.reader_rows;
    }

    pub fn set_status(self: *State, comptime fmt: []const u8, args: anytype) void {
        self.status.set_fmt(fmt, args);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fill(store: *Store) !void {
    const messages = [_]Message{
        .{ .id = MessageId.from_int(1), .mailbox = .inbox, .timestamp_unix = 500, .subject = Text(limits.subject_max).init("Design tokens") },
        .{ .id = MessageId.from_int(2), .mailbox = .sent, .timestamp_unix = 400, .subject = Text(limits.subject_max).init("Re: Design tokens") },
        .{ .id = MessageId.from_int(3), .mailbox = .inbox, .timestamp_unix = 300, .subject = Text(limits.subject_max).init("Invoice") },
        .{ .id = MessageId.from_int(4), .mailbox = .inbox, .timestamp_unix = 200, .subject = Text(limits.subject_max).init("Invoice reminder") },
    };
    for (messages) |message| try store.insert(&message);
}

test "rebuild shows only the selected mailbox, in store order" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{};
    state.rebuild(&store);

    try testing.expectEqual(@as(u32, 3), state.visible_len);
    try testing.expectEqual(@as(u32, 0), state.visible[0]);
    try testing.expectEqual(@as(u32, 2), state.visible[1]);
    try testing.expectEqual(@as(u32, 3), state.visible[2]);
}

test "rebuild applies the query to sender and subject" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{};
    state.query.set("invoice");
    state.rebuild(&store);

    try testing.expectEqual(@as(u32, 2), state.visible_len);
}

test "rebuild of an empty mailbox resets cursor and offset" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{ .mailbox = .trash, .cursor = 3, .offset = 2 };
    state.rebuild(&store);

    try testing.expectEqual(@as(u32, 0), state.visible_len);
    try testing.expectEqual(@as(u32, 0), state.cursor);
    try testing.expectEqual(@as(u32, 0), state.offset);
    try testing.expectEqual(@as(u16, 0), state.row_count());
    try testing.expect(state.selected_index(&store) == null);
}

test "rebuild clamps a cursor beyond the new list" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{ .cursor = 99 };
    state.rebuild(&store);
    try testing.expectEqual(@as(u32, 2), state.cursor);
}

test "scroll_into_view keeps the cursor on screen" {
    var store = try Store.init(testing.allocator, 16);
    defer store.deinit(testing.allocator);

    var index: u32 = 1;
    while (index <= 10) : (index += 1) {
        const message = Message{ .id = MessageId.from_int(index), .timestamp_unix = @intCast(100 + index) };
        try store.insert(&message);
    }

    var state: State = .{ .list_rows = 3 };
    state.rebuild(&store);
    try testing.expectEqual(@as(u32, 0), state.offset);

    state.cursor = 2;
    state.scroll_into_view();
    try testing.expectEqual(@as(u32, 0), state.offset);

    state.cursor = 3;
    state.scroll_into_view();
    try testing.expectEqual(@as(u32, 1), state.offset);

    state.cursor = 9;
    state.scroll_into_view();
    try testing.expectEqual(@as(u32, 7), state.offset);

    state.cursor = 0;
    state.scroll_into_view();
    try testing.expectEqual(@as(u32, 0), state.offset);
}

test "scroll_into_view never leaves blank rows at the bottom" {
    var store = try Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{ .list_rows = 10 };
    state.rebuild(&store);
    try testing.expectEqual(@as(u32, 0), state.offset);

    state.cursor = 2;
    state.scroll_into_view();
    try testing.expectEqual(@as(u32, 0), state.offset);
}

test "row_count counts the rows between offset and the end" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{ .list_rows = 2 };
    state.rebuild(&store);
    try testing.expectEqual(@as(u16, 2), state.row_count());

    state.offset = 2;
    try testing.expectEqual(@as(u16, 1), state.row_count());

    state.offset = 3;
    try testing.expectEqual(@as(u16, 0), state.row_count());
}

test "selected_index and selected point at the same message" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    try fill(&store);

    var state: State = .{};
    state.rebuild(&store);
    state.cursor = 1;

    const index = state.selected_index(&store).?;
    try testing.expectEqual(@as(u32, 2), index);
    try testing.expectEqual(MessageId.from_int(3), state.selected(&store).?.id);
    try testing.expectEqual(MessageId.from_int(3), state.selected_const(&store).?.id);
}

test "max_reader_scroll never goes negative" {
    var state: State = .{ .body_rows = 100, .reader_rows = 10 };
    try testing.expectEqual(@as(u32, 90), state.max_reader_scroll());

    state.body_rows = 3;
    try testing.expectEqual(@as(u32, 0), state.max_reader_scroll());
}

test "set_status formats and truncates like every other text" {
    var state: State = .{};
    state.set_status("Filter: {s}", .{"invoice"});
    try testing.expectEqualStrings("Filter: invoice", state.status.slice());

    const long: [200]u8 = @splat('x');
    state.set_status("{s}", .{long});
    try testing.expectEqual(limits.status_max, state.status.len);
}
