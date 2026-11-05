//! User intents, expressed without a keyboard, a mouse, or a screen.
//!
//! The TUI and (later) the GUI both translate their input into these commands.
//! `update` is the only place that decides what a command means, so the two
//! front ends cannot drift apart.

const std = @import("std");
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Address = @import("../domain/address.zig").Address;

pub const Move = enum {
    up,
    down,
    top,
    bottom,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
};

/// Geometry the front end reports so paging and scrolling have bounds.
pub const Viewport = struct {
    /// Rows available to the message list.
    list_rows: u16 = 1,
    /// Rows available to the message body.
    reader_rows: u16 = 1,
    /// Total wrapped lines of the open body, as measured by the renderer.
    body_rows: u32 = 0,
};

/// The original of a reply, as the front end already holds it.
pub const Quote = struct {
    /// Plain text of the message being answered, borrowed from the reader's
    /// buffer: a reply opened from the list has none, and quotes nothing.
    text: []const u8 = "",
    from: Address = .{},
    at: i64 = 0,
};

pub const Command = union(enum) {
    /// Nothing happened. Useful for a render tick.
    noop,
    quit,
    move: Move,
    open_selected,
    /// `q`/`Esc`: leaves the current layer (search, help, reader) or quits from
    /// the top level.
    dismiss,
    next_mailbox,
    /// Open the chooser that puts the selected message in another folder.
    begin_move,
    previous_mailbox,
    select_mailbox: Mailbox,
    toggle_unread,
    toggle_flag,
    archive_selected,
    delete_selected,
    /// Trash only: remove the selected message for good.
    delete_forever,
    /// Trash only: remove everything in it.
    empty_trash,
    /// The accounts overlay: open it, move in it, pick, remove, add, close.
    open_accounts,
    accounts_move: Move,
    accounts_select,
    accounts_remove,
    accounts_add,
    accounts_edit,
    accounts_rename,
    accounts_oauth,
    accounts_close,
    begin_search,
    search_char: u8,
    search_backspace,
    search_commit,
    search_cancel,
    begin_help_search,
    help_search_char: u8,
    /// Scroll the list of keys: one line, or a page of them.
    help_scroll: i16,
    help_search_backspace,
    help_search_commit,
    help_search_cancel,
    toggle_help,
    refresh,
    set_viewport: Viewport,
    /// All accounts -> account 1 -> ... -> all accounts.
    cycle_account,
    compose_new,
    compose_reply,
    compose_send,
    /// Ctrl+S: the same send, but a few seconds late, so it can still be
    /// stopped. The session runs the countdown; the core never reads a clock.
    compose_send_held: struct { now_unix: i64 },
    compose_cancel,
    compose_char: u21,
    compose_newline,
    compose_backspace,
    compose_next_field,
    compose_previous_field,
    compose_clear_field,
    /// Append the original below the draft, quoted. Sent right after
    /// `compose_reply` when the message is already loaded.
    compose_quote: Quote,
    /// Hand the body to the user's editor: the front end runs it and answers
    /// with `compose_body_set`.
    compose_edit,
    compose_body_set: struct { text: []const u8 },
    /// The editor could not be started, or exited with nothing usable.
    compose_edit_failed,
    /// Internal: the outbox accepted the message.
    send_succeeded,
    /// Internal: the outbox refused it; the draft stays.
    send_failed,

    /// Status text is a response to a user action, so the next action clears it.
    /// Viewport updates arrive on every resize and must not erase it.
    pub fn clears_status(self: Command) bool {
        return switch (self) {
            // These set their own status message.
            .noop, .set_viewport, .send_succeeded, .send_failed, .compose_body_set => false,
            else => true,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every command is classified for status clearing" {
    const commands = [_]struct { command: Command, clears: bool }{
        .{ .command = .noop, .clears = false },
        .{ .command = .{ .set_viewport = .{} }, .clears = false },
        .{ .command = .quit, .clears = true },
        .{ .command = .{ .move = .down }, .clears = true },
        .{ .command = .open_selected, .clears = true },
        .{ .command = .dismiss, .clears = true },
        .{ .command = .next_mailbox, .clears = true },
        .{ .command = .previous_mailbox, .clears = true },
        .{ .command = .{ .select_mailbox = .sent }, .clears = true },
        .{ .command = .toggle_unread, .clears = true },
        .{ .command = .toggle_flag, .clears = true },
        .{ .command = .archive_selected, .clears = true },
        .{ .command = .delete_selected, .clears = true },
        .{ .command = .delete_forever, .clears = true },
        .{ .command = .empty_trash, .clears = true },
        .{ .command = .open_accounts, .clears = true },
        .{ .command = .accounts_select, .clears = true },
        .{ .command = .accounts_remove, .clears = true },
        .{ .command = .accounts_add, .clears = true },
        .{ .command = .accounts_edit, .clears = true },
        .{ .command = .accounts_rename, .clears = true },
        .{ .command = .accounts_oauth, .clears = true },
        .{ .command = .accounts_close, .clears = true },
        .{ .command = .begin_search, .clears = true },
        .{ .command = .{ .search_char = 'a' }, .clears = true },
        .{ .command = .search_backspace, .clears = true },
        .{ .command = .search_commit, .clears = true },
        .{ .command = .search_cancel, .clears = true },
        .{ .command = .begin_help_search, .clears = true },
        .{ .command = .{ .help_search_char = 'a' }, .clears = true },
        .{ .command = .{ .help_scroll = 1 }, .clears = true },
        .{ .command = .help_search_backspace, .clears = true },
        .{ .command = .help_search_commit, .clears = true },
        .{ .command = .help_search_cancel, .clears = true },
        .{ .command = .toggle_help, .clears = true },
        .{ .command = .refresh, .clears = true },
        .{ .command = .cycle_account, .clears = true },
        .{ .command = .compose_new, .clears = true },
        .{ .command = .compose_reply, .clears = true },
        .{ .command = .compose_send, .clears = true },
        .{ .command = .{ .compose_send_held = .{ .now_unix = 0 } }, .clears = true },
        .{ .command = .compose_cancel, .clears = true },
        .{ .command = .{ .compose_char = 'a' }, .clears = true },
        .{ .command = .compose_newline, .clears = true },
        .{ .command = .compose_backspace, .clears = true },
        .{ .command = .compose_next_field, .clears = true },
        .{ .command = .compose_previous_field, .clears = true },
        .{ .command = .compose_clear_field, .clears = true },
        .{ .command = .{ .compose_quote = .{} }, .clears = true },
        .{ .command = .compose_edit, .clears = true },
        .{ .command = .{ .compose_body_set = .{ .text = "x" } }, .clears = false },
        .{ .command = .compose_edit_failed, .clears = true },
        .{ .command = .send_succeeded, .clears = false },
        .{ .command = .send_failed, .clears = false },
    };
    for (commands) |case| {
        try testing.expectEqual(case.clears, case.command.clears_status());
    }
    try testing.expectEqual(@as(usize, 54), commands.len);
}
