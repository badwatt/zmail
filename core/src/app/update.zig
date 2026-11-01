//! The state machine: `(state, store, command) -> effects`.
//!
//! This function is the whole behaviour of the client. It performs no I/O, so
//! every rule below is a unit test. Front ends only translate input into
//! commands and execute the returned effects.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../limits.zig");
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const Store = @import("../domain/store.zig").Store;

const Command = @import("command.zig").Command;
const Move = @import("command.zig").Move;
const Viewport = @import("command.zig").Viewport;
const Effect = @import("effect.zig").Effect;
const Effects = @import("effect.zig").Effects;
const State = @import("state.zig").State;
const View = @import("state.zig").View;

pub fn apply(state: *State, store: *Store, command: Command) Effects {
    var effects: Effects = .{};
    if (command.clears_status()) state.clear_status();
    // A confirmation only survives the command that asked for it.
    if (command != .empty_trash) state.pending_empty = false;

    switch (command) {
        .noop => {},
        .quit => state.quit = true,
        .move => |move| apply_move(state, move),
        .open_selected => apply_open(state, store, &effects),
        .dismiss => apply_dismiss(state, store),
        .next_mailbox => switch_mailbox(state, store, state.mailbox.next(), &effects),
        .previous_mailbox => switch_mailbox(state, store, state.mailbox.previous(), &effects),
        .select_mailbox => |mailbox| switch_mailbox(state, store, mailbox, &effects),
        .toggle_unread => toggle_unread(state, store, &effects),
        .toggle_flag => toggle_flag(state, store, &effects),
        .archive_selected => move_selected(state, store, .archive, "Archived", &effects),
        .delete_selected => move_selected(state, store, .trash, "Moved to Trash", &effects),
        .delete_forever => delete_forever(state, store, &effects),
        .empty_trash => empty_trash(state, store, &effects),
        .open_accounts => open_accounts(state),
        .accounts_move => |move| accounts_move(state, move),
        .accounts_select => accounts_select(state, store),
        .accounts_remove => accounts_remove(state, &effects),
        .accounts_add => effects.add(.{ .edit_account = .{ .account = null } }),
        .accounts_edit => accounts_edit(state, &effects),
        .accounts_rename => accounts_rename(state, &effects),
        .accounts_close => state.view = .list,
        .begin_search => begin_search(state),
        .search_char => |byte| search_char(state, store, byte),
        .search_backspace => search_backspace(state, store),
        .search_commit => search_commit(state, store),
        .search_cancel => search_cancel(state, store),
        .begin_help_search => begin_help_search(state),
        .help_search_char => |byte| help_search_char(state, byte),
        .help_search_backspace => help_search_backspace(state),
        .help_search_commit => help_search_commit(state),
        .help_search_cancel => help_search_cancel(state),
        .toggle_help => toggle_help(state),
        .refresh => apply_refresh(state, &effects),
        .set_viewport => |viewport| apply_viewport(state, viewport),
        .cycle_account => cycle_account(state, store),
        .compose_new => start_compose(state, store),
        .compose_reply => start_reply(state, store),
        .compose_send => send_compose(state, &effects),
        .compose_cancel => cancel_compose(state),
        .compose_char => |codepoint| {
            if (state.view == .compose) state.compose.append(codepoint);
        },
        .compose_newline => {
            if (state.view == .compose) state.compose.append_newline();
        },
        .compose_backspace => {
            if (state.view == .compose) state.compose.backspace();
        },
        .compose_next_field => {
            if (state.view == .compose) state.compose.next_field();
        },
        .compose_previous_field => {
            if (state.view == .compose) state.compose.previous_field();
        },
        .compose_clear_field => {
            if (state.view == .compose) state.compose.clear_field();
        },
        .send_succeeded => compose_sent(state),
        .send_failed => compose_failed(state),
    }
    return effects;
}

fn cycle_account(state: *State, store: *Store) void {
    if (state.accounts.len == 0) return;
    const current = state.account_filter;
    var next_index: u8 = 0;
    if (current) |filter| {
        const position = state.accounts.index_of(filter) orelse {
            // The filter points at an account that is gone: back to unified.
            state.account_filter = null;
            state.cursor = 0;
            state.offset = 0;
            state.rebuild(store);
            return;
        };
        next_index = position + 1;
    }
    if (next_index >= state.accounts.len) {
        state.account_filter = null;
    } else {
        state.account_filter = state.accounts.items[next_index].id;
    }
    state.cursor = 0;
    state.offset = 0;
    state.rebuild(store);
}

fn apply_move(state: *State, move: Move) void {
    switch (state.view) {
        .list => move_cursor(state, move),
        .reader => scroll_reader(state, move),
        .accounts => accounts_move(state, move),
        .help, .compose => {},
    }
}

fn move_cursor(state: *State, move: Move) void {
    if (state.visible_len == 0) {
        state.cursor = 0;
        state.offset = 0;
        return;
    }

    const last = state.visible_len - 1;
    const page: u32 = @max(1, state.list_rows);
    const half_page: u32 = @max(1, page / 2);

    state.cursor = switch (move) {
        .up => state.cursor -| 1,
        .down => @min(last, state.cursor + 1),
        .top => 0,
        .bottom => last,
        .page_up => state.cursor -| page,
        .page_down => @min(last, state.cursor + page),
        .half_page_up => state.cursor -| half_page,
        .half_page_down => @min(last, state.cursor + half_page),
    };
    state.scroll_into_view();
}

fn scroll_reader(state: *State, move: Move) void {
    const page: u32 = @max(1, state.reader_rows);
    const half_page: u32 = @max(1, page / 2);
    const max_scroll = state.max_reader_scroll();

    state.reader_scroll = switch (move) {
        .up => state.reader_scroll -| 1,
        .down => @min(max_scroll, state.reader_scroll + 1),
        .top => 0,
        .bottom => max_scroll,
        .page_up => state.reader_scroll -| page,
        .page_down => @min(max_scroll, state.reader_scroll + page),
        .half_page_up => state.reader_scroll -| half_page,
        .half_page_down => @min(max_scroll, state.reader_scroll + half_page),
    };
}

fn apply_open(state: *State, store: *Store, effects: *Effects) void {
    if (state.view != .list) return;

    const message = state.selected(store) orelse {
        state.set_status("No message selected", .{});
        return;
    };

    state.opened = message.id;
    state.opened_account = message.account;
    state.view = .reader;
    state.reader_scroll = 0;

    if (message.is_unread()) {
        message.flags = message.flags.mark_read();
        effects.add(.{ .sync_flags = .{ .account = message.account, .id = message.id, .flags = message.flags } });
    }
    effects.add(.{ .fetch_body = .{ .account = message.account, .mailbox = message.mailbox, .id = message.id } });
}

