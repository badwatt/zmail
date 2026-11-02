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
const selection = @import("selection.zig");
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
    /// Links in `body`, as byte ranges: one scan for the whole message, so a
    /// URL split by the wrapper is still one link.
    links: []const core.links.Link = &.{},
    /// The link the pointer is over, if any: lit up so a click is not a guess.
    hovered: ?core.links.Link = null,
    /// What the mouse has covered so far, shown while it is being dragged.
    selection: ?selection.Selection = null,
    /// Which wrapped line is being drawn, so the selection can be placed.
    line_index: ?u32 = null,
    /// What kind of line each rendered HTML line is: headings, quotes, bullets.
    kinds: []const core.html.Kind = &.{},
    /// Rows hidden behind a picture: the reader leaves them empty so the image
    /// is not drawn over text.
    cover: []const u8 = &.{},
    now_unix: i64 = 0,
    columns: u16 = 80,
    rows: u16 = 24,
};

/// One line for renaming an account: the label, and nothing else changes.
pub fn rename_prompt(out: *Screen, theme: Theme, label: []const u8) void {
    out.clear();
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "Account name: {s}", .{label}) catch "Account name:";
    _ = out.put_text(1, out.rows / 2, text, out.columns -| 2, theme.text);
    out.put(1 + screen.text_columns(text), out.rows / 2, ' ', theme.text.with_reverse());
    _ = out.put_text(1, out.rows -| 1, "Enter rename · Esc cancel · Ctrl+U clear", out.columns -| 2, theme.dim);
}

/// The account form: every field on one card, the active one marked. Drawn by
/// the same renderer as the rest of the app — no second full-screen program.
pub fn settings(
    setup: *const core.setup.Setup,
    field: anytype,
    editing: bool,
    theme: Theme,
    out: *Screen,
) void {
    out.clear();

    const card_width: u16 = @min(66, out.columns -| 4);
    // Only the rows that make sense right now: no password with OAuth, no
    // client id unless Advanced is open.
    var visible: [10]u8 = undefined;
    var visible_count: u8 = 0;
    for (0..10) |candidate| {
        const index: u8 = @intCast(candidate);
        if (!setup.field_visible(index)) continue;
        visible[visible_count] = index;
        visible_count += 1;
    }
    const rows: u16 = visible_count;
    const card_height: u16 = rows + 6; // title, blanks, fields, problem
    const rect = Rect{
        .x = (out.columns -| card_width) / 2,
        .y = (out.rows -| card_height) / 2,
        .width = card_width,
        .height = card_height,
    };

    out.fill_rect(rect, ' ', theme.text);
    out.box(rect, theme.border);
    _ = out.put_text(rect.x + 2, rect.y, if (editing) " Edit account " else " New account ", card_width -| 4, theme.accent.with_bold());

    const labels = [_][]const u8{
        "Address",
        "IMAP server",
        "IMAP port",
        "SMTP server",
        "SMTP port",
        "Sign in",
        "Password",
        "Advanced",
        "Username",
        "Client ID",
    };

    var row: u8 = 0;
    while (row < rows) : (row += 1) {
        const index = visible[row];
        const y = rect.y + 2 + row;
        const active = index == @backingInt(field);
        if (active) {
            out.fill_rect(.{ .x = rect.x + 1, .y = y, .width = rect.width - 2, .height = 1 }, ' ', theme.selection);
            out.put(rect.x + 1, y, '▌', theme.accent);
        }

        const shown = switch (index) {
            7 => if (setup.show_advanced) "Advanced ▾" else "Advanced ▸",
            else => labels[index],
        };
        _ = out.put_text(rect.x + 3, y, shown, 13, if (active) theme.accent else theme.dim);

        var masked: [core.limits.secret_max]u8 = @splat('*');
        const raw = switch (index) {
            5 => if (setup.oauth) "oauth" else "password",
            7 => if (setup.show_advanced) "open" else "",
            9 => setup.oauth_client_id.slice(),
            else => field_value(setup, index),
        };
        const value = if (index == 6) masked[0..@min(raw.len, 32)] else raw;
        const style = if (active) theme.text.with_bold() else theme.text;
        const written = out.put_text(rect.x + 17, y, value, rect.width -| 19, style);
        if (active) out.put(rect.x + 17 + written, y, ' ', theme.text.with_reverse());
    }

    const hint_y = rect.y + rect.height - 2;
    if (!setup.problem.is_empty()) {
        _ = out.put_text(rect.x + 3, hint_y, setup.problem.slice(), rect.width -| 4, theme.alert);
    } else if (@backingInt(field) == rows - 1) {
        _ = out.put_text(rect.x + 3, hint_y, "Enter saves · Ctrl+S also saves", rect.width -| 4, theme.accent);
    } else {
        _ = out.put_text(rect.x + 3, hint_y, "Tab moves · space toggles · Ctrl+S saves · Esc closes", rect.width -| 4, theme.dim);
    }

    const hints = [_]Hint{
        .{ .keys = "Tab", .action = "next field" },
        .{ .keys = "Ctrl+S", .action = "save" },
        .{ .keys = "Esc", .action = "cancel" },
    };
    render_hints(&hints, out.rows -| 1, out.columns -| 2, &theme, out);
}

fn field_value(setup: *const core.setup.Setup, index: u8) []const u8 {
    return switch (index) {
        0 => setup.address.slice(),
        1 => setup.imap_host.slice(),
        2 => setup.imap_port.slice(),
        3 => setup.smtp_host.slice(),
        4 => setup.smtp_port.slice(),
        8 => setup.username_or_address(),
        else => setup.password.expose(),
    };
}

