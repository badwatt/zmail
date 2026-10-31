//! State to pixels: a pure function from application state to a cell buffer.
//!
//! No I/O, no terminal: tests compare rows of the buffer, and the same layout
//! can later be painted by a GUI. Nothing here reads global state, the clock, or
//! the environment; `now` and the viewport come in as inputs.

const std = @import("std");
const core = @import("core");

const screen = @import("screen.zig");
const theme_mod = @import("theme.zig");
const layout_mod = @import("layout.zig");
const wrap = @import("wrap.zig");

const Screen = screen.Screen;
const Style = screen.Style;
const Rect = screen.Rect;
const Theme = theme_mod.Theme;
const State = core.state.State;
const Store = core.store.Store;
const Mailbox = core.mailbox.Mailbox;

pub const Inputs = struct {
    state: *const State,
    store: *const Store,
    theme: *const Theme,
    /// Plain-text body of the open message, if any.
    body: []const u8 = "",
    /// Body wrapped to the reader width. Null means "not loaded yet".
    wrapped: ?*const wrap.Wrapped = null,
    now_unix: i64 = 0,
    columns: u16 = 80,
    rows: u16 = 24,
};

pub fn frame(inputs: Inputs, out: *Screen) void {
    out.resize(inputs.columns, inputs.rows);
    const lay = layout_mod.Layout.compute(out.columns, out.rows);
    if (lay.too_small) {
        render_too_small(inputs, out);
        return;
    }

    switch (inputs.state.view) {
        .list => render_list(inputs, lay, out),
        .reader => render_reader(inputs, lay, out),
        .help => {
            switch (inputs.state.help_return) {
                .reader => render_reader(inputs, lay, out),
                else => render_list(inputs, lay, out),
            }
            render_help(inputs, lay, out);
        },
    }
    render_footer(inputs, lay, out);
}

fn render_list(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    if (inputs.state.mode == .search) {
        render_search_bar(inputs, lay, out);
    } else {
        render_tabs(inputs, lay, out);
    }
    out.hline(0, lay.top_rule_y, lay.columns, '─', inputs.theme.border);
    render_rows(inputs, lay, out);
    out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
}

fn render_tabs(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const name = core.meta.name;
    _ = out.put_text(1, lay.header_y, name, 6, inputs.theme.accent.with_bold());

    if (!lay.show_tabs) {
        // Narrow terminal: one tab, plus the count. Tab/Shift+Tab still switch.
        const x: u16 = 1 + screen.text_columns(name) + 2;
        _ = out.put_text(x, lay.header_y, inputs.state.mailbox.title(), 16, inputs.theme.accent.with_bold());
        const unread = inputs.store.unread_in(inputs.state.mailbox);
        if (unread > 0) {
            var buffer: [4]u8 = undefined;
            const count = std.fmt.bufPrint(&buffer, "{d}", .{unread}) catch "";
            put_right(out, x + 16, lay.header_y, count, inputs.theme.accent);
        }
        return;
    }

    for (Mailbox.all) |mailbox| {
        const x = lay.tab_x(mailbox);
        const active = mailbox == inputs.state.mailbox;
        const title_style = if (active) inputs.theme.accent.with_bold() else inputs.theme.dim;
        _ = out.put_text(x, lay.header_y, mailbox.title(), layout_mod.tab_width - 4, title_style);

        const unread = inputs.store.unread_in(mailbox);
        if (unread == 0) continue;
        var buffer: [4]u8 = undefined;
        const count = std.fmt.bufPrint(&buffer, "{d}", .{@min(unread, 999)}) catch "";
        const count_style = if (active) title_style else inputs.theme.accent;
        put_right(out, x + layout_mod.tab_width - 2, lay.header_y, count, count_style);
    }
}

fn render_search_bar(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const y = lay.header_y;
    _ = out.put_text(1, y, "/", 1, inputs.theme.accent.with_bold());

    const draft = inputs.state.draft.slice();
    const x = @as(u16, 3) + out.put_text(3, y, draft, lay.columns - 10, inputs.theme.text);
    out.put(x, y, ' ', inputs.theme.text.with_reverse());

    var buffer: [24]u8 = undefined;
    const label = if (inputs.state.visible_len == 1)
        std.fmt.bufPrint(&buffer, "1 match", .{}) catch ""
    else
        std.fmt.bufPrint(&buffer, "{d} matches", .{inputs.state.visible_len}) catch "";
    put_right(out, lay.columns - 2, y, label, inputs.theme.dim);
}