fn apply_dismiss(state: *State, store: *Store) void {
    switch (state.mode) {
        .search => search_cancel(state, store),
        .help_search => help_search_cancel(state),
        .normal => switch (state.view) {
            .help => {
                state.view = state.help_return;
                state.mode = .normal;
            },
            .reader => {
                state.view = .list;
                state.reader_scroll = 0;
            },
            .compose => cancel_compose(state),
            .accounts => state.view = .list,
            // `q` at the top level quits. Esc never reaches this branch: the
            // key map does not translate it to `dismiss` in the list.
            .list => state.quit = true,
        },
    }
}

fn switch_mailbox(state: *State, store: *Store, mailbox: Mailbox, effects: *Effects) void {
    if (state.mailbox == mailbox) return;

    state.mailbox = mailbox;
    effects.add(.{ .refresh = .{ .account = state.account_filter, .mailbox = mailbox, .force = false } });
    state.query.clear();
    state.draft.clear();
    state.mode = .normal;
    state.view = .list;
    state.cursor = 0;
    state.offset = 0;
    state.reader_scroll = 0;
    state.opened = .unknown;
    state.rebuild(store);
}

fn toggle_unread(state: *State, store: *Store, effects: *Effects) void {
    const message = state.selected(store) orelse {
        state.set_status("No message selected", .{});
        return;
    };

    message.flags = message.flags.toggle_unread();
    effects.add(.{ .sync_flags = .{ .account = message.account, .id = message.id, .flags = message.flags } });
    if (message.is_unread()) {
        state.set_status("Marked unread", .{});
    } else {
        state.set_status("Marked read", .{});
    }
}

fn toggle_flag(state: *State, store: *Store, effects: *Effects) void {
    const message = state.selected(store) orelse {
        state.set_status("No message selected", .{});
        return;
    };

    message.flags = message.flags.toggle_flagged();
    effects.add(.{ .sync_flags = .{ .account = message.account, .id = message.id, .flags = message.flags } });
    if (message.is_flagged()) {
        state.set_status("Starred", .{});
    } else {
        state.set_status("Unstarred", .{});
    }
}

fn open_accounts(state: *State) void {
    state.view = .accounts;
    state.mode = .normal;
    state.accounts_cursor = 0;
}

fn accounts_move(state: *State, move: Move) void {
    const last: u8 = state.accounts.len;
    state.accounts_cursor = switch (move) {
        .up => state.accounts_cursor -| 1,
        .down => @min(last, state.accounts_cursor + 1),
        .top => 0,
        .bottom => last,
        else => state.accounts_cursor,
    };
}

fn accounts_select(state: *State, store: *const Store) void {
    const cursor = state.accounts_cursor;
    state.view = .list;
    if (cursor == 0) {
        state.account_filter = null;
        state.cursor = 0;
        state.offset = 0;
        // Rebuild: the filter is applied here, so the list changes immediately.
        state.rebuild(store);
        state.set_status("All accounts", .{});
        return;
    }
    const account = state.accounts.at(cursor - 1) orelse {
        state.set_status("No account there", .{});
        return;
    };
    state.account_filter = account.id;
    state.cursor = 0;
    state.offset = 0;
    state.rebuild(store);
    state.set_status("{s}", .{account.label.slice()});
}

fn accounts_edit(state: *State, effects: *Effects) void {
    if (state.accounts_cursor == 0) {
        state.set_status("Pick an account to edit", .{});
        return;
    }
    const account = state.accounts.at(state.accounts_cursor - 1) orelse {
        state.set_status("No account there", .{});
        return;
    };
    effects.add(.{ .edit_account = .{ .account = account.id } });
}

fn accounts_rename(state: *State, effects: *Effects) void {
    if (state.accounts_cursor == 0) {
        state.set_status("Pick an account to rename", .{});
        return;
    }
    const account = state.accounts.at(state.accounts_cursor - 1) orelse {
        state.set_status("No account there", .{});
        return;
    };
    effects.add(.{ .rename_account = .{ .account = account.id } });
}

fn accounts_remove(state: *State, effects: *Effects) void {
    if (state.accounts_cursor == 0) {
        state.set_status("All accounts cannot be removed", .{});
        return;
    }
    const account = state.accounts.at(state.accounts_cursor - 1) orelse {
        state.set_status("No account there", .{});
        return;
    };
    effects.add(.{ .remove_account = .{ .account = account.id } });
    state.set_status("Removing {s}…", .{account.label.slice()});
}

/// Only in Trash: there is no "undo" here, so it is a separate command.
fn delete_forever(state: *State, store: *Store, effects: *Effects) void {
    if (state.mailbox != .trash) {
        state.set_status("Only in Trash: d moves a message here first", .{});
        return;
    }
    const message = state.selected(store) orelse {
        state.set_status("No message selected", .{});
        return;
    };

    const account = message.account;
    const id = message.id;
    _ = store.remove_by_id(account, id);
    state.rebuild(store);
    if (state.view == .reader) {
        state.view = .list;
        state.reader_scroll = 0;
    }
    effects.add(.{ .delete_message = .{ .account = account, .mailbox = .trash, .id = id } });
    state.set_status("Deleted for good", .{});
}

/// Only in Trash: empties it for every account in scope.
fn empty_trash(state: *State, store: *Store, effects: *Effects) void {
    if (state.mailbox != .trash) {
        state.set_status("Emptying is only offered in Trash", .{});
        return;
    }

    var empty: bool = true;
    for (store.messages[0..store.len]) |*message| {
        if (message.mailbox != .trash) continue;
        if (state.account_filter) |filter| {
            if (message.account != filter) continue;
        }
        empty = false;
    }
    if (empty) {
        state.set_status("Trash is already empty", .{});
        return;
    }
    if (!state.pending_empty) {
        state.pending_empty = true;
        state.set_status("Press E again to empty Trash", .{});
        return;
    }
    state.pending_empty = false;

    effects.add(.{ .empty_mailbox = .{ .account = state.account_filter, .mailbox = .trash } });
    if (state.account_filter) |filter| {
        _ = store.remove_in(filter, .trash);
    } else {
        // Whatever account a trashed message belongs to, it goes.
        var index: u32 = 0;
        while (index < store.len) {
            const message = store.at(index);
            if (message.mailbox == .trash) {
                _ = store.remove_by_id(message.account, message.id);
                continue;
            }
            index += 1;
        }
    }
    state.rebuild(store);
    if (state.view == .reader) state.view = .list;
    state.set_status("Trash emptied", .{});
}

