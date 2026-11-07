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
const splash = @import("splash.zig");

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
    /// The anchors of the HTML view: their words are a link, and the address they
    /// go to is not in the text -- the mark has to ask for it.
    anchors: []const core.html.Anchor = &.{},
    /// The link the pointer is over, if any: lit up so a click is not a guess.
    hovered: ?core.links.Link = null,
    /// Where that link goes, shown in a popup while the pointer is on it.
    hover_url: ?[]const u8 = null,
    /// What the mouse has covered so far, shown while it is being dragged.
    selection: ?selection.Selection = null,
    /// Which wrapped line is being drawn, so the selection can be placed.
    line_index: ?u32 = null,
    /// What kind of line each rendered HTML line is: headings, quotes, bullets.
    kinds: []const core.html.Kind = &.{},
    /// Who else was on the message; empty when the reader has no body yet.
    details: *const core.headers.Details = &.{},
    /// Showing every header, instead of the one line of From.
    show_details: bool = false,
    /// Rows hidden behind a picture: the reader leaves them empty so the image
    /// is not drawn over text.
    cover: []const u8 = &.{},
    /// Set when the user asked for no motion: the splash draws its still frame.
    reduced_motion: bool = false,
    /// The folder sidebar is wanted. It is drawn only when the terminal can
    /// afford it; `Layout` decides.
    sidebar: bool = false,
    /// Milliseconds since the first screen went up. The splash's only clock: the loop
    /// and the painter thread both read it, so the mark cannot jump when one hands
    /// over to the other.
    elapsed_ms: i64 = 0,
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

    out.card(rect, theme.text, theme.border);
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
    out.shift = 0;
    const lay = layout_mod.Layout.compute_with(
        out.columns,
        out.rows,
        inputs.state.accounts.max_label(),
        inputs.sidebar,
    );
    if (lay.too_small) {
        render_too_small(inputs, out);
        return;
    }
    if (inputs.state.booting) {
        splash.draw(out, inputs.state, inputs.theme, inputs.elapsed_ms, inputs.reduced_motion);
        return;
    }

    // The sidebar is painted where it lives, then everything else is shifted
    // past it: one rule and one blank column, and no renderer knows it is there.
    if (lay.sidebar) {
        render_sidebar(inputs, lay, out);
        out.shift = lay.shift;
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
    if (inputs.state.moving) render_move(inputs, lay, out);
    render_back(inputs, lay, out);
    render_footer(inputs, lay, out);
}

/// The way back: a button in the corner, three cells wide, whose glyph sits in the
/// column the text below starts in -- left edge, first character, aligned.
pub const back_x: u16 = 0;
pub const back_y: u16 = 0;
pub const back_width: u16 = 3;
/// Blank columns between the button and the line it shares a row with: the slack
/// cell of the button is the space, so nothing more is needed.
pub const back_gap: u16 = 0;

/// Whether a cell is on the chip: one rectangle, so the pointer and the click
/// cannot disagree about where the button is.
pub fn in_back(x: u16, y: u16) bool {
    if (y != back_y) return false;
    return x >= back_x and x < back_x + back_width;
}

/// Where the subject starts: after the button when there is one, at the margin when
/// there is not.
pub fn subject_x(state: *const State, sidebar: bool) u16 {
    if (!shows_back(state, sidebar)) return 1;
    return back_x + back_width + back_gap;
}

/// Whether this screen has somewhere to go back to, and a corner to say it in. The
/// list is where the app begins; and when the sidebar is drawn, its first cell is
/// already a thing to click -- two meanings for one cell is one too many.
pub fn shows_back(state: *const State, sidebar: bool) bool {
    if (state.view == .list) return false;
    return !sidebar;
}

/// The way back with a mouse, in the corner the eye already knows: a chip with the
/// same background a selected row has, so it reads as something to press.
fn render_back(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    if (!shows_back(inputs.state, lay.sidebar)) return;
    // The glyph alone: a background would be three cells of highlight around one
    // character, which reads as something left over. The button is the cells the
    // pointer and the click use, and neither of them needs to be painted.
    out.put(back_x + back_width / 2, back_y, '←', inputs.theme.accent.with_bold());
}

/// The first network load can take a second: say so, beautifully, instead of
/// showing an empty list. Cached mail never reaches this path.
/// The footer's busy glyph: one cell, so it has to say "working" at a glance and
/// not be a second animation competing with the breath.
const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn render_list(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    if (inputs.state.mode == .search and lay.show_header) {
        render_search_bar(inputs, lay, out);
        out.hline(0, lay.top_rule_y, lay.columns, '─', inputs.theme.border);
    } else if (lay.show_header) {
        render_tabs(inputs, lay, out);
        out.hline(0, lay.top_rule_y, lay.columns, '─', inputs.theme.border);
    }
    render_rows(inputs, lay, out);
    out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
}

/// One row of the folder sidebar and what a click on it means.
pub const SidebarEntry = union(enum) {
    all_accounts,
    account: core.id.AccountId,
    /// A folder row. `mailbox` is one of the six; `slot` is one of the account's
    /// own folders, as `LIST` named them. Exactly one is set.
    folder: struct {
        account: ?core.id.AccountId,
        mailbox: ?Mailbox = null,
        slot: ?u8 = null,
    },
};

pub const SidebarRow = struct { y: u16, entry: SidebarEntry };

/// The scopes, the rule under them, and the six folders of the scope on screen.
pub const max_sidebar_rows: usize = 1 + core.state.accounts_max + Mailbox.all.len;

/// A scope row: every account at once, or one of them.
pub const SidebarScope = union(enum) {
    all_accounts,
    account: core.id.AccountId,
};

/// The rows the sidebar draws, top to bottom: the scopes that choose whose
/// folders these are, then the folders themselves. The renderer and the mouse
/// both walk this list, so a label and its hit box cannot drift apart.
pub fn sidebar_rows(
    accounts: *const core.state.Accounts,
    folders: *const core.folder.Table,
    scope: ?core.id.AccountId,
    rows: []SidebarRow,
) usize {
    var count: usize = 0;
    if (count == rows.len) return count;
    rows[count] = .{ .y = 0, .entry = .all_accounts };
    count += 1;

    var y: u16 = 1;
    for (accounts.items[0..accounts.len]) |account| {
        if (count == rows.len) return count;
        rows[count] = .{ .y = y, .entry = .{ .account = account.id } };
        count += 1;
        y += 1;
    }

    // One row says "the folders below belong to the scope above".
    y += 1;
    if (scope) |account| {
        // The account's own folders, in the order its server listed them. A
        // server that has not answered yet leaves the six the app knows.
        if (!folders.is_empty(account)) {
            var slot: u8 = 0;
            while (slot < folders.count(account)) : (slot += 1) {
                if (count == rows.len) return count;
                const entry = folders.at(account, slot).?;
                rows[count] = .{ .y = y, .entry = .{ .folder = if (entry.canonical) |mailbox|
                    .{ .account = account, .mailbox = mailbox }
                else
                    .{ .account = account, .slot = slot } } };
                count += 1;
                y += 1;
            }
            return count;
        }
    }
    for (Mailbox.all) |mailbox| {
        if (count == rows.len) return count;
        rows[count] = .{ .y = y, .entry = .{ .folder = .{ .account = scope, .mailbox = mailbox } } };
        count += 1;
        y += 1;
    }
    return count;
}

/// What the row at `y` is, if it is a row at all.
pub fn sidebar_hit(
    accounts: *const core.state.Accounts,
    folders: *const core.folder.Table,
    scope: ?core.id.AccountId,
    y: u16,
) ?SidebarEntry {
    var rows: [max_sidebar_rows]SidebarRow = undefined;
    const count = sidebar_rows(accounts, folders, scope, &rows);
    for (rows[0..count]) |row| {
        if (row.y == y) return row.entry;
    }
    return null;
}

fn sidebar_active(state: *const State, entry: SidebarEntry) bool {
    return switch (entry) {
        .all_accounts => state.account_filter == null,
        .account => |id| state.account_filter == id,
        .folder => |row| blk: {
            if (row.slot) |slot| {
                const ref = state.named orelse break :blk false;
                break :blk row.account == ref.account and slot == ref.slot;
            }
            const mailbox = row.mailbox orelse break :blk false;
            break :blk state.named == null and state.account_filter == row.account and state.mailbox == mailbox;
        },
    };
}

fn render_sidebar(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const theme = inputs.theme;
    const width = lay.sidebar_width;
    out.vline(width, 0, out.rows, '│', theme.border);

    var rows: [max_sidebar_rows]SidebarRow = undefined;
    const count = sidebar_rows(
        &inputs.state.accounts,
        &inputs.state.folders,
        inputs.state.account_filter,
        &rows,
    );

    // The rule between the scopes and the folders of the scope on screen.
    const separator: u16 = 1 + inputs.state.accounts.len;
    if (separator < out.rows) out.hline(1, separator, width -| 2, '─', theme.border);

    for (rows[0..count]) |row| {
        if (row.y >= out.rows) break;
        const active = sidebar_active(inputs.state, row.entry);
        if (active) {
            out.fill_rect(.{ .x = 0, .y = row.y, .width = width, .height = 1 }, ' ', theme.selection);
        }
        switch (row.entry) {
            .all_accounts => {
                const style = selected_style(
                    if (active) theme.accent.with_bold() else theme.dim.with_bold(),
                    theme,
                    active,
                );
                _ = out.put_text(1, row.y, "ALL ACCOUNTS", width -| 2, style);
                render_sidebar_total(inputs, out, row.y, width, null, active);
            },
            .account => |id| {
                const style = selected_style(
                    if (active) theme.accent.with_bold() else theme.text.with_bold(),
                    theme,
                    active,
                );
                const label = inputs.state.accounts.label_for(id);
                out.put_text_truncated(1, row.y, label, width -| 4, style);
                render_sidebar_total(inputs, out, row.y, width, id, active);
            },
            .folder => |folder| {
                // The server's own name for a folder the six do not cover.
                var named_title: []const u8 = "";
                if (folder.slot) |slot| {
                    const account = folder.account orelse continue;
                    named_title = if (inputs.state.folders.at(account, slot)) |entry| entry.display() else "";
                }
                // The six are counted from the store, the others from what the
                // server said about them.
                const named_entry = if (folder.slot) |slot|
                    (if (folder.account) |account| inputs.state.folders.at(account, slot) else null)
                else
                    null;
                const unread = if (folder.mailbox) |mailbox|
                    inputs.store.unread_in(mailbox, folder.account)
                else if (named_entry) |entry|
                    entry.unread
                else
                    0;
                const style = selected_style(
                    if (active) theme.accent.with_bold() else if (unread > 0) theme.text else theme.dim,
                    theme,
                    active,
                );
                const title = if (folder.mailbox) |mailbox| mailbox.title() else named_title;
                out.put_text_truncated(3, row.y, title, width -| 4, style);
                if (folder.mailbox) |mailbox| {
                    render_sidebar_count(inputs, out, row.y, width, mailbox, folder.account, active);
                } else if (unread > 0) {
                    var unread_buffer: [8]u8 = undefined;
                    const number = if (unread > 999) "999" else std.fmt.bufPrint(&unread_buffer, "{d}", .{unread}) catch "";
                    put_right(out, width -| 2, row.y, number, selected_style(inputs.theme.accent, inputs.theme, active));
                }
            },
        }
    }
}