pub fn frame(inputs: Inputs, out: *Screen) void {
    out.resize(inputs.columns, inputs.rows);
    // Renderers draw what they need; anything else must not survive from the
    // previous view. The flush still compares rows, so this costs nothing on
    // the wire.
    out.clear();
    const lay = layout_mod.Layout.compute(out.columns, out.rows, inputs.state.accounts.max_label());
    if (lay.too_small) {
        render_too_small(inputs, out);
        return;
    }
    if (inputs.state.booting) {
        render_splash(inputs, out);
        return;
    }

    switch (inputs.state.view) {
        .list => render_list(inputs, lay, out),
        .reader => render_reader(inputs, lay, out),
        .help => {
            switch (inputs.state.help_return) {
                .reader => render_reader(inputs, lay, out),
                .compose => render_compose(inputs, lay, out),
                else => render_list(inputs, lay, out),
            }
            render_help(inputs, lay, out);
        },
        .compose => render_compose(inputs, lay, out),
        .accounts => {
            render_list(inputs, lay, out);
            render_accounts(inputs, lay, out);
        },
    }
    render_footer(inputs, lay, out);
}

/// The first network load can take a second: say so, beautifully, instead of
/// showing an empty list. Cached mail never reaches this path.
const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// The welcome screen: a block wordmark, a live spinner, and what is happening.
/// It stays up while the first load runs in the background, so it breathes.
fn render_splash(inputs: Inputs, out: *Screen) void {
    out.clear();
    const theme = inputs.theme;
    const middle = out.rows / 2;

    const wordmark = [_][]const u8{
        "              ▄▀█ █▀▄▀█ ▄▀█ █ █              ",
        "              █▀█ █ ▀ █ █▀█ █ █              ",
    };
    for (wordmark, 0..) |line, index| {
        put_centered(out, (middle -| 3) + @as(u16, @intCast(index)), line, theme.accent.with_bold());
    }

    put_centered(out, middle -| 1, "the quiet terminal mail client", theme.dim.with_dim());
    put_centered(out, middle, "──────────────────────────────", theme.border);

    var label_buffer: [96]u8 = undefined;
    const spinner = spinner_frames[inputs.state.spinner % spinner_frames.len];
    const labels = account_labels(inputs.state, &label_buffer);
    var line_buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buffer,
        "{s}  connecting to {s}",
        .{ spinner, labels },
    ) catch "connecting";
    put_centered(out, middle +| 2, line, theme.accent);

    if (inputs.state.accounts.len == 1) {
        var address_buffer: [core.limits.address_max]u8 = undefined;
        const address = inputs.state.accounts.items[0].address.addr_spec(&address_buffer);
        if (address.len > 0) put_centered(out, middle +| 3, address, theme.dim.with_dim());
    }

    put_centered(out, middle +| 5, "cached mail opens instantly · Ctrl+R refreshes", theme.dim.with_dim());
    put_centered(out, out.rows -| 1, "Esc never quits · Ctrl+Q quits", theme.border);
}

/// What the splash says it is connecting to: only the accounts in scope, since
/// the others are not touched at all.
fn account_labels(state: *const State, buffer: []u8) []const u8 {
    if (state.accounts.len == 0) return "mail";
    if (state.account_filter) |filter| {
        const label = state.accounts.label_for(filter);
        if (label.len > 0) return label;
    }

    var writer = std.Io.Writer.fixed(buffer);
    var index: u8 = 0;
    while (index < state.accounts.len) : (index += 1) {
        const account = state.accounts.at(index) orelse continue;
        if (index > 0) writer.writeAll(", ") catch break;
        writer.writeAll(account.label.slice()) catch break;
    }
    return writer.buffered();
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
        // Narrow terminal: the active mailbox and its count, right next to each
        // other. Tab/Shift+Tab still switch.
        const x: u16 = 1 + screen.text_columns(name) + 2;
        _ = out.put_text(x, lay.header_y, inputs.state.mailbox.title(), 16, inputs.theme.accent.with_bold());
        render_unread_count(
            inputs,
            lay.header_y,
            x + layout_mod.title_width(inputs.state.mailbox) + 1,
            inputs.state.mailbox,
            out,
        );
        return;
    }

    for (Mailbox.all) |mailbox| {
        const x = lay.tab_x(mailbox);
        const active = mailbox == inputs.state.mailbox;
        const title_style = if (active)
            inputs.theme.accent.with_bold().with_underline()
        else
            inputs.theme.dim;
        _ = out.put_text(x, lay.header_y, mailbox.title(), layout_mod.title_width(mailbox), title_style);
        render_unread_count(inputs, lay.header_y, lay.tab_count_x(mailbox), mailbox, out);
    }

    if (lay.columns >= 88) {
        const scope = if (inputs.state.account_filter) |filter|
            inputs.state.accounts.label_for(filter)
        else
            "all accounts";
        if (scope.len > 0) put_right(out, lay.columns -| 2, lay.header_y, scope, inputs.theme.dim);
    }
}

