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
const Address = @import("../domain/address.zig").Address;
const AccountId = @import("../domain/id.zig").AccountId;
const Compose = @import("compose.zig").Compose;

pub const View = enum { list, reader, help, compose };

pub const accounts_max: u8 = 4;

pub const AccountInfo = struct {
    id: AccountId = .unknown,
    label: Text(limits.label_max) = .{},
    address: Address = .{},
};

/// The accounts the application knows about, in configuration order.
pub const Accounts = struct {
    items: [accounts_max]AccountInfo = undefined,
    len: u8 = 0,

    pub fn add(self: *Accounts, id: AccountId, label: []const u8, address: Address) void {
        assert(id.is_known());
        assert(self.len < accounts_max);
        self.items[self.len] = .{ .id = id, .address = address };
        self.items[self.len].label.set(label);
        self.len += 1;
    }

    pub fn address_for(self: *const Accounts, id: AccountId) ?Address {
        for (self.items[0..self.len]) |*entry| {
            if (entry.id == id) return entry.address;
        }
        return null;
    }

    /// The label lives in the array; iterate by reference so the returned slice
    /// points at it, not at a loop copy.
    pub fn label_for(self: *const Accounts, id: AccountId) []const u8 {
        for (self.items[0..self.len]) |*entry| {
            if (entry.id == id) return entry.label.slice();
        }
        return "";
    }

    /// Longest label, or zero when there is nothing to tell apart. The list
    /// uses it to size the account column so "personal" is not "perso…".
    pub fn max_label(self: *const Accounts) u8 {
        if (self.len < 2) return 0;
        var longest: u8 = 0;
        for (self.items[0..self.len]) |*entry| {
            longest = @max(longest, @as(u8, @intCast(@min(entry.label.len, 255))));
        }
        return longest;
    }

    pub fn index_of(self: *const Accounts, id: AccountId) ?u8 {
        for (self.items[0..self.len], 0..) |entry, index| {
            if (entry.id == id) return @intCast(index);
        }
        return null;
    }
};
pub const Mode = enum { normal, search, help_search };

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
    opened_account: AccountId = .unknown,
    reader_scroll: u32 = 0,
    reader_rows: u16 = 1,
    body_rows: u32 = 0,

    /// Where to return when the help overlay closes.
    help_return: View = .list,
    /// Filter typed inside the help overlay.
    help_filter: Text(limits.help_query_max) = .{},

    /// The account's own address, used as the sender of composed mail.
    from_address: Address = .{},
    /// Configured accounts, and the current scope (null = all of them).
    accounts: Accounts = .{},
    account_filter: ?AccountId = null,
    compose: Compose = .{},

    /// True while the first network load runs: the frame becomes a splash.
    booting: bool = false,
    /// True while a background refresh runs: the footer shows a spinner.
    refreshing: bool = false,
    /// Free-running tick for the splash spinner.
    spinner: u8 = 0,
    status: Text(limits.status_max) = .{},
    /// Errors are shown with the alert style; plain confirmations are not.
    status_alert: bool = false,
    quit: bool = false,

    /// Recomputes the visible rows from the store. Called after any mutation
    /// that can change the list: mailbox switch, filter, archive, refresh.
    pub fn rebuild(self: *State, store: *const Store) void {
        self.visible_len = 0;
        var index: u32 = 0;
        while (index < store.len) : (index += 1) {
            const message = store.at_const(index);
            if (message.mailbox != self.mailbox) continue;
            if (self.account_filter) |filter| {
                if (message.account != filter) continue;
            }
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
        self.status_alert = false;
    }

    pub fn set_alert(self: *State, comptime fmt: []const u8, args: anytype) void {
        self.status.set_fmt(fmt, args);
        self.status_alert = true;
    }

    pub fn clear_status(self: *State) void {
        self.status.clear();
        self.status_alert = false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fill(store: *Store) !void {
    const messages = [_]Message{
        .{ .id = MessageId.from_int(1), .account = AccountId.from_int(1), .mailbox = .inbox, .timestamp_unix = 500, .subject = Text(limits.subject_max).init("Design tokens") },
        .{ .id = MessageId.from_int(2), .account = AccountId.from_int(1), .mailbox = .sent, .timestamp_unix = 400, .subject = Text(limits.subject_max).init("Re: Design tokens") },
        .{ .id = MessageId.from_int(3), .account = AccountId.from_int(1), .mailbox = .inbox, .timestamp_unix = 300, .subject = Text(limits.subject_max).init("Invoice") },
        .{ .id = MessageId.from_int(4), .account = AccountId.from_int(1), .mailbox = .inbox, .timestamp_unix = 200, .subject = Text(limits.subject_max).init("Invoice reminder") },
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
        const message = Message{ .id = MessageId.from_int(index), .account = AccountId.from_int(1), .timestamp_unix = @intCast(100 + index) };
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

test "accounts keep labels and addresses, and filter by id" {
    var accounts: Accounts = .{};
    try testing.expectEqual(@as(?u8, null), accounts.index_of(AccountId.from_int(1)));
    try testing.expectEqualStrings("", accounts.label_for(AccountId.from_int(1)));
    try testing.expect(accounts.address_for(AccountId.from_int(1)) == null);

    const address = Address.from_parts("Me", "me", "example.com");
    accounts.add(AccountId.from_int(1), "personal", address);
    accounts.add(AccountId.from_int(2), "work", .{});

    try testing.expectEqual(@as(u8, 2), accounts.len);
    try testing.expectEqual(@as(?u8, 1), accounts.index_of(AccountId.from_int(2)));
    try testing.expectEqualStrings("work", accounts.label_for(AccountId.from_int(2)));
    try testing.expectEqualStrings("", accounts.label_for(AccountId.from_int(9)));
    try testing.expectEqualStrings("me", accounts.address_for(AccountId.from_int(1)).?.local.slice());
    try testing.expect(accounts.address_for(AccountId.from_int(9)) == null);
}

test "rebuild honours the account filter" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);

    const mine = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1), .timestamp_unix = 300 };
    const theirs = Message{ .id = MessageId.from_int(2), .account = AccountId.from_int(2), .timestamp_unix = 200 };
    try store.insert(&mine);
    try store.insert(&theirs);

    var state: State = .{};
    state.rebuild(&store);
    try testing.expectEqual(@as(u32, 2), state.visible_len);

    state.account_filter = AccountId.from_int(2);
    state.rebuild(&store);
    try testing.expectEqual(@as(u32, 1), state.visible_len);
    try testing.expectEqual(MessageId.from_int(2), state.selected_const(&store).?.id);
}

test "set_status formats and truncates like every other text" {
    var state: State = .{};
    state.set_status("Filter: {s}", .{"invoice"});
    try testing.expectEqualStrings("Filter: invoice", state.status.slice());
    try testing.expect(!state.status_alert);

    state.set_alert("Could not reach the server", .{});
    try testing.expect(state.status_alert);

    state.set_status("Archived", .{});
    try testing.expect(!state.status_alert);

    state.set_alert("again", .{});
    state.clear_status();
    try testing.expect(state.status.is_empty());
    try testing.expect(!state.status_alert);

    const long: [200]u8 = @splat('x');
    state.set_status("{s}", .{long});
    try testing.expectEqual(limits.status_max, state.status.len);
}