/// Unread everywhere in a scope: a group row counts what is behind it, not
/// what one of its folders happens to hold.
fn render_sidebar_total(
    inputs: Inputs,
    out: *Screen,
    y: u16,
    width: u16,
    account: ?core.id.AccountId,
    active: bool,
) void {
    var total: u32 = 0;
    for (Mailbox.all) |mailbox| total += inputs.store.unread_in(mailbox, account);
    if (total == 0) return;
    var buffer: [8]u8 = undefined;
    const count = if (total > 999) "999" else std.fmt.bufPrint(&buffer, "{d}", .{total}) catch "";
    put_right(out, width -| 2, y, count, selected_style(inputs.theme.accent, inputs.theme, active));
}

fn render_sidebar_count(
    inputs: Inputs,
    out: *Screen,
    y: u16,
    width: u16,
    mailbox: Mailbox,
    account: ?core.id.AccountId,
    active: bool,
) void {
    const unread = inputs.store.unread_in(mailbox, account);
    if (unread == 0) return;
    var buffer: [8]u8 = undefined;
    const count = if (unread > 999) "999" else std.fmt.bufPrint(&buffer, "{d}", .{unread}) catch "";
    put_right(out, width -| 2, y, count, selected_style(inputs.theme.accent, inputs.theme, active));
}

/// The "move to" chooser: the account's folders, the selected one marked, over
/// the list it is about.
fn render_move(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const message = inputs.state.selected_const(inputs.store) orelse return;
    var rows: [16]core.state.MoveRow = undefined;

    const count = inputs.state.move_rows(message, &rows);
    if (count == 0) return;

    const visible: u16 = @intCast(@min(count, 12));
    const card_width: u16 = @min(44, lay.columns -| 4);
    // Title on the top border, one row per folder, the hint, the bottom border.
    const card_height: u16 = visible + 3;
    const rect = Rect{
        .x = (lay.columns -| card_width) / 2,
        .y = (lay.rows -| card_height) / 2,
        .width = card_width,
        .height = card_height,
    };
    out.card(rect, inputs.theme.text, inputs.theme.border);
    _ = out.put_text(rect.x + 2, rect.y, " Move to ", card_width -| 4, inputs.theme.accent.with_bold());

    const cursor = @min(@as(usize, inputs.state.move_cursor), count - 1);
    for (rows[0..visible], 0..) |row, index| {
        const y = rect.y + 1 + @as(u16, @intCast(index));
        const style = if (index == cursor) inputs.theme.accent.with_bold() else inputs.theme.text;
        if (index == cursor) {
            out.fill_rect(.{ .x = rect.x + 1, .y = y, .width = card_width -| 2, .height = 1 }, ' ', inputs.theme.selection);
        }
        out.put_text_truncated(rect.x + 2, y, row.title, card_width -| 4, style);
    }
    _ = out.put_text(rect.x + 2, rect.y + 1 + visible, "Enter move · Esc cancel", card_width -| 4, inputs.theme.dim);
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

/// The search prompt as one footer row: what is typed, a cursor, and how many
/// messages match.
fn render_search_line(inputs: Inputs, y: u16, limit: u16, out: *Screen) void {
    _ = out.put_text(1, y, "/", 1, inputs.theme.accent.with_bold());
    const draft = inputs.state.draft.slice();
    const written = out.put_text(3, y, draft, limit -| 4, inputs.theme.text);
    out.put(3 + written, y, ' ', inputs.theme.text.with_reverse());

    var buffer: [24]u8 = undefined;
    const label = if (inputs.state.visible_len == 1)
        std.fmt.bufPrint(&buffer, "1 match", .{}) catch ""
    else
        std.fmt.bufPrint(&buffer, "{d} matches", .{inputs.state.visible_len}) catch "";
    put_right(out, limit -| 1, y, label, inputs.theme.dim);
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
    const left = subject_x(inputs.state, lay.sidebar);
    _ = out.put_text(left, 0, "From", 8, inputs.theme.dim);
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
    _ = out.put_text(left + 9, 0, writer.buffered(), lay.columns -| (left + 11), inputs.theme.dim);
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
    // The store is the live copy, but a refresh can drop a message while it is
    // on screen: what the reader shows comes from the snapshot taken when it was
    // opened, so the page never blanks under the cursor.
    const stored = inputs.state.opened_message(inputs.store);

    const header = Header{
        .subject = if (stored) |message| message.subject.slice() else inputs.state.opened_subject.slice(),
        .from = if (stored) |message| message.from else inputs.state.opened_from,
        .timestamp_unix = if (stored) |message| message.timestamp_unix else inputs.state.opened_time,
        .size_bytes = if (stored) |message| message.size_bytes else inputs.state.opened_size,
        .account = if (stored) |message| message.account else inputs.state.opened_account,
    };

    if (header.subject.len == 0 and !inputs.state.opened.is_known()) {
        put_centered(out, lay.reader_body_y + lay.reader_rows / 2, "Message unavailable", inputs.theme.alert);
        out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
        return;
    }

    const left = subject_x(inputs.state, lay.sidebar);
    out.put_text_truncated(
        left,
        lay.reader_subject_y,
        header.subject,
        lay.columns -| (left + 1),
        inputs.theme.text.with_bold(),
    );
    render_reader_meta(inputs, lay, header, out);
    out.hline(0, lay.reader_rule_y, lay.columns, '─', inputs.theme.border);
    render_body(inputs, lay, out);
    render_hover_popup(inputs, lay, out);
    if (inputs.show_details) render_details(inputs, lay, out);
    out.hline(0, lay.bottom_rule_y, lay.columns, '─', inputs.theme.border);
}

/// What the reader needs to know about the message it is showing.
const Header = struct {
    subject: []const u8,
    from: core.address.Address,
    timestamp_unix: i64,
    size_bytes: u32,
    /// Which of the reader's mailboxes the message came to: the one thing a
    /// message cannot say about itself, and the first thing a reader with two
    /// accounts asks.
    account: core.id.AccountId = .unknown,
};

/// The account a message arrived at, as one line: `work <me@work.example>`.
fn account_line(inputs: Inputs, account: core.id.AccountId, buffer: []u8) []const u8 {
    if (!account.is_known()) return "";
    const address = inputs.state.accounts.address_for(account) orelse return "";
    // An account that never got an address is not an address of "@".
    if (address.local.is_empty() and address.domain.is_empty()) return "";
    var address_buffer: [core.limits.address_max]u8 = undefined;
    const spec = address.addr_spec(&address_buffer);
    if (spec.len == 0) return "";
    const label = inputs.state.accounts.label_for(account);
    var writer = std.Io.Writer.fixed(buffer);
    if (label.len > 0) {
        writer.print("{s} <{s}>", .{ label, spec }) catch {};
    } else {
        writer.print("{s}", .{spec}) catch {};
    }
    return writer.buffered();
}

fn render_reader_meta(inputs: Inputs, lay: layout_mod.Layout, header: Header, out: *Screen) void {
    var date_buffer: [16]u8 = undefined;
    const date = core.time.full_date(&date_buffer, header.timestamp_unix);
    var size_buffer: [16]u8 = undefined;
    const size = size_text(&size_buffer, header.size_bytes);

    // The name somebody chose and the address they actually wrote from: mail
    // clients show both, and so does this one.
    var address_buffer: [core.limits.address_max]u8 = undefined;
    const address = header.from.addr_spec(&address_buffer);
    const named = header.from.name.len > 0 and address.len > 0;

    // The one line says who wrote it and to whom: the recipient is the question a reader
    // asks of a message they did not send. Everything else waits behind `v`.
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    if (named) {
        writer.print("From {s} <{s}>", .{ header.from.name.slice(), address }) catch {};
    } else {
        writer.print("From {s}", .{address}) catch {};
    }
    // To whom: the header when the message has one, and the mailbox it arrived at
    // when it does not -- a notification addressed to you alone often does not, and
    // "which of my accounts is this" is the question that remains.
    var account_buffer: [core.limits.address_max + 32]u8 = undefined;
    const own = account_line(inputs, header.account, &account_buffer);
    const to = inputs.details.to.slice();
    if (to.len > 0) {
        writer.print("  to {s}", .{to}) catch {};
    } else if (own.len > 0) {
        writer.print("  to {s}", .{own}) catch {};
    }
    writer.print("  ·  {s}  ·  {s}", .{ date, size }) catch {};
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

        const line = wrapped.at(line_index, inputs.body);
        var line_inputs = inputs;
        line_inputs.line_index = line_index;
        // "[IMG:…]" is a place to paint, not words to read.
        const visible = if (std.mem.indexOf(u8, line, "[IMG:")) |marker| line[0..marker] else line;
        draw_line_with_links(line_inputs, out, visible, lay.reader_body_y + row, lay.columns - 2);
    }
}

/// The address of the link under the pointer, in a box at the bottom of the
/// body: the mail says "read more", and this is where "read more" goes.
fn render_hover_popup(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const url = inputs.hover_url orelse return;
    if (url.len == 0) return;

    const inner: u16 = @min(@as(u16, @intCast(url.len)), lay.columns -| 6);
    if (inner == 0) return;
    const width: u16 = inner + 4;
    const height: u16 = 3;
    const rect = Rect{
        .x = 1,
        .y = lay.reader_body_y + lay.reader_rows -| (height + 1),
        .width = width,
        .height = height,
    };
    out.card(rect, inputs.theme.text, inputs.theme.accent);
    _ = out.put_text(rect.x + 2, rect.y + 1, url, inner, inputs.theme.accent);
}

/// One wrapped line, with its links underlined so they read as links and not
/// as punctuation soup.
/// What marks a link: the chain. Two cells -- it is an emoji -- which is the size at
/// which a link reads as a link from reading distance; a one-cell glyph next to prose is
/// a speck of dust.
pub const link_mark = "\u{1F517}";

/// What marks a mailbox: an envelope.
pub const mail_mark = "\u{1F4E7}";

/// What marks a phone number: a handset. All three are two cells wide, which is
/// what keeps the layout independent of what kind of link it is.
pub const tel_mark = "\u{1F4DE}";

/// The address a span goes to. An anchor's words carry theirs in `anchors`; a
/// written-out address is its own text.
fn address_of(inputs: Inputs, span: core.links.Link) []const u8 {
    for (inputs.anchors) |anchor| {
        if (anchor.span.start != span.start or anchor.span.end != span.end) continue;
        if (anchor.target.len > 0) return anchor.target;
    }
    const end = @min(span.end, inputs.body.len);
    if (span.start >= end) return "";
    return inputs.body[span.start..end];
}

/// The columns a link's mark takes: the glyph and one blank cell. A mark is a symbol
/// *about* the link, never part of the address -- a chain that touches the URL reads
/// as its first character, and an address with a glyph glued to it is not a link a
/// reader can copy with the eye.
pub fn mark_columns(mark: []const u8) u16 {
    return @as(u16, @intCast(screen.text_columns(mark))) + 1;
}

/// The glyph in front of a link, by where it goes: a chain for a page, an envelope
/// for `mailto:`, a handset for `tel:`.
pub fn mark_for(address: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(address, "mailto:")) return mail_mark;
    if (std.ascii.startsWithIgnoreCase(address, "tel:")) return tel_mark;
    return link_mark;
}

/// How many columns the marks before `before` take on this line. The frame adds it when
/// it draws, and the pointer subtracts it when it is clicked.
pub fn mark_shift(inputs: Inputs, line_start: usize, line_end: usize, before: usize) u16 {
    var shift: u16 = 0;
    for (inputs.links) |link| {
        if (link.end <= line_start or link.start >= line_end) continue;
        // Only the line a link starts on carries its mark.
        if (link.start < line_start) continue;
        if (link.start < before) shift += mark_columns(mark_for(address_of(inputs, link)));
    }
    return shift;
}