/// The count sits one space after its mailbox title, left-aligned in the
/// reserved count area. "Inbox 3" reads as one thing; a right-aligned count
/// floating between tabs reads as part of the next one.
fn render_unread_count(inputs: Inputs, y: u16, x: u16, mailbox: Mailbox, out: *Screen) void {
    const unread = inputs.store.unread_in(mailbox, inputs.state.account_filter);
    if (unread == 0) return;

    var buffer: [4]u8 = undefined;
    const count = if (unread > 99)
        "99+"
    else
        std.fmt.bufPrint(&buffer, "{d}", .{unread}) catch "";
    _ = out.put_text(x, y, count, layout_mod.tab_count_width, inputs.theme.accent.with_bold());
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

    if (lay.account_tags) {
        const label = inputs.state.accounts.label_for(message.account);
        if (label.len > 0) {
            const index = inputs.state.accounts.index_of(message.account) orelse 0;
            const color = theme.account_colors[index % theme.account_colors.len];
            const style = (Style{}).with_fg(color);
            out.put_text_truncated(
                lay.account_x,
                y,
                label,
                lay.account_width,
                selected_style(style, theme, selected),
            );
        }
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

const compose_rows = 4;

fn render_compose(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const state = inputs.state;
    render_compose_from(inputs, lay, out);
    render_compose_field(inputs, lay, 1, "To", state.compose.to.slice(), .to, out);
    render_compose_field(inputs, lay, 2, "Subject", state.compose.subject.slice(), .subject, out);
    out.hline(0, 3, lay.columns, '─', inputs.theme.border);
    render_compose_body(inputs, lay, out);
    out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
}

fn render_compose_from(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    _ = out.put_text(1, 0, "From", 8, inputs.theme.dim);
    var buffer: [200]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const label = inputs.state.accounts.label_for(inputs.state.compose.account);
    const address = inputs.state.compose.from;
    if (address.local.is_empty()) {
        writer.print("{s}", .{label}) catch {};
    } else {
        writer.print("{s} <{s}@{s}>", .{
            label,
            address.local.slice(),
            address.domain.slice(),
        }) catch {};
    }
    _ = out.put_text(10, 0, writer.buffered(), lay.columns -| 12, inputs.theme.dim);
}

fn render_compose_field(
    inputs: Inputs,
    lay: layout_mod.Layout,
    y: u16,
    label: []const u8,
    value: []const u8,
    field: core.compose.Field,
    out: *Screen,
) void {
    _ = out.put_text(1, y, label, 8, inputs.theme.dim);
    const active = inputs.state.compose.field == field;

    if (value.len == 0) {
        const placeholder = switch (field) {
            .to => "someone@example.com",
            .subject => "(no subject)",
            .body => "",
        };
        if (active) {
            // The cursor cell stays free, so the hint reads after it.
            out.put(10, y, ' ', inputs.theme.text.with_reverse());
            if (placeholder.len > 0) {
                _ = out.put_text(11, y, placeholder, lay.columns -| 13, inputs.theme.dim);
            }
        } else if (placeholder.len > 0) {
            _ = out.put_text(10, y, placeholder, lay.columns -| 12, inputs.theme.dim);
        }
        return;
    }

    const style = if (active) inputs.theme.text.with_bold() else inputs.theme.text;
    const x = @as(u16, 10) + out.put_text(10, y, value, lay.columns -| 12, style);
    if (active) out.put(x, y, ' ', inputs.theme.text.with_reverse());
}

fn render_compose_body(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const rows = lay.bottom_rule_y -| compose_rows;
    if (rows == 0) return;

    const body = inputs.state.compose.body_slice();
    const width = lay.columns -| 2;
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, width, &wrapped);

    if (body.len == 0) {
        // Leave the cursor cell free so the hint is not overwritten.
        const hint_x: u16 = if (inputs.state.compose.field == .body) 2 else 1;
        _ = out.put_text(hint_x, compose_rows, "Write your message.", width -| (hint_x - 1), inputs.theme.dim);
    }

    // Keep the end of the draft visible: typing happens at the end.
    const first = if (wrapped.len > rows) wrapped.len - rows else 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const index = first + row;
        if (index >= wrapped.len) break;
        _ = out.put_text(1, compose_rows + row, wrapped.at(index, body), width, inputs.theme.text);
    }

    if (inputs.state.compose.field != .body) return;

    const visible = wrapped.len -| first;
    const last_line = if (visible > 0) wrapped.at(first + visible - 1, body) else "";
    const cursor_row: u16 = compose_rows + @as(u16, @intCast(visible -| 1));
    if (cursor_row >= lay.bottom_rule_y) return;
    out.put(1 + screen.text_columns(last_line), cursor_row, ' ', inputs.theme.text.with_reverse());
}