fn render_rows(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    if (inputs.state.visible_len == 0) {
        render_empty(inputs, lay, out);
        return;
    }

    const rows = inputs.state.row_count();
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        const visible_index = inputs.state.offset + index;
        const message = inputs.store.at_const(inputs.state.visible[visible_index]);
        render_row(
            inputs,
            lay,
            message,
            lay.body_y + index,
            visible_index == inputs.state.cursor,
            out,
        );
    }
}

fn render_row(inputs: Inputs, lay: layout_mod.Layout, message: *const core.message.Message, y: u16, selected: bool, out: *Screen) void {
    const theme = inputs.theme;
    if (selected) {
        out.fill_rect(.{ .x = 0, .y = y, .width = lay.columns, .height = 1 }, ' ', theme.selection);
    }

    const unread = message.is_unread();
    if (unread) {
        out.put(lay.dot_x, y, '●', selected_style(theme.accent, theme, selected));
    }

    const sender_style = if (unread) theme.text else theme.dim;
    _ = out.put_text(
        lay.sender_x,
        y,
        message.from.label(),
        lay.sender_width,
        selected_style(sender_style, theme, selected),
    );

    const subject_style = if (unread) theme.text.with_bold() else theme.text;
    out.put_text_truncated(
        lay.subject_x,
        y,
        message.subject.slice(),
        lay.subject_width,
        selected_style(subject_style, theme, selected),
    );

    var stamp_buffer: [8]u8 = undefined;
    const stamp = core.time.relative(&stamp_buffer, inputs.now_unix, message.timestamp_unix);
    put_right(out, lay.date_x + lay.date_width - 1, y, stamp, selected_style(theme.dim, theme, selected));

    if (message.is_flagged()) {
        out.put(lay.flag_x, y, '★', selected_style(theme.flagged, theme, selected));
    }
}

fn selected_style(style: Style, theme: *const Theme, selected: bool) Style {
    if (!selected) return style;
    var result = style;
    result.bg = theme.selection.bg;
    if (theme.selection.attrs.reverse) result.attrs.reverse = true;
    return result;
}

fn render_empty(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    var buffer: [96]u8 = undefined;
    const text = if (inputs.state.query.is_empty())
        std.fmt.bufPrint(&buffer, "Nothing in {s}", .{inputs.state.mailbox.title()}) catch ""
    else
        std.fmt.bufPrint(&buffer, "No matches for \"{s}\"", .{inputs.state.query.slice()}) catch "";

    const y = lay.body_y + lay.list_rows / 2;
    put_centered(out, y, text, inputs.theme.dim);
    if (y + 2 < lay.bottom_rule_y) {
        put_centered(out, y + 2, "Press ? for keys", inputs.theme.dim);
    }
}

fn render_reader(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const message = inputs.store.get_const(inputs.state.opened) orelse {
        put_centered(out, lay.reader_body_y + lay.reader_rows / 2, "Message unavailable", inputs.theme.alert);
        out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
        return;
    };

    out.put_text_truncated(
        1,
        lay.reader_subject_y,
        message.subject.slice(),
        lay.columns - 2,
        inputs.theme.text.with_bold(),
    );
    render_reader_meta(inputs, lay, message, out);
    out.hline(0, lay.reader_rule_y, lay.columns, '─', inputs.theme.border);
    render_body(inputs, lay, out);
    out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
}

fn render_reader_meta(inputs: Inputs, lay: layout_mod.Layout, message: *const core.message.Message, out: *Screen) void {
    var date_buffer: [16]u8 = undefined;
    const date = core.time.full_date(&date_buffer, message.timestamp_unix);
    var size_buffer: [16]u8 = undefined;
    const size = size_text(&size_buffer, message.size_bytes);

    var buffer: [160]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("From {s}  ·  {s}  ·  {s}", .{ message.from.label(), date, size }) catch {};
    _ = out.put_text(1, lay.reader_meta_y, writer.buffered(), lay.columns - 2, inputs.theme.dim);
}