fn move_selected(state: *State, store: *Store, target: Mailbox, status_text: []const u8, effects: *Effects) void {
    const message = state.selected(store) orelse {
        state.set_status("No message selected", .{});
        return;
    };

    if (message.mailbox == target) {
        state.set_status("Already in {s}", .{target.title()});
        return;
    }

    message.mailbox = target;
    effects.add(.{ .move_message = .{ .account = message.account, .id = message.id, .to = target } });
    if (state.view == .reader) {
        state.view = .list;
        state.reader_scroll = 0;
    }
    state.rebuild(store);
    state.set_status("{s}", .{status_text});
}

fn begin_search(state: *State) void {
    if (state.view != .list) return;
    state.mode = .search;
    state.draft.set(state.query.slice());
}

fn search_char(state: *State, store: *Store, byte: u8) void {
    if (state.mode != .search) return;
    if (byte < 0x20 or byte > 0x7e) return;
    state.draft.append_ascii(byte);
    apply_filter(state, store);
}

fn search_backspace(state: *State, store: *Store) void {
    if (state.mode != .search) return;
    state.draft.pop_codepoint();
    apply_filter(state, store);
}

fn apply_filter(state: *State, store: *Store) void {
    state.query.set(state.draft.slice());
    state.cursor = 0;
    state.offset = 0;
    state.rebuild(store);
}

fn search_commit(state: *State, store: *Store) void {
    if (state.mode != .search) return;
    state.mode = .normal;
    apply_filter(state, store);
    if (state.query.is_empty()) {
        state.set_status("Filter cleared", .{});
    } else {
        state.set_status("Filter: {s}", .{state.query.slice()});
    }
}

fn search_cancel(state: *State, store: *Store) void {
    if (state.mode != .search) return;
    state.mode = .normal;
    state.draft.clear();
    state.query.clear();
    state.cursor = 0;
    state.offset = 0;
    state.rebuild(store);
}

fn start_compose(state: *State, store: *Store) void {
    _ = store;
    state.compose.reset();
    const account = state.account_filter orelse state.accounts.items[0].id;
    state.compose.account = account;
    state.compose.from = state.accounts.address_for(account) orelse state.from_address;
    state.view = .compose;
}

fn start_reply(state: *State, store: *Store) void {
    const message = state.selected(store) orelse {
        state.set_status("No message selected", .{});
        return;
    };

    state.compose.reset();
    var address_buffer: [limits.address_max]u8 = undefined;
    state.compose.to.set(message.from.addr_spec(&address_buffer));

    const subject = message.subject.slice();
    if (startsWithIgnoreCase(subject, "re:")) {
        state.compose.subject.set(subject);
    } else {
        state.compose.subject.set_fmt("Re: {s}", .{subject});
    }

    state.compose.in_reply_to = message.id;
    state.compose.account = message.account;
    state.compose.from = state.accounts.address_for(message.account) orelse state.from_address;
    state.compose.field = .body;
    state.view = .compose;
}

fn send_compose(state: *State, effects: *Effects) void {
    if (state.view != .compose) return;

    const recipient = state.compose.recipient() orelse {
        state.set_alert("That address does not look right", .{});
        return;
    };

    effects.add(.{ .send = .{
        .account = state.compose.account,
        .from = state.compose.from,
        .to = recipient,
        .subject = state.compose.subject,
        .body = state.compose.body_slice(),
        .in_reply_to = state.compose.in_reply_to,
    } });
}

fn cancel_compose(state: *State) void {
    if (state.view != .compose) return;
    state.compose.active = false;
    state.compose.field = .to;
    state.view = .list;
}

fn compose_sent(state: *State) void {
    state.compose.active = false;
    state.compose.field = .to;
    state.view = .list;
    state.set_status("Message sent · 2 opens Sent", .{});
}

fn compose_failed(state: *State) void {
    state.set_alert("Could not send; the draft is still here", .{});
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn begin_help_search(state: *State) void {
    if (state.view != .help) return;
    state.mode = .help_search;
}

fn help_search_char(state: *State, byte: u8) void {
    if (state.mode != .help_search) return;
    if (byte < 0x20 or byte > 0x7e) return;
    state.help_filter.append_ascii(byte);
}

fn help_search_backspace(state: *State) void {
    if (state.mode != .help_search) return;
    state.help_filter.pop_codepoint();
}

fn help_search_commit(state: *State) void {
    if (state.mode != .help_search) return;
    state.mode = .normal;
}

fn help_search_cancel(state: *State) void {
    if (state.mode != .help_search) return;
    state.mode = .normal;
    state.help_filter.clear();
}

fn toggle_help(state: *State) void {
    if (state.view == .help) {
        state.view = state.help_return;
        state.mode = .normal;
        return;
    }
    state.help_return = state.view;
    state.view = .help;
    state.mode = .normal;
    state.help_filter.clear();
}

fn apply_refresh(state: *State, effects: *Effects) void {
    // No status line: the footer's spinner says it, in the same place as the
    // other hints, without stealing the row.
    effects.add(.{ .refresh = .{ .account = state.account_filter, .mailbox = state.mailbox, .force = true } });
}

fn apply_viewport(state: *State, viewport: Viewport) void {
    state.list_rows = @max(1, viewport.list_rows);
    state.reader_rows = @max(1, viewport.reader_rows);
    state.body_rows = viewport.body_rows;

    state.clamp_cursor();
    state.scroll_into_view();
    state.reader_scroll = @min(state.reader_scroll, state.max_reader_scroll());
}

comptime {
    // A command may produce at most two effects today; the bound leaves room
    // for compose/send later and keeps the list allocation-free.
    assert(limits.actions_max >= 2);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Text = @import("../domain/text.zig").Text;
const MessageId = @import("../domain/id.zig").MessageId;
const Address = @import("../domain/address.zig").Address;
const AccountId = @import("../domain/id.zig").AccountId;

fn message_with(id: u64, subject: []const u8, mailbox: Mailbox, timestamp_unix: i64) Message {
    var message = Message{
        .id = MessageId.from_int(id),
        .account = AccountId.from_int(1),
        .mailbox = mailbox,
        .timestamp_unix = timestamp_unix,
        .flags = .{ .unread = true },
    };
    message.subject.set(subject);
    message.snippet.set("snippet");
    return message;
}

fn sample_store() !Store {
    return sample_store_with(testing.allocator);
}

fn sample_store_with(gpa: std.mem.Allocator) !Store {
    // Nothing after `init` can allocate, so there is no cleanup path to guard.
    var store = try Store.init(gpa, 8);

    const messages = [_]Message{
        message_with(1, "Invoice for October", .inbox, 500),
        message_with(2, "Design tokens review", .inbox, 400),
        message_with(3, "Lunch?", .inbox, 300),
        message_with(4, "Re: Lunch?", .sent, 200),
    };
    for (messages) |message| try store.insert(&message);
    return store;
}

fn expect_effects(effects: *const Effects, expected: []const Effect) !void {
    const actual = effects.slice();
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_effect, actual_effect| {
        try testing.expect(std.meta.eql(expected_effect, actual_effect));
    }
}

fn ready() !struct { store: Store, state: State } {
    var store = try sample_store();
    var state: State = .{ .list_rows = 3 };
    state.rebuild(&store);
    return .{ .store = store, .state = state };
}

test "the accounts overlay opens, moves, selects, and closes" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.accounts.add(AccountId.from_int(1), "home", .{}, .{});
    fixture.state.accounts.add(AccountId.from_int(2), "work", .{}, .{});
    // One message from another account, so filtering is observable.
    var other = message_with(9, "from work", .inbox, 100);
    other.account = AccountId.from_int(2);
    try fixture.store.insert(&other);
    fixture.state.rebuild(&fixture.store);
    fixture.state.accounts_cursor = 1;

    _ = apply(&fixture.state, &fixture.store, .open_accounts);
    try testing.expectEqual(View.accounts, fixture.state.view);
    try testing.expectEqual(@as(u8, 0), fixture.state.accounts_cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .down });
    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .down });
    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .down });
    try testing.expectEqual(@as(u8, 2), fixture.state.accounts_cursor); // clamped at len
    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .top });
    try testing.expectEqual(@as(u8, 0), fixture.state.accounts_cursor);
    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .bottom });
    try testing.expectEqual(@as(u8, 2), fixture.state.accounts_cursor);
    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .up });
    try testing.expectEqual(@as(u8, 1), fixture.state.accounts_cursor);

    _ = apply(&fixture.state, &fixture.store, .accounts_select);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqual(AccountId.from_int(1), fixture.state.account_filter.?);
    try testing.expectEqualStrings("home", fixture.state.status.slice());
    // The list is filtered right away, without waiting for a refresh.
    try testing.expect(fixture.state.visible_len < fixture.store.len);

    _ = apply(&fixture.state, &fixture.store, .open_accounts);
    _ = apply(&fixture.state, &fixture.store, .accounts_select);
    try testing.expect(fixture.state.account_filter == null);
    try testing.expectEqualStrings("All accounts", fixture.state.status.slice());

    fixture.state.accounts_cursor = 9;
    _ = apply(&fixture.state, &fixture.store, .accounts_select);
    try testing.expectEqualStrings("No account there", fixture.state.status.slice());

    _ = apply(&fixture.state, &fixture.store, .open_accounts);
    _ = apply(&fixture.state, &fixture.store, .accounts_close);
    try testing.expectEqual(View.list, fixture.state.view);
}