fn render_reader(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const message = (if (inputs.state.opened_account.is_known())
        inputs.store.get_const(inputs.state.opened_account, inputs.state.opened)
    else
        null) orelse {
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

    // The name somebody chose and the address they actually wrote from: mail
    // clients show both, and so does this one.
    var address_buffer: [core.limits.address_max]u8 = undefined;
    const address = message.from.addr_spec(&address_buffer);
    const named = message.from.name.len > 0 and address.len > 0;

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    if (named) {
        writer.print("From {s} <{s}>  ·  {s}  ·  {s}", .{
            message.from.name.slice(), address, date, size,
        }) catch {};
    } else {
        writer.print("From {s}  ·  {s}  ·  {s}", .{ address, date, size }) catch {};
    }
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

    var covered_until: u32 = 0;
    var row: u16 = 0;
    while (row < lay.reader_rows) : (row += 1) {
        const line_index = inputs.state.reader_scroll + row;
        if (line_index >= wrapped.len) break;
        // A picture occupies the rows it covers: printing text there would be
        // printing it only to paint over it.
        if (line_index < covered_until) {
            _ = out.put_text(1, lay.reader_body_y + row, "", lay.columns - 2, inputs.theme.text);
            continue;
        }
        if (line_index < inputs.cover.len) {
            const height = inputs.cover[line_index];
            if (height > 1) covered_until = line_index + height;
        }
        const line = wrapped.at(line_index, inputs.body);
        var line_inputs = inputs;
        line_inputs.line_index = line_index;
        // "[IMG:…]" is a place to paint, not words to read.
        const visible = if (std.mem.indexOf(u8, line, "[IMG:")) |marker| line[0..marker] else line;
        draw_line_with_links(line_inputs, out, visible, lay.reader_body_y + row, lay.columns - 2);
    }
}

/// One wrapped line, with its links underlined so they read as links and not
/// as punctuation soup.
fn draw_line_with_links(inputs: Inputs, out: *Screen, line: []const u8, y: u16, width: u16) void {
    if (draw_line_selection(inputs, out, line, y, width)) return;
    if (inputs.links.len == 0) {
        _ = out.put_text(1, y, line, width, line_style(inputs));
        return;
    }

    // The links are ranges in the whole body; the line is a window onto it.
    const line_start = @intFromPtr(line.ptr) - @intFromPtr(inputs.body.ptr);
    const line_end = line_start + line.len;

    var cursor: usize = line_start;
    for (inputs.links) |link| {
        if (link.end <= line_start) continue;
        if (link.start >= line_end) break;
        const start = @max(link.start, line_start);
        const end = @min(link.end, line_end);
        if (start > cursor) {
            draw_segment_kind(inputs, out, line, cursor - line_start, start - line_start, y, width, .text);
            cursor = start;
        }
        if (end > cursor) {
            const lit = if (inputs.hovered) |hovered|
                hovered.start == link.start and hovered.end == link.end
            else
                false;
            draw_segment_kind(inputs, out, line, cursor - line_start, end - line_start, y, width, if (lit) .hovered else .link);
            cursor = end;
        }
    }
    if (cursor < line_end) {
        draw_segment_kind(inputs, out, line, cursor - line_start, line.len, y, width, .text);
    }
}

/// How a line of the HTML rendering is drawn. A terminal has no fonts, so the
/// difference between a heading and a paragraph has to be weight and colour.
fn line_style(inputs: Inputs) Style {
    const index = inputs.line_index orelse return inputs.theme.text;
    if (index >= inputs.kinds.len) return inputs.theme.text;
    return switch (inputs.kinds[index]) {
        .heading => inputs.theme.accent.with_bold(),
        .quote => inputs.theme.dim,
        .bullet => inputs.theme.text,
        .body => inputs.theme.text,
    };
}

/// Paints the selected part of one line, if the drag reaches it. Returns false
/// when there is nothing selected here, so links can be drawn as usual.
fn draw_line_selection(inputs: Inputs, out: *Screen, line: []const u8, y: u16, width: u16) bool {
    const drag = inputs.selection orelse return false;
    const row = inputs.line_index orelse return false;
    const range = drag.ordered();
    if (row < range.first.line or row > range.last.line) return false;

    const length: u16 = @intCast(line.len);
    const from: u16 = if (row == range.first.line) @min(range.first.column, length) else 0;
    const to: u16 = if (row == range.last.line) @min(range.last.column + 1, length) else length;
    if (to <= from) return false;

    if (from > 0) _ = out.put_text(1, y, line[0..from], width, inputs.theme.text);
    _ = out.put_text(1 + from, y, line[from..to], width -| from, inputs.theme.selection);
    if (to < length) _ = out.put_text(1 + to, y, line[to..], width -| to, inputs.theme.text);
    return true;
}

const Segment = enum { text, link, hovered };

fn draw_segment_kind(
    inputs: Inputs,
    out: *Screen,
    line: []const u8,
    start: usize,
    end: usize,
    y: u16,
    width: u16,
    kind: Segment,
) void {
    if (end <= start) return;
    // Columns are counted from the line, which starts after the gutter.
    const offset = screen.text_columns(line[0..start]);
    const segment = line[@min(start, line.len)..@min(end, line.len)];
    _ = out.put_text(1 + offset, y, segment, width -| offset, segment_style(inputs, kind));
}

fn segment_style(inputs: Inputs, kind: Segment) Style {
    return switch (kind) {
        .text => line_style(inputs),
        // Underlining every link turns the body into a sea of lines; the one
        // under the pointer is the one that has to stand out.
        .link => inputs.theme.accent,
        .hovered => inputs.theme.accent.with_bold().with_underline(),
    };
}

const Hint = struct {
    keys: []const u8,
    action: []const u8,
};

const accounts_hints = [_]Hint{
    .{ .keys = "j/k", .action = "move" },
    .{ .keys = "Enter", .action = "select" },
    .{ .keys = "n", .action = "add" },
    .{ .keys = "e", .action = "edit" },
    .{ .keys = "r", .action = "rename" },
    .{ .keys = "o", .action = "sign in (OAuth)" },
    .{ .keys = "d", .action = "remove" },
    .{ .keys = "Esc", .action = "close" },
};

const trash_hints = [_]Hint{
    .{ .keys = "j/k", .action = "move" },
    .{ .keys = "Enter", .action = "open" },
    .{ .keys = "X", .action = "delete" },
    .{ .keys = "E", .action = "empty" },
    .{ .keys = "^R", .action = "refresh" },
    .{ .keys = "?", .action = "help" },
};

const list_hints = [_]Hint{
    .{ .keys = "j/k", .action = "move" },
    .{ .keys = "Enter", .action = "open" },
    .{ .keys = "c", .action = "compose" },
    .{ .keys = "r", .action = "reply" },
    .{ .keys = "^R", .action = "refresh" },
    .{ .keys = "A", .action = "accounts" },
    .{ .keys = "?", .action = "help" },
};

const reader_hints = [_]Hint{
    .{ .keys = "j/k", .action = "scroll" },
    .{ .keys = "Space", .action = "page" },
    .{ .keys = "H", .action = "html" },
    .{ .keys = "click", .action = "open link" },
    .{ .keys = "r", .action = "reply" },
    .{ .keys = "q", .action = "back" },
    .{ .keys = "^R", .action = "refresh" },
};

const search_hints = [_]Hint{
    .{ .keys = "type", .action = "filter" },
    .{ .keys = "Enter", .action = "apply" },
    .{ .keys = "Esc", .action = "cancel" },
};

const help_hints = [_]Hint{
    .{ .keys = "j/k", .action = "scroll" },
    .{ .keys = "/", .action = "filter" },
    .{ .keys = "any key", .action = "closes" },
};

const compose_hints = [_]Hint{
    .{ .keys = "Tab", .action = "next field" },
    .{ .keys = "Ctrl+S", .action = "send" },
    .{ .keys = "Ctrl+U", .action = "clear field" },
    .{ .keys = "Esc", .action = "cancel" },
};

const help_search_hints = [_]Hint{
    .{ .keys = "type", .action = "filter" },
    .{ .keys = "Enter", .action = "apply" },
    .{ .keys = "Esc", .action = "cancel" },
};

fn hints_for(state: *const State) []const Hint {
    if (state.mode == .search) return &search_hints;
    if (state.mode == .help_search) return &help_search_hints;
    return switch (state.view) {
        .accounts => &accounts_hints,
        .list => if (state.mailbox == .trash) &trash_hints else &list_hints,
        .reader => &reader_hints,
        .help => &help_hints,
        .compose => &compose_hints,
    };
}

fn render_footer(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const y = lay.footer_y;
    var right_buffer: [16]u8 = undefined;
    const position = position_text(inputs.state, &right_buffer);
    // A refresh in progress turns the position into "⠹ 3/24": no new row, no
    // transient message, just the spinner next to where you are.
    var spinner_buffer: [32]u8 = undefined;
    const right = if (inputs.state.busy()) blk: {
        const glyph = spinner_frames[inputs.state.spinner % spinner_frames.len];
        break :blk std.fmt.bufPrint(&spinner_buffer, "{s} {s}", .{ glyph, position }) catch position;
    } else position;
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
    if (state.view == .compose) return "";
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

/// Every key amail answers to, grouped by where it works. An entry with no
/// `keys` is a heading.
const help_rows = [_]Hint{
    .{ .keys = "", .action = "-- anywhere" },
    .{ .keys = "?", .action = "this card (j/k scrolls, / filters)" },
    .{ .keys = "Ctrl+Q / C", .action = "quit" },
    .{ .keys = "Ctrl+R", .action = "refresh" },
    .{ .keys = "Tab / [ ]", .action = "next / previous mailbox" },
    .{ .keys = "1 - 6", .action = "Inbox, Sent, Drafts, Archive, Trash, Junk" },
    .{ .keys = "a", .action = "next account scope" },
    .{ .keys = "A", .action = "accounts: pick, add, edit, rename, sign in" },
    .{ .keys = "/", .action = "search the list" },
    .{ .keys = "", .action = "-- moving" },
    .{ .keys = "j / Down", .action = "down a line" },
    .{ .keys = "k / Up", .action = "up a line" },
    .{ .keys = "g / Home", .action = "first row" },
    .{ .keys = "G / End", .action = "last row" },
    .{ .keys = "Ctrl+D / U", .action = "half a page" },
    .{ .keys = "Ctrl+F / B", .action = "a whole page" },
    .{ .keys = "Ctrl+N / P", .action = "down / up a line" },
    .{ .keys = "PageDown / PageUp", .action = "a whole page" },
    .{ .keys = "Space", .action = "a whole page" },
    .{ .keys = "", .action = "-- the list" },
    .{ .keys = "Enter / l / Right", .action = "open the message" },
    .{ .keys = "o", .action = "open the message" },
    .{ .keys = "c", .action = "compose a new one" },
    .{ .keys = "r", .action = "reply" },
    .{ .keys = "u", .action = "read / unread" },
    .{ .keys = "s / *", .action = "star / unstar" },
    .{ .keys = "d", .action = "archive" },
    .{ .keys = "# / Delete", .action = "move to Trash" },
    .{ .keys = "X", .action = "delete for good (Trash only)" },
    .{ .keys = "E", .action = "empty Trash" },
    .{ .keys = "click", .action = "select a row; again to open it" },
    .{ .keys = "wheel", .action = "scroll the list" },
    .{ .keys = "", .action = "-- the reader" },
    .{ .keys = "q / h / Esc / Left", .action = "back to the list" },
    .{ .keys = "H", .action = "HTML view, or the plain text one" },
    .{ .keys = "o", .action = "open the mail in a browser" },
    .{ .keys = "Ctrl+click", .action = "open the link under the pointer" },
    .{ .keys = "click", .action = "open a link; on plain text, nothing" },
    .{ .keys = "drag", .action = "select, then copy (and the primary selection)" },
    .{ .keys = "", .action = "-- writing" },
    .{ .keys = "Tab / Shift+Tab", .action = "next / previous field" },
    .{ .keys = "Enter", .action = "next field, or a new line in the body" },
    .{ .keys = "Ctrl+S", .action = "send (compose), save (forms)" },
    .{ .keys = "Ctrl+U", .action = "clear the field" },
    .{ .keys = "Space", .action = "toggle an option" },
    .{ .keys = "Esc", .action = "cancel, close" },
    .{ .keys = "", .action = "-- the accounts overlay" },
    .{ .keys = "n / e / r / d", .action = "add, edit, rename, remove" },
    .{ .keys = "o", .action = "sign in with the provider" },
    .{ .keys = "Enter", .action = "use this account" },
    .{ .keys = "", .action = "-- in this card" },
    .{ .keys = "/", .action = "filter the keys by word" },
    .{ .keys = "Enter", .action = "keep the filter" },
    .{ .keys = "Esc", .action = "drop the filter" },
};

/// What the card must mention, checked by a test: a key that works and is not
/// here is a key nobody will find.
const required_in_help = [_][]const u8{
    "Ctrl+Q", "Ctrl+R", "Tab",   "1 - 6",  "a",      "A",          "/",        "j",
    "k",      "g",      "G",     "Ctrl+D", "Ctrl+F", "Ctrl+N",     "PageDown", "Space",
    "Enter",  "l",      "Right", "o",      "c",      "r",          "u",        "s",
    "*",      "d",      "#",     "Delete", "X",      "E",          "click",    "wheel",
    "q",      "h",      "Esc",   "Left",   "H",      "Ctrl+click", "drag",     "Shift+Tab",
    "Ctrl+S", "Ctrl+U", "n",     "e",      "Up",     "Down",       "Home",     "End",
};

const account_rows_max = 8;

/// The accounts overlay: pick the scope, add one, remove one.
fn render_accounts(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const rows = @min(inputs.state.accounts.len + 1, account_rows_max);
    const card_width: u16 = @min(52, lay.columns - 4);
    const card_height: u16 = rows + 4; // title, rows, hints
    const rect = Rect{
        .x = (lay.columns - card_width) / 2,
        .y = (lay.rows - card_height) / 2,
        .width = card_width,
        .height = card_height,
    };

    out.fill_rect(rect, ' ', inputs.theme.text);
    out.box(rect, inputs.theme.border);
    _ = out.put_text(rect.x + 2, rect.y, " Accounts ", card_width -| 4, inputs.theme.accent.with_bold());

    var index: u8 = 0;
    while (index < rows) : (index += 1) {
        const y = rect.y + 1 + index;
        const selected = index == inputs.state.accounts_cursor;
        const style = if (selected) inputs.theme.selection else inputs.theme.text;
        if (selected) {
            out.fill_rect(.{ .x = rect.x + 1, .y = y, .width = rect.width - 2, .height = 1 }, ' ', style);
        }

        var buffer: [96]u8 = undefined;
        const text = if (index == 0)
            "All accounts"
        else blk: {
            const account = inputs.state.accounts.at(index - 1) orelse break :blk "";
            var address_buffer: [core.limits.address_max]u8 = undefined;
            break :blk std.fmt.bufPrint(&buffer, "{s}  {s}", .{
                account.label.slice(),
                account.address.addr_spec(&address_buffer),
            }) catch account.label.slice();
        };
        _ = out.put_text(rect.x + 2, y, text, rect.width -| 4, style);

        // The scope in use gets a marker.
        const active = if (index == 0)
            inputs.state.account_filter == null
        else if (inputs.state.accounts.at(index - 1)) |account|
            inputs.state.account_filter != null and inputs.state.account_filter.? == account.id
        else
            false;
        if (active) out.put(rect.x + 1, y, '*', inputs.theme.accent);
    }

    _ = out.put_text(
        rect.x + 2,
        rect.y + rect.height - 1,
        "Enter select · n add · e edit · r rename · d remove · Esc",
        rect.width -| 4,
        inputs.theme.dim,
    );
}

fn render_help(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const card_width: u16 = @min(64, lay.columns - 4);
    // Title, filter line, the rows, and the footer.
    const card_height: u16 = @min(@as(u16, help_rows.len + 5), lay.rows - 2);
    const rect = Rect{
        .x = (lay.columns - card_width) / 2,
        .y = (lay.rows - card_height) / 2,
        .width = card_width,
        .height = card_height,
    };

    out.fill_rect(rect, ' ', inputs.theme.text);
    out.box(rect, inputs.theme.border);
    _ = out.put_text(rect.x + 2, rect.y, " Keys ", card_width - 4, inputs.theme.accent.with_bold());
    render_help_filter(inputs, rect, out);

    const filter = inputs.state.help_filter.slice();

    // Only the rows that match the filter are counted, so scrolling is measured
    // in what the eye sees, not in the table.
    var matching: u16 = 0;
    for (help_rows) |entry| {
        if (help_matches(filter, entry)) matching += 1;
    }
    const visible: u16 = rect.height -| 3;
    const max_scroll: u16 = matching -| visible;
    const scroll: u16 = @min(inputs.state.help_scroll, max_scroll);

    var row: u16 = 0;
    var seen: u16 = 0;
    var shown: u16 = 0;
    while (row < help_rows.len) : (row += 1) {
        const entry = help_rows[row];
        if (!help_matches(filter, entry)) continue;
        if (seen < scroll) {
            seen += 1;
            continue;
        }
        const y = rect.y + 2 + shown;
        if (y >= rect.bottom() - 1) break;
        if (entry.keys.len == 0) {
            // A heading: the card groups the keys by where they work.
            _ = out.put_text(rect.x + 2, y, entry.action, card_width -| 4, inputs.theme.accent.with_bold());
            shown += 1;
            continue;
        }
        _ = out.put_text(rect.x + 2, y, entry.keys, help_key_width, inputs.theme.accent);
        _ = out.put_text(
            rect.x + 2 + help_key_width,
            y,
            entry.action,
            card_width -| (help_key_width + 4),
            inputs.theme.text,
        );
        shown += 1;
    }

    if (shown == 0) {
        _ = out.put_text(rect.x + 2, rect.y + 3, "No keys match", card_width - 4, inputs.theme.dim);
    }

    const footer = if (inputs.state.mode == .help_search)
        " Enter apply  ·  Esc cancel "
    else if (max_scroll > 0)
        " j/k scroll  ·  / filters  ·  any other key closes "
    else
        " any key closes  ·  / filters ";
    _ = out.put_text(rect.x + 2, rect.bottom() - 1, footer, card_width - 4, inputs.theme.dim);
}

const help_key_width: u16 = 18;

fn render_help_filter(inputs: Inputs, rect: Rect, out: *Screen) void {
    const y = rect.y + 1;
    _ = out.put_text(rect.x + 2, y, "/", 1, inputs.theme.accent.with_bold());

    const filter = inputs.state.help_filter.slice();
    if (filter.len == 0 and inputs.state.mode != .help_search) {
        _ = out.put_text(rect.x + 4, y, "filter keys", rect.width -| 6, inputs.theme.dim);
        return;
    }

    const written = out.put_text(rect.x + 4, y, filter, rect.width -| 6, inputs.theme.text);
    if (inputs.state.mode == .help_search) {
        // The caret follows the text: `put_text` returns cells written, not an
        // absolute column, so it must be added to where the text started.
        out.put(rect.x + 4 + written, y, ' ', inputs.theme.text.with_reverse());
    }
}

fn help_matches(filter: []const u8, entry: Hint) bool {
    if (filter.len == 0) return true;
    if (core.text.contains_ignore_case(entry.keys, filter)) return true;
    return core.text.contains_ignore_case(entry.action, filter);
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
        .account = core.id.AccountId.from_int(1),
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
    try row_contains(&out, 0, "Inbox 2");
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

test "with several accounts, each row carries its account tag" {
    var f = try fixture();
    defer f.deinit();
    f.state.accounts.add(core.id.AccountId.from_int(1), "home", .{}, .{});
    f.state.accounts.add(core.id.AccountId.from_int(2), "work", .{}, .{});
    for (0..3) |index| {
        f.store.at(@intCast(index)).account = core.id.AccountId.from_int(if (index == 1) 2 else 1);
    }
    f.state.rebuild(&f.store);

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    // The whole label, not just its initial, in its account's hue.
    try row_contains(&out, 2, "home");
    try row_contains(&out, 3, "work");
    // account_x now leaves a space after the unread dot.
    try testing.expectEqual(
        screen.Color{ .ansi256 = 74 },
        out.cells[2][3].style.fg,
    );
    try testing.expectEqual(
        screen.Color{ .ansi256 = 180 },
        out.cells[3][3].style.fg,
    );
    try row_contains(&out, 0, "all accounts");
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
    // The card groups the keys by where they work, and scrolls to the rest.
    try row_contains(&out, 3, "-- anywhere");
    try row_contains(&out, 21, "closes");
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

test "the composer shows placeholders for empty fields" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .compose;
    f.state.compose.reset();

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 1, "someone@example.com");
    try row_contains(&out, 2, "(no subject)");
    try row_contains(&out, 4, "Write your message.");

    // In the body, the cursor takes the first cell and the hint moves right.
    f.state.compose.field = .body;
    frame(f.inputs(100, 24), &out);
    try testing.expect(out.cells[4][1].style.attrs.reverse);
    try row_contains(&out, 4, "Write your message.");
}

test "frame renders the compose view: fields, rule, and body" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .compose;
    f.state.compose.reset();
    f.state.compose.to.set("alice@example.com");
    f.state.compose.subject.set("Re: design tokens");
    f.state.compose.field = .body;
    _ = f.state.compose.append('h');
    _ = f.state.compose.append('i');

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    try row_contains(&out, 0, "From");
    try row_contains(&out, 1, "To");
    try row_contains(&out, 1, "alice@example.com");
    try row_contains(&out, 2, "Subject");
    try row_contains(&out, 2, "Re: design tokens");
    try row_contains(&out, 4, "hi");
    try row_contains(&out, 23, "Ctrl+S");
    try row_contains(&out, 23, "send");
}

test "the active compose field shows a cursor at its end" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .compose;
    f.state.compose.reset();
    f.state.compose.to.set("ab");

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try testing.expect(out.cells[1][12].style.attrs.reverse);

    f.state.compose.next_field();
    frame(f.inputs(100, 24), &out);
    try testing.expect(!out.cells[1][12].style.attrs.reverse);
    try testing.expect(out.cells[2][10].style.attrs.reverse);
}