fn draw_line_with_links(inputs: Inputs, out: *Screen, line: []const u8, y: u16, width: u16) void {
    if (draw_line_selection(inputs, out, line, y, width)) return;
    if (inputs.links.len == 0) {
        _ = out.put_text(1, y, line, width, line_style(inputs));
        draw_hover(inputs, out, line, y, width);
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
            draw_segment_kind(inputs, out, line, cursor - line_start, start - line_start, y, width, .text, 0);
            cursor = start;
        }
        if (end > cursor) {
            // The mark in front of every link, on the line the link starts: the glyph
            // says where it goes, so a mailbox is not a page.
            const starts_here = link.start >= line_start;
            const mark = mark_for(address_of(inputs, link));
            if (starts_here) {
                const at = screen.text_columns(line[0 .. start - line_start]) + mark_shift(inputs, line_start, line_end, start);
                _ = out.put_text(1 + at, y, mark, width -| at, inputs.theme.accent.with_bold());
            }
            draw_segment_kind(inputs, out, line, cursor - line_start, end - line_start, y, width, .link, mark_columns(mark));
            cursor = end;
        }
    }
    if (cursor < line_end) {
        draw_segment_kind(inputs, out, line, cursor - line_start, line.len, y, width, .text, 0);
    }
    draw_hover(inputs, out, line, y, width);
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

/// The link under the pointer, drawn over the line it is on. It is a separate
/// pass because in the HTML view the link is the anchor's words, which are not
/// one of the written-out addresses.
fn draw_hover(inputs: Inputs, out: *Screen, line: []const u8, y: u16, width: u16) void {
    const hovered = inputs.hovered orelse return;
    const line_start = @intFromPtr(line.ptr) - @intFromPtr(inputs.body.ptr);
    const line_end = line_start + line.len;
    if (hovered.end <= line_start or hovered.start >= line_end) return;
    const start = @max(hovered.start, line_start) - line_start;
    const end = @min(hovered.end, line_end) - line_start;
    if (end <= start) return;
    const marked = hovered.start >= line_start;
    const mark: u16 = if (marked) mark_columns(mark_for(address_of(inputs, hovered))) else 0;
    draw_segment_kind(inputs, out, line, start, end, y, width, .hovered, mark);
}

fn draw_segment_kind(
    inputs: Inputs,
    out: *Screen,
    line: []const u8,
    start: usize,
    end: usize,
    y: u16,
    width: u16,
    kind: Segment,
    /// How many columns this segment's own mark takes, if it has one.
    marked: u16,
) void {
    if (end <= start) return;
    // Columns are counted from the line, which starts after the gutter, plus the marks
    // drawn before this segment on the same line.
    const line_start = @intFromPtr(line.ptr) - @intFromPtr(inputs.body.ptr);
    const line_end = line_start + line.len;
    var offset = screen.text_columns(line[0..start]);
    offset += mark_shift(inputs, line_start, line_end, line_start + start);
    // A segment that carries the link's own mark starts after it.
    offset += marked;
    const segment = line[@min(start, line.len)..@min(end, line.len)];
    _ = out.put_text(1 + offset, y, segment, width -| offset, segment_style(inputs, kind));
}

fn segment_style(inputs: Inputs, kind: Segment) Style {
    return switch (kind) {
        .text => line_style(inputs),
        // Underlining every link turns the body into a sea of lines; the one
        // under the pointer is the one that has to stand out.
        // Underlined as well as coloured: a link has to be a link on a terminal that
        // ignored the colour, and the underline is the one cue every terminal has.
        .link => inputs.theme.accent.with_underline(),
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
    .{ .keys = "/", .action = "search" },
    .{ .keys = "c", .action = "compose" },
    .{ .keys = "r", .action = "reply" },
    .{ .keys = "d", .action = "archive" },
    .{ .keys = "m", .action = "move to another folder" },
    .{ .keys = "^R", .action = "refresh" },
    .{ .keys = "?", .action = "help" },
};

const reader_hints = [_]Hint{
    .{ .keys = "j/k", .action = "scroll" },
    .{ .keys = "i", .action = "pictures" },
    .{ .keys = "\\", .action = "details" },
    .{ .keys = "H", .action = "html" },
    .{ .keys = "r", .action = "reply" },
    .{ .keys = "q", .action = "back (never quits)" },
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
    .{ .keys = "Ctrl+E", .action = "edit body" },
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

/// The current filter, as `/words`, when one is applied and not being typed: while
/// typing, the prompt row already says more.
fn filter_badge(state: *const State, buffer: []u8) ?[]const u8 {
    if (state.mode == .search) return null;
    if (state.view == .reader or state.view == .compose) return null;
    if (state.query.is_empty()) return null;
    return std.fmt.bufPrint(buffer, "/{s}", .{state.query.slice()}) catch null;
}

fn render_footer(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const y = lay.footer_y;
    var right_buffer: [16]u8 = undefined;
    const position = position_text(inputs.state, &right_buffer);
    // A refresh in progress turns the position into "⠹ 3/24": no new row, no
    // transient message, just the spinner next to where you are.
    var spinner_buffer: [32]u8 = undefined;
    var filter_buffer: [core.limits.filter_max + 24]u8 = undefined;
    const right = if (inputs.state.busy()) blk: {
        const glyph = spinner_frames[inputs.state.spinner % spinner_frames.len];
        break :blk std.fmt.bufPrint(&spinner_buffer, "{s} {s}", .{ glyph, position }) catch position;
    } else if (filter_badge(inputs.state, &filter_buffer)) |badge| blk: {
        // The list says it is filtered where a status message cannot cover it: a
        // reader must never wonder why the message they are looking for is not here.
        break :blk std.fmt.bufPrint(&spinner_buffer, "{s}  {s}", .{ badge, position }) catch position;
    } else position;
    const right_width = screen.text_columns(right);
    const limit = lay.columns -| (right_width + 3);
    put_right(out, lay.columns - 2, y, right, inputs.theme.dim);

    // With no bar over the list, a search is typed where the hints live: one
    // prompt row, and the list never moves under it.
    if (inputs.state.mode == .search and !lay.show_header) {
        render_search_line(inputs, y, limit, out);
        return;
    }
    if (!inputs.state.status.is_empty()) {
        const style = if (inputs.state.status_alert) inputs.theme.alert else inputs.theme.accent;
        out.put_text_truncated(1, y, inputs.state.status.slice(), limit -| 1, style);
        return;
    }
    render_hints(hints_for(inputs.state), y, limit, inputs.theme, out);
}

fn position_text(state: *const State, buffer: []u8) []const u8 {
    if (state.view == .reader) {
        const percent = reader_percent(state) orelse return "";
        return std.fmt.bufPrint(buffer, "{d}%", .{percent}) catch "";
    }
    if (state.view == .compose) return "";
    return std.fmt.bufPrint(buffer, "{d}/{d}", .{ list_position(state), state.visible_len }) catch "";
}

fn list_position(state: *const State) u32 {
    if (state.visible_len == 0) return 0;
    return state.cursor + 1;
}

/// How far through the message the reader is: zero at the top, a hundred when the
/// last line is on screen. What is measured is the scroll, not the reading -- at the
/// top of a long mail the eye is at the beginning, whatever is visible below it.
///
/// Null when there is nothing to scroll. A number that cannot move is not a position,
/// and a mail that fits on the screen would wear a "100%" for as long as it is open.
fn reader_percent(state: *const State) ?u32 {
    const scrollable = state.max_reader_scroll();
    if (state.body_rows == 0 or scrollable == 0) return null;
    return @min(100, state.reader_scroll * 100 / scrollable);
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

/// Every key zmail answers to, grouped by where it works. An entry with no
/// `keys` is a heading.
const help_rows = [_]Hint{
    .{ .keys = "", .action = "-- anywhere" },
    .{ .keys = "?", .action = "this card" },
    .{ .keys = "Ctrl+C", .action = "quit (the only way out)" },
    .{ .keys = "/", .action = "search the list" },
    .{ .keys = "Ctrl+R", .action = "refresh from the server" },
    .{ .keys = "J / K", .action = "next / previous folder" },
    .{ .keys = "1 - 9", .action = "the folder in that position, as the sidebar lists it" },
    .{ .keys = "a / A", .action = "next account / accounts overlay" },
    .{ .keys = "", .action = "-- the list" },
    .{ .keys = "Enter / l / →", .action = "open the message" },
    .{ .keys = "j / k", .action = "down / up a row" },
    .{ .keys = "g / G", .action = "first / last row" },
    .{ .keys = "Space, Ctrl+D/U", .action = "a page, and half a page" },
    .{ .keys = "Ctrl+F/B, PageDown", .action = "a whole page" },
    .{ .keys = "Up Down Home End", .action = "the same, without vim" },
    .{ .keys = "c / r", .action = "compose / reply" },
    .{ .keys = "u", .action = "read or unread" },
    .{ .keys = "s / *", .action = "star or unstar" },
    .{ .keys = "d", .action = "archive" },
    .{ .keys = "m", .action = "move to another folder" },
    .{ .keys = "# / Delete", .action = "move to Trash" },
    .{ .keys = "X", .action = "delete for good (Trash only)" },
    .{ .keys = "E", .action = "empty Trash" },
    .{ .keys = "", .action = "-- the reader" },
    .{ .keys = "q / h / Esc / ←", .action = "back to the list" },
    .{ .keys = "j / k / Space", .action = "scroll" },
    .{ .keys = "r / c", .action = "reply / compose" },
    .{ .keys = "o", .action = "the whole mail in a browser" },
    .{ .keys = "H", .action = "HTML view, or the plain text one" },
    .{ .keys = "i", .action = "the pictures the message carries" },
    .{ .keys = "\\", .action = "every header: to, cc, reply-to, date, id" },
    .{ .keys = "u / s / d / #", .action = "as in the list, on this message" },
    .{ .keys = "Ctrl+click", .action = "open the link under the pointer" },
    .{ .keys = "drag", .action = "select, and copy it" },
    .{ .keys = "", .action = "-- writing" },
    .{ .keys = "Tab / Shift+Tab", .action = "next / previous field" },
    .{ .keys = "Enter", .action = "next field, or a line break in the body" },
    .{ .keys = "Ctrl+S", .action = "send in five seconds" },
    .{ .keys = "Ctrl+E", .action = "write the body in $EDITOR" },
    .{ .keys = "Ctrl+U", .action = "clear the field" },
    .{ .keys = "Esc", .action = "cancel, close" },
    .{ .keys = "", .action = "-- the accounts overlay" },
    .{ .keys = "n / e / r / d", .action = "add, edit, rename, remove" },
    .{ .keys = "o", .action = "sign in with the provider" },
    .{ .keys = "Enter / Esc", .action = "use this account / close" },
    .{ .keys = "", .action = "-- in this card" },
    .{ .keys = "/", .action = "filter the keys by word" },
    .{ .keys = "j / k", .action = "scroll" },
    .{ .keys = "any other key", .action = "closes" },
};

/// What the card must mention, checked by a test: a key that works and is not
/// here is a key nobody will find.
const required_in_help = [_][]const u8{
    "Ctrl+C", "Ctrl+R",    "Tab",    "1 - 9",  "a",          "A",        "/",     "j",
    "k",      "g",         "G",      "Ctrl+D", "Ctrl+F",     "PageDown", "Space", "Enter",
    "l",      "o",         "c",      "r",      "u",          "s",        "d",     "#",
    "m",      "X",         "E",      "q",      "h",          "Esc",      "H",     "i",
    "drag",   "Shift+Tab", "Ctrl+S", "Ctrl+U", "Ctrl+E",     "n",        "e",     "Up",
    "Down",   "Home",      "End",    "Delete", "Ctrl+click",
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

    out.card(rect, inputs.theme.text, inputs.theme.border);
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

/// Every header the reader has, over the message it belongs to: the list a mail client
/// hides behind "show details", in the place where the message is.
fn render_details(inputs: Inputs, lay: layout_mod.Layout, out: *Screen) void {
    const details = inputs.details;
    var from_buffer: [core.limits.address_max]u8 = undefined;
    const stored = inputs.state.opened_message(inputs.store);
    const from = if (stored) |message| message.from else inputs.state.opened_from;
    const from_address = from.addr_spec(&from_buffer);
    const card_width: u16 = @min(76, lay.columns - 4);
    const rect = Rect{
        .x = (lay.columns -| card_width) / 2,
        .y = lay.reader_body_y,
        .width = card_width,
        .height = @min(10, lay.reader_rows),
    };
    out.card(rect, inputs.theme.text, inputs.theme.border);
    _ = out.put_text(rect.x + 2, rect.y, " Details ", card_width -| 4, inputs.theme.accent.with_bold());

    var account_buffer: [core.limits.address_max + 32]u8 = undefined;
    const account_id = if (stored) |message| message.account else inputs.state.opened_account;
    const account = account_line(inputs, account_id, &account_buffer);

    var row: u16 = rect.y + 1;
    const rows = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "Account", .value = account },
        .{ .label = "From", .value = from_address },
        .{ .label = "To", .value = details.to.slice() },
        .{ .label = "Cc", .value = details.cc.slice() },
        .{ .label = "Reply-To", .value = details.reply_to.slice() },
        .{ .label = "Date", .value = details.date.slice() },
        .{ .label = "Id", .value = details.message_id.slice() },
    };
    for (rows) |entry| {
        if (row >= rect.bottom() -| 1) break;
        if (entry.value.len == 0) continue;
        _ = out.put_text(rect.x + 2, row, entry.label, 10, inputs.theme.dim);
        _ = out.put_text(rect.x + 12, row, entry.value, card_width -| 14, inputs.theme.text);
        row += 1;
    }
    _ = out.put_text(rect.x + 2, rect.bottom() -| 1, " \\ closes ", card_width -| 4, inputs.theme.dim);
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

    out.card(rect, inputs.theme.text, inputs.theme.border);
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

const help_key_width: u16 = 24;

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
    /// Milliseconds since the splash went up, for the tests that watch it breathe.
    elapsed_ms: i64 = 0,

    fn deinit(self: *Fixture) void {
        self.store.deinit(testing.allocator);
    }

    fn inputs(self: *Fixture, columns: u16, rows: u16) Inputs {
        _ = &self.elapsed_ms;
        return .{
            .elapsed_ms = self.elapsed_ms,
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

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
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

    try row_contains(&out, 0, core.meta.name);
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

test "with the sidebar on, the search prompt is the footer row" {
    var f = try fixture();
    defer f.deinit();
    f.state.accounts.add(core.id.AccountId.from_int(1), "home", .{}, .{});
    f.state.mode = .search;
    f.state.draft.set("a");
    f.state.query.set("a");
    f.state.rebuild(&f.store);

    var inputs = f.inputs(120, 30);
    inputs.sidebar = true;
    var out = Screen.init(120, 30);
    frame(inputs, &out);

    // No bar over the list, so the prompt takes the row the hints would have.
    try row_contains(&out, 29, "/ a");
    try row_contains(&out, 29, "matches");
    // The cursor sits after the typed text, and the row is shifted past the sidebar.
    const shift: u16 = layout_mod.sidebar_width + 2;
    try testing.expect(out.cells[29][shift + 4].style.attrs.reverse);

    // One match is not "1 matches".
    f.state.draft.set("tokens");
    f.state.query.set("tokens");
    f.state.rebuild(&f.store);
    frame(inputs, &out);
    try row_contains(&out, 29, "1 match");
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

    // Still empty: the reader says so instead of showing a blank body.
    f.wrapped = .{};
    f.wrapped_ready = true;
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 3, "no text body");
}

test "frame reports an unavailable message instead of crashing" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .reader;
    // Nothing was ever opened: there is no message to describe.
    f.state.opened = .unknown;

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);
    try row_contains(&out, 12, "Message unavailable");
}

test "a message dropped from the store still reads on screen" {
    var f = try fixture();
    defer f.deinit();
    _ = core.update.apply(&f.state, &f.store, .open_selected);

    // What a refresh does: the mailbox is swapped for a newer list, and the
    // message being read is not in it.
    const opened = f.state.opened;
    _ = f.store.remove_in(f.state.opened_account, f.state.mailbox);
    f.state.rebuild(&f.store);

    const body = "still here";
    @memcpy(f.body[0..body.len], body);
    f.body_len = body.len;
    wrap.wrap(f.body[0..f.body_len], 80, &f.wrapped);
    f.wrapped_ready = true;

    var out = Screen.init(100, 24);
    frame(f.inputs(100, 24), &out);

    // The header comes from the snapshot, and the body is still drawn.
    try testing.expectEqual(opened, f.state.opened);
    var found = false;
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var buffer: [256]u8 = undefined;
        if (std.mem.indexOf(u8, out.row_text(row, &buffer), f.state.opened_subject.slice()) != null) found = true;
    }
    try testing.expect(found);
    found = false;
    row = 0;
    while (row < 24) : (row += 1) {
        var buffer: [256]u8 = undefined;
        if (std.mem.indexOf(u8, out.row_text(row, &buffer), "still here") != null) found = true;
    }
    try testing.expect(found);
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
    try row_contains(&out, 23, "50%");
}

test "the reader's percentage is where you are, not how much you have seen" {
    // Top of the mail: nothing has scrolled. Bottom: everything that can scroll has.
    var state: State = .{ .list_rows = 20 };
    state.view = .reader;
    state.reader_rows = 10;

    var buffer: [32]u8 = undefined;
    state.body_rows = 20;
    try testing.expectEqualStrings("0%", position_text(&state, &buffer));

    state.reader_scroll = 5;
    try testing.expectEqualStrings("50%", position_text(&state, &buffer));

    state.reader_scroll = 10;
    try testing.expectEqualStrings("100%", position_text(&state, &buffer));

    // A message shorter than the window is all of it: there is nothing to scroll, so
    // there is no position to report, and the footer says nothing rather than "100%"
    // for the whole time the reader is open.
    state.body_rows = 4;
    state.reader_scroll = 0;
    try testing.expectEqualStrings("", position_text(&state, &buffer));

    // Nothing loaded yet is not a position either.
    state.body_rows = 0;
    try testing.expectEqualStrings("", position_text(&state, &buffer));
}

test "the boot splash is a wordmark, the account, and a footer" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;
    f.state.accounts.add(core.id.AccountId.from_int(1), "work", try core.address.Address.init("alice@example.com"), .{});

    var out = Screen.init(80, 24);
    frame(f.inputs(80, 24), &out);
    // middle = 12: the big mark on 5..14, status on 17, address on 18, footer 23.
    try row_contains(&out, 5, "█████████████   ███      ████   █████████████   █████   █████");
    try row_contains(&out, 14, "█████████████   ███      ████   █████   █████   █████   ███████████");
    try row_contains(&out, 23, "connecting to work");
    try row_contains(&out, 17, "alice@example.com");
    // The version, from the manifest, right under the mark.
    var version_buffer: [64]u8 = undefined;
    let_version: {
        const line = std.fmt.bufPrint(&version_buffer, "version: {s}", .{core.meta.version}) catch break :let_version;
        try row_contains(&out, 16, line);
    }
    var footer_buffer: [512]u8 = undefined;
    const footer = std.mem.trim(u8, out.row_text(23, &footer_buffer), " ");
    // The footer is the sentence on the left and the way out on the right, with the
    // middle kept clear.
    try testing.expect(startsWith(footer, "connecting to work"));
    try testing.expect(std.mem.endsWith(u8, footer, "Ctrl+C quits"));
    try testing.expect(std.mem.indexOf(u8, footer, "cached mail") == null);

    // The list is not drawn behind it.
    var row_buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, out.row_text(2, &row_buffer), "Inbox") == null);
}