fn render_body(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const wrapped = inputs.wrapped orelse {
        _ = out.put_text(1, lay.reader_body_y, "Loading...", lay.columns - 2, inputs.theme.dim);
        return;
    };
    if (wrapped.len == 0) {
        _ = out.put_text(1, lay.reader_body_y, "This message has no text body.", lay.columns - 2, inputs.theme.dim);
        return;
    }

    var row: u16 = 0;
    while (row < lay.reader_rows) : (row += 1) {
        const line_index = inputs.state.reader_scroll + row;
        if (line_index >= wrapped.len) break;
        _ = out.put_text(
            1,
            lay.reader_body_y + row,
            wrapped.at(line_index, inputs.body),
            lay.columns - 2,
            inputs.theme.text,
        );
    }
}

const Hint = struct {
    keys: []const u8,
    action: []const u8,
};

const list_hints = [_]Hint{
    .{ .keys = "j/k", .action = "move" },
    .{ .keys = "Enter", .action = "open" },
    .{ .keys = "/", .action = "search" },
    .{ .keys = "d", .action = "archive" },
    .{ .keys = "?", .action = "help" },
};

const reader_hints = [_]Hint{
    .{ .keys = "j/k", .action = "scroll" },
    .{ .keys = "Space", .action = "page" },
    .{ .keys = "q", .action = "back" },
    .{ .keys = "u", .action = "unread" },
    .{ .keys = "d", .action = "archive" },
};

const search_hints = [_]Hint{
    .{ .keys = "type", .action = "filter" },
    .{ .keys = "Enter", .action = "apply" },
    .{ .keys = "Esc", .action = "cancel" },
};

const help_hints = [_]Hint{
    .{ .keys = "any key", .action = "close help" },
};

fn hints_for(state: *const State) []const Hint {
    if (state.mode == .search) return &search_hints;
    return switch (state.view) {
        .list => &list_hints,
        .reader => &reader_hints,
        .help => &help_hints,
    };
}

fn render_footer(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const y = lay.footer_y;
    var right_buffer: [16]u8 = undefined;
    const right = position_text(inputs.state, &right_buffer);
    const right_width = screen.text_columns(right);
    const limit = lay.columns -| (right_width + 3);
    put_right(out, lay.columns - 2, y, right, inputs.theme.dim);

    if (!inputs.state.status.is_empty()) {
        const style = if (inputs.state.status_alert) inputs.theme.alert else inputs.theme.accent;
        out.put_text_truncated(1, y, inputs.state.status.slice(), limit -| 1, style);
        return;
    }
    render_hints(hints_for(inputs.state), y, limit, inputs.theme, out);
}

fn position_text(state: *const State, buffer: []u8) []const u8 {
    if (state.view == .reader) {
        return std.fmt.bufPrint(buffer, "{d}%", .{reader_percent(state)}) catch "";
    }
    return std.fmt.bufPrint(buffer, "{d}/{d}", .{ list_position(state), state.visible_len }) catch "";
}

fn list_position(state: *const State) u32 {
    if (state.visible_len == 0) return 0;
    return state.cursor + 1;
}

fn reader_percent(state: *const State) u32 {
    if (state.body_rows == 0) return 0;
    if (state.body_rows <= state.reader_rows) return 100;
    const last_visible = state.reader_scroll + state.reader_rows;
    const percent = last_visible * 100 / state.body_rows;
    return @min(100, percent);
}

fn render_hints(hints: []const Hint, y: u16, limit: u16, theme: *const Theme, out: *Screen) void {
    var x: u16 = 1;
    for (hints, 0..) |hint, index| {
        if (index > 0) {
            const separator = "  ·  ";
            const separator_width = screen.text_columns(separator);
            if (x + separator_width >= limit) break;
            _ = out.put_text(x, y, separator, limit - x, theme.dim);
            x += separator_width;
        }

        const keys_width = screen.text_columns(hint.keys);
        const action_width = screen.text_columns(hint.action);
        if (x + keys_width + 1 + action_width > limit) break;

        _ = out.put_text(x, y, hint.keys, keys_width, theme.accent);
        x += keys_width;
        _ = out.put_text(x, y, " ", 1, theme.dim);
        x += 1;
        _ = out.put_text(x, y, hint.action, action_width, theme.dim);
        x += action_width;
    }
}