test "the compose body scrolls to keep the end visible and puts the cursor there" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .compose;
    f.state.compose.reset();
    f.state.compose.field = .body;
    var line: u32 = 0;
    while (line < 40) : (line += 1) {
        _ = f.state.compose.append('x');
        f.state.compose.append_newline();
    }
    _ = f.state.compose.append('z');

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    // 41 lines: the last visible body row holds the "z" line.
    try row_contains(&out, 20, "z");
    try testing.expect(out.cells[20][2].style.attrs.reverse);
}

test "the help overlay can open above compose" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .compose;
    f.state.compose.reset();
    f.state.compose.to.set("alice@example.com");
    f.state.help_return = .compose;
    f.state.view = .help;

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 1, "alice");
    try row_contains(&out, 1, "Keys");
}

test "the help overlay advertises its filter and filters rows" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .toggle_help);

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 2, "/ filter keys");
    try row_contains(&out, 3, "-- anywhere");
    // The filter line lives inside the card, borders included.
    try testing.expectEqual(@as(u21, '│'), out.cells[2][18].ch);
    try testing.expectEqual(@as(u21, '│'), out.cells[2][81].ch);

    // Type a filter that keeps only the star binding.
    _ = core.update.apply(&f.state, &f.store, .begin_help_search);
    _ = core.update.apply(&f.state, &f.store, .{ .help_search_char = 's' });
    _ = core.update.apply(&f.state, &f.store, .{ .help_search_char = 't' });
    _ = core.update.apply(&f.state, &f.store, .{ .help_search_char = 'a' });
    _ = core.update.apply(&f.state, &f.store, .{ .help_search_char = 'r' });
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 2, "/ star");
    try row_contains(&out, 3, "star");
    try row_contains(&out, 21, "Esc cancel");

    var buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, out.row_text(4, &buffer), "move down") == null);
}