test "the light moves across the splash.wordmark while its shape stays put" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;

    var before = Screen.init(80, 24);
    f.elapsed_ms = 0;
    frame(f.inputs(80, 24), &before);
    var after = Screen.init(80, 24);
    // Three ticks in: past the peak, still on screen -- the far side of the breath
    // (the trough) is a different test, and there the glyphs are gone on purpose.
    f.elapsed_ms = 540;
    frame(f.inputs(80, 24), &after);

    var moved = false;
    for (5..15) |y| {
        for (0..80) |x| {
            // The letters never change, only how lit they are.
            try testing.expectEqual(before.cells[y][x].ch, after.cells[y][x].ch);
            if (!before.cells[y][x].style.eql(after.cells[y][x].style)) moved = true;
        }
    }
    try testing.expect(moved);
}

test "reduced motion draws one still frame" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;

    var inputs = f.inputs(80, 24);
    inputs.reduced_motion = true;

    var first = Screen.init(80, 24);
    f.state.spinner = 0;
    frame(inputs, &first);
    var later = Screen.init(80, 24);
    f.state.spinner = 9;
    frame(inputs, &later);

    for (0..24) |y| {
        for (0..80) |x| {
            try testing.expect(first.cells[y][x].style.eql(later.cells[y][x].style));
        }
    }
}

test "a cramped splash drops the address before it reaches the footer" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;
    f.state.accounts.add(core.id.AccountId.from_int(1), "work", try core.address.Address.init("alice@example.com"), .{});

    var out = Screen.init(40, 10);
    frame(f.inputs(40, 10), &out);
    // Ten rows: middle is 5, so the splash.wordmark starts at 1 and the footer is 9.
    try row_contains(&out, 1, "█████");
    var footer_buffer: [512]u8 = undefined;
    const footer = out.row_text(9, &footer_buffer);
    try testing.expect(std.mem.indexOf(u8, footer, "Ctrl+C quits") != null);
    // Two things fit on a forty-column row, and these are the two.
    try testing.expect(startsWith(std.mem.trim(u8, footer, " "), "connecting to work"));
    try testing.expect(std.mem.indexOf(u8, footer, "alice@example.com") == null);
}

test "the splash names the account in scope, not every account" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;
    f.state.accounts.add(core.id.AccountId.from_int(1), "home", try core.address.Address.init("me@home.example"), .{});
    f.state.accounts.add(core.id.AccountId.from_int(2), "work", try core.address.Address.init("me@work.example"), .{});
    f.state.account_filter = core.id.AccountId.from_int(2);

    var out = Screen.init(80, 24);
    frame(f.inputs(80, 24), &out);
    try row_contains(&out, 23, "connecting to work");
    var row_buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, out.row_text(17, &row_buffer), "home") == null);
}

test "the splash.wordmark is lit by the derived theme, not by a fixed palette" {
    var f = try fixture();
    defer f.deinit();
    f.theme = theme_mod.Theme.from_background(.{ .r = 25, .g = 25, .b = 37 });
    f.state.booting = true;

    var out = Screen.init(80, 24);
    frame(f.inputs(80, 24), &out);

    var lit: u32 = 0;
    var ansi: u32 = 0;
    for (5..15) |y| {
        for (0..80) |x| {
            switch (out.cells[y][x].style.fg) {
                .rgb => lit += 1,
                // A 256-colour index here would mean the first screen kept its
                // own palette while the rest of the app followed the terminal.
                .ansi256 => ansi += 1,
                .default => {},
            }
        }
    }
    try testing.expect(lit > 0);
    try testing.expectEqual(@as(u32, 0), ansi);
}

