//! Keys to commands.
//!
//! Vim first, but never only vim: every action has an arrow/Home/Page key and a
//! mouse path (mouse is resolved in the session, which knows the geometry).
//! `?` shows this table inside the app, so the bindings are discoverable without
//! reading a manual.

const std = @import("std");
const core = @import("core");
const Key = @import("input.zig").Key;

const Command = core.command.Command;
const Mailbox = core.mailbox.Mailbox;
const Mode = core.state.Mode;
const View = core.state.View;

pub const Context = struct {
    mode: Mode = .normal,
    view: View = .list,
};

pub fn translate(key: Key, context: Context) ?Command {
    if (context.mode == .search) return search_key(key);
    if (context.mode == .help_search) return help_search_key(key);
    if (context.view == .compose) return compose_key(key);
    if (context.view == .help) return help_key(key);
    if (context.view == .accounts) return accounts_key(key);
    return normal_key(key, context.view);
}

fn compose_key(key: Key) ?Command {
    return switch (key) {
        .char => |codepoint| .{ .compose_char = codepoint },
        .enter => .compose_newline,
        .tab => .compose_next_field,
        .back_tab => .compose_previous_field,
        .backspace => .compose_backspace,
        .escape => .dismiss,
        .ctrl => |letter| switch (letter) {
            's' => .compose_send,
            'u' => .compose_clear_field,
            'c', 'q' => .quit,
            else => null,
        },
        .up, .down, .page_up, .page_down, .home, .end, .left, .right, .delete, .insert, .mouse, .unknown => null,
    };
}

fn help_key(key: Key) ?Command {
    return switch (key) {
        .ctrl => |letter| if (letter == 'c' or letter == 'q') .quit else .toggle_help,
        .char => |codepoint| if (codepoint == '/') .begin_help_search else .toggle_help,
        else => .toggle_help,
    };
}

fn help_search_key(key: Key) ?Command {
    return switch (key) {
        .char => |codepoint| if (codepoint >= 0x20 and codepoint <= 0x7e)
            .{ .help_search_char = @intCast(codepoint) }
        else
            null,
        .backspace => .help_search_backspace,
        .enter => .help_search_commit,
        .escape => .help_search_cancel,
        .ctrl => |letter| if (letter == 'c' or letter == 'q') .quit else null,
        else => null,
    };
}

fn normal_key(key: Key, view: View) ?Command {
    return switch (key) {
        .char => |codepoint| char_command(codepoint, view),
        .enter => .open_selected,
        .tab => .next_mailbox,
        .back_tab => .previous_mailbox,
        .up => .{ .move = .up },
        .down => .{ .move = .down },
        .home => .{ .move = .top },
        .end => .{ .move = .bottom },
        .page_up => .{ .move = .page_up },
        .page_down => .{ .move = .page_down },
        .left, .escape => if (view == .list) null else .dismiss,
        .right => if (view == .list) .open_selected else null,
        .backspace => null,
        .delete => .delete_selected,
        .insert, .unknown, .mouse => null,
        .ctrl => |letter| ctrl_command(letter),
    };
}

fn char_command(codepoint: u21, view: View) ?Command {
    return switch (codepoint) {
        'j' => .{ .move = .down },
        'k' => .{ .move = .up },
        'g' => .{ .move = .top },
        'G' => .{ .move = .bottom },
        'l', 'o' => .open_selected,
        'q' => .dismiss,
        'c' => .compose_new,
        'r' => .compose_reply,
        'h' => if (view == .list) null else .dismiss,
        'u' => .toggle_unread,
        's', '*' => .toggle_flag,
        'd' => .archive_selected,
        'X' => .delete_forever,
        'E' => .empty_trash,
        '#' => .delete_selected,
        '/' => .begin_search,
        '?' => .toggle_help,
        'a' => .cycle_account,
        'A' => .open_accounts,
        '[' => .previous_mailbox,
        ']' => .next_mailbox,
        '1'...'6' => .{ .select_mailbox = Mailbox.from_index(@intCast(codepoint - '1')) },
        else => null,
    };
}

fn ctrl_command(letter: u8) ?Command {
    return switch (letter) {
        'c', 'q' => .quit,
        'd' => .{ .move = .half_page_down },
        'u' => .{ .move = .half_page_up },
        'f' => .{ .move = .page_down },
        'b' => .{ .move = .page_up },
        'n' => .{ .move = .down },
        'p' => .{ .move = .up },
        'r' => .refresh,
        else => null,
    };
}