test "the help overlay says so when nothing matches" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .toggle_help);
    _ = core.update.apply(&f.state, &f.store, .begin_help_search);
    _ = core.update.apply(&f.state, &f.store, .{ .help_search_char = 'z' });
    _ = core.update.apply(&f.state, &f.store, .{ .help_search_char = 'z' });

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 4, "No keys match");
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
    try row_contains(&out, 23, "compose");
    try row_contains(&out, 23, "reply");
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

test "the boot splash shows the wordmark, the server, and a spinner" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;
    f.state.accounts.add(core.id.AccountId.from_int(1), "work", try core.address.Address.init("alice@example.com"), .{});

    var out = Screen.init(80, 24);
    frame(f.inputs(80, 24), &out);
    // middle = 12: wordmark at 9..10, tagline 11, rule 12, spinner 14, address 15.
    try row_contains(&out, 9, "▄▀█");
    try row_contains(&out, 11, "quiet terminal mail client");
    try row_contains(&out, 14, "connecting to work");
    try row_contains(&out, 15, "alice@example.com");
    try row_contains(&out, 17, "Ctrl+R refreshes");
    try row_contains(&out, 23, "Ctrl+Q quits");
    // The list is not drawn behind it.
    var row_buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, out.row_text(2, &row_buffer), "Inbox") == null);
}