test "the splash breathes without color when color is off" {
    var f = try fixture();
    defer f.deinit();
    f.theme = theme_mod.Theme.mono();
    f.state.booting = true;
    f.state.spinner = 8;

    var out = Screen.init(80, 24);
    frame(f.inputs(80, 24), &out);
    for (0..24) |y| {
        for (0..80) |x| {
            const style = out.cells[y][x].style;
            try testing.expect(std.meta.eql(style.fg, screen.Color.default));
            try testing.expect(std.meta.eql(style.bg, screen.Color.default));
        }
    }

    // And the breath is still there: weight carries it when hue cannot.
    var other = Screen.init(80, 24);
    // Far enough into the breath for the two-step monochrome ramp to change: bold at
    // the top, dim once it is past half.
    f.elapsed_ms = 2_400;
    frame(f.inputs(80, 24), &other);
    var moved = false;
    for (5..15) |y| {
        for (0..80) |x| {
            if (!out.cells[y][x].style.eql(other.cells[y][x].style)) moved = true;
        }
    }
    try testing.expect(moved);
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

    try row_contains(&out, 0, core.meta.name);
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
    // As wide as the row, less the mark: the link's chain takes its columns first.
    const mark_width: u16 = mark_columns(link_mark);
    wrap.wrap(body, 20 - mark_width, &wrapped);
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

    // The body starts in column 1, so the row carries a leading cell and then the
    // wrapped line: no gaps, no doubled spaces. The link's mark sits before it, once.
    var text_buffer: [64]u8 = undefined;
    const first = std.mem.trimEnd(u8, canvas.row_text(0, &text_buffer), " ");
    // The row starts with the gutter, the link's chain (and the cells it continues into),
    // and then the line itself.
    var expected: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&expected);
    writer.writeAll(link_mark) catch unreachable;
    // The cells the chain continues into are the wide glyph's second half: the screen
    // keeps them as zero, and skips them when it writes the row. Then the blank cell
    // that keeps the mark off the address.
    const glyph: u16 = @intCast(screen.text_columns(link_mark));
    var pad: u16 = 1;
    while (pad < glyph) : (pad += 1) writer.writeByte(0) catch unreachable;
    writer.writeByte(' ') catch unreachable;
    writer.writeAll(wrapped.at(0, body)) catch unreachable;
    try testing.expectEqualStrings(writer.buffered(), std.mem.trimStart(u8, first, " "));
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
    // The sender is not named twice: an address with no display name is the name.
    try testing.expect(!screen_contains(&out, "From bob@example.com <bob@example.com>"));
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
        try testing.expect(found);
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

test "the address of the hovered link shows in a popup" {
    var f = try fixture();
    defer f.deinit();
    // A real message, so the reader has something to draw over.
    f.state.view = .reader;
    const opened = f.state.selected(&f.store).?;
    f.state.opened_account = opened.account;
    f.state.opened = opened.id;
    const body = "Read the docs today";
    @memcpy(f.body[0..body.len], body);
    f.body_len = body.len;
    wrap.wrap(body, 80, &f.wrapped);
    f.wrapped_ready = true;

    var out = Screen.init(100, 24);
    var inputs = f.inputs(100, 24);
    inputs.hovered = .{ .start = 5, .end = 13 };
    inputs.hover_url = "https://example.com/a";
    frame(inputs, &out);

    // The popup sits over the body, with the whole address in it.
    var found = false;
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var buffer: [256]u8 = undefined;
        if (std.mem.indexOf(u8, out.row_text(row, &buffer), "https://example.com/a") != null) found = true;
    }
    try testing.expect(found);

    // With nothing hovered there is no popup.
    var plain = Screen.init(100, 24);
    inputs.hover_url = null;
    inputs.hovered = null;
    frame(inputs, &plain);
    row = 0;
    while (row < 24) : (row += 1) {
        var buffer: [256]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, plain.row_text(row, &buffer), "https://example.com/a") == null);
    }
}

/// The rows of a screen as one buffer, newline separated, so a test can look for
/// text without knowing which row it landed on.
fn screen_text(out: *const Screen, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (0..out.rows) |y| {
        const line = out.row_text(@intCast(y), buffer[len..]);
        len += line.len;
        buffer[len] = '\n';
        len += 1;
    }
    return buffer[0..len];
}

/// The form's field order, which the session owns; a test only needs the shape.
const FormField = enum(u8) {
    address,
    imap_host,
    imap_port,
    smtp_host,
    smtp_port,
    sign_in,
    password,
    advanced,
    username,
    client_id,
};

test "the account form shows the OAuth client id and the username when advanced is open" {
    const theme = theme_mod.Theme.dark();
    var setup = core.setup.Setup.init();
    setup.address.set("me@example.com");
    setup.set_oauth(true);
    setup.show_advanced = true;
    setup.oauth_client_id.set("abc-123");
    setup.username.set("me");

    var out = Screen.init(80, 24);
    var text: [4096]u8 = undefined;
    settings(&setup, FormField.client_id, false, theme, &out);
    const drawn = screen_text(&out, &text);
    try testing.expect(std.mem.indexOf(u8, drawn, "Client ID") != null);
    try testing.expect(std.mem.indexOf(u8, drawn, "abc-123") != null);
    try testing.expect(std.mem.indexOf(u8, drawn, "Username") != null);

    // The username row reads as the address when none was typed.
    setup.username.clear();
    settings(&setup, FormField.username, false, theme, &out);
    try testing.expect(std.mem.indexOf(u8, screen_text(&out, &text), "me@example.com") != null);
}

test "the account form says what went wrong, and what Enter does on the last row" {
    const theme = theme_mod.Theme.dark();
    var setup = core.setup.Setup.init();
    setup.problem.set("the server refused the password");

    var out = Screen.init(80, 24);
    var text: [4096]u8 = undefined;
    settings(&setup, FormField.password, false, theme, &out);
    try testing.expect(std.mem.indexOf(u8, screen_text(&out, &text), "the server refused the password") != null);

    // With no OAuth and nothing unfolded, Advanced is the last row of the form,
    // and there Enter saves instead of moving on.
    setup.problem.clear();
    settings(&setup, FormField.advanced, false, theme, &out);
    try testing.expect(std.mem.indexOf(u8, screen_text(&out, &text), "Enter saves") != null);
}

test "a quote is drawn dimmer than the words around it" {
    const theme = theme_mod.Theme.dark();
    const kinds = [_]core.html.Kind{ .body, .quote };
    const lines = [_][]const u8{ "the words", "the quoted words" };

    var out: Screen = .{};
    out.resize(40, 1);
    const inputs = Inputs{
        .state = undefined,
        .store = undefined,
        .theme = &theme,
        .body = "",
        .wrapped = undefined,
        .columns = 40,
        .rows = 1,
        .now_unix = 0,
        .line_index = 1,
        .kinds = &kinds,
    };
    // line_style is what decides: the quote row is dim, the body row is not.
    draw_line_with_links(inputs, &out, lines[1], 0, 40);
    try testing.expectEqual(theme.dim, out.cells[0][1].style);
    const body_row = Inputs{
        .state = undefined,
        .store = undefined,
        .theme = &theme,
        .body = "",
        .wrapped = undefined,
        .columns = 40,
        .rows = 1,
        .now_unix = 0,
        .line_index = 0,
        .kinds = &kinds,
    };
    out.resize(40, 1);
    draw_line_with_links(body_row, &out, lines[0], 0, 40);
    try testing.expectEqual(theme.text, out.cells[0][1].style);
}

test "a drag over the body paints only what the drag covers" {
    const theme = theme_mod.Theme.dark();
    const lines = [_][]const u8{ "first line", "second line" };

    var out: Screen = .{};
    out.resize(20, 2);
    const drag = selection.Selection{
        .anchor = .{ .line = 0, .column = 6 },
        .cursor = .{ .line = 1, .column = 5 },
    };

    // The drag starts on the first line at column 6 and ends on the second at
    // column 5, so "line" on the first and "second" on the second are painted.
    for (lines, 0..) |line, y| {
        const inputs = Inputs{
            .state = undefined,
            .store = undefined,
            .theme = &theme,
            .body = "",
            .wrapped = undefined,
            .columns = 20,
            .rows = 2,
            .now_unix = 0,
            .line_index = @intCast(y),
            .selection = drag,
        };
        try testing.expect(draw_line_selection(inputs, &out, line, @intCast(y), 20));
    }
    // Nothing is drawn left of column 1.
    try testing.expectEqual(theme.text, out.cells[0][1].style);
    try testing.expectEqual(theme.selection, out.cells[0][7].style);
    try testing.expectEqual(theme.selection, out.cells[1][1].style);
    try testing.expectEqual(theme.text, out.cells[1][7].style);

    // A line the drag does not reach is not painted by it.
    const outside = Inputs{
        .state = undefined,
        .store = undefined,
        .theme = &theme,
        .body = "",
        .wrapped = undefined,
        .columns = 20,
        .rows = 2,
        .now_unix = 0,
        .line_index = 5,
        .selection = drag,
    };
    try testing.expect(!draw_line_selection(outside, &out, lines[0], 0, 20));
}

/// The columns of `row` painted as the band of light.
fn shimmer_columns(out: *const Screen, row: u16, theme: *const Theme, buffer: []u16) []const u16 {
    var count: usize = 0;
    const band = theme.accent.with_bold();
    for (0..out.columns) |x| {
        if (!std.meta.eql(out.cells[row][x].style, band)) continue;
        buffer[count] = @intCast(x);
        count += 1;
    }
    return buffer[0..count];
}

test "the band keeps its width and travels along the line" {
    const theme = theme_mod.Theme.dark();
    var buffer: [64]u16 = undefined;

    // Two moments where the band is fully over the text: it does not grow, it
    // moves, which is what a pulse is and a fill is not.
    var early = Screen.init(60, 1);
    _ = splash.draw_shimmer(&early, 0, 0, "connecting to home", 400, &theme);
    const before = shimmer_columns(&early, 0, &theme, &buffer);
    const before_len = before.len;
    const before_start = if (before.len > 0) before[0] else 0;

    var later = Screen.init(60, 1);
    _ = splash.draw_shimmer(&later, 0, 0, "connecting to home", 700, &theme);
    const after = shimmer_columns(&later, 0, &theme, &buffer);

    try testing.expect(before_len > 0);
    try testing.expectEqual(before_len, after.len);
    try testing.expect(before_start < after[0]);
    // A band, never the whole line.
    try testing.expect(@as(u16, @intCast(before_len)) <= splash.shimmer_width);
}

test "the band crosses one way only" {
    const theme = theme_mod.Theme.dark();
    const text = "connecting to home";
    const width: u16 = @intCast(screen.text_columns(text));

    var buffer: [64]u16 = undefined;
    var previous: i64 = -1;
    var rising_seen = false;
    var backward = false;

    // Five seconds of watching: several crossings, and never a step to the left
    // while the band is on the line.
    var moment: i64 = 0;
    while (moment < 5_000) : (moment += 20) {
        var out = Screen.init(60, 1);
        _ = splash.draw_shimmer(&out, 0, 0, text, moment, &theme);
        const columns = shimmer_columns(&out, 0, &theme, &buffer);
        const position: i64 = if (columns.len > 0) columns[0] else -1;
        if (previous >= 0 and position >= 0) {
            if (position > previous) rising_seen = true;
            if (position < previous) backward = true;
        }
        previous = position;
    }
    _ = width;
    try testing.expect(rising_seen);
    // Left to right, then it starts again: it never travels back.
    try testing.expect(!backward);
}