test "dismissing the accounts overlay returns to the list" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.view = .accounts;

    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(View.list, fixture.state.view);
}

test "moving the accounts cursor with an unmapped move leaves it alone" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.accounts.add(AccountId.from_int(1), "home", .{}, .{});
    fixture.state.view = .accounts;
    fixture.state.accounts_cursor = 1;

    _ = apply(&fixture.state, &fixture.store, .{ .accounts_move = .page_down });
    try testing.expectEqual(@as(u8, 1), fixture.state.accounts_cursor);
}

test "renaming needs an account too" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.accounts.add(AccountId.from_int(1), "home", .{}, .{});

    fixture.state.accounts_cursor = 0;
    _ = apply(&fixture.state, &fixture.store, .accounts_rename);
    try testing.expectEqualStrings("Pick an account to rename", fixture.state.status.slice());

    fixture.state.accounts_cursor = 4;
    _ = apply(&fixture.state, &fixture.store, .accounts_rename);
    try testing.expectEqualStrings("No account there", fixture.state.status.slice());

    fixture.state.accounts_cursor = 1;
    const effects = apply(&fixture.state, &fixture.store, .accounts_rename);
    try expect_effects(&effects, &.{.{ .rename_account = .{ .account = AccountId.from_int(1) } }});
}

test "editing needs an account: the first row is not one" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.accounts.add(AccountId.from_int(1), "home", .{}, .{});

    fixture.state.accounts_cursor = 0;
    _ = apply(&fixture.state, &fixture.store, .accounts_edit);
    try testing.expectEqualStrings("Pick an account to edit", fixture.state.status.slice());

    fixture.state.accounts_cursor = 5;
    _ = apply(&fixture.state, &fixture.store, .accounts_edit);
    try testing.expectEqualStrings("No account there", fixture.state.status.slice());

    fixture.state.accounts_cursor = 1;
    const effects = apply(&fixture.state, &fixture.store, .accounts_edit);
    try expect_effects(&effects, &.{.{ .edit_account = .{ .account = AccountId.from_int(1) } }});
}

test "removing and adding accounts emits the effects the session runs" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.accounts.add(AccountId.from_int(1), "home", .{}, .{});

    fixture.state.accounts_cursor = 0;
    const refused = apply(&fixture.state, &fixture.store, .accounts_remove);
    try testing.expect(refused.is_empty());
    try testing.expectEqualStrings("All accounts cannot be removed", fixture.state.status.slice());

    fixture.state.accounts_cursor = 1;
    const remove = apply(&fixture.state, &fixture.store, .accounts_remove);
    try expect_effects(&remove, &.{.{ .remove_account = .{ .account = AccountId.from_int(1) } }});
    try testing.expectEqualStrings("Removing home…", fixture.state.status.slice());

    fixture.state.accounts_cursor = 7;
    _ = apply(&fixture.state, &fixture.store, .accounts_remove);
    try testing.expectEqualStrings("No account there", fixture.state.status.slice());

    const add = apply(&fixture.state, &fixture.store, .accounts_add);
    try expect_effects(&add, &.{.{ .edit_account = .{ .account = null } }});
}

test "delete_forever removes the message and asks the server, in Trash only" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    // Outside Trash it just explains itself.
    const refused = apply(&fixture.state, &fixture.store, .delete_forever);
    try testing.expect(refused.is_empty());
    try testing.expectEqualStrings("Only in Trash: d moves a message here first", fixture.state.status.slice());

    fixture.state.mailbox = .trash;
    fixture.store.at(0).mailbox = .trash;
    fixture.state.rebuild(&fixture.store);
    const before = fixture.store.len;

    const effects = apply(&fixture.state, &fixture.store, .delete_forever);
    try expect_effects(&effects, &.{.{ .delete_message = .{
        .account = AccountId.from_int(1),
        .mailbox = .trash,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqual(before - 1, fixture.store.len);
    try testing.expectEqualStrings("Deleted for good", fixture.state.status.slice());
}

test "delete_forever with nothing selected says so" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .trash;
    fixture.state.visible_len = 0;
    fixture.state.cursor = 0;

    _ = apply(&fixture.state, &fixture.store, .delete_forever);
    try testing.expectEqualStrings("No message selected", fixture.state.status.slice());
}

test "delete_forever from the reader returns to the list" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .trash;
    fixture.store.at(0).mailbox = .trash;
    fixture.state.rebuild(&fixture.store);
    fixture.state.view = .reader;
    fixture.state.reader_scroll = 4;

    _ = apply(&fixture.state, &fixture.store, .delete_forever);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);
}