const help_rows = [_]Hint{
    .{ .keys = "j / Down", .action = "move down" },
    .{ .keys = "k / Up", .action = "move up" },
    .{ .keys = "g / Home", .action = "first row" },
    .{ .keys = "G / End", .action = "last row" },
    .{ .keys = "Ctrl+D / U", .action = "half page" },
    .{ .keys = "PageDown / Up", .action = "page" },
    .{ .keys = "Enter / l / o", .action = "open message" },
    .{ .keys = "h / q / Esc", .action = "back, or quit" },
    .{ .keys = "u", .action = "read / unread" },
    .{ .keys = "s / *", .action = "star" },
    .{ .keys = "d", .action = "archive" },
    .{ .keys = "#", .action = "move to trash" },
    .{ .keys = "/", .action = "search" },
    .{ .keys = "Tab / [ ]", .action = "next mailbox" },
    .{ .keys = "1 - 6", .action = "jump to mailbox" },
    .{ .keys = "R", .action = "refresh" },
    .{ .keys = "Ctrl+C", .action = "quit" },
};

fn render_help(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const card_width: u16 = @min(64, lay.columns - 4);
    const card_height: u16 = @min(@as(u16, help_rows.len + 4), lay.rows - 2);
    const rect = Rect{
        .x = (lay.columns - card_width) / 2,
        .y = (lay.rows - card_height) / 2,
        .width = card_width,
        .height = card_height,
    };

    out.fill_rect(rect, ' ', inputs.theme.text);
    out.box(rect, inputs.theme.border);
    _ = out.put_text(rect.x + 2, rect.y, " Keys ", card_width - 4, inputs.theme.accent.with_bold());

    const key_width: u16 = 16;
    var row: u16 = 0;
    while (row < help_rows.len) : (row += 1) {
        const y = rect.y + 2 + row;
        if (y >= rect.bottom() - 1) break;
        const entry = help_rows[row];
        _ = out.put_text(rect.x + 2, y, entry.keys, key_width, inputs.theme.accent);
        _ = out.put_text(rect.x + 2 + key_width, y, entry.action, card_width -| (key_width + 4), inputs.theme.text);
    }
    _ = out.put_text(rect.x + 2, rect.bottom() - 1, " any key closes ", card_width - 4, inputs.theme.dim);
}

fn render_too_small(inputs: Inputs, out: *Screen) void {
    var buffer: [48]u8 = undefined;
    const requirement = std.fmt.bufPrint(
        &buffer,
        "Need at least {d}x{d}",
        .{ layout_mod.min_columns, layout_mod.min_rows },
    ) catch "";

    const middle = out.rows / 2;
    put_centered(out, middle -| 1, "Terminal too small", inputs.theme.accent.with_bold());
    put_centered(out, middle + 1, requirement, inputs.theme.dim);
}

fn put_centered(out: *Screen, y: u16, text: []const u8, style: Style) void {
    const width = screen.text_columns(text);
    const x = (out.columns -| width) / 2;
    _ = out.put_text(x, y, text, out.columns -| x, style);
}

/// Right-aligns `text` so that its last cell lands on `x_right`.
fn put_right(out: *Screen, x_right: u16, y: u16, text: []const u8, style: Style) void {
    const width = screen.text_columns(text);
    const x = x_right + 1 -| width;
    _ = out.put_text(x, y, text, x_right + 1 - x, style);
}

/// "512 B", "4.0 KiB", "1.4 MiB".
pub fn size_text(buffer: []u8, bytes: u32) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    const kib = bytes / 1024;
    const kib_tenths = (bytes % 1024) * 10 / 1024;
    if (kib < 1024) return std.fmt.bufPrint(buffer, "{d}.{d} KiB", .{ kib, kib_tenths }) catch "";
    const mib = kib / 1024;
    const mib_tenths = (kib % 1024) * 10 / 1024;
    return std.fmt.bufPrint(buffer, "{d}.{d} MiB", .{ mib, mib_tenths }) catch "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Text = core.text.Text;
const MessageId = core.id.MessageId;

fn message_with(id: u64, from: []const u8, subject: []const u8, unread: bool, flagged: bool, timestamp_unix: i64) !core.message.Message {
    var message = core.message.Message{
        .id = MessageId.from_int(id),
        .from = try core.address.Address.init(from),
        .timestamp_unix = timestamp_unix,
        .size_bytes = 4096,
        .flags = .{ .unread = unread, .flagged = flagged },
    };
    message.subject.set(subject);
    message.snippet.set("snippet");
    return message;
}