test "the band leaves the line at both ends and comes round" {
    const theme = theme_mod.Theme.dark();
    const text = "connecting";
    const width: u16 = @intCast(screen.text_columns(text));
    const span: i64 = width + splash.shimmer_width;

    var seen_off = false;
    var seen_on = false;
    var buffer: [64]u16 = undefined;
    var moment: i64 = 0;
    const cycle_ms: i64 = @divTrunc(3 * span * 1000, @as(i64, splash.shimmer_speed));
    while (moment < cycle_ms) : (moment += 40) {
        var out = Screen.init(40, 1);
        _ = splash.draw_shimmer(&out, 0, 0, text, moment, &theme);
        const columns = shimmer_columns(&out, 0, &theme, &buffer);
        if (columns.len == 0) seen_off = true;
        if (columns.len == splash.shimmer_width) seen_on = true;
    }
    // It enters, it crosses, it leaves, it starts again.
    try testing.expect(seen_off);
    try testing.expect(seen_on);
}

test "a shimmer with nothing to shine on draws nothing" {
    const theme = theme_mod.Theme.dark();
    var out = Screen.init(10, 1);
    try testing.expectEqual(@as(u16, 0), splash.draw_shimmer(&out, 0, 0, "", 0, &theme));
    try testing.expectEqual(@as(u16, 0), splash.draw_shimmer(&out, 0, 5, "text", 0, &theme));
    try testing.expectEqual(@as(u16, 0), splash.draw_shimmer(&out, 12, 0, "text", 0, &theme));
}

test "the splash.wordmark breathes: it dims and comes back, and never leaves" {
    var lowest: f32 = 1;
    var highest: f32 = 0;
    var moment: i64 = 0;
    while (moment < splash.breath_ms) : (moment += 90) {
        const level = splash.breath_level_at(moment);
        lowest = @min(lowest, level);
        highest = @max(highest, level);
    }
    // Solid at the peak, quieter at the trough -- and never transparent enough to be
    // gone: the mark stays readable while it breathes.
    try testing.expect(highest >= 0.99);
    try testing.expect(lowest >= splash.breath_floor - 0.01);
    try testing.expect(lowest < 0.6);
}

test "at the trough the mark is dimmer, and at the peak it is whole" {
    var f = try fixture();
    defer f.deinit();
    f.state.booting = true;

    var shown = Screen.init(80, 24);
    f.elapsed_ms = 0;
    frame(f.inputs(80, 24), &shown);

    var hidden = Screen.init(80, 24);
    // Half a breath in -- the trough of the cosine: nothing is painted at all.
    f.elapsed_ms = splash.breath_ms / 2;
    frame(f.inputs(80, 24), &hidden);

    var drawn_shown = false;
    var drawn_hidden = false;
    for (0..24) |y| {
        for (0..80) |x| {
            const mark = shown.cells[y][x].ch == '█' or shown.cells[y][x].ch == '▀';
            if (mark) drawn_shown = true;
            const gone = hidden.cells[y][x].ch == '█' or hidden.cells[y][x].ch == '▀';
            if (gone) drawn_hidden = true;
        }
    }
    try testing.expect(drawn_shown);
    // Still drawn at the trough: quieter, not gone.
    try testing.expect(drawn_hidden);
    var dimmer = false;
    for (0..24) |y| {
        for (0..80) |x| {
            const before = shown.cells[y][x].style;
            const after = hidden.cells[y][x].style;
            if (!before.eql(after) and hidden.cells[y][x].ch == '█') dimmer = true;
        }
    }
    try testing.expect(dimmer);
    // Nothing else moved: the words under it are still there while it is gone.
    try testing.expect(screen_contains(&hidden, "connecting to"));
}

test "a faded letter is mixed towards the terminal's own ground" {
    // A light terminal fades towards its paper; a dark one towards its own dark.
    const paper = theme_mod.Theme.from_background(.{ .r = 253, .g = 246, .b = 227 });
    const night = theme_mod.Theme.from_background(.{ .r = 20, .g = 20, .b = 24 });

    const faint_on_paper = splash.breath_style(&paper, 0.05);
    const faint_at_night = splash.breath_style(&night, 0.05);
    try testing.expect(faint_on_paper.fg == .rgb);
    try testing.expect(faint_at_night.fg == .rgb);

    const paper_level = core.oklch.luminance(.{ .r = faint_on_paper.fg.rgb.r, .g = faint_on_paper.fg.rgb.g, .b = faint_on_paper.fg.rgb.b });
    const night_level = core.oklch.luminance(.{ .r = faint_at_night.fg.rgb.r, .g = faint_at_night.fg.rgb.g, .b = faint_at_night.fg.rgb.b });
    try testing.expect(paper_level > night_level);
    // Faded is dimmer than solid, on the same ground.
    const solid = splash.breath_style(&night, 1.0);
    const solid_level = core.oklch.luminance(.{ .r = solid.fg.rgb.r, .g = solid.fg.rgb.g, .b = solid.fg.rgb.b });
    try testing.expect(solid_level > night_level);
}

test "without a derivation the breath is carried by weight and the palette's steps" {
    const mono = theme_mod.Theme.mono();
    try testing.expect(splash.breath_style(&mono, 0.2).attrs.dim);
    try testing.expect(splash.breath_style(&mono, 0.9).attrs.bold);

    // The built-in palette has no ground to mix towards: it walks its own ramp.
    const dark = theme_mod.Theme.dark();
    var lowest: u8 = 255;
    var highest: u8 = 0;
    var tick: u16 = 0;
    while (tick < splash.breath_ticks * 2) : (tick += 1) {
        const index = splash.breath_style(&dark, splash.breath_level_at(tick * 90)).fg.ansi256;
        lowest = @min(lowest, index);
        highest = @max(highest, index);
    }
    try testing.expect(lowest < highest);
}

test "the breath moves from the first tick, at a speed the eye can see" {
    // A cosine would spend its first quarter within two per cent of the peak: a mark
    // that looks frozen. The level has to be a visible step away by the second tick.
    const first = splash.breath_level_at(0);
    const second = splash.breath_level_at(90);
    try testing.expectEqual(@as(f32, 1.0), first);
    try testing.expect(first - second > 0.05);
    // And the way back is the same movement in reverse: empty at the trough, and up
    // again four ticks later.
    try testing.expectEqual(splash.breath_floor, splash.breath_level_at(splash.breath_ms / 2));
    // And it climbs again on the way back, without a plateau at the bottom.
    try testing.expect(splash.breath_level_at(splash.breath_ms / 2 + 540) > splash.breath_level_at(splash.breath_ms / 2 + 180));
    try testing.expect(splash.breath_level_at(splash.breath_ms / 2 + 540) > splash.breath_floor);
}

test "the footer: two corners, and nothing between them" {
    var buffer: [64]u8 = undefined;
    const left = splash.splash_line(24, "work, home", &buffer);
    var other: [64]u8 = undefined;
    const right = splash.splash_right(80, 24, &other);

    try testing.expectEqualStrings("connecting to work, home", left.text);
    try testing.expectEqualStrings("Ctrl+C quits", right.text);
    try testing.expectEqual(left.row, right.row);
    try testing.expectEqual(@as(u16, 1), left.left);
    // Two columns in from the right edge, and clear of the left sentence.
    try testing.expectEqual(@as(u16, 80 - 2 - 12), right.left);
    try testing.expect(left.left + screen.text_columns(left.text) < right.left);

    // A buffer too small truncates instead of writing past it.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("Ctrl", splash.splash_right(80, 24, &small).text);
}

test "both sizes of the mark answer their own cells" {
    const huge = splash.splash_mark(120, 24);
    try testing.expectEqual(@as(u8, 3), huge.scale);
    // As big as the screen allows, up to four cells a stroke.
    const widest = splash.splash_mark(170, 45);
    try testing.expectEqual(@as(u8, 4), widest.scale);
    const large = splash.splash_mark(90, 24);
    try testing.expectEqual(@as(u8, 2), large.scale);
    try testing.expect(splash.mark_cell(2, 0, 0) != 0);

    const small = splash.splash_mark(36, 24);
    try testing.expectEqual(@as(u8, 1), small.scale);
    try testing.expect(splash.mark_cell(1, 0, 0) != 0);
    // The masthead is the same word at twice the size, in both directions.
    try testing.expectEqual(small.width * 2, large.width);
    try testing.expectEqual(small.width * 3, huge.width);
    try testing.expectEqual(small.height * 2, large.height);
}

test "every link gets a mark, and only one each" {
    const body = "one https://a.example/x two https://b.example/y and a long one " ++
        "https://c.example/a/very/long/address/that/wraps/over/two/lines/at/this/width";
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, 40, &wrapped);

    var buffer: [core.links.max_links]core.links.Link = undefined;
    const count = core.links.scan(body, &buffer);

    var canvas: Screen = .{};
    canvas.resize(60, 12);
    const state = State{};
    const theme = Theme.dark();
    var row: u16 = 0;
    while (row < wrapped.len) : (row += 1) {
        const inputs = Inputs{
            .state = &state,
            .store = undefined,
            .theme = &theme,
            .body = body,
            .links = buffer[0..count],
            .line_index = row,
        };
        draw_line_with_links(inputs, &canvas, wrapped.at(row, body), row, 50);
    }

    var marks: usize = 0;
    var row_buffer: [512]u8 = undefined;
    var line: u16 = 0;
    while (line < canvas.rows) : (line += 1) {
        marks += std.mem.count(u8, canvas.row_text(line, &row_buffer), link_mark);
    }
    // One per link, even the one that wraps: three links, three marks.
    try testing.expectEqual(@as(usize, 3), marks);
    try testing.expectEqual(@as(usize, 3), count);
}

test "the meta line says who the message was sent to" {
    var store = try core.store.Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);
    var state: State = .{ .list_rows = 20 };
    state.view = .reader;
    state.opened_subject.set("hi");
    state.opened_from = try core.address.Address.init("Alice <alice@example.com>");

    var details_copy = core.headers.Details{};
    details_copy.to.set("bob@example.com");

    var out: Screen = .{};
    frame(.{
        .state = &state,
        .store = &store,
        .theme = &Theme.dark(),
        .body = "",
        .wrapped = null,
        .details = &details_copy,
        .columns = 100,
        .rows = 24,
        .now_unix = 1_700_000_000,
    }, &out);
    var row_buffer: [512]u8 = undefined;
    var line: u16 = 0;
    var found = false;
    while (line < out.rows) : (line += 1) {
        if (std.mem.indexOf(u8, out.row_text(line, &row_buffer), "to bob@example.com") != null) found = true;
    }
    try testing.expect(found);
}

