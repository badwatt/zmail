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
    if (context.view == .help) {
        return switch (key) {
            .ctrl => |letter| if (letter == 'c') .quit else .toggle_help,
            else => .toggle_help,
        };
    }
    return normal_key(key, context.view);
}

fn normal_key(key: Key, view: View) ?Command {
    return switch (key) {
        .char => |codepoint| char_command(codepoint),
        .enter => .open_selected,
        .tab => .next_mailbox,
        .back_tab => .previous_mailbox,
        .up => .{ .move = .up },
        .down => .{ .move = .down },
        .home => .{ .move = .top },
        .end => .{ .move = .bottom },
        .page_up => .{ .move = .page_up },
        .page_down => .{ .move = .page_down },
        .left => if (view == .list) null else .dismiss,
        .right => if (view == .list) .open_selected else null,
        .escape => .dismiss,
        .backspace => null,
        .delete => .delete_selected,
        .insert, .unknown, .mouse => null,
        .ctrl => |letter| ctrl_command(letter),
    };
}

fn char_command(codepoint: u21) ?Command {
    return switch (codepoint) {
        'j' => .{ .move = .down },
        'k' => .{ .move = .up },
        'g' => .{ .move = .top },
        'G' => .{ .move = .bottom },
        'l', 'o' => .open_selected,
        'h', 'q' => .dismiss,
        'u' => .toggle_unread,
        's', '*' => .toggle_flag,
        'd' => .archive_selected,
        '#' => .delete_selected,
        '/' => .begin_search,
        '?' => .toggle_help,
        'R' => .refresh,
        '[' => .previous_mailbox,
        ']' => .next_mailbox,
        '1'...'6' => .{ .select_mailbox = Mailbox.from_index(@intCast(codepoint - '1')) },
        else => null,
    };
}

fn ctrl_command(letter: u8) ?Command {
    return switch (letter) {
        'c' => .quit,
        'd' => .{ .move = .half_page_down },
        'u' => .{ .move = .half_page_up },
        'f' => .{ .move = .page_down },
        'b' => .{ .move = .page_up },
        'n' => .{ .move = .down },
        'p' => .{ .move = .up },
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
        .{ .key = .{ .ctrl = 'q' }, .expected = null },
    };
    for (cases) |case| try check(case);
}

test "opening and dismissing" {
    const cases = [_]Case{
        .{ .key = .enter, .expected = .open_selected },
        .{ .key = .{ .char = 'l' }, .expected = .open_selected },
        .{ .key = .{ .char = 'o' }, .expected = .open_selected },
        .{ .key = .right, .expected = .open_selected },
        .{ .key = .escape, .expected = .dismiss },
        .{ .key = .{ .char = 'q' }, .expected = .dismiss },
        .{ .key = .{ .char = 'h' }, .expected = .dismiss },
        .{ .key = .{ .char = 'x' }, .expected = null },
    };
    for (cases) |case| try check(case);
}

test "in the reader, left goes back and right does nothing" {
    const reader: Context = .{ .view = .reader };
    try check(.{ .key = .left, .context = reader, .expected = .dismiss });
    try check(.{ .key = .right, .context = reader, .expected = null });
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

test "actions: unread, flag, archive, delete, search, help, refresh" {
    const cases = [_]Case{
        .{ .key = .{ .char = 'u' }, .expected = .toggle_unread },
        .{ .key = .{ .char = 's' }, .expected = .toggle_flag },
        .{ .key = .{ .char = '*' }, .expected = .toggle_flag },
        .{ .key = .{ .char = 'd' }, .expected = .archive_selected },
        .{ .key = .{ .char = '#' }, .expected = .delete_selected },
        .{ .key = .delete, .expected = .delete_selected },
        .{ .key = .{ .char = '/' }, .expected = .begin_search },
        .{ .key = .{ .char = '?' }, .expected = .toggle_help },
        .{ .key = .{ .char = 'R' }, .expected = .refresh },
    };
    for (cases) |case| try check(case);
}

test "help closes on any key, but Ctrl+C still quits" {
    const help: Context = .{ .view = .help };
    try check(.{ .key = .{ .char = 'j' }, .context = help, .expected = .toggle_help });
    try check(.{ .key = .escape, .context = help, .expected = .toggle_help });
    try check(.{ .key = .{ .ctrl = 'c' }, .context = help, .expected = .quit });
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

test "mouse and unknown keys are resolved elsewhere or ignored" {
    const mouse: Key = .{ .mouse = .{ .kind = .press, .button = .left, .x = 0, .y = 0 } };
    try check(.{ .key = mouse, .expected = null });
    try check(.{ .key = .unknown, .expected = null });
    try check(.{ .key = .insert, .expected = null });
    try check(.{ .key = .backspace, .expected = null });
}