test "empty_trash asks once, then empties the scope" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .trash;
    fixture.store.at(0).mailbox = .trash;
    fixture.store.at(1).mailbox = .trash;
    fixture.state.rebuild(&fixture.store);

    // First press only arms it.
    const armed = apply(&fixture.state, &fixture.store, .empty_trash);
    try testing.expect(armed.is_empty());
    try testing.expect(fixture.state.pending_empty);
    try testing.expectEqualStrings("Press E again to empty Trash", fixture.state.status.slice());
    try testing.expectEqual(@as(u32, 2), fixture.state.visible_len);

    // Anything else disarms it.
    const other = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 0), other.len);
    try testing.expect(!fixture.state.pending_empty);

    _ = apply(&fixture.state, &fixture.store, .empty_trash);
    const effects = apply(&fixture.state, &fixture.store, .empty_trash);
    try expect_effects(&effects, &.{.{ .empty_mailbox = .{ .account = null, .mailbox = .trash } }});
    try testing.expectEqual(@as(u32, 0), fixture.state.visible_len);
    try testing.expectEqualStrings("Trash emptied", fixture.state.status.slice());
}

test "empty_trash outside Trash, and when empty, is refused" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .empty_trash);
    try testing.expectEqualStrings("Emptying is only offered in Trash", fixture.state.status.slice());

    fixture.state.mailbox = .trash;
    fixture.state.rebuild(&fixture.store);
    _ = apply(&fixture.state, &fixture.store, .empty_trash);
    try testing.expectEqualStrings("Trash is already empty", fixture.state.status.slice());
}

test "emptying Trash from the reader returns to the list" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .trash;
    fixture.store.at(0).mailbox = .trash;
    fixture.state.rebuild(&fixture.store);
    fixture.state.view = .reader;

    fixture.state.pending_empty = true;
    _ = apply(&fixture.state, &fixture.store, .empty_trash);
    try testing.expectEqual(View.list, fixture.state.view);
}

test "empty_trash honours the account filter" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    var second = message_with(9, "other account", .trash, 100);
    second.account = AccountId.from_int(2);
    try fixture.store.insert(&second);
    fixture.store.at(0).mailbox = .trash;
    fixture.state.mailbox = .trash;
    fixture.state.account_filter = AccountId.from_int(1);
    fixture.state.rebuild(&fixture.store);

    fixture.state.pending_empty = true;
    const effects = apply(&fixture.state, &fixture.store, .empty_trash);
    try expect_effects(&effects, &.{.{ .empty_mailbox = .{
        .account = AccountId.from_int(1),
        .mailbox = .trash,
    } }});

    // Only account 1's trash went away.
    var index: u32 = 0;
    var survivors: u32 = 0;
    while (index < fixture.store.len) : (index += 1) {
        if (fixture.store.at(index).mailbox == .trash) survivors += 1;
    }
    try testing.expectEqual(@as(u32, 1), survivors);
}

test "sample_store propagates allocation failure without leaking" {
    try testing.expectError(error.OutOfMemory, sample_store_with(testing.failing_allocator));
}

test "noop changes nothing and keeps the status" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.set_status("hello", .{});

    const effects = apply(&fixture.state, &fixture.store, .noop);
    try testing.expect(effects.is_empty());
    try testing.expectEqualStrings("hello", fixture.state.status.slice());
}

test "quit sets the flag" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    const effects = apply(&fixture.state, &fixture.store, .quit);
    try testing.expect(effects.is_empty());
    try testing.expect(fixture.state.quit);
}

test "move: up and down stay inside the list" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .up });
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 1), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .bottom });
    try testing.expectEqual(@as(u32, 2), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 2), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .top });
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);
}

test "move: page and half page are bounded" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.list_rows = 2;

    _ = apply(&fixture.state, &fixture.store, .{ .move = .page_down });
    try testing.expectEqual(@as(u32, 2), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .page_up });
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .half_page_down });
    try testing.expectEqual(@as(u32, 1), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .half_page_up });
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);
}

test "move: an empty list never moves the cursor" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .junk;
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);
    try testing.expectEqual(@as(u32, 0), fixture.state.offset);
}

test "move in the reader scrolls the body and clamps at both ends" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.view = .reader;
    fixture.state.reader_rows = 10;
    fixture.state.body_rows = 25;

    _ = apply(&fixture.state, &fixture.store, .{ .move = .up });
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 1), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .bottom });
    try testing.expectEqual(@as(u32, 15), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 15), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .page_up });
    try testing.expectEqual(@as(u32, 5), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .half_page_up });
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .half_page_down });
    try testing.expectEqual(@as(u32, 5), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .page_down });
    try testing.expectEqual(@as(u32, 15), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .{ .move = .top });
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);
}

test "move while help is open does nothing" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.view = .help;

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);
}

test "open: marks an unread message read, fetches the body, and switches view" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    const effects = apply(&fixture.state, &fixture.store, .open_selected);
    try testing.expectEqual(View.reader, fixture.state.view);
    try testing.expectEqual(MessageId.from_int(1), fixture.state.opened);
    try testing.expect(!fixture.store.at(0).is_unread());

    try expect_effects(&effects, &.{
        .{ .sync_flags = .{ .account = AccountId.from_int(1), .id = MessageId.from_int(1), .flags = .{ .unread = false } } },
        .{ .fetch_body = .{ .account = AccountId.from_int(1), .mailbox = .inbox, .id = MessageId.from_int(1) } },
    });
}

test "open: an already-read message only fetches the body" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.store.at(0).flags = .{ .unread = false };

    const effects = apply(&fixture.state, &fixture.store, .open_selected);
    try expect_effects(&effects, &.{.{ .fetch_body = .{ .account = AccountId.from_int(1), .mailbox = .inbox, .id = MessageId.from_int(1) } }});
}

test "open: an empty list explains itself and stays put" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .junk;
    fixture.state.rebuild(&fixture.store);

    const effects = apply(&fixture.state, &fixture.store, .open_selected);
    try testing.expect(effects.is_empty());
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqualStrings("No message selected", fixture.state.status.slice());
}