test "the splash spinner advances with the tick" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;
    var out = Screen.init(80, 24);
    f.state.spinner = 0;
    frame(f.inputs(80, 24), &out);
    try row_contains(&out, 14, spinner_frames[0]);
    f.state.spinner = 3;
    frame(f.inputs(80, 24), &out);
    try row_contains(&out, 14, spinner_frames[3]);
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
    try row_contains(&out, 0, "Inbox 2");
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

test "a link that wraps is drawn without gaps or doubled spaces" {
    const body = "https://unsubscribe.example.com/?token=abcdefghijklmnopqrstuvwxyz0123456789";
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, 20, &wrapped);
    try testing.expect(wrapped.len > 2);

    var buffer: [core.links.max_links]core.links.Link = undefined;
    const count = core.links.scan(body, &buffer);

    var canvas: Screen = .{};
    canvas.resize(40, 10);
    const state = State{};
    const theme = Theme.dark();
    var row: u16 = 0;
    while (row < wrapped.len) : (row += 1) {
        var inputs = Inputs{
            .state = &state,
            .store = undefined,
            .theme = &theme,
            .body = body,
            .links = buffer[0..count],
            .line_index = row,
        };
        _ = &inputs;
        draw_line_with_links(inputs, &canvas, wrapped.at(row, body), row, 20);
    }

    // The body starts in column 1, so the row carries a leading cell and then
    // the wrapped line, byte for byte: no gaps, no doubled spaces.
    var text_buffer: [64]u8 = undefined;
    const first = std.mem.trimEnd(u8, canvas.row_text(0, &text_buffer), " ");
    try testing.expectEqualStrings(wrapped.at(0, body), std.mem.trimStart(u8, first, " "));
    var second: [64]u8 = undefined;
    const next = std.mem.trimEnd(u8, canvas.row_text(1, &second), " ");
    try testing.expectEqualStrings(wrapped.at(1, body), std.mem.trimStart(u8, next, " "));
}