const Fixture = struct {
    store: Store,
    state: State,
    theme: theme_mod.Theme,
    body: [512]u8 = undefined,
    body_len: u32 = 0,
    wrapped: wrap.Wrapped = .{},
    wrapped_ready: bool = false,

    fn deinit(self: *Fixture) void {
        self.store.deinit(testing.allocator);
    }

    fn inputs(self: *Fixture, columns: u16, rows: u16) Inputs {
        return .{
            .state = &self.state,
            .store = &self.store,
            .theme = &self.theme,
            .body = self.body[0..self.body_len],
            .wrapped = if (self.wrapped_ready) &self.wrapped else null,
            .now_unix = 1_700_000_000,
            .columns = columns,
            .rows = rows,
        };
    }
};

fn fixture() !Fixture {
    var store = try Store.init(testing.allocator, 8);
    var state: State = .{ .list_rows = 20 };
    const messages = [_]struct { id: u64, from: []const u8, subject: []const u8, unread: bool, flagged: bool, ts: i64 }{
        .{ .id = 1, .from = "Alice Rivera <alice@rivera.dev>", .subject = "Re: design tokens review", .unread = true, .flagged = false, .ts = 1_699_999_905 },
        .{ .id = 2, .from = "Bob Chen <bob@chenworks.io>", .subject = "Zig 0.17 release notes", .unread = true, .flagged = true, .ts = 1_699_999_160 },
        .{ .id = 3, .from = "GitHub <notifications@github.com>", .subject = "A short subject", .unread = false, .flagged = false, .ts = 1_699_992_800 },
    };
    for (messages) |entry| {
        var message = try message_with(entry.id, entry.from, entry.subject, entry.unread, entry.flagged, entry.ts);
        try store.insert(&message);
    }
    state.rebuild(&store);
    return .{ .store = store, .state = state, .theme = theme_mod.Theme.dark() };
}

fn row_contains(out: *const Screen, y: u16, needle: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const text = out.row_text(y, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, needle) != null);
}

test "frame draws the app name, tabs with unread counts, and mail rows" {
    var f = try fixture();
    defer f.deinit();
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 0, "amail");
    try row_contains(&out, 0, "Inbox");
    try row_contains(&out, 0, "2");
    try row_contains(&out, 2, "Alice Rivera");
    try row_contains(&out, 2, "Re: design tokens review");
    try row_contains(&out, 3, "Bob Chen");
    try row_contains(&out, 4, "GitHub");
}

test "frame marks unread rows with a dot and flagged rows with a star" {
    var f = try fixture();
    defer f.deinit();
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try testing.expectEqual(@as(u21, '●'), out.cells[2][1].ch);
    try testing.expectEqual(@as(u21, ' '), out.cells[4][1].ch);
    try testing.expectEqual(@as(u21, '★'), out.cells[3][99].ch);
}

test "frame paints the selected row with the selection background" {
    var f = try fixture();
    defer f.deinit();
    f.state.cursor = 1;
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try testing.expectEqual(screen.Color{ .ansi256 = 237 }, out.cells[3][50].style.bg);
    try testing.expectEqual(screen.Color.default, out.cells[2][50].style.bg);
}

test "frame shows a friendly empty state and the active mailbox" {
    var f = try fixture();
    defer f.deinit();
    f.state.mailbox = .junk;
    f.state.rebuild(&f.store);
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 11, "Nothing in Junk");
    try row_contains(&out, 13, "Press ? for keys");
}

test "frame explains an empty search with the query" {
    var f = try fixture();
    defer f.deinit();
    f.state.query.set("nomatch");
    f.state.rebuild(&f.store);
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 11, "No matches for \"nomatch\"");
}

test "frame shows a singular match count" {
    var f = try fixture();
    defer f.deinit();
    f.state.mode = .search;
    f.state.draft.set("alice");
    f.state.query.set("alice");
    f.state.rebuild(&f.store);
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 0, "1 match");
}

test "frame renders the search bar with the draft and a cursor" {
    var f = try fixture();
    defer f.deinit();
    f.state.mode = .search;
    f.state.draft.set("inv");
    f.state.query.set("inv");
    f.state.rebuild(&f.store);
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 0, "/ inv");
    try testing.expect(out.cells[0][6].style.attrs.reverse);
}