test "open while already reading does nothing" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.view = .reader;

    const effects = apply(&fixture.state, &fixture.store, .open_selected);
    try testing.expect(effects.is_empty());
}

test "dismiss: cancel search, close help, leave the reader, then quit from the list" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    fixture.state.mode = .search;
    fixture.state.draft.set("inv");
    fixture.state.query.set("inv");
    fixture.state.rebuild(&fixture.store);
    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expect(fixture.state.query.is_empty());

    fixture.state.view = .help;
    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(View.list, fixture.state.view);

    fixture.state.view = .reader;
    fixture.state.reader_scroll = 5;
    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);

    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expect(fixture.state.quit);
    try testing.expectEqual(View.list, fixture.state.view);
}

test "next and previous mailbox cycle and ask the adapter to load them" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    const effects = apply(&fixture.state, &fixture.store, .next_mailbox);
    try testing.expectEqual(Mailbox.sent, fixture.state.mailbox);
    try testing.expectEqual(@as(u32, 1), fixture.state.visible_len);
    try expect_effects(&effects, &.{.{ .refresh = .{ .account = null, .mailbox = .sent, .force = false } }});

    _ = apply(&fixture.state, &fixture.store, .previous_mailbox);
    try testing.expectEqual(Mailbox.inbox, fixture.state.mailbox);
}

test "switching mailbox clears the filter, closes the reader, and resets the cursor" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    fixture.state.view = .reader;
    fixture.state.reader_scroll = 4;
    fixture.state.query.set("invoice");
    fixture.state.draft.set("invoice");
    fixture.state.mode = .search;
    fixture.state.cursor = 2;
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .{ .select_mailbox = .inbox });
    try testing.expectEqual(Mailbox.inbox, fixture.state.mailbox);

    const effects = apply(&fixture.state, &fixture.store, .{ .select_mailbox = .drafts });
    try testing.expectEqual(Mailbox.drafts, fixture.state.mailbox);
    try expect_effects(&effects, &.{.{ .refresh = .{ .account = null, .mailbox = .drafts, .force = false } }});
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expect(fixture.state.query.is_empty());
    try testing.expect(fixture.state.draft.is_empty());
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);
    try testing.expectEqual(MessageId.unknown, fixture.state.opened);
}

test "selecting the current mailbox is a no-op" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.query.set("invoice");
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .{ .select_mailbox = .inbox });
    try testing.expectEqualStrings("invoice", fixture.state.query.slice());
    try testing.expectEqual(@as(u32, 1), fixture.state.visible_len);
}

test "toggle_unread flips the flag, syncs it, and reports the new state" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    var effects = apply(&fixture.state, &fixture.store, .toggle_unread);
    try testing.expect(!fixture.store.at(0).is_unread());
    try testing.expectEqualStrings("Marked read", fixture.state.status.slice());
    try expect_effects(&effects, &.{.{ .sync_flags = .{ .account = AccountId.from_int(1), .id = MessageId.from_int(1), .flags = .{ .unread = false } } }});

    effects = apply(&fixture.state, &fixture.store, .toggle_unread);
    try testing.expect(fixture.store.at(0).is_unread());
    try testing.expectEqualStrings("Marked unread", fixture.state.status.slice());
}

test "toggle_unread with an empty list explains itself" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .junk;
    fixture.state.rebuild(&fixture.store);

    const effects = apply(&fixture.state, &fixture.store, .toggle_unread);
    try testing.expect(effects.is_empty());
    try testing.expectEqualStrings("No message selected", fixture.state.status.slice());
}

test "toggle_flag flips the flag and reports the new state" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    var effects = apply(&fixture.state, &fixture.store, .toggle_flag);
    try testing.expect(fixture.store.at(0).is_flagged());
    try testing.expectEqualStrings("Starred", fixture.state.status.slice());
    try testing.expectEqual(@as(usize, 1), effects.slice().len);

    _ = apply(&fixture.state, &fixture.store, .toggle_flag);
    try testing.expect(!fixture.store.at(0).is_flagged());
    try testing.expectEqualStrings("Unstarred", fixture.state.status.slice());
}

test "toggle_flag with an empty list explains itself" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .junk;
    fixture.state.rebuild(&fixture.store);

    const effects = apply(&fixture.state, &fixture.store, .toggle_flag);
    try testing.expect(effects.is_empty());
    try testing.expectEqualStrings("No message selected", fixture.state.status.slice());
}

test "archive moves the message out of the list and syncs the server" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    const effects = apply(&fixture.state, &fixture.store, .archive_selected);
    try testing.expectEqual(Mailbox.archive, fixture.store.at(0).mailbox);
    try testing.expectEqual(@as(u32, 2), fixture.state.visible_len);
    try testing.expectEqualStrings("Archived", fixture.state.status.slice());
    try expect_effects(&effects, &.{.{ .move_message = .{ .account = AccountId.from_int(1), .id = MessageId.from_int(1), .to = .archive } }});
}

test "archive from the reader returns to the list" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .open_selected);

    _ = apply(&fixture.state, &fixture.store, .archive_selected);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqual(@as(u32, 0), fixture.state.reader_scroll);
}

test "archiving an archived message and deleting a trashed one explain themselves" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .archive_selected);
    _ = apply(&fixture.state, &fixture.store, .{ .select_mailbox = .archive });
    const effects = apply(&fixture.state, &fixture.store, .archive_selected);
    try testing.expect(effects.is_empty());
    try testing.expectEqualStrings("Already in Archive", fixture.state.status.slice());

    _ = apply(&fixture.state, &fixture.store, .{ .select_mailbox = .inbox });
    _ = apply(&fixture.state, &fixture.store, .delete_selected);
    try testing.expectEqual(Mailbox.trash, fixture.store.at(1).mailbox);
    _ = apply(&fixture.state, &fixture.store, .{ .select_mailbox = .trash });
    _ = apply(&fixture.state, &fixture.store, .delete_selected);
    try testing.expectEqualStrings("Already in Trash", fixture.state.status.slice());
}

test "move without a selection explains itself" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .junk;
    fixture.state.rebuild(&fixture.store);

    const effects = apply(&fixture.state, &fixture.store, .archive_selected);
    try testing.expect(effects.is_empty());
    try testing.expectEqualStrings("No message selected", fixture.state.status.slice());
}

test "search: begin copies the active filter into the draft" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.query.set("invoice");

    _ = apply(&fixture.state, &fixture.store, .begin_search);
    try testing.expectEqual(.search, fixture.state.mode);
    try testing.expectEqualStrings("invoice", fixture.state.draft.slice());
}