/// Reads every row: the reader's layout decides where the meta line lands.
fn screen_contains(out: *const Screen, needle: []const u8) bool {
    var row: u16 = 0;
    var buffer: [512]u8 = undefined;
    while (row < out.rows) : (row += 1) {
        if (std.mem.indexOf(u8, out.row_text(row, &buffer), needle) != null) return true;
    }
    return false;
}

test "the reader shows the address behind the name" {
    var store = try core.store.Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);

    var message = core.message.Message{
        .id = core.id.MessageId.from_int(1),
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .timestamp_unix = 1_700_000_000,
        .from = try core.address.Address.init("Alice Rivera <alice@example.com>"),
    };
    message.subject.set("Hello");
    try store.insert(&message);

    var state = State{};
    state.accounts.add(core.id.AccountId.from_int(1), "work", message.from, .{});
    state.view = .reader;
    state.opened_account = message.account;
    state.opened = message.id;
    state.rebuild(&store);

    var out: Screen = .{};
    var inputs = Inputs{
        .state = &state,
        .store = &store,
        .theme = &Theme.dark(),
        .body = "text",
        .columns = 100,
        .rows = 24,
    };
    inputs.now_unix = 1_700_000_000;
    frame(inputs, &out);

    try testing.expect(screen_contains(&out, "Alice Rivera <alice@example.com>"));
}

test "a sender with no display name is just the address, not twice" {
    var store = try core.store.Store.init(testing.allocator, 2);
    defer store.deinit(testing.allocator);

    var message = core.message.Message{
        .id = core.id.MessageId.from_int(1),
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .timestamp_unix = 1_700_000_000,
        .from = try core.address.Address.init("bob@example.com"),
    };
    message.subject.set("Hello");
    try store.insert(&message);

    var state = State{};
    state.accounts.add(core.id.AccountId.from_int(1), "work", message.from, .{});
    state.view = .reader;
    state.opened_account = message.account;
    state.opened = message.id;
    state.rebuild(&store);

    var out: Screen = .{};
    frame(.{
        .state = &state,
        .store = &store,
        .theme = &Theme.dark(),
        .body = "text",
        .columns = 100,
        .rows = 24,
        .now_unix = 1_700_000_000,
    }, &out);

    try testing.expect(screen_contains(&out, "From bob@example.com"));
    try testing.expect(!screen_contains(&out, "<bob@example.com>"));
}

test "the rows a picture covers are left empty, not printed over" {
    var store = try core.store.Store.init(testing.allocator, 2);
    defer store.deinit(testing.allocator);

    var message = core.message.Message{
        .id = core.id.MessageId.from_int(1),
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .timestamp_unix = 1_700_000_000,
        .from = try core.address.Address.init("a@example.com"),
    };
    message.subject.set("Con imagen");
    try store.insert(&message);

    var state = State{};
    state.accounts.add(core.id.AccountId.from_int(1), "work", message.from, .{});
    state.view = .reader;
    state.opened_account = message.account;
    state.opened = message.id;
    state.rebuild(&store);

    const body = "[IMG:logo@x]\nline under the picture\nlast line";
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, 60, &wrapped);
    try testing.expect(wrapped.len >= 3);

    // The picture is three rows tall: two of text hide behind it.
    var cover: [8]u8 = @splat(0);
    cover[0] = 3;

    var out: Screen = .{};
    frame(.{
        .state = &state,
        .store = &store,
        .theme = &Theme.dark(),
        .body = body,
        .wrapped = &wrapped,
        .cover = &cover,
        .columns = 100,
        .rows = 24,
        .now_unix = 1_700_000_000,
    }, &out);

    try testing.expect(!screen_contains(&out, "line under the picture"));
    try testing.expect(!screen_contains(&out, "last line"));
}

test "the help card names every key that works" {
    for (required_in_help) |label| {
        var found = false;
        for (help_rows) |entry| {
            if (std.mem.indexOf(u8, entry.keys, label) != null) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing from help: {s}\n", .{label});
            return error.TestUnexpectedResult;
        }
    }
}

test "the help card scrolls to its last row" {
    // More keys than a 24-row terminal can show, so the card must scroll.
    try testing.expect(help_rows.len > 20);

    var f = try fixture();
    defer f.deinit();
    f.state.view = .help;
    f.state.help_return = .list;

    // Scrolling past the end stops at the end, and never goes below the top.
    _ = core.update.apply(&f.state, &f.store, .{ .help_scroll = 400 });
    const bottom = f.state.help_scroll;
    try testing.expect(bottom > 0);
    _ = core.update.apply(&f.state, &f.store, .{ .help_scroll = -1 });
    try testing.expectEqual(bottom - 1, f.state.help_scroll);
    _ = core.update.apply(&f.state, &f.store, .{ .help_scroll = -1000 });
    try testing.expectEqual(@as(u16, 0), f.state.help_scroll);

    // Scrolled to the end, the card still draws inside a 24-row terminal.
    f.state.help_scroll = 400;
    var out: Screen = .{};
    out.resize(80, 24);
    frame(f.inputs(80, 24), &out);
    var buffer: [256]u8 = undefined;
    // The footer is the last row of the card, not the last row of the screen.
    try testing.expect(std.mem.indexOf(u8, out.row_text(23, &buffer), "filters") == null);
}