test "frame renders the reader: subject, metadata, and body" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .open_selected);
    const text: []const u8 = std.fmt.bufPrint(&f.body, "First line\nSecond line\nThird line", .{}) catch "";
    f.body_len = @intCast(text.len);
    wrap.wrap(f.body[0..f.body_len], 60, &f.wrapped);
    f.wrapped_ready = true;

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 0, "Re: design tokens review");
    try row_contains(&out, 1, "From Alice Rivera");
    try row_contains(&out, 1, "14 Nov 2023");
    try row_contains(&out, 3, "First line");
    try row_contains(&out, 4, "Second line");
}

test "frame scrolls the reader body" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .open_selected);
    const text: []const u8 = std.fmt.bufPrint(&f.body, "one\ntwo\nthree\nfour", .{}) catch "";
    f.body_len = @intCast(text.len);
    wrap.wrap(f.body[0..f.body_len], 60, &f.wrapped);
    f.wrapped_ready = true;
    f.state.reader_scroll = 2;

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 3, "three");
    try row_contains(&out, 4, "four");
}

test "frame says so when the body is not loaded yet or empty" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .open_selected);

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 3, "Loading...");

    f.wrapped = .{};
    f.wrapped_ready = true;
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 3, "no text body");
}

test "frame reports an unavailable message instead of crashing" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .reader;
    f.state.opened = MessageId.from_int(99);

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 12, "Message unavailable");
}

test "frame draws the help overlay over the current view" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .toggle_help);

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 1, "Keys");
    try row_contains(&out, 3, "move down");
    try row_contains(&out, 20, "any key closes");
}

test "frame keeps the reader under the help overlay" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .open_selected);
    _ = core.update.apply(&f.state, &f.store, .toggle_help);
    try testing.expectEqual(core.state.View.help, f.state.view);
    try testing.expectEqual(core.state.View.reader, f.state.help_return);

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    // The reader header is still drawn to the left of the card.
    try row_contains(&out, 0, "Re: design");
    try row_contains(&out, 1, "Keys");
}

test "frame asks for a bigger terminal below the minimum size" {
    var f = try fixture();
    defer f.deinit();
    var out = Screen.init(30, 8);
    frame(f.inputs(30, 8), &out);

    try row_contains(&out, 3, "Terminal too small");
    try row_contains(&out, 5, "Need at least 40x10");
}

test "frame shows contextual hints and the list position" {
    var f = try fixture();
    defer f.deinit();
    f.state.cursor = 1;
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 23, "j/k");
    try row_contains(&out, 23, "move");
    try row_contains(&out, 23, "2/3");
}

test "frame shows reader hints and a scroll percentage" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .open_selected);
    f.state.reader_rows = 10;
    f.state.body_rows = 20;
    f.state.reader_scroll = 5;

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 23, "scroll");
    try row_contains(&out, 23, "75%");
}

test "frame shows search hints while typing" {
    var f = try fixture();
    defer f.deinit();
    f.state.mode = .search;
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 23, "filter");
    try row_contains(&out, 23, "cancel");
}

test "a status message replaces the hints, with an alert style for errors" {
    var f = try fixture();
    defer f.deinit();

    f.state.set_status("Archived", .{});
    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 23, "Archived");

    f.state.set_alert("Could not reach the server", .{});
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 23, "Could not reach the server");
    try testing.expectEqual(screen.Color{ .ansi256 = 167 }, f.theme.alert.fg);
}

test "a narrow terminal keeps one mailbox title and hides tabs" {
    var f = try fixture();
    defer f.deinit();
    var out = Screen.init(60, 24);
    frame(f.inputs(60, 24), &out);

    try row_contains(&out, 0, "amail");
    try row_contains(&out, 0, "Inbox");
    try row_contains(&out, 0, "2");
}

test "monochrome rendering never emits color codes" {
    var f = try fixture();
    defer f.deinit();
    f.theme = theme_mod.Theme.mono();
    var out = Screen.init(80, 24);
    frame(f.inputs(80, 24), &out);

    var buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try out.write_frame(&writer, f.theme.colored);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;5") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "48;5") == null);
}

test "size_text covers bytes, kibibytes, and mebibytes" {
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("512 B", size_text(&buffer, 512));
    try testing.expectEqualStrings("4.0 KiB", size_text(&buffer, 4096));
    try testing.expectEqualStrings("1.4 MiB", size_text(&buffer, 1_500_000));
}