test "search: begin from the reader is ignored" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.view = .reader;

    _ = apply(&fixture.state, &fixture.store, .begin_search);
    try testing.expectEqual(.normal, fixture.state.mode);
}

test "search: typing filters live and resets the cursor" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .begin_search);
    fixture.state.cursor = 2;

    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'i' });
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'n' });
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'v' });
    try testing.expectEqual(@as(u32, 1), fixture.state.visible_len);
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);
    try testing.expectEqualStrings("inv", fixture.state.query.slice());
}

test "search: non-printable bytes and characters outside search mode are ignored" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'x' });
    try testing.expect(fixture.state.query.is_empty());

    _ = apply(&fixture.state, &fixture.store, .begin_search);
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 0x1b });
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 0x7f });
    try testing.expect(fixture.state.draft.is_empty());
}

test "search: backspace removes one character and refilters" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .begin_search);

    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'i' });
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'n' });
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'v' });
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    try testing.expectEqualStrings("in", fixture.state.draft.slice());

    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    try testing.expect(fixture.state.draft.is_empty());
    try testing.expectEqual(@as(u32, 3), fixture.state.visible_len);
}

test "search: backspace outside search mode is ignored" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    try testing.expectEqual(.normal, fixture.state.mode);
}

test "search: commit keeps the filter and reports it" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .begin_search);
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'i' });
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'n' });

    _ = apply(&fixture.state, &fixture.store, .search_commit);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expectEqualStrings("in", fixture.state.query.slice());
    try testing.expectEqualStrings("Filter: in", fixture.state.status.slice());
}

test "search: committing an empty filter clears it" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.query.set("invoice");
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .begin_search);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_backspace);
    _ = apply(&fixture.state, &fixture.store, .search_commit);
    try testing.expect(fixture.state.query.is_empty());
    try testing.expectEqualStrings("Filter cleared", fixture.state.status.slice());
    try testing.expectEqual(@as(u32, 3), fixture.state.visible_len);
}

test "search: commit outside search mode is ignored" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .search_commit);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expect(fixture.state.status.is_empty());
}

test "search: cancel drops the filter entirely" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.query.set("invoice");
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .begin_search);
    _ = apply(&fixture.state, &fixture.store, .{ .search_char = 'x' });
    _ = apply(&fixture.state, &fixture.store, .search_cancel);

    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expect(fixture.state.query.is_empty());
    try testing.expect(fixture.state.draft.is_empty());
    try testing.expectEqual(@as(u32, 3), fixture.state.visible_len);
}

test "help toggles over the current view and returns to it" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    try testing.expectEqual(View.help, fixture.state.view);
    try testing.expectEqual(View.list, fixture.state.help_return);

    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    try testing.expectEqual(View.list, fixture.state.view);

    fixture.state.view = .reader;
    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    try testing.expectEqual(View.help, fixture.state.view);
    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    try testing.expectEqual(View.reader, fixture.state.view);
}

test "help search: begin, type, backspace, commit" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    _ = apply(&fixture.state, &fixture.store, .begin_help_search);
    try testing.expectEqual(.help_search, fixture.state.mode);

    _ = apply(&fixture.state, &fixture.store, .{ .help_search_char = 'm' });
    _ = apply(&fixture.state, &fixture.store, .{ .help_search_char = 'o' });
    try testing.expectEqualStrings("mo", fixture.state.help_filter.slice());

    _ = apply(&fixture.state, &fixture.store, .help_search_backspace);
    try testing.expectEqualStrings("m", fixture.state.help_filter.slice());

    _ = apply(&fixture.state, &fixture.store, .help_search_commit);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expectEqualStrings("m", fixture.state.help_filter.slice());
    try testing.expectEqual(View.help, fixture.state.view);
}

test "help search: cancel drops the filter; dismiss cancels first, then closes" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    _ = apply(&fixture.state, &fixture.store, .begin_help_search);
    _ = apply(&fixture.state, &fixture.store, .{ .help_search_char = 'x' });
    _ = apply(&fixture.state, &fixture.store, .help_search_cancel);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expect(fixture.state.help_filter.is_empty());

    _ = apply(&fixture.state, &fixture.store, .begin_help_search);
    _ = apply(&fixture.state, &fixture.store, .{ .help_search_char = 'x' });
    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(.normal, fixture.state.mode);
    try testing.expectEqual(View.help, fixture.state.view);

    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(View.list, fixture.state.view);
}

test "help search: ignored outside help, and non-printable bytes are ignored" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .begin_help_search);
    try testing.expectEqual(.normal, fixture.state.mode);

    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    _ = apply(&fixture.state, &fixture.store, .begin_help_search);
    _ = apply(&fixture.state, &fixture.store, .{ .help_search_char = 0x1b });
    _ = apply(&fixture.state, &fixture.store, .help_search_backspace);
    try testing.expect(fixture.state.help_filter.is_empty());

    _ = apply(&fixture.state, &fixture.store, .help_search_commit);
    _ = apply(&fixture.state, &fixture.store, .help_search_cancel);
}

test "opening help clears a previous filter" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    _ = apply(&fixture.state, &fixture.store, .begin_help_search);
    _ = apply(&fixture.state, &fixture.store, .{ .help_search_char = 'z' });
    _ = apply(&fixture.state, &fixture.store, .help_search_commit);
    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    _ = apply(&fixture.state, &fixture.store, .toggle_help);
    try testing.expect(fixture.state.help_filter.is_empty());
}

test "compose_new opens an empty draft at the recipient" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .compose_new);
    try testing.expectEqual(View.compose, fixture.state.view);
    try testing.expect(fixture.state.compose.active);
    try testing.expectEqual(.to, fixture.state.compose.field);
}

test "compose_reply prefills the recipient and subject" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .compose_reply);
    try testing.expectEqual(View.compose, fixture.state.view);
    try testing.expectEqual(.body, fixture.state.compose.field);
    // The fixture's first message has no sender, so the address is just "@".
    try testing.expectEqualStrings("@", fixture.state.compose.to.slice());
    // The subject still gets the Re: prefix.
    try testing.expectEqualStrings("Re: Invoice for October", fixture.state.compose.subject.slice());
    try testing.expectEqual(MessageId.from_int(1), fixture.state.compose.in_reply_to);
}

test "compose_reply does not double the Re: prefix" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.store.at(0).subject.set("Re: lunch");
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .compose_reply);
    try testing.expectEqualStrings("Re: lunch", fixture.state.compose.subject.slice());
}