test "the sidebar lists every account's folders, and a row knows where it leads" {
    var f = try fixture();
    defer f.deinit();
    f.state.accounts.add(core.id.AccountId.from_int(1), "home", .{}, .{});
    f.state.accounts.add(core.id.AccountId.from_int(2), "work", .{}, .{});

    var rows: [max_sidebar_rows]SidebarRow = undefined;
    const count = sidebar_rows(&f.state.accounts, &f.state.folders, null, &rows);
    // All accounts, the two of them, and the six folders of the scope. The rule
    // between the two halves is a gap in `y`, not a row of its own.
    try testing.expectEqual(@as(usize, 1 + 2 + 6), count);
    try testing.expectEqual(SidebarEntry.all_accounts, rows[0].entry);
    try testing.expectEqual(@as(u16, 0), rows[0].y);

    const first_account = rows[1];
    try testing.expectEqual(@as(u16, 1), first_account.y);
    try testing.expectEqual(SidebarEntry{ .account = core.id.AccountId.from_int(1) }, first_account.entry);
    // The rule sits at y = 3, so the folders start under it.
    try testing.expectEqual(@as(u16, 4), rows[3].y);
    try testing.expectEqual(
        SidebarEntry{ .folder = .{ .account = null, .mailbox = .inbox } },
        rows[3].entry,
    );
    // The folders are the ones of the scope on screen: this account's, here.
    var account_rows: [max_sidebar_rows]SidebarRow = undefined;
    const account_count = sidebar_rows(&f.state.accounts, &f.state.folders, core.id.AccountId.from_int(2), &account_rows);
    try testing.expectEqual(count, account_count);
    try testing.expectEqual(
        SidebarEntry{ .folder = .{ .account = core.id.AccountId.from_int(2), .mailbox = .inbox } },
        account_rows[3].entry,
    );

    // The same list answers the mouse.
    try testing.expectEqual(first_account.entry, sidebar_hit(&f.state.accounts, &f.state.folders, null, 1).?);
    try testing.expect(sidebar_hit(&f.state.accounts, &f.state.folders, null, 3) == null);
    try testing.expect(sidebar_hit(&f.state.accounts, &f.state.folders, null, 99) == null);
}

test "with the sidebar on, the folders are on the left and the list starts after the rule" {
    var f = try fixture();
    defer f.deinit();
    f.state.accounts.add(core.id.AccountId.from_int(1), "home", .{}, .{});
    f.state.accounts.add(core.id.AccountId.from_int(2), "work", .{}, .{});
    f.store.at(0).account = core.id.AccountId.from_int(2);
    f.state.rebuild(&f.store);

    // The list is on another mailbox of the first account: Sent is the active row,
    // and the unread Inbox beside it is not.
    f.state.mailbox = .sent;
    f.state.account_filter = core.id.AccountId.from_int(1);
    var inputs = f.inputs(120, 30);
    inputs.sidebar = true;
    var out = Screen.init(120, 30);
    frame(inputs, &out);

    try row_contains(&out, 0, "ALL ACCOUNTS");
    try row_contains(&out, 1, "home");
    try row_contains(&out, 2, "work");
    try row_contains(&out, 4, "Inbox");
    // The rule is the sidebar's last column, and the list starts next to it.
    try testing.expectEqual(@as(u21, '│'), out.cells[0][layout_mod.sidebar_width].ch);
    try testing.expectEqual(@as(u21, ' '), out.cells[0][layout_mod.sidebar_width + 1].ch);
    // No bar over the list: the first row of mail is row 0 of the screen.
    try row_contains(&out, 0, "Alice Rivera");
    // The scope row counts what is behind it, at the sidebar's right edge.
    try testing.expectEqual(@as(u21, '2'), out.cells[0][layout_mod.sidebar_width - 2].ch);
    // A folder row counts its own mailbox, in the scope on screen: one unread each.
    try testing.expectEqual(@as(u21, '1'), out.cells[4][layout_mod.sidebar_width - 2].ch);
    // A folder with unread mail that is not the one on screen still reads as text,
    // not as the dim of a mailbox with nothing in it.
    try testing.expectEqual(f.theme.text.with_bold().fg, out.cells[4][3].style.fg);
}

test "the sidebar draws the server's own name for a folder the six do not cover" {
    var f = try fixture();
    defer f.deinit();
    const account = core.id.AccountId.from_int(1);
    f.state.accounts.add(account, "work", .{}, .{});
    _ = f.state.folders.add(account, "Inbox", .inbox);
    _ = f.state.folders.add(account, "Clients", null);
    f.state.account_filter = account;
    // The second folder of the scope is the one the six do not cover, and it is
    // the one on screen.
    f.state.named = .{ .account = account, .slot = 1 };

    var inputs = f.inputs(120, 30);
    inputs.sidebar = true;
    var out = Screen.init(120, 30);
    frame(inputs, &out);

    // Rows: 0 all accounts, 1 the account, 2 the rule, 3 Inbox, 4 Clients.
    try row_contains(&out, 3, "Inbox");
    try row_contains(&out, 4, "Clients");
    // The active folder is the named one, so its row carries the selection.
    try testing.expectEqual(f.theme.selection.bg, out.cells[4][1].style.bg);
    try testing.expect(!std.meta.eql(out.cells[3][1].style.bg, f.theme.selection.bg));
}

test "the move chooser lists the account's folders over the list" {
    var f = try fixture();
    defer f.deinit();
    const account = core.id.AccountId.from_int(1);
    f.state.accounts.add(account, "work", .{}, .{});
    _ = f.state.folders.add(account, "Inbox", .inbox);
    _ = f.state.folders.add(account, "Clients", null);
    // The first message is in Inbox, so the chooser offers Clients.
    f.store.at(0).account = account;
    f.state.moving = true;
    f.state.move_cursor = 1;

    var inputs = f.inputs(100, 24);
    inputs.sidebar = true;
    var out = Screen.init(100, 24);
    frame(inputs, &out);

    try row_contains(&out, 0, "Alice Rivera");
    // The card says what it is, and where the cursor is.
    var found = false;
    var line: u16 = 0;
    var buffer: [512]u8 = undefined;
    while (line < out.rows) : (line += 1) {
        const text = out.row_text(line, &buffer);
        if (std.mem.indexOf(u8, text, "Move to") != null) found = true;
        if (std.mem.indexOf(u8, text, "Enter move") != null) found = true;
    }
    try testing.expect(found);
    try testing.expect(std.mem.indexOf(u8, out.row_text(0, &buffer), "Inbox") == null);
}

test "a named folder with more unread than fits is counted as 999" {
    var f = try fixture();
    defer f.deinit();
    const account = core.id.AccountId.from_int(1);
    f.state.accounts.add(account, "work", .{}, .{});
    _ = f.state.folders.add_counted(account, "Clients", "", null, 1500);
    f.state.account_filter = account;

    var inputs = f.inputs(100, 24);
    inputs.sidebar = true;
    var out = Screen.init(100, 24);
    frame(inputs, &out);

    var buffer: [512]u8 = undefined;
    const row = out.row_text(3, &buffer);
    try testing.expect(std.mem.indexOf(u8, row, "Clients") != null);
    try testing.expect(std.mem.indexOf(u8, row, "999") != null);
    // Its name is still readable: the count does not eat the folder.
    try testing.expect(std.mem.indexOf(u8, row, "15") == null);
}

test "a server that calls the inbox INBOX still lights the folder you are in" {
    var f = try fixture();
    defer f.deinit();
    const account = core.id.AccountId.from_int(1);
    f.state.accounts.add(account, "work", .{}, .{});
    // Gmail's shape: the name is INBOX, the flag may not say so, and the app
    // still knows it is the Inbox -- so the row is the one the list is on.
    _ = f.state.folders.add(account, "INBOX", .inbox);
    _ = f.state.folders.add(account, "Clients", null);
    f.state.account_filter = account;
    f.state.mailbox = .inbox;
    f.state.named = null;

    var inputs = f.inputs(120, 30);
    inputs.sidebar = true;
    var out = Screen.init(120, 30);
    frame(inputs, &out);

    // Rows: 0 all accounts, 1 the account, 2 the rule, 3 Inbox, 4 Clients. The
    // six keep the app's own words: "INBOX" is Inbox, like "[Gmail]/Sent Mail"
    // is Sent.
    try row_contains(&out, 3, "Inbox");
    try testing.expectEqual(f.theme.selection.bg, out.cells[3][1].style.bg);
    try testing.expect(!std.meta.eql(out.cells[4][1].style.bg, f.theme.selection.bg));
}

test "the reader's header is the message in the folder it was opened from" {
    var store = try core.store.Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);
    // The same number in two folders: a UID is unique in its own folder and
    // nowhere else, so 7 in INBOX is one message and 7 in "Importantes" another.
    var inbox: core.message.Message = .{
        .id = MessageId.from_int(7),
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
    };
    inbox.subject.set("tune my music");
    try store.insert(&inbox);

    var label: core.message.Message = .{
        .id = MessageId.from_int(7),
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
    };
    label.named = 0;
    label.subject.set("GitHub: a new sign-in");
    try store.insert(&label);

    var state: State = .{ .list_rows = 20 };
    state.view = .reader;
    state.opened_account = core.id.AccountId.from_int(1);
    state.opened = MessageId.from_int(7);
    state.opened_folder = .{ .named = .{ .account = core.id.AccountId.from_int(1), .slot = 0 } };
    state.opened_subject.set("GitHub: a new sign-in");

    var out: Screen = .{};
    frame(.{
        .state = &state,
        .store = &store,
        .theme = &Theme.dark(),
        .body = "",
        .wrapped = null,
        .columns = 100,
        .rows = 24,
        .now_unix = 1_700_000_000,
    }, &out);

    var row_buffer: [512]u8 = undefined;
    var line: u16 = 0;
    var found = false;
    while (line < out.rows) : (line += 1) {
        if (std.mem.indexOf(u8, out.row_text(line, &row_buffer), "GitHub: a new sign-in") != null) found = true;
        try testing.expect(std.mem.indexOf(u8, out.row_text(line, &row_buffer), "tune my music") == null);
    }
    try testing.expect(found);
}

test "a message with no To header says which mailbox it arrived at" {
    var store = try core.store.Store.init(testing.allocator, 2);
    defer store.deinit(testing.allocator);

    var message = core.message.Message{
        .id = core.id.MessageId.from_int(1),
        .account = core.id.AccountId.from_int(2),
        .mailbox = .inbox,
        .timestamp_unix = 1_700_000_000,
        .from = try core.address.Address.init("GitHub <noreply@github.com>"),
    };
    message.subject.set("[GitHub] Actions minutes");
    try store.insert(&message);

    var state = State{};
    state.accounts.add(core.id.AccountId.from_int(1), "work", try core.address.Address.init("me@work.example"), .{});
    state.accounts.add(core.id.AccountId.from_int(2), "home", try core.address.Address.init("me@home.example"), .{});
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
        .columns = 110,
        .rows = 24,
        .now_unix = 1_700_000_000,
    }, &out);

    // A notification addressed to you alone often has no To at all: the line says
    // where it landed instead, which is the question a reader with two accounts has.
    try testing.expect(screen_contains(&out, "to home <me@home.example>"));

    // And with the card open, the account is a row of its own.
    var details_copy = core.headers.Details{};
    details_copy.to.set("me@home.example");
    var card: Screen = .{};
    frame(.{
        .state = &state,
        .store = &store,
        .theme = &Theme.dark(),
        .body = "text",
        .details = &details_copy,
        .show_details = true,
        .columns = 110,
        .rows = 24,
        .now_unix = 1_700_000_000,
    }, &card);
    try testing.expect(screen_contains(&card, "Account"));
    try testing.expect(screen_contains(&card, "home <me@home.example>"));
}

test "the account line says the label and the address it knows" {
    var f = try fixture();
    defer f.deinit();
    f.state.accounts.add(core.id.AccountId.from_int(1), "work", try core.address.Address.init("me@work.example"), .{});
    f.state.accounts.add(core.id.AccountId.from_int(2), "", try core.address.Address.init("me@home.example"), .{});
    f.state.accounts.add(core.id.AccountId.from_int(3), "broken", .{}, .{});

    var buffer: [core.limits.address_max + 32]u8 = undefined;
    const inputs = Inputs{ .state = &f.state, .store = &f.store, .theme = &Theme.dark() };
    try testing.expectEqualStrings("work <me@work.example>", account_line(inputs, core.id.AccountId.from_int(1), &buffer));
    // No label: the address is the whole answer.
    try testing.expectEqualStrings("me@home.example", account_line(inputs, core.id.AccountId.from_int(2), &buffer));
    // No address and no such account: nothing rather than a guess.
    try testing.expectEqualStrings("", account_line(inputs, core.id.AccountId.from_int(3), &buffer));
    try testing.expectEqualStrings("", account_line(inputs, .unknown, &buffer));
}