fn accounts_key(key: Key) ?Command {
    return switch (key) {
        .char => |codepoint| switch (codepoint) {
            'j' => .{ .accounts_move = .down },
            'k' => .{ .accounts_move = .up },
            'g' => .{ .accounts_move = .top },
            'G' => .{ .accounts_move = .bottom },
            'd' => .accounts_remove,
            'n' => .accounts_add,
            'e' => .accounts_edit,
            'r' => .accounts_rename,
            'o' => .accounts_oauth,
            'q' => .accounts_close,
            else => null,
        },
        .enter => .accounts_select,
        .escape => .accounts_close,
        .up => .{ .accounts_move = .up },
        .down => .{ .accounts_move = .down },
        .home => .{ .accounts_move = .top },
        .end => .{ .accounts_move = .bottom },
        .ctrl => |letter| if (letter == 'c' or letter == 'q') .quit else null,
        else => null,
    };
}

fn search_key(key: Key) ?Command {
    return switch (key) {
        .char => |codepoint| if (codepoint >= 0x20 and codepoint <= 0x7e)
            .{ .search_char = @intCast(codepoint) }
        else
            null,
        .backspace => .search_backspace,
        .enter => .search_commit,
        .escape => .search_cancel,
        .up => .{ .move = .up },
        .down => .{ .move = .down },
        .ctrl => |letter| if (letter == 'c') .quit else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Case = struct {
    key: Key,
    context: Context = .{},
    expected: ?Command,
};

fn check(case: Case) !void {
    const actual = translate(case.key, case.context);
    if (case.expected) |expected| {
        try testing.expect(actual != null);
        try testing.expect(std.meta.eql(expected, actual.?));
    } else {
        try testing.expect(actual == null);
    }
}

test "vim movement keys" {
    const cases = [_]Case{
        .{ .key = .{ .char = 'j' }, .expected = .{ .move = .down } },
        .{ .key = .{ .char = 'k' }, .expected = .{ .move = .up } },
        .{ .key = .{ .char = 'g' }, .expected = .{ .move = .top } },
        .{ .key = .{ .char = 'G' }, .expected = .{ .move = .bottom } },
    };
    for (cases) |case| try check(case);
}

test "arrow and navigation keys mirror the vim keys" {
    const cases = [_]Case{
        .{ .key = .down, .expected = .{ .move = .down } },
        .{ .key = .up, .expected = .{ .move = .up } },
        .{ .key = .home, .expected = .{ .move = .top } },
        .{ .key = .end, .expected = .{ .move = .bottom } },
        .{ .key = .page_down, .expected = .{ .move = .page_down } },
        .{ .key = .page_up, .expected = .{ .move = .page_up } },
    };
    for (cases) |case| try check(case);
}

test "control keys page and move" {
    const cases = [_]Case{
        .{ .key = .{ .ctrl = 'd' }, .expected = .{ .move = .half_page_down } },
        .{ .key = .{ .ctrl = 'u' }, .expected = .{ .move = .half_page_up } },
        .{ .key = .{ .ctrl = 'f' }, .expected = .{ .move = .page_down } },
        .{ .key = .{ .ctrl = 'b' }, .expected = .{ .move = .page_up } },
        .{ .key = .{ .ctrl = 'n' }, .expected = .{ .move = .down } },
        .{ .key = .{ .ctrl = 'p' }, .expected = .{ .move = .up } },
        .{ .key = .{ .ctrl = 'c' }, .expected = .quit },
        .{ .key = .{ .ctrl = 'q' }, .expected = .quit },
    };
    for (cases) |case| try check(case);
}

test "opening and dismissing" {
    const cases = [_]Case{
        .{ .key = .enter, .expected = .open_selected },
        .{ .key = .{ .char = 'l' }, .expected = .open_selected },
        .{ .key = .{ .char = 'o' }, .expected = .open_selected },
        .{ .key = .right, .expected = .open_selected },
        .{ .key = .escape, .expected = null },
        .{ .key = .{ .char = 'q' }, .expected = .dismiss },
        .{ .key = .{ .char = 'h' }, .expected = null },
        .{ .key = .{ .char = 'x' }, .expected = null },
    };
    for (cases) |case| try check(case);
}

test "in the reader, escape, left, h and q go back; right does nothing" {
    const reader: Context = .{ .view = .reader };
    try check(.{ .key = .left, .context = reader, .expected = .dismiss });
    try check(.{ .key = .right, .context = reader, .expected = null });
    try check(.{ .key = .escape, .context = reader, .expected = .dismiss });
    try check(.{ .key = .{ .char = 'h' }, .context = reader, .expected = .dismiss });
    try check(.{ .key = .{ .char = 'q' }, .context = reader, .expected = .dismiss });
    try check(.{ .key = .{ .char = 'j' }, .context = reader, .expected = .{ .move = .down } });
}

test "mailbox switching" {
    const cases = [_]Case{
        .{ .key = .tab, .expected = .next_mailbox },
        .{ .key = .back_tab, .expected = .previous_mailbox },
        .{ .key = .{ .char = ']' }, .expected = .next_mailbox },
        .{ .key = .{ .char = '[' }, .expected = .previous_mailbox },
        .{ .key = .{ .char = '1' }, .expected = .{ .select_mailbox = .inbox } },
        .{ .key = .{ .char = '2' }, .expected = .{ .select_mailbox = .sent } },
        .{ .key = .{ .char = '3' }, .expected = .{ .select_mailbox = .drafts } },
        .{ .key = .{ .char = '4' }, .expected = .{ .select_mailbox = .archive } },
        .{ .key = .{ .char = '5' }, .expected = .{ .select_mailbox = .trash } },
        .{ .key = .{ .char = '6' }, .expected = .{ .select_mailbox = .junk } },
        .{ .key = .{ .char = '7' }, .expected = null },
        .{ .key = .{ .char = '0' }, .expected = null },
    };
    for (cases) |case| try check(case);
}

test "accounts view: movement, select, remove, add, close" {
    const context = Context{ .view = .accounts, .mode = .normal };
    const cases = [_]struct { key: Key, expected: Command }{
        .{ .key = .{ .char = 'j' }, .expected = .{ .accounts_move = .down } },
        .{ .key = .{ .char = 'k' }, .expected = .{ .accounts_move = .up } },
        .{ .key = .{ .char = 'g' }, .expected = .{ .accounts_move = .top } },
        .{ .key = .{ .char = 'G' }, .expected = .{ .accounts_move = .bottom } },
        .{ .key = .{ .char = 'd' }, .expected = .accounts_remove },
        .{ .key = .{ .char = 'n' }, .expected = .accounts_add },
        .{ .key = .{ .char = 'q' }, .expected = .accounts_close },
        .{ .key = .enter, .expected = .accounts_select },
        .{ .key = .escape, .expected = .accounts_close },
        .{ .key = .up, .expected = .{ .accounts_move = .up } },
        .{ .key = .down, .expected = .{ .accounts_move = .down } },
        .{ .key = .home, .expected = .{ .accounts_move = .top } },
        .{ .key = .end, .expected = .{ .accounts_move = .bottom } },
        .{ .key = .{ .ctrl = 'q' }, .expected = .quit },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, translate(case.key, context).?);
    }
    try testing.expect(translate(.{ .char = 'z' }, context) == null);
    try testing.expect(translate(.{ .ctrl = 'd' }, context) == null);
}

test "actions: unread, flag, archive, delete, search, help, refresh" {
    const cases = [_]Case{
        .{ .key = .{ .char = 'u' }, .expected = .toggle_unread },
        .{ .key = .{ .char = 's' }, .expected = .toggle_flag },
        .{ .key = .{ .char = '*' }, .expected = .toggle_flag },
        .{ .key = .{ .char = 'd' }, .expected = .archive_selected },
        .{ .key = .{ .char = '#' }, .expected = .delete_selected },
        .{ .key = .{ .char = 'X' }, .expected = .delete_forever },
        .{ .key = .{ .char = 'E' }, .expected = .empty_trash },
        .{ .key = .delete, .expected = .delete_selected },
        .{ .key = .{ .char = '/' }, .expected = .begin_search },
        .{ .key = .{ .char = '?' }, .expected = .toggle_help },
        .{ .key = .{ .ctrl = 'r' }, .expected = .refresh },
        .{ .key = .{ .char = 'a' }, .expected = .cycle_account },
    };
    for (cases) |case| try check(case);
}

test "help closes on any key, / starts a filter, and Ctrl+C/Ctrl+Q quit" {
    const help: Context = .{ .view = .help };
    try check(.{ .key = .{ .char = 'j' }, .context = help, .expected = .toggle_help });
    try check(.{ .key = .{ .char = 'q' }, .context = help, .expected = .toggle_help });
    try check(.{ .key = .escape, .context = help, .expected = .toggle_help });
    try check(.{ .key = .{ .char = '/' }, .context = help, .expected = .begin_help_search });
    try check(.{ .key = .{ .ctrl = 'c' }, .context = help, .expected = .quit });
    try check(.{ .key = .{ .ctrl = 'q' }, .context = help, .expected = .quit });
}

test "filtering the help overlay: type, delete, apply, cancel" {
    const filtering: Context = .{ .view = .help, .mode = .help_search };
    try check(.{ .key = .{ .char = 'a' }, .context = filtering, .expected = .{ .help_search_char = 'a' } });
    try check(.{ .key = .{ .char = '/' }, .context = filtering, .expected = .{ .help_search_char = '/' } });
    try check(.{ .key = .{ .char = 0xe9 }, .context = filtering, .expected = null });
    try check(.{ .key = .backspace, .context = filtering, .expected = .help_search_backspace });
    try check(.{ .key = .enter, .context = filtering, .expected = .help_search_commit });
    try check(.{ .key = .escape, .context = filtering, .expected = .help_search_cancel });
    try check(.{ .key = .{ .ctrl = 'c' }, .context = filtering, .expected = .quit });
    try check(.{ .key = .{ .ctrl = 'q' }, .context = filtering, .expected = .quit });
    try check(.{ .key = .down, .context = filtering, .expected = null });
    try check(.{ .key = .{ .ctrl = 'd' }, .context = filtering, .expected = null });
}

test "q quits from the list but never from a text field" {
    try check(.{ .key = .{ .char = 'q' }, .expected = .dismiss });
    const search: Context = .{ .mode = .search };
    try check(.{ .key = .{ .char = 'q' }, .context = search, .expected = .{ .search_char = 'q' } });
    const filtering: Context = .{ .view = .help, .mode = .help_search };
    try check(.{ .key = .{ .char = 'q' }, .context = filtering, .expected = .{ .help_search_char = 'q' } });
}

test "search mode types, edits, and commits" {
    const search: Context = .{ .mode = .search };
    const cases = [_]Case{
        .{ .key = .{ .char = 'a' }, .context = search, .expected = .{ .search_char = 'a' } },
        .{ .key = .{ .char = ' ' }, .context = search, .expected = .{ .search_char = ' ' } },
        .{ .key = .{ .char = '~' }, .context = search, .expected = .{ .search_char = '~' } },
        .{ .key = .{ .char = 0xe9 }, .context = search, .expected = null },
        .{ .key = .backspace, .context = search, .expected = .search_backspace },
        .{ .key = .enter, .context = search, .expected = .search_commit },
        .{ .key = .escape, .context = search, .expected = .search_cancel },
        .{ .key = .down, .context = search, .expected = .{ .move = .down } },
        .{ .key = .up, .context = search, .expected = .{ .move = .up } },
        .{ .key = .{ .ctrl = 'c' }, .context = search, .expected = .quit },
        .{ .key = .{ .ctrl = 'd' }, .context = search, .expected = null },
        .{ .key = .{ .char = 'j' }, .context = search, .expected = .{ .search_char = 'j' } },
    };
    for (cases) |case| try check(case);
}

test "c composes and r replies from the list and the reader" {
    try check(.{ .key = .{ .char = 'c' }, .expected = .compose_new });
    try check(.{ .key = .{ .char = 'r' }, .expected = .compose_reply });
    const reader: Context = .{ .view = .reader };
    try check(.{ .key = .{ .char = 'r' }, .context = reader, .expected = .compose_reply });
}

test "compose mode: typing, fields, send, cancel" {
    const writing: Context = .{ .view = .compose };
    try check(.{ .key = .{ .char = 'a' }, .context = writing, .expected = .{ .compose_char = 'a' } });
    try check(.{ .key = .{ .char = 0xe9 }, .context = writing, .expected = .{ .compose_char = 0xe9 } });
    try check(.{ .key = .{ .char = ' ' }, .context = writing, .expected = .{ .compose_char = ' ' } });
    try check(.{ .key = .enter, .context = writing, .expected = .compose_newline });
    try check(.{ .key = .tab, .context = writing, .expected = .compose_next_field });
    try check(.{ .key = .back_tab, .context = writing, .expected = .compose_previous_field });
    try check(.{ .key = .backspace, .context = writing, .expected = .compose_backspace });
    try check(.{ .key = .escape, .context = writing, .expected = .dismiss });
    try check(.{ .key = .{ .ctrl = 's' }, .context = writing, .expected = .compose_send });
    try check(.{ .key = .{ .ctrl = 'u' }, .context = writing, .expected = .compose_clear_field });
    try check(.{ .key = .{ .ctrl = 'c' }, .context = writing, .expected = .quit });
    try check(.{ .key = .{ .ctrl = 'q' }, .context = writing, .expected = .quit });
    try check(.{ .key = .{ .ctrl = 'd' }, .context = writing, .expected = null });
    try check(.{ .key = .left, .context = writing, .expected = null });
    try check(.{ .key = .{ .char = 'j' }, .context = writing, .expected = .{ .compose_char = 'j' } });
}

test "mouse and unknown keys are resolved elsewhere or ignored" {
    const mouse: Key = .{ .mouse = .{ .kind = .press, .button = .left, .x = 0, .y = 0 } };
    try check(.{ .key = mouse, .expected = null });
    try check(.{ .key = .unknown, .expected = null });
    try check(.{ .key = .insert, .expected = null });
    try check(.{ .key = .backspace, .expected = null });
}
