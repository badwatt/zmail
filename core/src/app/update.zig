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
        .begin_search => begin_search(state),
        .search_char => |byte| search_char(state, store, byte),
        .search_backspace => search_backspace(state, store),
        .search_commit => search_commit(state, store),
        .search_cancel => search_cancel(state, store),
        .toggle_help => toggle_help(state),
        .refresh => apply_refresh(state, &effects),
        .set_viewport => |viewport| apply_viewport(state, viewport),
    }
    return effects;
}

fn apply_move(state: *State, move: Move) void {
    switch (state.view) {
        .list => move_cursor(state, move),
        .reader => scroll_reader(state, move),
        .help => {},
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
    state.view = .reader;
    state.reader_scroll = 0;

    if (message.is_unread()) {
        message.flags = message.flags.mark_read();
        effects.add(.{ .sync_flags = .{ .id = message.id, .flags = message.flags } });
    }
    effects.add(.{ .fetch_body = message.id });
}

fn apply_dismiss(state: *State, store: *Store) void {
    switch (state.mode) {
        .search => search_cancel(state, store),
        .normal => switch (state.view) {
            .help => state.view = state.help_return,
            .reader => {
                state.view = .list;
                state.reader_scroll = 0;
            },
            .list => state.quit = true,
        },
    }
}

fn switch_mailbox(state: *State, store: *Store, mailbox: Mailbox, effects: *Effects) void {
    if (state.mailbox == mailbox) return;

    state.mailbox = mailbox;
    effects.add(.{ .refresh = mailbox });
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
    effects.add(.{ .sync_flags = .{ .id = message.id, .flags = message.flags } });
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
    effects.add(.{ .sync_flags = .{ .id = message.id, .flags = message.flags } });
    if (message.is_flagged()) {
        state.set_status("Starred", .{});
    } else {
        state.set_status("Unstarred", .{});
    }
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
    effects.add(.{ .move_message = .{ .id = message.id, .to = target } });
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

fn toggle_help(state: *State) void {
    if (state.view == .help) {
        state.view = state.help_return;
        return;
    }
    state.help_return = state.view;
    state.view = .help;
}

fn apply_refresh(state: *State, effects: *Effects) void {
    effects.add(.{ .refresh = state.mailbox });
    state.set_status("Refreshing...", .{});
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

fn message_with(id: u64, subject: []const u8, mailbox: Mailbox, timestamp_unix: i64) Message {
    var message = Message{
        .id = MessageId.from_int(id),
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
        .{ .sync_flags = .{ .id = MessageId.from_int(1), .flags = .{ .unread = false } } },
        .{ .fetch_body = MessageId.from_int(1) },
    });
}

test "open: an already-read message only fetches the body" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);
    fixture.store.at(0).flags = .{ .unread = false };

    const effects = apply(&fixture.state, &fixture.store, .open_selected);
    try expect_effects(&effects, &.{.{ .fetch_body = MessageId.from_int(1) }});
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

test "dismiss: cancel search, close help, leave the reader, then quit" {
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
}

test "next and previous mailbox cycle and ask the adapter to load them" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    const effects = apply(&fixture.state, &fixture.store, .next_mailbox);
    try testing.expectEqual(Mailbox.sent, fixture.state.mailbox);
    try testing.expectEqual(@as(u32, 1), fixture.state.visible_len);
    try expect_effects(&effects, &.{.{ .refresh = .sent }});

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
    try expect_effects(&effects, &.{.{ .refresh = .drafts }});
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
    try expect_effects(&effects, &.{.{ .sync_flags = .{ .id = MessageId.from_int(1), .flags = .{ .unread = false } } }});

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
    try expect_effects(&effects, &.{.{ .move_message = .{ .id = MessageId.from_int(1), .to = .archive } }});
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

test "refresh asks for the current mailbox and says so" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    const effects = apply(&fixture.state, &fixture.store, .refresh);
    try expect_effects(&effects, &.{.{ .refresh = .inbox }});
    try testing.expectEqualStrings("Refreshing...", fixture.state.status.slice());
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

test "a user command clears the status, a viewport update does not" {
    var fixture = try ready();
    defer fixture.store.deinit(testing.allocator);

    fixture.state.set_status("Archived", .{});
    _ = apply(&fixture.state, &fixture.store, .{ .set_viewport = .{} });
    try testing.expect(!fixture.state.status.is_empty());

    _ = apply(&fixture.state, &fixture.store, .{ .move = .down });
    try testing.expect(fixture.state.status.is_empty());
}