test "the corner says there is a way back, and the list does not" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .reader;
    f.state.opened = core.id.MessageId.from_int(1);

    var corner: Screen = .{};
    frame(.{
        .state = &f.state,
        .store = &f.store,
        .theme = &Theme.dark(),
        .body = "text",
        .columns = 100,
        .rows = 24,
        .sidebar = false,
        .now_unix = 1_700_000_000,
    }, &corner);
    var row_buffer: [64]u8 = undefined;
    // With no sidebar the corner is nobody else's, and it says where back is: a chip
    // with the arrow in it, a couple of columns before the subject.
    const row = corner.row_text(back_y, &row_buffer);
    try testing.expectEqual(@as(usize, back_x + back_width / 2), std.mem.indexOf(u8, row, "←").?);
    // The chip is a button, and its cells are the ones the pointer and the click use.
    try testing.expect(in_back(back_x, back_y));
    try testing.expect(in_back(back_x + back_width - 1, back_y));
    try testing.expect(!in_back(back_x + back_width, back_y));
    try testing.expect(!in_back(back_x, back_y + 1));
    try testing.expect(shows_back(&f.state, false));
    try testing.expectEqual(back_x + back_width + back_gap, subject_x(&f.state, false));
    // And it is close: one blank cell after the arrow, not a gap of three.
    try testing.expectEqual(@as(u16, 1), subject_x(&f.state, false) - (back_x + back_width / 2 + 1));
    // The subject itself starts after the gap, on the same row as the chip.
    try testing.expectEqual(@as(u16, 1), subject_x(&f.state, true));

    // The list is where the app begins: nothing to go back to, nothing drawn.
    f.state.view = .list;
    try testing.expect(!shows_back(&f.state, false));

    // And with the sidebar on, its first cell is already a thing to click.
    f.state.view = .reader;
    try testing.expect(!shows_back(&f.state, true));
}

test "the arrow stands in the column the text below starts in" {
    var f = try fixture();
    defer f.deinit();
    f.state.view = .reader;
    f.state.opened = core.id.MessageId.from_int(1);
    f.state.opened_account = f.store.at(0).account;
    f.state.opened_folder = .{ .mailbox = f.store.at(0).mailbox };

    var out: Screen = .{};
    frame(.{
        .state = &f.state,
        .store = &f.store,
        .theme = &Theme.dark(),
        .body = "text",
        .columns = 100,
        .rows = 24,
        .sidebar = false,
        .now_unix = 1_700_000_000,
    }, &out);

    var buffer: [512]u8 = undefined;
    const above = out.row_text(back_y, &buffer);
    const arrow = std.mem.indexOf(u8, above, "←").?;

    var other: [512]u8 = undefined;
    const below = out.row_text(back_y + 1, &other);
    // The meta line under it starts at the margin, and so does the arrow: one left
    // edge for the whole page, which is what the eye reads.
    const margin = below.len - std.mem.trimStart(u8, below, " ").len;
    try testing.expectEqual(margin, arrow);
    try testing.expectEqual(@as(usize, 1), arrow);
    // The subject keeps its distance: the button's width plus the gap, and the cell
    // it starts in is a letter, not a blank.
    const left = subject_x(&f.state, false);
    try testing.expectEqual(back_x + back_width + back_gap, left);
    const subject = f.state.opened_message(&f.store).?.subject.slice();
    // The arrow is one cell but three bytes: the subject's byte offset is the cell
    // it starts in plus the two bytes the glyph adds.
    try testing.expectEqual(@as(usize, left) + ("←".len - 1), std.mem.indexOf(u8, above, subject).?);
}

test "the mark says what kind of link it is, and all of them are two cells" {
    try testing.expectEqualStrings(link_mark, mark_for("https://example.com"));
    try testing.expectEqualStrings(link_mark, mark_for("www.example.com"));
    try testing.expectEqualStrings(mail_mark, mark_for("mailto:alvaro@example.com"));
    // The scheme is case-insensitive: a sender may write `MAILTO:`.
    try testing.expectEqualStrings(mail_mark, mark_for("MAILTO:alvaro@example.com"));
    try testing.expectEqualStrings(tel_mark, mark_for("tel:+34985456789"));
    try testing.expectEqualStrings(link_mark, mark_for(""));

    // One width for all three: the frame places the text after the mark from a
    // constant, and a narrower glyph would shift every line of the body.
    const width: u16 = @intCast(screen.text_columns(link_mark));
    try testing.expectEqual(width, screen.text_columns(mail_mark));
    try testing.expectEqual(width, screen.text_columns(tel_mark));
}

test "a mailbox in the body wears an envelope, and a phone a handset" {
    const body = "write to mailto:alvaro@example.com or call tel:+34985456789";
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, 60, &wrapped);

    var links: [core.links.max_links]core.links.Link = undefined;
    const count = core.links.scan(body, &links);

    var canvas: Screen = .{};
    canvas.resize(70, 4);
    const state = State{};
    const theme = Theme.dark();
    var row: u16 = 0;
    while (row < wrapped.len) : (row += 1) {
        draw_line_with_links(.{
            .state = &state,
            .store = undefined,
            .theme = &theme,
            .body = body,
            .links = links[0..count],
        }, &canvas, wrapped.at(row, body), row, 66);
    }

    // The two marks are on the one wrapped line; a row is where they land.
    var seen_mail = false;
    var seen_tel = false;
    var seen_chain = false;
    var buffer: [256]u8 = undefined;
    var line: u16 = 0;
    while (line < canvas.rows) : (line += 1) {
        const text = canvas.row_text(line, &buffer);
        if (std.mem.indexOf(u8, text, mail_mark) != null) seen_mail = true;
        if (std.mem.indexOf(u8, text, tel_mark) != null) seen_tel = true;
        if (std.mem.indexOf(u8, text, link_mark) != null) seen_chain = true;
    }
    try testing.expect(seen_mail);
    try testing.expect(seen_tel);
    try testing.expect(!seen_chain);
}

test "an anchor's words wear the mark of where the anchor goes" {
    var store = try core.store.Store.init(testing.allocator, 2);
    defer store.deinit(testing.allocator);

    // The words say nothing about the destination: only the anchor knows.
    const body = "Write to us (me@example.com)";
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, 60, &wrapped);

    // "Write to us" is the anchor's words, and it goes to a mailbox.
    const span = core.links.Link{ .start = 0, .end = "Write to us".len };
    var anchors = [_]core.html.Anchor{.{ .span = span, .target = "mailto:me@example.com" }};
    var links = [_]core.links.Link{span};

    var canvas: Screen = .{};
    canvas.resize(70, 4);
    const state = State{};
    const theme = Theme.dark();
    draw_line_with_links(.{
        .state = &state,
        .store = &store,
        .theme = &theme,
        .body = body,
        .links = &links,
        .anchors = &anchors,
    }, &canvas, wrapped.at(0, body), 0, 66);

    var buffer: [256]u8 = undefined;
    const row = canvas.row_text(0, &buffer);
    try testing.expect(std.mem.indexOf(u8, row, mail_mark) != null);
    try testing.expect(std.mem.indexOf(u8, row, link_mark) == null);
}

test "every mark stands a cell clear of the address it marks" {
    const glyph: u16 = @intCast(screen.text_columns(link_mark));
    // The mark, and one blank cell, whatever the mark is.
    try testing.expectEqual(glyph + 1, mark_columns(link_mark));
    try testing.expectEqual(glyph + 1, mark_columns(mark_for("https://example.com")));
    try testing.expectEqual(glyph + 1, mark_columns(mark_for("mailto:me@example.com")));
    try testing.expectEqual(glyph + 1, mark_columns(mark_for("tel:+34985456789")));

    // And a chain is drawn that way too: the address starts one cell after it.
    const body = "write mailto:me@example.com";
    var wrapped: wrap.Wrapped = .{};
    wrap.wrap(body, 60, &wrapped);
    var links: [core.links.max_links]core.links.Link = undefined;
    const count = core.links.scan(body, &links);

    var canvas: Screen = .{};
    canvas.resize(70, 4);
    const state = State{};
    const theme = Theme.dark();
    draw_line_with_links(.{
        .state = &state,
        .store = undefined,
        .theme = &theme,
        .body = body,
        .links = links[0..count],
    }, &canvas, wrapped.at(0, body), 0, 66);

    var buffer: [160]u8 = undefined;
    const row = canvas.row_text(0, &buffer);
    const mark_at = std.mem.indexOf(u8, row, mail_mark).?;
    const mark_end = mark_at + mail_mark.len;
    // The wide glyph's second cell is the one the row skips, so what stands between
    // the over and the address is exactly the one blank cell.
    const address_at = std.mem.indexOf(u8, row, "mailto:me@example.com").?;
    try testing.expectEqual(@as(u16, 1), screen.text_columns(row[mark_end..address_at]));
}

test "the selected row of the sidebar is one colour, letters included" {
    var f = try fixture();
    defer f.deinit();
    const account = core.id.AccountId.from_int(1);
    f.state.accounts.add(account, "work", try core.address.Address.init("me@work.example"), .{});
    f.state.account_filter = account;
    f.state.rebuild(&f.store);

    var out: Screen = .{};
    const theme = Theme.dark();
    frame(.{
        .state = &f.state,
        .store = &f.store,
        .theme = &theme,
        .body = "",
        .wrapped = null,
        .columns = 100,
        .rows = 24,
        .sidebar = true,
        .now_unix = 1_700_000_000,
    }, &out);

    // The scope on screen is the first account: its row is the selected one, and
    // the bar must not have holes where the letters are.
    const row = out.cells[1][0..layout_mod.sidebar_width];
    for (row) |cell| {
        try testing.expectEqual(theme.selection.bg, cell.style.bg);
    }
    // A row that is not selected is not painted: nothing to punch through.
    const other = out.cells[0][0..layout_mod.sidebar_width];
    for (other) |cell| {
        try testing.expect(!std.meta.eql(theme.selection.bg, cell.style.bg));
    }
}

test "a filtered list says so in the corner, next to the position" {
    var f = try fixture();
    defer f.deinit();

    var out: Screen = .{};
    frame(f.inputs(100, 24), &out);
    var buffer: [512]u8 = undefined;
    var line: u16 = 0;
    while (line < out.rows) : (line += 1) {
        try testing.expect(std.mem.indexOf(u8, out.row_text(line, &buffer), "/Invoice") == null);
    }

    // A filter is applied: the footer carries it, beside the count, where a status
    // message cannot cover it.
    f.state.query.set("Invoice");
    f.state.rebuild(&f.store);
    frame(f.inputs(100, 24), &out);
    var found = false;
    line = 0;
    while (line < out.rows) : (line += 1) {
        const text = out.row_text(line, &buffer);
        if (std.mem.indexOf(u8, text, "/Invoice") != null) found = true;
    }
    try testing.expect(found);

    // While it is being typed, the prompt says it, and the corner does not repeat it.
    f.state.mode = .search;
    f.state.draft.set("Invoice");
    frame(f.inputs(100, 24), &out);
    const last = out.rows - 1;
    try testing.expect(std.mem.indexOf(u8, out.row_text(last, &buffer), "Invoice") == null);
    var typed = false;
    line = 0;
    while (line < out.rows) : (line += 1) {
        if (std.mem.indexOf(u8, out.row_text(line, &buffer), "Invoice") != null) typed = true;
    }
    try testing.expect(typed);
}