test "compose_reply with no selection explains itself" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.mailbox = .junk;
    fixture.state.rebuild(&fixture.store);

    _ = apply(&fixture.state, &fixture.store, .compose_reply);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expectEqualStrings("No message selected", fixture.state.status.slice());
}

test "compose_send validates the recipient and emits the message" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.from_address = try Address.init("Me <me@amail.local>");

    _ = apply(&fixture.state, &fixture.store, .compose_new);
    var effects = apply(&fixture.state, &fixture.store, .compose_send);
    try testing.expect(effects.is_empty());
    try testing.expectEqualStrings("That address does not look right", fixture.state.status.slice());

    fixture.state.compose.to.set("alice@example.com");
    fixture.state.compose.subject.set("Hello");
    fixture.state.compose.field = .body;
    _ = apply(&fixture.state, &fixture.store, .{ .compose_char = 'b' });
    effects = apply(&fixture.state, &fixture.store, .compose_send);
    try testing.expectEqual(@as(usize, 1), effects.slice().len);

    const outgoing = effects.slice()[0].send;
    try testing.expectEqualStrings("alice", outgoing.to.local.slice());
    try testing.expectEqualStrings("Hello", outgoing.subject.slice());
    try testing.expectEqualStrings("b", outgoing.body);
    try testing.expectEqualStrings("me", outgoing.from.local.slice());
}

test "compose editing commands are ignored outside the compose view" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .{ .compose_char = 'x' });
    _ = apply(&fixture.state, &fixture.store, .compose_newline);
    _ = apply(&fixture.state, &fixture.store, .compose_backspace);
    _ = apply(&fixture.state, &fixture.store, .compose_next_field);
    _ = apply(&fixture.state, &fixture.store, .compose_previous_field);
    _ = apply(&fixture.state, &fixture.store, .compose_clear_field);
    try testing.expect(fixture.state.compose.to.is_empty());
    try testing.expectEqual(.to, fixture.state.compose.field);
}

test "compose_send outside compose does nothing" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    const effects = apply(&fixture.state, &fixture.store, .compose_send);
    try testing.expect(effects.is_empty());
}

test "dismiss cancels compose and keeps the list intact" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .compose_new);
    _ = apply(&fixture.state, &fixture.store, .{ .compose_char = 'a' });

    _ = apply(&fixture.state, &fixture.store, .dismiss);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expect(!fixture.state.compose.active);
    try testing.expect(!fixture.state.quit);
}

test "compose_cancel closes the draft without quitting" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .compose_new);

    _ = apply(&fixture.state, &fixture.store, .compose_cancel);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expect(!fixture.state.compose.active);
    try testing.expect(!fixture.state.quit);

    _ = apply(&fixture.state, &fixture.store, .compose_cancel);
    try testing.expectEqual(View.list, fixture.state.view);
}

test "a successful send closes the draft; a failure keeps it and alerts" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    _ = apply(&fixture.state, &fixture.store, .compose_new);
    _ = apply(&fixture.state, &fixture.store, .{ .compose_char = 'a' });

    _ = apply(&fixture.state, &fixture.store, .send_failed);
    try testing.expectEqual(View.compose, fixture.state.view);
    try testing.expect(fixture.state.compose.active);
    try testing.expectEqualStrings("a", fixture.state.compose.to.slice());
    try testing.expect(fixture.state.status_alert);

    _ = apply(&fixture.state, &fixture.store, .send_succeeded);
    try testing.expectEqual(View.list, fixture.state.view);
    try testing.expect(!fixture.state.compose.active);
    try testing.expectEqualStrings("Message sent · 2 opens Sent", fixture.state.status.slice());
}

test "refresh asks for the current mailbox" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    const effects = apply(&fixture.state, &fixture.store, .refresh);
    try expect_effects(&effects, &.{.{ .refresh = .{ .account = null, .mailbox = .inbox, .force = true } }});
    try testing.expect(fixture.state.status.is_empty());
}

test "set_viewport clamps the cursor and the reader scroll, and keeps the status" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.set_status("Archived", .{});
    fixture.state.cursor = 2;

    _ = apply(&fixture.state, &fixture.store, .{ .set_viewport = .{
        .list_rows = 1,
        .reader_rows = 5,
        .body_rows = 8,
    } });

    try testing.expectEqual(@as(u16, 1), fixture.state.list_rows);
    try testing.expectEqual(@as(u16, 5), fixture.state.reader_rows);
    try testing.expectEqual(@as(u32, 8), fixture.state.body_rows);
    try testing.expectEqual(@as(u32, 2), fixture.state.offset);
    try testing.expectEqualStrings("Archived", fixture.state.status.slice());
}

test "set_viewport tolerates zero rows and clamps the reader scroll" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.view = .reader;
    fixture.state.reader_scroll = 100;

    _ = apply(&fixture.state, &fixture.store, .{ .set_viewport = .{
        .list_rows = 0,
        .reader_rows = 0,
        .body_rows = 2,
    } });

    try testing.expectEqual(@as(u16, 1), fixture.state.list_rows);
    try testing.expectEqual(@as(u16, 1), fixture.state.reader_rows);
    try testing.expectEqual(@as(u32, 1), fixture.state.reader_scroll);
}

test "cycle_account walks all accounts and returns to the unified view" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.state.accounts.add(AccountId.from_int(1), "personal", .{}, .{});
    fixture.state.accounts.add(AccountId.from_int(2), "work", .{}, .{});
    fixture.state.cursor = 1;

    _ = apply(&fixture.state, &fixture.store, .cycle_account);
    try testing.expectEqual(AccountId.from_int(1), fixture.state.account_filter.?);
    try testing.expectEqual(@as(u32, 0), fixture.state.cursor);

    _ = apply(&fixture.state, &fixture.store, .cycle_account);
    try testing.expectEqual(AccountId.from_int(2), fixture.state.account_filter.?);

    _ = apply(&fixture.state, &fixture.store, .cycle_account);
    try testing.expect(fixture.state.account_filter == null);
}

test "cycle_account without accounts or with an unknown filter stays safe" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    _ = apply(&fixture.state, &fixture.store, .cycle_account);
    try testing.expect(fixture.state.account_filter == null);

    fixture.state.accounts.add(AccountId.from_int(1), "personal", .{}, .{});
    fixture.state.account_filter = AccountId.from_int(9);
    _ = apply(&fixture.state, &fixture.store, .cycle_account);
    try testing.expect(fixture.state.account_filter == null);
}

test "a user command clears the status, a viewport update does not" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    fixture.state.set_status("Archived", .{});
    _ = apply(&fixture.state, &fixture.store, .{ .set_viewport = .{} });
    try testing.expect(!fixture.state.status.is_empty());

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expect(fixture.state.status.is_empty());
}
