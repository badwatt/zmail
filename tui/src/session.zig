//! The terminal session: read, translate, update, execute effects, render.
//!
//! All policy lives in `core.update`; this file owns the loop and the wiring.
//! It is driven through the `System` port, so the whole loop is unit tested with
//! scripted keystrokes and captured output.

const std = @import("std");
const core = @import("core");

const input = @import("input.zig");
const selection_mod = @import("selection.zig");
const clipboard_mod = @import("clipboard.zig");
const keymap = @import("keymap.zig");
const layout_mod = @import("layout.zig");
const render_mod = @import("render.zig");
const screen_mod = @import("screen.zig");
const system_mod = @import("system.zig");
const theme_mod = @import("theme.zig");
const os = @import("os.zig");
const refresh_mod = @import("refresh.zig");
const wrap = @import("wrap.zig");

const Mailbox = core.mailbox.Mailbox;
const Message = core.message.Message;
const MessageId = core.id.MessageId;
const Screen = screen_mod.Screen;
const System = system_mod.System;

/// Where "now" comes from. Injected so relative dates are deterministic in
/// tests and correct in the real client.
pub const Now = *const fn () i64;

/// Deterministic clock used by tests and as a safe default.
pub fn fixed_now() i64 {
    return 1_700_000_000;
}

/// One configured account: its identity, its mail connection, and its outbox.
pub const MailSource = struct {
    id: core.id.AccountId,
    label: []const u8,
    from: core.address.Address = .{},
    mail: core.mail_port.Mail,
    /// Enough to edit the account without re-reading the config.
    imap_host: []const u8 = "",
    imap_port: u16 = 0,
    username: []const u8 = "",
    smtp_host: []const u8 = "",
    smtp_port: u16 = 0,
    smtp: bool = false,
    oauth_client_id: []const u8 = "",
    /// Why this server is known to reject password logins, if it is.
    hint: []const u8 = "",
};

/// Text the session owns for a source: slices in `MailSource` point here, so an
/// account added at runtime never borrows the caller's memory.
const SourceText = struct {
    label: core.text.Text(core.limits.label_max) = .{},
    imap_host: core.text.Text(core.limits.host_max) = .{},
    username: core.text.Text(core.limits.username_max) = .{},
    smtp_host: core.text.Text(core.limits.host_max) = .{},
};

pub const OutboxSource = struct {
    id: core.id.AccountId,
    outbox: core.outbox_port.Outbox,
};

pub const Deps = struct {
    accounts: []const MailSource,
    outboxes: []const OutboxSource = &.{},
    /// Optional on-disk cache: startup and mailbox switches come from here
    /// first, and `Ctrl+R` refreshes from the network.
    cache: ?core.cache_port.Cache = null,
    /// Whether connecting can block for long enough to deserve a splash. The
    /// demo's mail is in memory, so it boots straight to the list.
    splash: bool = true,
    /// Sealed bodies on disk: reading a message twice must not touch the
    /// network twice.
    bodies: ?core.bodies_port.BodyCache = null,
    /// Adding and removing accounts writes the config: a port, so the core
    /// still never touches the filesystem.
    accounts_file: ?core.accounts_port.Accounts = null,
    /// What the reader left selected: one account's label, or empty for all.
    scope: ?core.scope_port.Scope = null,
    /// Something the user must know at start (a broken config, for instance).
    notice: ?[]const u8 = null,
    /// Paint the spinner while an effect runs, and keep it up this long (ms) so
    /// even an instant fetch reads as "working", not as a jump.
    loading_ms: u32 = 90,
    system: System,
    theme: theme_mod.Theme = theme_mod.Theme.dark(),
    now: Now = fixed_now,
    /// Fallback sender when an account has no address configured.
    from_address: core.address.Address = .{},
    /// Opens a link in the browser. Null in tests and in a terminal with no
    /// opener: clicking a link then does nothing rather than lying.
    open_url: ?*const fn (context: *anyopaque, url: []const u8) void = null,
    open_url_context: *anyopaque = undefined,
    /// Opens the whole message elsewhere: the HTML part in the browser, or its
    /// first link when there is no HTML.
    open_external: ?*const fn (context: *anyopaque, html: []const u8, link: []const u8) void = null,
    open_external_context: *anyopaque = undefined,
    /// Paints one image of the message at a cell, from its PNG bytes. False
    /// when the terminal cannot draw it.
    draw_image: ?*const fn (
        context: *anyopaque,
        png: []const u8,
        id: u32,
        x: u16,
        y: u16,
        columns: u16,
        rows: u16,
    ) bool = null,
    draw_image_context: *anyopaque = undefined,
    /// Downloads a picture the message points at. False when it cannot be
    /// had: a mail reader does not fail because a logo is missing.
    fetch_image: ?*const fn (
        context: *anyopaque,
        url: []const u8,
        out: []u8,
    ) ?[]const u8 = null,
    fetch_image_context: *anyopaque = undefined,
    /// Takes every painted image away before the next frame is drawn.
    clear_images: ?*const fn (context: *anyopaque) void = null,
    clear_images_context: *anyopaque = undefined,
};

/// How many images one frame will paint: past a handful the mail is a gallery,
/// not a message.
const max_images_drawn: u8 = 8;
const cell_width: u32 = 9;
const cell_height: u32 = 18;
/// An image taller than this is scaled down: a reader scrolls, it does not zoom.
const max_image_rows: u32 = 12;

const ImageSlot = struct {
    key: core.text.Text(128) = .{},
    bytes: [96 * 1024]u8 = undefined,
    len: u32 = 0,
};

const ImageSize = struct { width: u32, height: u32 };
const ImageCells = struct { columns: u16, rows: u16 };

/// A picture's id in the terminal. It has to be unique per message as well as
/// per marker: a terminal ignores a transmission for an id it already holds, so
/// "r0" in another mail would quietly show the previous logo.
fn image_id(account: core.id.AccountId, message: core.id.MessageId, key: []const u8) u32 {
    var hash = std.hash.Wyhash.init(0xa5a5);
    hash.update(std.mem.asBytes(&account));
    hash.update(std.mem.asBytes(&message));
    hash.update(key);
    return @intCast((hash.final() & 0x7fffffff) | 1);
}

/// The marker a numbered network image gets: "r0", "r1", …
fn is_remote_marker(key: []const u8) bool {
    if (key.len < 2 or key[0] != 'r') return false;
    for (key[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// An image that came with the message can be painted; one with an address
/// cannot, without fetching it.
fn is_local_image(key: []const u8) bool {
    if (key.len == 0) return false;
    return std.mem.indexOf(u8, key, "://") == null and
        std.mem.indexOfScalar(u8, key, '/') == null and
        std.mem.indexOfScalar(u8, key, '.') == null;
}

/// Width and height from a PNG's IHDR chunk. Anything else is refused: the
/// terminal paints PNG, and a terminal cannot transcode a JPEG.
fn png_size(bytes: []const u8) ?ImageSize {
    if (bytes.len < 24) return null;
    if (bytes[0] != 0x89 or bytes[1] != 'P' or bytes[2] != 'N' or bytes[3] != 'G') return null;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

fn image_cells(size: ImageSize) ImageCells {
    const wanted_rows = (size.height + cell_height - 1) / cell_height;
    const scale = if (wanted_rows > max_image_rows)
        @as(f64, @floatFromInt(max_image_rows)) / @as(f64, @floatFromInt(wanted_rows))
    else
        1.0;

    const columns_f = @as(f64, @floatFromInt(size.width)) / @as(f64, @floatFromInt(cell_width)) * scale;
    const rows_f = @as(f64, @floatFromInt(wanted_rows)) * scale;
    return .{
        .columns = @intFromFloat(@max(1.0, @min(columns_f, 255.0))),
        .rows = @intFromFloat(@max(1.0, @min(rows_f, 255.0))),
    };
}

pub const Session = struct {
    gpa: std.mem.Allocator,
    deps: Deps,

    state: core.state.State = .{},
    store: core.store.Store = undefined,
    /// Fetch target, so a failed refresh never empties the cache.
    scratch: []Message = &.{},

    screen: Screen = .{},
    parser: input.Parser = .{},

    body: [core.limits.body_max]u8 = undefined,
    body_len: u32 = 0,
    /// The same text with the line breaks inside addresses removed: what the
    /// reader draws, and what the links are measured against.
    shown: [core.limits.body_max]u8 = undefined,
    shown_len: u32 = 0,
    body_loaded: bool = false,
    wrapped: wrap.Wrapped = .{},
    /// The message as it arrived, kept so both views can be rendered without a
    /// second fetch.
    raw: [core.limits.body_max]u8 = undefined,
    raw_len: u32 = 0,
    /// The HTML part, and the reading view made from it.
    html_part: [core.limits.body_max]u8 = undefined,
    /// The HTML with the entities a text browser cannot print taken out.
    html_cleaned: [core.limits.body_max]u8 = undefined,
    html_cleaned_len: u32 = 0,
    /// The same HTML with each image replaced by a marker the reader can find
    /// in the laid-out text.
    html_marked: [core.limits.body_max * 2]u8 = undefined,
    html_marked_len: u32 = 0,
    /// The view the last frame was drawn for: a change repaints everything.
    last_view: core.state.View = .list,
    /// Whether the reader already explained why no picture appeared.
    image_hint_shown: bool = false,
    /// Signature of the layer on screen, so an unchanged one is left alone.
    image_painted: u64 = 0,
    /// Room for one decoded image, and the pixels-per-cell arithmetic that
    /// turns it into a place on screen.
    image_buffer: [core.limits.body_max]u8 = undefined,
    /// Every picture of this message, decoded or downloaded once.
    image_slots: [max_images_drawn]ImageSlot = @splat(.{}),
    /// The link under a ctrl-hovered pointer, if any.
    hovered: ?core.links.Link = null,
    /// Its address, shown in a popup while ctrl is held over it.
    hover_url: core.text.Text(core.limits.url_max) = .{},
    image_slot_count: u8 = 0,
    /// How many rows each wrapped line hides behind a picture.
    cover_rows: [wrap.max_lines]u8 = @splat(0),
    cover_len: u32 = 0,
    /// The addresses of the pictures the message points at, in the order the
    /// markers number them.
    remote_sources: [core.html.max_remote_images]core.text.Text(core.limits.url_max) = @splat(.{}),
    remote_sources_count: usize = 0,
    /// The one picture downloaded from the network, and where it came from.
    remote_url: core.text.Text(core.limits.url_max) = .{},
    remote_bytes: [core.limits.body_max]u8 = undefined,
    remote_len: u32 = 0,
    html_part_len: u32 = 0,
    /// Set when a text browser has to lay the HTML out before it can be shown.
    html_text: [core.limits.body_max]u8 = undefined,
    html_len: u32 = 0,
    /// Which view the reader is showing. HTML only when the message has it.
    html_view: bool = false,
    /// Whether the HTML part has already been rendered to text.
    html_ready: bool = false,

    /// Where a mouse drag started and where it is now. A drag copies; a click
    /// still opens a link.
    selection: ?selection_mod.Selection = null,
    clip_text: [clipboard_mod.max_text]u8 = undefined,
    clip_encoded: [clipboard_mod.max_encoded]u8 = undefined,
    html_links: [core.links.max_links]core.links.Link = undefined,
    html_kinds: [wrap.max_lines]core.html.Kind = undefined,
    html_kind_count: usize = 0,
    html_link_count: usize = 0,
    /// Anchor words and the addresses they point at, in the HTML view.
    html_anchors: [core.html.max_anchors]core.html.Anchor = undefined,
    html_anchor_count: usize = 0,
    text_links: [core.links.max_links]core.links.Link = undefined,
    text_link_count: usize = 0,
    /// MIME decoding scratch, kept here so nothing is allocated per message.
    scratch_bytes: [core.limits.body_max]u8 = undefined,

    size: system_mod.Size = .{},
    now_unix: i64 = 0,
    needs_render: bool = true,
    /// Set when the cache could not fill the current mailbox.
    needs_boot: bool = false,

    /// Background refresh: the worker writes into `refresh_scratch`; the UI
    /// thread swaps the result into the store when the job reports done.
    refreshing: bool = false,
    refresh_job: refresh_mod.Job = .{},
    refresh_scratch: []Message = undefined,
    refresh_sources: [core.state.accounts_max]refresh_mod.Source = undefined,
    /// Which of the session's sources each job slot came from, and how many.
    refresh_index: [core.state.accounts_max]u8 = undefined,
    refresh_count: u8 = 0,
    refresh_mailbox: Mailbox = .inbox,
    /// The live account list: a copy of what the launcher built, plus anything
    /// added from the TUI (and minus anything removed).
    sources: [core.state.accounts_max]MailSource = undefined,
    source_text: [core.state.accounts_max]SourceText = undefined,
    source_count: u8 = 0,
    /// A body asked for while the worker holds the connection. Applied as soon
    /// as the refresh finishes, so the reader shows text instead of a frozen UI.
    pending_body: ?struct { account: core.id.AccountId, mailbox: Mailbox, id: MessageId } = null,

    /// The account form, when it is open. It lives here, not in the core state,
    /// because it holds a password and is pure UI.
    settings: ?Settings = null,
    renaming: ?Rename = null,

    /// One row of encoded ANSI. Bounded by the widest row times the longest
    /// possible style run, so a frame never allocates.
    row_buffer: [screen_mod.max_columns * 40]u8 = undefined,
    /// Which (account, mailbox) pairs are in the store. Switching to a loaded
    /// mailbox must not hit the network again.
    loaded_mask: u32 = 0,

    /// Initializes in place: the session owns megabytes, so it must not be
    /// copied around the stack.
    pub fn init(self: *Session, gpa: std.mem.Allocator, deps: Deps) !void {
        self.* = .{
            .gpa = gpa,
            .deps = deps,
            .store = try core.store.Store.init(gpa, core.limits.messages_max),
        };
        errdefer self.store.deinit(gpa);

        self.scratch = try gpa.alloc(Message, core.limits.messages_max);
        errdefer gpa.free(self.scratch);

        self.refresh_scratch = try gpa.alloc(Message, core.limits.messages_max);
        errdefer gpa.free(self.refresh_scratch);

        self.state = .{};
        self.state.from_address = deps.from_address;
        self.source_count = 0;
        self.source_text = @splat(.{});
        for (deps.accounts) |source| self.add_source(source);
        self.restore_scope();
        if (deps.notice) |notice| self.state.set_alert("{s}", .{notice});
        self.parser = .{};
        self.body_loaded = false;
        self.body_len = 0;
        self.wrapped = .{};
        self.needs_render = true;
        self.now_unix = deps.now();
        self.size = deps.system.size() catch system_mod.Size{};
        self.screen.resize(self.size.columns, self.size.rows);
        // Cache only: the first frame must not wait for a socket. Anything the
        // cache cannot serve is fetched by `boot`, after that frame is painted.
        self.load_cached(self.state.mailbox, true);
    }

    /// Whether this account is the one being looked at (or every one is).
    fn in_scope(self: *const Session, account: core.id.AccountId) bool {
        const filter = self.state.account_filter orelse return true;
        return filter == account;
    }

    /// Reopens on the account the reader left selected, if it is still there.
    fn restore_scope(self: *Session) void {
        const scope = self.deps.scope orelse return;
        var label: core.text.Text(core.limits.label_max) = .{};
        if (!scope.load(&label)) return;

        var index: u8 = 0;
        while (index < self.state.accounts.len) : (index += 1) {
            const account = self.state.accounts.at(index) orelse continue;
            if (!std.mem.eql(u8, account.label.slice(), label.slice())) continue;
            self.state.account_filter = account.id;
            self.state.rebuild(&self.store);
            return;
        }
        // The account was removed or renamed: forget it, and start on all.
        scope.save("") catch {};
    }

    /// Copies one account into the session's own list and registers it.
    fn add_source(self: *Session, source: MailSource) void {
        const index = self.source_count;
        if (index >= self.sources.len) return;

        const text = &self.source_text[index];
        text.label.set(source.label);
        text.imap_host.set(source.imap_host);
        text.username.set(source.username);
        text.smtp_host.set(source.smtp_host);

        self.sources[index] = source;
        self.sources[index].label = text.label.slice();
        self.sources[index].imap_host = text.imap_host.slice();
        self.sources[index].username = text.username.slice();
        self.sources[index].smtp_host = text.smtp_host.slice();
        self.source_count += 1;

        self.state.accounts.add(source.id, text.label.slice(), source.from, .{
            .imap_host = text.imap_host.slice(),
            .imap_port = source.imap_port,
            .username = text.username.slice(),
            .smtp_host = text.smtp_host.slice(),
            .smtp_port = source.smtp_port,
            .smtp = source.smtp,
            .oauth_client_id = source.oauth_client_id,
        });
    }

    /// The most useful thing we can say about a refused login.
    fn login_hint(self: *const Session) []const u8 {
        for (self.live_sources()) |source| {
            if (source.hint.len > 0) return source.hint;
        }
        return "check the password";
    }

    fn live_sources(self: anytype) []const MailSource {
        return self.sources[0..self.source_count];
    }

    /// Fills the store from the on-disk cache and remembers whether the network
    /// is still needed.
    fn load_cached(self: *Session, mailbox: Mailbox, detect_boot: bool) void {
        for (self.live_sources(), 0..) |source, index| {
            const mask = mask_bit(@intCast(index), @backingInt(mailbox));
            if (self.deps.cache) |cache| {
                const cached = cache.load(source.id, mailbox, self.scratch) catch 0;
                if (cached > 0) {
                    core.sync.replace_mailbox(&self.store, source.id, mailbox, self.scratch[0..cached]);
                    self.loaded_mask |= mask;
                    continue;
                }
            }
            if (detect_boot) self.needs_boot = true;
        }

        self.state.rebuild(&self.store);
        self.needs_render = true;
    }

    /// Leaves the splash on screen only while there is something to wait for.
    fn stop_splash(self: *Session) void {
        self.state.booting = false;
        self.needs_render = true;
    }

    /// Runs once, right after the first frame: opens the connections the cache
    /// could not replace. The splash is on screen while this blocks.
    pub fn boot(self: *Session) void {
        if (!self.needs_boot) {
            self.stop_splash();
            return;
        }
        self.needs_boot = false;
        if (self.source_count == 0) {
            // Nothing to connect to (a broken config, no accounts): do not sit
            // on the splash. The notice is what the user needs to read.
            self.stop_splash();
            return;
        }

        // The first connection must be made on this thread: the transport's
        // Io belongs to the event loop, and opening it from the worker leaves
        // both waiting forever (no mail, spinner forever). Later refreshes
        // reuse the open connection, so those can run in the background.
        self.state.booting = self.deps.splash;
        self.reload(self.state.mailbox);
        self.state.booting = false;
        self.needs_render = true;
    }

    pub fn deinit(self: *Session) void {
        // A running worker touches `refresh_scratch`; wait for it before freeing.
        if (self.refreshing) {
            while (!self.refresh_job.finished()) std.atomic.spinLoopHint();
            self.refresh_job.join();
        }
        if (self.settings) |*form| form.setup.deinit();
        self.store.deinit(self.gpa);
        self.gpa.free(self.refresh_scratch);
        self.gpa.free(self.scratch);
        self.* = undefined;
    }

    /// Advances the loop by one step. Returns false when the session is over.
    pub fn step(self: *Session) bool {
        self.poll_refresh();
        // While a refresh runs the spinner must move, so every tick redraws.
        if (self.refreshing) self.needs_render = true;

        var read_buffer: [256]u8 = undefined;
        if (self.deps.system.read(&read_buffer, system_mod.read_timeout_ms)) |read| {
            if (read > 0) {
                self.handle_bytes(read_buffer[0..read]);
            } else if (self.parser.flush()) |key| {
                _ = self.handle_key(key);
            }
        } else |err| {
            if (err == error.InputClosed) {
                self.state.quit = true;
                return false;
            }
            self.state.set_alert("Terminal error", .{});
            self.needs_render = true;
        }

        self.sync_size();
        self.state.spinner +%= 1;
        self.now_unix = self.deps.now();
        if (self.needs_render) self.render();
        return !self.state.quit;
    }

    /// Runs until the user quits. `run.zig` wraps this with raw mode and the
    /// alternate screen.
    pub fn loop(self: *Session) void {
        const needs_network = self.needs_boot;
        if (self.deps.splash) {
            // The welcome screen shows on every start, with the spinner moving
            // for a moment before the slow part. A frozen one-frame splash read
            // as a bug.
            self.state.booting = true;
            self.play_splash(4);
            self.boot();
        } else {
            // Nothing here can block: no empty frame, no splash.
            self.boot();
            self.render();
        }

        // Starting from cache means no connection is open. Opening a message
        // would then pay TCP + TLS + LOGIN before the first byte of mail, so
        // warm it in the background (this is the worker thread: no freeze)
        // while the user reads what is already on screen.
        if (!needs_network and self.source_count > 0) self.start_refresh();

        while (self.step()) {}
    }

    fn start_refresh(self: *Session) void {
        if (self.refreshing) return;

        // The worker takes exactly the accounts in scope: refreshing never wakes
        // an account the reader is not looking at.
        var count: u8 = 0;
        for (self.live_sources(), 0..) |source, index| {
            if (!self.in_scope(source.id)) continue;
            self.refresh_sources[count] = .{ .id = source.id, .mail = source.mail };
            self.refresh_index[count] = @intCast(index);
            count += 1;
        }
        if (count == 0) return;
        self.refresh_count = count;

        // Paint what the cache has first: switching mailboxes stays instant.
        self.load_cached(self.state.mailbox, false);

        self.refresh_mailbox = self.state.mailbox;
        self.refresh_job.start(self.refresh_sources[0..count], self.refresh_mailbox, self.refresh_scratch);
        self.refreshing = true;
        self.state.refreshing = true;
        self.needs_render = true;
    }

    fn poll_refresh(self: *Session) void {
        if (!self.refreshing) return;
        if (!self.refresh_job.finished()) return;
        self.finish_refresh();
    }

    fn finish_refresh(self: *Session) void {
        self.refresh_job.join();

        var slot: u8 = 0;
        while (slot < self.refresh_count) : (slot += 1) {
            const index = self.refresh_index[slot];
            const source = self.live_sources()[index];
            // A failed account keeps whatever the cache already showed.
            if (!self.refresh_job.ok[slot]) continue;

            const offset = self.refresh_job.offsets[slot];
            const count = self.refresh_job.counts[slot];
            const fetched = self.refresh_scratch[offset..][0..count];

            core.sync.replace_mailbox(&self.store, source.id, self.refresh_mailbox, fetched);
            self.loaded_mask |= mask_bit(@intCast(index), @backingInt(self.refresh_mailbox));
            if (self.deps.cache) |cache| {
                cache.save(source.id, self.refresh_mailbox, fetched) catch {};
            }
        }

        const failures = self.refresh_job.failures;
        self.state.booting = false;
        self.refreshing = false;
        self.state.refreshing = false;
        self.state.rebuild(&self.store);
        self.needs_render = true;

        if (failures > 0) {
            self.state.set_alert("Could not refresh {s}", .{self.refresh_mailbox.title()});
        }

        // Deliver a body that was requested while the worker was busy.
        if (self.pending_body) |request| {
            self.pending_body = null;
            self.fetch_body(request.account, request.mailbox, request.id);
        }
    }

    /// Waits for an in-flight refresh, then applies its results. Used when a
    /// command needs the connection the worker is holding.
    pub fn wait_refresh(self: *Session) void {
        while (self.refreshing) {
            self.poll_refresh();
            std.atomic.spinLoopHint();
        }
    }

    pub fn settle_refresh_for_test(self: *Session) void {
        self.wait_refresh();
    }

    /// After another full-screen flow (the assistant) painted the terminal, the
    /// diff against our last frame is meaningless: repaint everything.
    fn invalidate_screen(self: *Session) void {
        self.screen.pristine = true;
        self.needs_render = true;
    }

    /// Paints `frames` splash frames with a short pause between them, so the
    /// spinner is visibly alive even when the wait that follows is short.
    fn play_splash(self: *Session, frames: u8) void {
        var frame: u8 = 0;
        while (frame < frames) : (frame += 1) {
            self.state.spinner = frame * 2;
            self.render();
            os.sleep_ms(55);
        }
    }

    fn sync_size(self: *Session) void {
        const size = self.deps.system.size() catch return;
        if (size.columns == self.size.columns) {
            if (size.rows == self.size.rows) return;
        }
        self.size = size;
        self.screen.resize(size.columns, size.rows);
        self.needs_render = true;
    }

    fn handle_bytes(self: *Session, bytes: []const u8) void {
        // Decoding in bounded chunks keeps the key buffer fixed and lets the
        // parser keep its state across chunk boundaries.
        var index: usize = 0;
        while (index < bytes.len) {
            const end = @min(bytes.len, index + input.keys_max);
            var keys: input.Keys = .{};
            self.parser.decode(bytes[index..end], &keys);
            for (keys.slice()) |key| _ = self.handle_key(key);
            index = end;
        }
    }

    fn handle_key(self: *Session, key: input.Key) bool {
        if (self.renaming) |*rename| return self.rename_key(rename, key);
        if (self.settings) |*form| return self.settings_key(form, key);
        if (key == .mouse) return self.handle_mouse(key.mouse);
        // Views are not commands: the core has no opinion about them.
        if (key == .char and self.state.view == .reader) {
            switch (key.char) {
                'H' => return self.toggle_html(),
                'o' => return self.open_external_message(),
                else => {},
            }
        }
        const command = keymap.translate(key, .{ .mode = self.state.mode, .view = self.state.view }) orelse return false;
        return self.apply(command);
    }

    fn handle_mouse(self: *Session, mouse: input.Mouse) bool {
        if (mouse.kind == .release) return self.finish_selection(mouse);
        if (mouse.kind == .motion and mouse.button == .left) return self.extend_selection(mouse);
        if (mouse.kind == .motion) return self.hover_link(mouse);

        switch (mouse.button) {
            .wheel_up => return self.apply(.{ .move = .up }),
            .wheel_down => return self.apply(.{ .move = .down }),
            .left => {},
            else => return false,
        }

        const lay = layout_mod.Layout.compute(self.size.columns, self.size.rows, self.state.accounts.max_label());
        if (lay.too_small) return false;

        if (self.state.view == .list) {
            if (mouse.y == lay.header_y) {
                if (lay.mailbox_at(mouse.x)) |mailbox| {
                    return self.apply(.{ .select_mailbox = mailbox });
                }
                return false;
            }
            if (mouse.y >= lay.body_y and mouse.y < lay.body_y + lay.list_rows) {
                return self.click_row(lay, mouse.y);
            }
        }
        // Ctrl turns the pointer into a link opener; without it a press in the
        // body starts a selection, and the release decides whether it was a
        // click (nothing) or a drag (copy).
        if (mouse.ctrl) return self.click_link(lay, mouse);
        if (self.start_selection(lay, mouse)) return true;
        return false;
    }

    /// The whole message as another program would show it: the browser for the
    /// HTML part, or the first link for a text-only mail.
    fn open_external_message(self: *Session) bool {
        if (!self.body_loaded) return false;
        const open = self.deps.open_external orelse {
            self.state.set_status("No way to open it from here", .{});
            self.needs_render = true;
            return true;
        };
        if (self.html_part_len > 0) {
            // The part itself: a browser that is handed our text rendering sees
            // one collapsed paragraph with no styling at all.
            open(self.deps.open_external_context, self.html_part[0..self.html_part_len], "");
            self.state.set_status("Opened in the browser", .{});
        } else if (self.text_link_count > 0) {
            var url_buffer: [core.limits.url_max]u8 = undefined;
            const link = self.text_links[0];
            open(self.deps.open_external_context, "", link.url(self.reader_text(), &url_buffer));
            self.state.set_status("Opened the first link", .{});
        } else {
            self.state.set_status("This message has nothing to open", .{});
        }
        self.needs_render = true;
        return true;
    }

    /// A picture of the mail, drawn in the terminal: what a mail client shows,
    /// as near as a terminal can get.
    /// Keys while the picture is up: scroll it, or leave.
    /// Paints the picture over the frame that is already on screen.
    /// The HTML part, read as text: structure kept, nothing fetched, nothing
    /// executed. Rendered on first use and kept for this message.
    fn toggle_html(self: *Session) bool {
        if (!self.body_loaded) return false;
        if (!self.html_ready) self.render_html_view();
        if (self.html_len == 0) {
            self.state.set_status("This message has no HTML version", .{});
            self.needs_render = true;
            return true;
        }
        self.html_view = !self.html_view;
        self.wrapped = .{};
        self.state.reader_scroll = 0;
        self.state.set_status("{s}", .{if (self.html_view) "HTML view" else "Plain text"});
        self.needs_render = true;
        return true;
    }

    /// A click inside the body that lands on a link opens it. The scan is the
    /// same one the highlighter uses, over the same line, so what looks like a
    /// link is what reacts.
    /// Where the pointer is, in the body text. Null outside the reader's lines.
    fn cell_offset(self: *Session, lay: layout_mod.Layout, mouse: input.Mouse) ?u32 {
        if (self.state.view != .reader or !self.body_loaded) return null;
        if (mouse.y < lay.reader_body_y or mouse.y >= lay.reader_body_y + lay.reader_rows) return null;
        if (mouse.x < 1) return null;

        const row = mouse.y - lay.reader_body_y;
        const index = self.state.reader_scroll + row;
        if (index >= self.wrapped.len) return null;

        const text = self.reader_text();
        const line = self.wrapped.at(index, text);
        const line_start: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(text.ptr));
        // Clicking past the end of a line is clicking nothing, not clicking the
        // text that happens to follow it in the buffer.
        const column = mouse.x - 1;
        if (column >= line.len) return null;
        return line_start + column;
    }

    /// Ctrl held and the pointer over a link: it lights up, so the click is not
    /// a leap of faith.
    fn hover_link(self: *Session, mouse: input.Mouse) bool {
        const lay = layout_mod.Layout.compute(self.size.columns, self.size.rows, self.state.accounts.max_label());
        // Ctrl is the question "what would this do?": without it the pointer
        // changes nothing, so reading is never disturbed.
        var found: ?core.links.Link = null;
        var target: ?[]const u8 = null;
        if (mouse.ctrl) {
            if (self.cell_offset(lay, mouse)) |offset| {
                found = self.link_span_at(offset);
                if (found != null) {
                    var buffer: [core.limits.url_max]u8 = undefined;
                    if (self.target_at(offset, &buffer)) |url| {
                        // Kept for the popup: the address is not in the text.
                        self.hover_url.set(url);
                        target = self.hover_url.slice();
                    }
                }
            }
        }
        if (found == null and self.hovered == null) return false;
        if (found != null and self.hovered != null and found.?.start == self.hovered.?.start) return false;
        self.hovered = found;
        if (target == null) self.hover_url.clear();
        self.needs_render = true;
        return true;
    }

    /// The span of the link under a cell: the words of an anchor in the HTML
    /// view, or a written-out address. What the pointer lights up and what a
    /// click opens both come from here, so they cannot disagree.
    fn link_span_at(self: *Session, offset: u32) ?core.links.Link {
        if (self.html_view) {
            for (self.html_anchors[0..self.html_anchor_count]) |anchor| {
                if (offset >= anchor.span.start and offset < anchor.span.end) return anchor.span;
            }
        }
        return core.links.at(self.reader_text(), offset);
    }

    /// The address under a cell of the body: the anchor whose words it is, the
    /// address written after those words, or a numbered reference.
    fn target_at(self: *Session, offset: u32, out: *[core.limits.url_max]u8) ?[]const u8 {
        if (self.html_view) {
            const anchors = self.html_anchors[0..self.html_anchor_count];
            for (anchors) |anchor| {
                if (offset < anchor.span.start or offset >= anchor.span.end) continue;
                if (anchor.target.len == 0) continue;
                return anchor.target;
            }
        }
        const text = self.reader_text();
        if (core.links.at(text, offset)) |link| return link.url(text, out);
        if (core.links.reference_at(text, offset)) |number|
            return core.links.reference_url(text, number, out);
        return null;
    }

    fn click_link(self: *Session, lay: layout_mod.Layout, mouse: input.Mouse) bool {
        const offset = self.cell_offset(lay, mouse) orelse return false;
        var url_buffer: [core.limits.url_max]u8 = undefined;
        const url = self.target_at(offset, &url_buffer) orelse return false;

        // Say it before the browser starts: opening one takes a moment, and a
        // click with no answer feels broken. The frame goes out first.
        self.state.set_status("Opening {s} in the browser…", .{url});
        self.needs_render = true;
        self.render();
        if (self.deps.open_url) |open| open(self.deps.open_url_context, url);
        self.state.set_status("Opened {s}", .{url});
        self.needs_render = true;
        return true;
    }

    /// The cell under a mouse report, in the reader's coordinates.
    fn body_cell(self: *Session, lay: layout_mod.Layout, mouse: input.Mouse) ?selection_mod.Cell {
        if (self.state.view != .reader or !self.body_loaded) return null;
        if (mouse.y < lay.reader_body_y) return null;
        const row = mouse.y - lay.reader_body_y;
        if (row >= lay.reader_rows) return null;
        return .{
            .line = self.state.reader_scroll + row,
            .column = mouse.x -| 1,
        };
    }

    fn start_selection(self: *Session, lay: layout_mod.Layout, mouse: input.Mouse) bool {
        const cell = self.body_cell(lay, mouse) orelse return false;
        self.selection = selection_mod.Selection.start(cell);
        return true;
    }

    fn extend_selection(self: *Session, mouse: input.Mouse) bool {
        var active = self.selection orelse return false;
        const lay = layout_mod.Layout.compute(self.size.columns, self.size.rows, self.state.accounts.max_label());
        const cell = self.body_cell(lay, mouse) orelse return false;
        active.dragTo(cell);
        self.selection = active;
        self.needs_render = true;
        return true;
    }

    /// A drag copies what it covered; a click opens the link under it.
    fn finish_selection(self: *Session, mouse: input.Mouse) bool {
        var active = self.selection orelse return false;
        self.selection = null;

        const lay = layout_mod.Layout.compute(self.size.columns, self.size.rows, self.state.accounts.max_label());
        if (self.body_cell(lay, mouse)) |cell| active.dragTo(cell);

        if (!active.isDrag()) {
            // A click that never moved opens nothing: opening a link takes ctrl,
            // so a click meant for the text never launches a browser.
            self.needs_render = true;
            return true;
        }

        const text = selection_mod.extract(
            active,
            &self.wrapped,
            self.reader_text(),
            &self.clip_text,
        );
        const copied = clipboard_mod.copy(self.deps.system, text, &self.clip_encoded);
        self.state.set_status("Copied {d} characters", .{copied});
        self.needs_render = true;
        return true;
    }

    fn click_row(self: *Session, lay: layout_mod.Layout, y: u16) bool {
        const row = y - lay.body_y;
        const index = self.state.offset + row;
        if (index >= self.state.visible_len) return false;

        if (index == self.state.cursor) {
            // A second click on the selected row opens it. No double-click
            // timer: the first click is the confirmation.
            return self.apply(.open_selected);
        }
        self.state.cursor = index;
        self.state.scroll_into_view();
        self.needs_render = true;
        return true;
    }

    fn apply(self: *Session, command: core.command.Command) bool {
        const effects = core.update.apply(&self.state, &self.store, command);
        self.run_effects(effects.slice());
        self.needs_render = true;
        // A scope is a preference, however it was changed: the picker or the
        // `a` key both end up here, and the next start opens where this one is.
        switch (command) {
            .accounts_select, .cycle_account => self.remember_scope(),
            else => {},
        }
        return true;
    }

    fn remember_scope(self: *Session) void {
        const scope = self.deps.scope orelse return;
        const label = if (self.state.account_filter) |id|
            self.state.accounts.label_for(id)
        else
            "";
        scope.save(label) catch {};
    }

    /// Test hook: run effects the way the loop does.
    pub fn run_effects_for_test(self: *Session, effects: []const core.effect.Effect) void {
        self.run_effects(effects);
    }

    /// Shows the spinner before an effect that may wait, and keeps it visible
    /// long enough to be seen. `loading_ms` is 0 in tests that do not want to
    /// sleep.
    fn begin_loading(self: *Session) ?i64 {
        if (self.deps.loading_ms == 0) return null;
        self.state.loading = true;
        self.render();
        return os.monotonic_ms();
    }

    fn end_loading(self: *Session, started: ?i64) void {
        if (self.deps.loading_ms == 0) return;
        if (started) |begin| {
            const elapsed: i64 = @max(0, os.monotonic_ms() - begin);
            const minimum: i64 = @intCast(self.deps.loading_ms);
            if (elapsed < minimum) os.sleep_ms(@intCast(minimum - elapsed));
        }
        self.state.loading = false;
        self.needs_render = true;
    }

    fn run_effects(self: *Session, effects: []const core.effect.Effect) void {
        for (effects) |effect| {
            // One connection: a body asked for while the worker has it is
            // deferred (the reader shows its placeholder) instead of freezing
            // the UI; everything else waits for the worker.
            switch (effect) {
                .refresh => {},
                .fetch_body => |args| {
                    if (self.refreshing) {
                        self.pending_body = .{
                            .account = args.account,
                            .mailbox = args.mailbox,
                            .id = args.id,
                        };
                        continue;
                    }
                },
                else => self.wait_refresh(),
            }

            const timer = self.begin_loading();
            switch (effect) {
                .fetch_body => |args| self.fetch_body(args.account, args.mailbox, args.id),
                .sync_flags => |args| self.sync_flags(args.account, args.id, args.flags),
                .move_message => |args| self.move_message(args.account, args.id, args.to),
                .delete_message => |args| self.delete_message(args.account, args.mailbox, args.id),
                .empty_mailbox => |args| self.empty_mailbox(args.account, args.mailbox),
                .remove_account => |args| self.remove_account(args.account),
                .edit_account => |args| self.open_settings(args.account),
                .rename_account => |args| self.open_rename(args.account),
                .oauth_account => |args| self.oauth_account(args.account),
                .refresh => self.start_refresh(),
                .send => |outgoing| self.send(&outgoing),
            }
            self.end_loading(timer);
        }
    }

    fn source_for(self: *Session, account: core.id.AccountId) ?core.mail_port.Mail {
        for (self.live_sources()) |source| {
            if (source.id == account) return source.mail;
        }
        return null;
    }

    fn outbox_for(self: *Session, account: core.id.AccountId) ?core.outbox_port.Outbox {
        for (self.deps.outboxes) |source| {
            if (source.id == account) return source.outbox;
        }
        return null;
    }

    fn fetch_body(self: *Session, account: core.id.AccountId, mailbox: Mailbox, id: MessageId) void {
        // The local copy first: opening a message you have read is instant.
        if (self.deps.bodies) |bodies| {
            if (bodies.load(account, mailbox, id, &self.raw) catch null) |cached| {
                self.set_raw(cached);
                return;
            }
        }

        const mail = self.source_for(account) orelse {
            self.state.set_alert("That account is not connected", .{});
            return;
        };
        const raw = mail.fetch_raw(mailbox, id, &self.raw) catch {
            self.raw_len = 0;
            self.body_len = 0;
            self.shown_len = 0;
            self.image_slot_count = 0;
            self.html_len = 0;
            self.body_loaded = true;
            self.wrapped = .{};
            self.needs_render = true;
            self.state.set_alert("Could not load this message", .{});
            return;
        };
        if (self.deps.bodies) |bodies| bodies.save(account, mailbox, id, raw) catch {};
        self.set_raw(raw);
    }

    /// Renders both views from one message: the text one (what the reader shows
    /// by default) and, when there is an HTML part, the reading view made from
    /// it. `H` switches between them without touching the network.
    fn set_raw(self: *Session, raw: []const u8) void {
        self.html_view = false;
        const length = @min(raw.len, self.raw.len);
        if (raw.ptr != &self.raw) @memcpy(self.raw[0..length], raw[0..length]);
        self.raw_len = @intCast(length);
        const message = self.raw[0..self.raw_len];

        const text = core.mime.text_body(message, &self.body, &self.scratch_bytes);
        self.body_len = @intCast(text.len);
        // A text part generated from HTML carries entities ("&emsp;", "&#8203;").
        // They are spacing or nothing at all, never words.
        const spaced = core.html.clean_spacing(self.body[0..self.body_len], &self.scratch_bytes);
        const joined = core.links.unwrap_urls(spaced, &self.shown);
        self.shown_len = @intCast(joined.len);

        self.text_link_count = core.links.scan(self.shown[0..self.shown_len], &self.text_links);

        // Pictures belong to the message that carried them: "r0" in another mail
        // is another picture, and keeping the slot hands back the previous bytes.
        self.image_slot_count = 0;
        self.image_painted = 0;
        self.hovered = null;
        self.hover_url.clear();

        self.html_len = 0;
        self.html_ready = false;
        self.html_link_count = 0;
        self.html_kind_count = 0;
        self.html_anchor_count = 0;
        self.render_html_view();
        self.prefer_html();
        self.body_loaded = true;
        self.wrapped = .{};
        self.needs_render = true;
    }

    /// Renders the HTML part, once, when the reader asks for it.
    fn render_html_view(self: *Session) void {
        self.html_ready = true;
        self.html_len = 0;
        self.html_part_len = 0;
        self.html_link_count = 0;
        self.html_anchor_count = 0;
        const message = self.raw[0..self.raw_len];
        const part = core.mime.html_body(message, &self.html_part, &self.scratch_bytes) orelse return;
        self.html_part_len = @intCast(part.len);
        const cleaned = core.html.clean_entities(part, &self.html_cleaned);
        self.html_cleaned_len = @intCast(cleaned.len);
        const marked = core.html.mark_images(cleaned, &self.html_marked);
        self.html_marked_len = @intCast(marked.len);

        var sources: [core.html.max_remote_images][]const u8 = undefined;
        self.remote_sources_count = core.html.remote_images(part, &sources);
        for (sources[0..self.remote_sources_count], 0..) |source, index| {
            self.remote_sources[index].set(source);
        }

        const rendered = core.html.render(
            self.html_marked[0..self.html_marked_len],
            &self.html_text,
            &self.html_links,
            &self.html_kinds,
            &self.html_anchors,
        );
        self.html_len = @intCast(rendered.text.len);
        self.html_link_count = rendered.links.len;
        self.html_kind_count = rendered.kinds.len;
        self.html_anchor_count = rendered.anchors.len;
    }

    /// Lays the HTML part out with a text browser, at the reader's width. The
    /// result is what aerc shows: real columns, real tables, links inline.
    /// Opens on the view a mail client would show: HTML when the message has
    /// one, text when it does not.
    fn prefer_html(self: *Session) void {
        self.html_view = self.html_len > 0;
    }

    /// The text the reader is showing right now.
    fn reader_text(self: *const Session) []const u8 {
        if (self.html_view and self.html_len > 0) return self.html_text[0..self.html_len];
        return self.shown[0..self.shown_len];
    }

    /// The links of the text the reader is showing, as ranges in that text.
    fn reader_links(self: *const Session) []const core.links.Link {
        if (self.html_view and self.html_len > 0) {
            return self.html_links[0..self.html_link_count];
        }
        return self.text_links[0..self.text_link_count];
    }

    fn delete_message(self: *Session, account: core.id.AccountId, mailbox: Mailbox, id: MessageId) void {
        const mail = self.source_for(account) orelse {
            self.state.set_alert("That account is not connected", .{});
            return;
        };
        mail.delete_message(mailbox, id) catch {
            self.state.set_alert("Could not delete on the server", .{});
            return;
        };
        self.state.set_status("Deleted for good", .{});
    }

    fn empty_mailbox(self: *Session, account: ?core.id.AccountId, mailbox: Mailbox) void {
        var done: u32 = 0;
        for (self.live_sources()) |source| {
            if (account) |filter| {
                if (source.id != filter) continue;
            }
            source.mail.empty_mailbox(mailbox) catch {
                self.state.set_alert("Could not empty {s} on the server", .{mailbox.title()});
                return;
            };
            done += 1;
        }
        if (done == 0) {
            self.state.set_alert("That account is not connected", .{});
            return;
        }
        self.state.set_status("Trash emptied", .{});
    }

    fn oauth_account(self: *Session, account: core.id.AccountId) void {
        const label = self.state.accounts.label_for(account);

        // A client id is only needed to talk to the provider: say so instead of
        // failing inside the flow.
        const index = self.state.accounts.index_of(account) orelse 0;
        if (self.state.accounts.items[index].oauth_client.is_empty()) {
            self.state.set_alert("OAuth needs a Client ID (Advanced in the account form)", .{});
            return;
        }
        const accounts = self.deps.accounts_file orelse {
            self.state.set_alert("Accounts cannot be changed here", .{});
            return;
        };
        // The flow talks to a human in a browser: give the terminal back first,
        // or the URL lands on a screen nobody is looking at.
        self.deps.system.suspend_ui() catch {};
        var problem: core.text.Text(256) = .{};
        accounts.oauth_login(account, &problem) catch {
            self.deps.system.resume_ui() catch {};
            self.invalidate_screen();
            self.invalidate_screen();
            // The account is saved either way: the sign-in is what failed.
            self.attach_new_account(account, label);
            if (problem.is_empty()) {
                self.state.set_alert("{s} saved; sign-in failed. Press o to retry", .{label});
            } else {
                self.state.set_alert("{s} saved; {s}", .{ label, problem.slice() });
            }
            return;
        };
        self.deps.system.resume_ui() catch {};
        self.invalidate_screen();
        self.state.set_status("Signed in {s}", .{label});
        self.open_settings_after_oauth(account);
    }

    /// After signing in, attach the account so its mail shows up.
    fn open_settings_after_oauth(self: *Session, account: core.id.AccountId) void {
        self.attach_new_account(account, self.state.accounts.label_for(account));
    }

    fn remove_account(self: *Session, account: core.id.AccountId) void {
        const label = self.state.accounts.label_for(account);
        const accounts = self.deps.accounts_file orelse {
            self.state.set_alert("Accounts cannot be changed here", .{});
            return;
        };
        accounts.remove(account) catch {
            self.state.set_alert("Could not rewrite the config", .{});
            return;
        };

        // Gone from the config and from the view: its mail goes with it.
        self.state.accounts.remove(account);
        if (self.state.account_filter) |filter| {
            if (filter == account) self.state.account_filter = null;
        }
        _ = self.store.remove_account(account);
        self.state.accounts_cursor = 0;
        self.state.rebuild(&self.store);
        self.state.set_status("{s} removed · restart to apply", .{label});
    }

    /// Every field on one screen: Tab moves, characters type, Ctrl+S saves.
    pub const Field = enum(u8) {
        address,
        imap_host,
        imap_port,
        smtp_host,
        smtp_port,
        // Sign in comes before the password: the choice decides whether there
        // is a password at all. Everything below Advanced is rare.
        sign_in,
        password,
        advanced,
        username,
        client_id,

        fn count() u8 {
            return 10;
        }

        fn step(self: Field) core.setup.Step {
            return switch (self) {
                .address => .address,
                .imap_host => .imap_host,
                .imap_port => .imap_port,
                .smtp_host => .smtp_host,
                .smtp_port => .smtp_port,
                .sign_in, .advanced, .client_id => .review,
                .password => .password,
                .username => .username,
            };
        }
    };

    const Settings = struct {
        setup: core.setup.Setup = .{},
        editing: ?core.id.AccountId = null,
        field: Field = .address,
    };

    /// Opens the account form: empty for a new account, prefilled for an edit.
    fn open_settings(self: *Session, account: ?core.id.AccountId) void {
        var form = Settings{ .editing = account };

        if (account) |id| {
            const index = self.state.accounts.index_of(id) orelse 0;
            const info = &self.state.accounts.items[index];
            var label_buffer: [core.limits.label_max]u8 = undefined;
            var port_buffer: [6]u8 = undefined;

            _ = form.setup.address.set(info.address.addr_spec(&label_buffer));
            form.setup.imap_host.set(info.imap_host.slice());
            if (info.imap_port != 0) {
                form.setup.imap_port.set(std.fmt.bufPrint(&port_buffer, "{d}", .{info.imap_port}) catch "");
            }
            form.setup.smtp_host.set(info.smtp_host.slice());
            if (info.smtp_port != 0) {
                form.setup.smtp_port.set(std.fmt.bufPrint(&port_buffer, "{d}", .{info.smtp_port}) catch "");
            }
            form.setup.username.set(info.username.slice());
            form.setup.send_enabled = info.smtp;
            if (!info.oauth_client.is_empty()) {
                form.setup.set_oauth(true);
                form.setup.oauth_client_id.set(info.oauth_client.slice());
            }
            // Start on the name so a rename is one keystroke away.
            form.field = .address;
        }

        self.settings = form;
        self.state.view = .accounts;
        self.state.set_status("", .{});
        self.needs_render = true;
    }

    /// A one-line rename prompt: the label is the only thing that changes.
    const Rename = struct {
        account: core.id.AccountId = .unknown,
        text: core.text.Text(core.limits.label_max) = .{},
    };

    fn open_rename(self: *Session, account: core.id.AccountId) void {
        const index = self.state.accounts.index_of(account) orelse return;
        self.renaming = .{ .account = account };
        self.renaming.?.text.set(self.state.accounts.items[index].label.slice());
        self.state.view = .accounts;
        self.needs_render = true;
    }

    fn rename_key(self: *Session, rename: *Rename, key: input.Key) bool {
        switch (key) {
            .char => |codepoint| {
                if (codepoint >= 0x20 and codepoint != 0x7f) rename.text.append_codepoint(codepoint);
                self.needs_render = true;
            },
            .backspace => {
                rename.text.pop_codepoint();
                self.needs_render = true;
            },
            .escape => {
                self.renaming = null;
                self.state.set_status("", .{});
                self.needs_render = true;
            },
            .enter => self.commit_rename(rename),
            .ctrl => |letter| switch (letter) {
                'u' => {
                    rename.text.clear();
                    self.needs_render = true;
                },
                'c', 'q' => self.state.quit = true,
                else => {},
            },
            else => {},
        }
        return true;
    }

    fn commit_rename(self: *Session, rename: *Rename) void {
        const accounts = self.deps.accounts_file orelse {
            self.renaming = null;
            self.state.set_alert("Accounts cannot be changed here", .{});
            return;
        };
        if (rename.text.is_empty()) {
            self.state.set_alert("A name cannot be empty", .{});
            return;
        }

        accounts.rename(rename.account, rename.text.slice()) catch {
            self.renaming = null;
            self.state.set_alert("Could not rename the account", .{});
            return;
        };
        if (self.state.accounts.index_of(rename.account)) |index| {
            self.state.accounts.items[index].label.set(rename.text.slice());
        }
        self.state.set_status("{s} renamed · restart to apply", .{rename.text.slice()});
        self.renaming = null;
        self.needs_render = true;
    }

    fn settings_key(self: *Session, form: *Settings, key: input.Key) bool {
        // The model routes by step, so point it at the field being edited.
        form.setup.step = form.field.step();
        self.needs_render = true;

        switch (key) {
            .char => |codepoint| switch (form.field) {
                .sign_in => if (codepoint == ' ') form.setup.set_oauth(!form.setup.oauth),
                .advanced => if (codepoint == ' ') form.setup.toggle_advanced(),
                .client_id => if (codepoint >= 0x20 and codepoint != 0x7f) form.setup.oauth_client_id.append_codepoint(codepoint),
                else => if (codepoint >= 0x20 and codepoint != 0x7f) form.setup.append(codepoint),
            },
            .backspace => switch (form.field) {
                .client_id => form.setup.oauth_client_id.pop_codepoint(),
                .sign_in => {},
                else => form.setup.backspace(),
            },
            .tab, .down => self.move_field(form, 1),
            .back_tab, .up => self.move_field(form, -1),
            .enter => switch (form.field) {
                .password => self.save_settings(form),
                .sign_in => form.setup.set_oauth(!form.setup.oauth),
                .advanced => form.setup.toggle_advanced(),
                .client_id => self.save_settings(form),
                else => self.move_field(form, 1),
            },
            .escape => self.close_settings(),
            .ctrl => |letter| switch (letter) {
                'u' => switch (form.field) {
                    .client_id => form.setup.oauth_client_id.clear(),
                    else => form.setup.clear_field(),
                },
                's' => self.save_settings(form),
                'c', 'q' => self.state.quit = true,
                else => {},
            },
            else => {},
        }
        return true;
    }

    /// A newly saved account is connected and shown now, not on the next start.
    fn attach_new_account(self: *Session, id: core.id.AccountId, label: []const u8) void {
        const accounts = self.deps.accounts_file orelse return;

        var opened: core.accounts_port.Accounts.Connected = .{};
        accounts.connect(id, &opened) catch {
            self.state.set_alert("{s} saved, but it did not connect", .{label});
            return;
        };
        const mail = opened.mail orelse {
            self.state.set_alert("{s} saved, but it did not connect", .{label});
            return;
        };

        self.add_source(.{
            .id = opened.id,
            .label = opened.label,
            .from = core.address.Address.init(opened.address_text) catch .{},
            .mail = mail,
            .imap_host = opened.imap_host,
            .imap_port = opened.imap_port,
            .username = opened.username,
            .smtp_host = opened.smtp_host,
            .smtp_port = opened.smtp_port,
            .smtp = opened.smtp,
        });
        self.state.set_status("{s} added", .{label});
        // Show its mail straight away.
        self.start_refresh();
    }

    fn move_field(self: *Session, form: *Settings, delta: i8) void {
        const count: i16 = Field.count();
        const current: i16 = @backingInt(form.field);
        // Walk in the direction asked, stepping over hidden rows.
        var next = @mod(current + delta + count, count);
        var guard: u8 = 0;
        while (!form.setup.field_visible(@intCast(next)) and guard < count) : (guard += 1) {
            next = @mod(next + delta + count, count);
        }
        form.field = @fromBackingInt(@intCast(@as(u8, @intCast(next))));
        form.setup.step = form.field.step();
        self.needs_render = true;
    }

    fn close_settings(self: *Session) void {
        if (self.settings) |*form| form.setup.deinit();
        self.settings = null;
        self.state.view = .accounts;
        self.state.set_status("", .{});
        self.needs_render = true;
    }

    fn save_settings(self: *Session, form: *Settings) void {
        // Nothing here closes the form: a refusal must not cost the user the
        // fields they just typed. The reason goes inside the card.
        const accounts = self.deps.accounts_file orelse {
            form.setup.problem.set("Accounts cannot be changed here");
            self.needs_render = true;
            return;
        };

        // Validate the whole account before writing anything.
        form.setup.step = .review;
        form.setup.next();
        if (!form.setup.done) {
            // Keep the cursor where it is; the problem line explains what is wrong.
            form.setup.step = form.field.step();
            self.needs_render = true;
            return;
        }

        var text_buffer: [4096]u8 = undefined;
        const text = form.setup.config_text(&text_buffer);
        var label_buffer: [core.limits.label_max]u8 = undefined;
        const label = form.setup.account_label(&label_buffer);

        // The label can change under us: a taken name is renamed, not refused.
        var final_label: core.text.Text(core.limits.label_max) = .{};
        final_label.set(label);
        var reason: core.text.Text(256) = .{};

        const saved_id = accounts.save(.{
            .text = text,
            .label = label,
            // An empty field means "keep the stored password", so editing does
            // not silently blank the credential.
            .password = if (form.setup.oauth or form.setup.password.len == 0)
                null
            else
                form.setup.password.expose(),
            .replaces = form.editing,
            .label_out = &final_label,
            .problem = &reason,
        }) catch {
            // Say what failed. "Fix the reason above" with nothing above was a
            // dead end.
            if (!reason.is_empty()) {
                form.setup.problem.set(reason.slice());
            } else {
                form.setup.problem.set("Could not write the config or the credential file");
            }
            self.needs_render = true;
            return;
        };

        // The view can follow a rename; the connection cannot follow a new host.
        if (form.editing) |id| {
            if (self.state.accounts.index_of(id)) |index| {
                var address = core.address.Address{};
                address = core.address.Address.init(form.setup.address.slice()) catch core.address.Address{};
                self.state.accounts.items[index].label.set(label);
                self.state.accounts.items[index].address = address;
                self.state.accounts.items[index].imap_host.set(form.setup.imap_host.slice());
                self.state.accounts.items[index].username.set(form.setup.username.slice());
            }
        }
        const added = form.editing == null;
        const oauth = form.setup.oauth;
        const new_id = saved_id;
        const saved_label = final_label.slice();
        self.close_settings();
        self.state.set_status("{s} saved", .{saved_label});
        if (!added) return;

        if (oauth) {
            // A brand-new OAuth account: sign in now, then attach it.
            self.oauth_account(new_id);
            return;
        }
        self.attach_new_account(new_id, saved_label);
    }

    fn sync_flags(self: *Session, account: core.id.AccountId, id: MessageId, flags: core.message.Flags) void {
        const mail = self.source_for(account) orelse return;
        mail.set_flags(id, flags) catch {
            self.state.set_alert("Could not update the server", .{});
        };
    }

    fn move_message(self: *Session, account: core.id.AccountId, id: MessageId, to: Mailbox) void {
        const mail = self.source_for(account) orelse return;
        mail.move_message(id, to) catch {
            self.state.set_alert("Could not move the message", .{});
        };
    }

    fn mask_bit(account_index: u8, mailbox_index: u8) u32 {
        return @as(u32, 1) << @intCast(@as(u16, account_index) * 6 + mailbox_index);
    }

    fn send(self: *Session, outgoing: *const core.outgoing.Outgoing) void {
        const outbox = self.outbox_for(outgoing.account) orelse {
            _ = core.update.apply(&self.state, &self.store, .send_failed);
            return;
        };
        outbox.send(outgoing) catch {
            _ = core.update.apply(&self.state, &self.store, .send_failed);
            return;
        };
        _ = core.update.apply(&self.state, &self.store, .send_succeeded);
        self.needs_render = true;
    }

    /// Boot only: the first load, synchronous, with the splash on screen. A
    /// worker thread would need a store the splash could already read.
    fn reload(self: *Session, mailbox: Mailbox) void {
        var loaded_any = false;
        var failed = false;
        var login_failed = false;

        for (self.live_sources(), 0..) |source, index| {
            // A single account in scope means the others are not opened at all:
            // no socket, no login, nothing to wait for.
            if (!self.in_scope(source.id)) continue;
            const count = source.mail.fetch(mailbox, self.scratch) catch |err| {
                failed = true;
                if (err == error.Rejected) login_failed = true;
                continue;
            };
            core.sync.replace_mailbox(&self.store, source.id, mailbox, self.scratch[0..count]);
            self.loaded_mask |= mask_bit(@intCast(index), @backingInt(mailbox));
            loaded_any = true;
            if (self.deps.cache) |cache| {
                cache.save(source.id, mailbox, self.scratch[0..count]) catch {};
            }
        }

        self.state.rebuild(&self.store);
        if (failed and !loaded_any) {
            // A refused login is the most useful thing we know: say it.
            if (login_failed) {
                self.state.set_alert("Login failed: {s}", .{self.login_hint()});
            } else {
                self.state.set_alert("Could not load {s}", .{mailbox.title()});
            }
        }
        self.needs_render = true;
    }

    fn render(self: *Session) void {
        if (self.renaming) |*rename| {
            render_mod.rename_prompt(&self.screen, self.deps.theme, rename.text.slice());
            self.flush();
            return;
        }
        if (self.settings) |*form| {
            render_mod.settings(&form.setup, form.field, form.editing != null, self.deps.theme, &self.screen);
            self.flush();
            return;
        }
        // Another view means another screen: the rows that held a picture have
        // nothing in them now, and a diff would leave them as they were.
        if (self.last_view != self.state.view) {
            self.last_view = self.state.view;
            self.screen.pristine = true;
        }

        const lay = layout_mod.Layout.compute(self.size.columns, self.size.rows, self.state.accounts.max_label());
        if (self.body_loaded) {
            wrap.wrap(self.reader_text(), lay.reader_text_width, &self.wrapped);
        }
        self.prepare_cover();

        _ = core.update.apply(&self.state, &self.store, .{ .set_viewport = .{
            .list_rows = lay.list_rows,
            .reader_rows = lay.reader_rows,
            .body_rows = if (self.body_loaded) self.wrapped.len else 0,
        } });

        render_mod.frame(.{
            .state = &self.state,
            .store = &self.store,
            .theme = &self.deps.theme,
            .body = self.reader_text(),
            .wrapped = if (self.body_loaded) &self.wrapped else null,
            .links = self.reader_links(),
            .hovered = self.hovered,
            .hover_url = if (self.hover_url.is_empty()) null else self.hover_url.slice(),
            .kinds = self.html_kinds[0..self.html_kind_count],
            .cover = self.cover_rows[0..self.cover_len],
            .selection = self.selection,
            .now_unix = self.now_unix,
            .columns = self.size.columns,
            .rows = self.size.rows,
        }, &self.screen);

        self.flush();
        self.needs_render = false;
        self.paint_images(lay);
    }

    /// The bytes of the picture behind a marker: a part of the message, or one
    /// downloaded from its address.
    fn image_png(self: *Session, key: []const u8) ?[]const u8 {
        for (self.image_slots[0..self.image_slot_count]) |*slot| {
            if (!std.mem.eql(u8, slot.key.slice(), key)) continue;
            return if (slot.len > 0) slot.bytes[0..slot.len] else null;
        }
        if (self.image_slot_count >= self.image_slots.len) return null;

        // Decoded or downloaded once per message: doing either inside a frame
        // is what made scrolling take a second.
        // "r3" is a picture with an address; anything else names a part of the
        // message. Checking the other way round treats "r3" as a content id.
        var decoded: ?[]const u8 = null;
        if (is_remote_marker(key)) {
            if (self.remote_source(key[1..])) |url| decoded = self.remote_image(url);
        } else if (is_local_image(key)) {
            decoded = core.mime.image_body(self.raw[0..self.raw_len], key, &self.image_buffer);
        }

        const slot = &self.image_slots[self.image_slot_count];
        slot.key.set(key);
        slot.len = 0;
        if (decoded) |png| {
            const length = @min(png.len, slot.bytes.len);
            @memcpy(slot.bytes[0..length], png[0..length]);
            slot.len = @intCast(length);
        }
        self.image_slot_count += 1;
        return if (slot.len > 0) slot.bytes[0..slot.len] else null;
    }

    /// How many rows a picture needs, which is how many rows of text it hides.
    fn image_rows(self: *Session, key: []const u8) u8 {
        const png = self.image_png(key) orelse return 0;
        const size = png_size(png) orelse return 0;
        return @intCast(@min(image_cells(size).rows, 255));
    }

    /// What the picture layer depends on: the message, the scroll, the size.
    fn image_signature(self: *Session) u64 {
        var hash = std.hash.Wyhash.init(0x9e3779b9);
        hash.update(std.mem.asBytes(&self.state.opened));
        hash.update(std.mem.asBytes(&self.state.opened_account));
        hash.update(std.mem.asBytes(&self.state.reader_scroll));
        hash.update(std.mem.asBytes(&self.size.columns));
        hash.update(std.mem.asBytes(&self.size.rows));
        if (self.state.view != .reader) hash.update("out");
        return hash.final();
    }

    /// Measures the pictures on the visible lines before the frame is drawn, so
    /// the text underneath them is not printed only to be covered.
    fn prepare_cover(self: *Session) void {
        self.cover_len = 0;
        if (!self.html_view or self.deps.draw_image == null) return;
        const text = self.reader_text();

        var line: u32 = 0;
        while (line < self.wrapped.len and line < self.cover_rows.len) : (line += 1) {
            const content = self.wrapped.at(line, text);
            const marker = std.mem.indexOf(u8, content, "[IMG:") orelse continue;
            const rest = content[marker + 5 ..];
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
            self.cover_rows[line] = self.image_rows(rest[0..close]);
            self.cover_len = line + 1;
        }
    }

    /// The address behind `[IMG:rN]`.
    fn remote_source(self: *const Session, digits: []const u8) ?[]const u8 {
        const index = std.fmt.parseInt(usize, digits, 10) catch return null;
        if (index >= self.remote_sources_count) return null;
        return self.remote_sources[index].slice();
    }

    /// One downloaded picture, kept until another is needed: a page shows a
    /// handful, and fetching one twice is worse than keeping one in memory.
    fn remote_image(self: *Session, url: []const u8) ?[]const u8 {
        if (self.remote_len > 0 and std.mem.eql(u8, self.remote_url.slice(), url)) {
            return self.remote_bytes[0..self.remote_len];
        }
        const fetch = self.deps.fetch_image orelse return null;
        const bytes = fetch(self.deps.fetch_image_context, url, &self.remote_bytes) orelse return null;
        self.remote_url.set(url);
        self.remote_len = @intCast(bytes.len);
        return bytes;
    }

    /// Paints the images of the message over the text, at the markers the layout
    /// left for them. Images from the network are not fetched: the reader says
    /// what they are and o shows the mail in a browser.
    fn paint_images(self: *Session, lay: layout_mod.Layout) void {
        // Whatever is on screen now, the pictures of the last frame go: a list,
        // a help page or a compose window must not have a logo over it.
        if (self.deps.clear_images) |clear| clear(self.deps.clear_images_context);
        if (self.state.view != .reader) return;
        const draw = self.deps.draw_image orelse return;
        if (self.html_view == false or self.html_len == 0) return;

        const text = self.reader_text();
        var row: u16 = 0;
        var painted: u8 = 0;
        while (row < lay.reader_rows and painted < max_images_drawn) : (row += 1) {
            const index = self.state.reader_scroll + row;
            if (index >= self.wrapped.len) break;
            const line = self.wrapped.at(index, text);

            const marker = std.mem.indexOf(u8, line, "[IMG:") orelse continue;
            const rest = line[marker + 5 ..];
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
            const key = rest[0..close];
            const png = self.image_png(key) orelse continue;
            const size = png_size(png) orelse continue;
            const cells = image_cells(size);
            if (cells.columns == 0 or cells.rows == 0) continue;
            const height: u16 = @min(cells.rows, lay.reader_rows -| row);
            const width: u16 = @min(cells.columns, lay.columns -| 1);
            if (height == 0 or width == 0) continue;

            // Where the marker sits is where the picture starts: a logo on the
            // left stays on the left, one in a column stays in its column.
            const column: u16 = @intCast(@min(marker, lay.columns -| 1));
            _ = draw(
                self.deps.draw_image_context,
                png,
                image_id(self.state.opened_account, self.state.opened, key),
                column,
                lay.reader_body_y + row,
                @min(width, lay.columns -| column),
                height,
            );
            painted += 1;
        }
    }

    fn flush(self: *Session) void {
        const system = self.deps.system;
        if (!self.screen.dirty_any()) return;

        var row: u16 = 0;
        while (row < self.screen.rows) : (row += 1) {
            if (!self.screen.row_changed(row)) continue;

            // Absolute placement per row: skipping rows means the terminal
            // cursor cannot be assumed to be anywhere in particular.
            var cursor: [16]u8 = undefined;
            const at = std.fmt.bufPrint(&cursor, "\x1b[{d};1H", .{row + 1}) catch return;
            system.write(at) catch return;

            var writer = std.Io.Writer.fixed(&self.row_buffer);
            self.screen.encode_row(row, &writer, self.deps.theme.colored) catch return;
            system.write(writer.buffered()) catch return;
        }
        system.write("\x1b[0m") catch {};
        self.screen.commit();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MemoryMail = core.memory_mail.MemoryMail;
const Fake = system_mod.Fake;

/// A mail adapter that can fail on demand, to exercise every error branch.
const FakeMail = struct {
    inner: MemoryMail = MemoryMail.init(),
    /// How many times the session asked this account for mail: the way to see
    /// that an account out of scope is never opened.
    fetch_calls: u32 = 0,
    fail_fetch: bool = false,
    fail_body: bool = false,
    fail_flags: bool = false,
    fail_move: bool = false,

    fn mail(self: *FakeMail) core.mail_port.Mail {
        return .{ .context = self, .vtable = &.{
            .fetch = fetchThunk,
            .fetch_body = fetchBodyThunk,
            .fetch_raw = fetchRawThunk,
            .set_flags = setFlagsThunk,
            .move_message = moveThunk,
            .delete_message = deleteThunk,
            .empty_mailbox = emptyThunk,
        } };
    }

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) core.mail_port.Error!u32 {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        self.fetch_calls += 1;
        if (self.fail_fetch) return error.Unavailable;
        return self.inner.mail().fetch(mailbox, out);
    }

    fn fetchBodyThunk(
        context: *anyopaque,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) core.mail_port.Error![]const u8 {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_body) return error.Rejected;
        return self.inner.mail().fetch_body(mailbox, id, out);
    }

    fn fetchRawThunk(
        context: *anyopaque,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) core.mail_port.Error![]const u8 {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_body) return error.Rejected;
        return self.inner.mail().fetch_raw(mailbox, id, out);
    }

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: core.message.Flags) core.mail_port.Error!void {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_flags) return error.Unavailable;
        return self.inner.mail().set_flags(id, flags);
    }

    fn deleteThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId) core.mail_port.Error!void {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_flags) return error.Unavailable;
        return self.inner.mail().delete_message(mailbox, id);
    }

    fn emptyThunk(context: *anyopaque, mailbox: Mailbox) core.mail_port.Error!void {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_flags) return error.Unavailable;
        return self.inner.mail().empty_mailbox(mailbox);
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) core.mail_port.Error!void {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_move) return error.Rejected;
        return self.inner.mail().move_message(id, to);
    }
};

fn rejectFetch(_: *anyopaque, _: Mailbox, _: []Message) core.mail_port.Error!u32 {
    return error.Rejected;
}

fn rejectBody(_: *anyopaque, _: Mailbox, _: MessageId, _: []u8) core.mail_port.Error![]const u8 {
    return error.Rejected;
}

fn rejectRaw(_: *anyopaque, _: Mailbox, _: MessageId, _: []u8) core.mail_port.Error![]const u8 {
    return error.Rejected;
}

fn rejectFlags(_: *anyopaque, _: MessageId, _: core.message.Flags) core.mail_port.Error!void {
    return error.Rejected;
}

fn rejectMove(_: *anyopaque, _: MessageId, _: Mailbox) core.mail_port.Error!void {
    return error.Rejected;
}

fn rejectDelete(_: *anyopaque, _: Mailbox, _: MessageId) core.mail_port.Error!void {
    return error.Rejected;
}

fn rejectEmpty(_: *anyopaque, _: Mailbox) core.mail_port.Error!void {
    return error.Rejected;
}

const reject_vtable = core.mail_port.Mail.VTable{
    .fetch = rejectFetch,
    .fetch_body = rejectBody,
    .fetch_raw = rejectRaw,
    .set_flags = rejectFlags,
    .move_message = rejectMove,
    .delete_message = rejectDelete,
    .empty_mailbox = rejectEmpty,
};

const Rig = struct {
    fake_system: Fake = .{ .size_value = .{ .columns = 100, .rows = 24 } },
    fake_mail: FakeMail = .{},
    sources: [1]MailSource = undefined,
    session: Session = undefined,

    fn seed(self: *Rig) !void {
        const senders = [_][]const u8{ "Alice <alice@example.com>", "Bob <bob@example.com>" };
        const subjects = [_][]const u8{ "Invoice 1", "Lunch plans" };
        var index: u32 = 0;
        while (index < 2) : (index += 1) {
            var message = Message{
                .id = MessageId.from_int(index + 1),
                .account = core.id.AccountId.from_int(1),
                .mailbox = .inbox,
                .timestamp_unix = 1_699_999_900 - @as(i64, index) * 100,
                .from = try core.address.Address.init(senders[index]),
                .flags = .{ .unread = index == 0 },
            };
            message.subject.set(subjects[index]);
            try self.fake_mail.inner.seed(&message);
        }
    }

    fn start(self: *Rig) !void {
        try self.seed();
        self.sources[0] = .{
            .id = core.id.AccountId.from_int(1),
            .label = "account",
            .from = core.address.Address.init("me@amail.local") catch .{},
            .mail = self.fake_mail.mail(),
        };
        try self.session.init(testing.allocator, .{
            .accounts = &self.sources,
            .system = self.fake_system.system(),
            .theme = theme_mod.Theme.dark(),
            .now = fixed_now,
            .loading_ms = 0,
        });
        // Tests exercise the steady state: the cache is empty, so boot fetches.
        self.session.boot();
        self.session.settle_refresh_for_test();
    }

    fn deinit(self: *Rig) void {
        self.session.deinit();
    }

    fn rejecting_mail(self: *Rig) core.mail_port.Mail {
        _ = self;
        return .{ .context = undefined, .vtable = &reject_vtable };
    }

    fn send_without_settle(self: *Rig, bytes: []const u8) void {
        self.fake_system.push_input(bytes);
        _ = self.session.step();
    }

    fn send(self: *Rig, bytes: []const u8) void {
        self.fake_system.push_input(bytes);
        _ = self.session.step();
        self.session.settle_refresh_for_test();
    }
};

test "session loads the initial mailbox on init" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();

    try testing.expectEqual(@as(u32, 2), rig.session.store.len);
    try testing.expectEqual(@as(u32, 2), rig.session.state.visible_len);
    try testing.expectEqual(Mailbox.inbox, rig.session.state.mailbox);
}

test "session paints the list before it touches the network" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
    });
    defer rig.deinit();

    // Nothing has been fetched yet: an empty cache means "boot later".
    try testing.expectEqual(@as(u32, 0), rig.session.store.len);
    try testing.expect(rig.session.needs_boot);

    rig.session.render();
    rig.session.boot();
    rig.session.settle_refresh_for_test();
    try testing.expectEqual(@as(u32, 2), rig.session.store.len);
    try testing.expect(std.mem.indexOf(u8, rig.fake_system.output_text(), "amail") != null);
    try testing.expect(std.mem.indexOf(u8, rig.fake_system.output_text(), "Inbox") != null);
}

test "j and k move the cursor and redraw" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("j");
    try testing.expectEqual(@as(u32, 1), rig.session.state.cursor);
    rig.send("k");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);
}

test "escape in the list does nothing, not even after the timeout resolves it" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("\x1b");
    // A lone ESC is ambiguous until the next read times out.
    _ = rig.session.step();
    try testing.expect(!rig.session.state.quit);
    try testing.expectEqual(core.state.View.list, rig.session.state.view);
}

test "Ctrl+Q quits from the list" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.fake_system.push_input("\x11");
    try testing.expect(!rig.session.step());
    try testing.expect(rig.session.state.quit);
}

test "q quits from the list but not from the search field" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("/");
    rig.send("q");
    try testing.expect(!rig.session.state.quit);
    try testing.expectEqualStrings("q", rig.session.state.query.slice());
    rig.send("\x1b");

    rig.send("q");
    try testing.expect(rig.session.state.quit);
}

test "closed stdin ends the session" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_system.closed = true;
    try testing.expect(!rig.session.step());
    try testing.expect(rig.session.state.quit);
}

test "a terminal read error shows an alert and keeps the session alive" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_system.read_failure = error.IoError;
    try testing.expect(rig.session.step());
    try testing.expectEqualStrings("Terminal error", rig.session.state.status.slice());
    try testing.expect(rig.session.state.status_alert);
}

test "opening a message fetches its body and renders the reader" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("\r");
    try testing.expectEqual(core.state.View.reader, rig.session.state.view);
    try testing.expect(rig.session.body_loaded);
    try testing.expect(rig.session.body_len > 0);
    try testing.expect(rig.session.wrapped.len > 0);
}

test "a failed body fetch becomes an alert, not a crash" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_mail.fail_body = true;
    _ = rig.session.step();

    rig.send("\r");
    try testing.expect(rig.session.body_loaded);
    try testing.expectEqual(@as(u32, 0), rig.session.body_len);
    try testing.expectEqualStrings("Could not load this message", rig.session.state.status.slice());
    try testing.expect(rig.session.state.status_alert);
}

const RecordingOutbox = struct {
    sent: u32 = 0,
    failure: ?core.outbox_port.Error = null,

    fn outbox(self: *RecordingOutbox) core.outbox_port.Outbox {
        return .{ .context = self, .vtable = &.{ .send = sendThunk } };
    }

    fn sendThunk(context: *anyopaque, message: *const core.outgoing.Outgoing) core.outbox_port.Error!void {
        const self: *RecordingOutbox = @ptrCast(@alignCast(context));
        if (self.failure) |err| return err;
        _ = message;
        self.sent += 1;
    }
};

test "composing and sending with a working outbox closes the draft" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    var outbox: RecordingOutbox = .{};
    const outboxes = [_]OutboxSource{.{ .id = core.id.AccountId.from_int(1), .outbox = outbox.outbox() }};
    rig.session.deps.outboxes = &outboxes;
    _ = rig.session.step();

    rig.send("c");
    rig.send("alice@example.com");
    rig.send("\t");
    rig.send("Hi");
    rig.send("\t\thello");
    rig.send("\x13"); // Ctrl+S

    try testing.expectEqual(@as(u32, 1), outbox.sent);
    try testing.expectEqual(core.state.View.list, rig.session.state.view);
    try testing.expectEqualStrings("Message sent · 2 opens Sent", rig.session.state.status.slice());
}

test "sending without an outbox keeps the draft and alerts" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("c");
    rig.send("alice@example.com");
    rig.send("\x13");
    try testing.expectEqual(core.state.View.compose, rig.session.state.view);
    try testing.expect(rig.session.state.compose.active);
    try testing.expect(rig.session.state.status_alert);
}

test "a failing outbox keeps the draft and alerts" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    var outbox: RecordingOutbox = .{ .failure = error.Rejected };
    const outboxes = [_]OutboxSource{.{ .id = core.id.AccountId.from_int(1), .outbox = outbox.outbox() }};
    rig.session.deps.outboxes = &outboxes;
    _ = rig.session.step();

    rig.send("c");
    rig.send("alice@example.com");
    rig.send("\x13");
    try testing.expectEqual(core.state.View.compose, rig.session.state.view);
    try testing.expect(rig.session.state.compose.active);
    try testing.expectEqualStrings("Could not send; the draft is still here", rig.session.state.status.slice());
}

test "two accounts share one unified list, and a cycles the scope" {
    var fake_system: Fake = .{ .size_value = .{ .columns = 100, .rows = 24 } };
    var first_mail: FakeMail = .{};
    var second_mail: FakeMail = .{};

    var first = Message{
        .id = MessageId.from_int(1),
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .timestamp_unix = 1_699_999_900,
        .from = try core.address.Address.init("Alice <alice@example.com>"),
    };
    first.subject.set("from personal");
    try first_mail.inner.seed(&first);

    var second = Message{
        .id = MessageId.from_int(1),
        .account = core.id.AccountId.from_int(2),
        .mailbox = .inbox,
        .timestamp_unix = 1_699_999_950,
        .from = try core.address.Address.init("Bob <bob@example.com>"),
    };
    second.subject.set("from work");
    try second_mail.inner.seed(&second);

    const sources = [_]MailSource{
        .{ .id = core.id.AccountId.from_int(1), .label = "personal", .mail = first_mail.mail() },
        .{ .id = core.id.AccountId.from_int(2), .label = "work", .mail = second_mail.mail() },
    };

    var session: Session = undefined;
    try session.init(testing.allocator, .{
        .accounts = &sources,
        .system = fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
    });
    defer session.deinit();
    session.boot();
    session.settle_refresh_for_test();

    try testing.expectEqual(@as(u32, 2), session.store.len);
    try testing.expectEqual(@as(u32, 2), session.state.visible_len);
    try testing.expectEqualStrings("work", session.state.accounts.label_for(core.id.AccountId.from_int(2)));

    fake_system.push_input("a");
    _ = session.step();
    try testing.expectEqual(core.id.AccountId.from_int(1), session.state.account_filter.?);
    try testing.expectEqual(@as(u32, 1), session.state.visible_len);
    try testing.expectEqualStrings("from personal", session.store.at(session.state.visible[0]).subject.slice());

    // A forced refresh with a filter skips the other account.
    fake_system.push_input("\x12");
    _ = session.step();
    try testing.expectEqual(core.id.AccountId.from_int(1), session.state.account_filter.?);
    try testing.expectEqual(@as(u32, 2), session.store.len);

    fake_system.push_input("a");
    _ = session.step();
    try testing.expectEqual(core.id.AccountId.from_int(2), session.state.account_filter.?);
    try testing.expectEqualStrings("from work", session.store.at(session.state.visible[0]).subject.slice());

    fake_system.push_input("a");
    _ = session.step();
    try testing.expect(session.state.account_filter == null);
    try testing.expectEqual(@as(u32, 2), session.state.visible_len);
}

test "switching to a loaded mailbox does not refetch it" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Inbox is loaded at startup; switching to Sent and back must not fetch
    // Inbox again.
    rig.send("\t");
    rig.send("\x1b[Z");
    try testing.expectEqual(Mailbox.inbox, rig.session.state.mailbox);
    try testing.expectEqual(@as(u32, 2), rig.session.store.len);
}

test "starting from a cache does not touch the network, and R refreshes and saves" {
    var rig: Rig = .{};
    try rig.seed();
    var cache: core.cache_port.Memory = .{ .load_count = 2 };
    rig.fake_system.size_value = .{ .columns = 100, .rows = 24 };
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .cache = cache.cache(),
    });
    rig.session.boot();
    defer rig.deinit();

    try testing.expectEqual(@as(u32, 1), cache.loads);
    try testing.expectEqual(@as(u32, 2), rig.session.state.visible_len);
    try testing.expectEqual(@as(u32, 0), cache.saves);

    rig.send("\x12");
    try testing.expectEqual(@as(u32, 1), cache.saves);
    try testing.expectEqual(@as(u32, 2), cache.last_saved);
}

test "switching to an unloaded mailbox reads the cache, not the network" {
    var rig: Rig = .{};
    try rig.seed();
    var cache: core.cache_port.Memory = .{ .load_count = 1 };
    rig.fake_system.size_value = .{ .columns = 100, .rows = 24 };
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .cache = cache.cache(),
    });
    defer rig.deinit();

    // Warm cache: no boot, and no transient status either.
    try testing.expect(!rig.session.needs_boot);
    try testing.expect(rig.session.state.status.is_empty());
    rig.session.boot();
    try testing.expectEqual(@as(u32, 1), rig.session.state.visible_len);
    try testing.expectEqualStrings("cached", rig.session.store.at(0).subject.slice());

    // Switching paints the cached copy first (instant), then refreshes.
    rig.send_without_settle("]");
    try testing.expectEqual(Mailbox.sent, rig.session.state.mailbox);
    try testing.expectEqual(@as(u32, 2), cache.loads);
    try testing.expectEqual(@as(u32, 1), rig.session.state.visible_len);
    const row = rig.session.state.visible[0];
    try testing.expectEqualStrings("cached", rig.session.store.at(row).subject.slice());
    try testing.expectEqual(Mailbox.sent, rig.session.store.at(row).mailbox);

    // The worker then replaces that mailbox with the server's truth.
    rig.session.settle_refresh_for_test();
    try testing.expectEqual(@as(u32, 0), rig.session.state.visible_len);
}

test "a cache miss falls back to the network and fills the cache" {
    var rig: Rig = .{};
    try rig.seed();
    var cache: core.cache_port.Memory = .{ .load_count = 0 };
    rig.fake_system.size_value = .{ .columns = 100, .rows = 24 };
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .cache = cache.cache(),
    });
    rig.session.boot();
    rig.session.settle_refresh_for_test();
    defer rig.deinit();

    // One cache read at init, one save after the fetch.
    try testing.expectEqual(@as(u32, 1), cache.loads);
    try testing.expectEqual(@as(u32, 1), cache.saves);
    try testing.expectEqual(@as(u32, 2), rig.session.state.visible_len);
}

test "a failing cache degrades to the network" {
    var rig: Rig = .{};
    try rig.seed();
    var cache: core.cache_port.Memory = .{ .load_failure = true, .save_failure = true };
    rig.fake_system.size_value = .{ .columns = 100, .rows = 24 };
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .cache = cache.cache(),
    });
    rig.session.boot();
    rig.session.settle_refresh_for_test();
    defer rig.deinit();

    try testing.expectEqual(@as(u32, 2), rig.session.state.visible_len);
}

test "an effect for an unknown account alerts instead of crashing" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    _ = core.update.apply(&rig.session.state, &rig.session.store, .{ .move = .down });
    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(9),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqualStrings("That account is not connected", rig.session.state.status.slice());
}

test "a failed flag sync becomes an alert" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_mail.fail_flags = true;
    _ = rig.session.step();

    rig.send("u");
    try testing.expectEqualStrings("Could not update the server", rig.session.state.status.slice());
}

test "archiving syncs the move to the server" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("d");
    const moved = rig.fake_mail.inner.find(MessageId.from_int(1)).?;
    try testing.expectEqual(Mailbox.archive, moved.mailbox);
    try testing.expectEqualStrings("Archived", rig.session.state.status.slice());
}

test "a failed move becomes an alert" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_mail.fail_move = true;
    _ = rig.session.step();

    rig.send("d");
    try testing.expectEqualStrings("Could not move the message", rig.session.state.status.slice());
}

test "a cached body opens without touching the network" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var bodies: core.bodies_port.Memory = .{};
    try bodies.cache().save(core.id.AccountId.from_int(1), .inbox, MessageId.from_int(1), "cached prose");
    bodies.saves = 0;
    rig.session.deps.bodies = bodies.cache();

    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqualStrings("cached prose", rig.session.body[0..rig.session.body_len]);
    try testing.expectEqual(@as(u32, 1), bodies.loads);
    try testing.expectEqual(@as(u32, 0), bodies.saves);
}

test "a fetched body is saved for next time" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var bodies: core.bodies_port.Memory = .{};
    rig.session.deps.bodies = bodies.cache();

    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqual(@as(u32, 1), bodies.saves);
    try testing.expect(bodies.have);
    try testing.expect(rig.session.body_len > 0);

    // Second open: the cache answers, the network is not asked again.
    rig.session.body_loaded = false;
    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqual(@as(u32, 2), bodies.loads);
}

test "an in-memory source boots without a splash" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .splash = false,
    });
    defer rig.deinit();

    // Same order as `loop` for a source that cannot block.
    rig.session.boot();
    rig.session.render();
    try testing.expectEqual(@as(u32, 2), rig.session.store.len);
    try testing.expect(std.mem.indexOf(u8, rig.fake_system.output_text(), "connecting") == null);
    try testing.expect(std.mem.indexOf(u8, rig.fake_system.output_text(), "Inbox") != null);
}

test "a boot with nothing to connect leaves the splash" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // A config that could not be read leaves no sources: the splash must not
    // stay up forever over the notice that explains it.
    rig.session.source_count = 0;
    rig.session.state.booting = true;
    rig.session.needs_boot = false;
    rig.session.boot();
    try testing.expect(!rig.session.state.booting);

    rig.session.state.booting = true;
    rig.session.needs_boot = true;
    rig.session.boot();
    try testing.expect(!rig.session.state.booting);
}

test "loop without a splash paints only the data" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    rig.fake_system.push_input("\x11"); // quit on the first step
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .splash = false,
    });
    defer rig.deinit();

    rig.session.loop();
    try testing.expectEqual(@as(u32, 2), rig.session.store.len);
    try testing.expect(std.mem.indexOf(u8, rig.fake_system.output_text(), "connecting") == null);
}

test "a refused login explains the provider, when the provider is known" {
    var rig: Rig = .{};
    try rig.seed();
    var source = MailSource{ .id = core.id.AccountId.from_int(1), .label = "outlook", .mail = rig.rejecting_mail() };
    source.hint = "Microsoft needs OAuth2 or an app password";
    rig.sources[0] = source;

    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 0,
    });
    defer rig.deinit();

    rig.session.boot();
    try testing.expectEqualStrings(
        "Login failed: Microsoft needs OAuth2 or an app password",
        rig.session.state.status.slice(),
    );
}

test "a refused login is named, not hidden behind a generic error" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "work",
        .mail = rig.rejecting_mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 0,
    });
    defer rig.deinit();

    rig.session.boot();
    try testing.expectEqualStrings("Login failed: check the password", rig.session.state.status.slice());
    try testing.expectEqual(@as(u32, 0), rig.session.store.len);
}

test "a cold boot that cannot connect says so, and shows an empty list" {
    var rig: Rig = .{};
    try rig.seed();
    rig.fake_mail.fail_fetch = true;
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
    });
    defer rig.deinit();

    rig.session.boot();
    try testing.expectEqualStrings("Could not load Inbox", rig.session.state.status.slice());
    try testing.expectEqual(@as(u32, 0), rig.session.store.len);

    // And the failure does not leave the session stuck in boot mode.
    try testing.expect(!rig.session.state.booting);
    try testing.expect(!rig.session.needs_boot);
    try testing.expect(!rig.session.refreshing);
}

test "delete and empty reach the account's server" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.run_effects_for_test(&.{.{ .delete_message = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expect(rig.fake_mail.inner.find(MessageId.from_int(1)) == null);
    try testing.expectEqualStrings("Deleted for good", rig.session.state.status.slice());

    rig.session.run_effects_for_test(&.{.{ .empty_mailbox = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
    } }});
    try testing.expectEqualStrings("Trash emptied", rig.session.state.status.slice());

    // All accounts (null filter) is the same path with no filter.
    rig.session.run_effects_for_test(&.{.{ .empty_mailbox = .{
        .account = null,
        .mailbox = .sent,
    } }});
    try testing.expectEqual(@as(u32, 1), rig.session.deps.accounts.len);
}

test "the account form opens empty, validates, and saves through the port" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;
    try testing.expectEqual(core.setup.Step.address, form.setup.step);

    // Typing goes into the form.
    rig.fake_system.push_input("x");
    _ = rig.session.step();
    try testing.expectEqualStrings("x", form.setup.address.slice());

    // Tab moves between fields on the same screen.
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.imap_host, form.field);
    _ = rig.session.settings_key(form, .back_tab);
    try testing.expectEqual(Session.Field.address, form.field);

    // An invalid address is refused instead of saved.
    form.setup.address.set("not-an-address");
    _ = rig.session.settings_key(form, .{ .ctrl = 's' });
    try testing.expect(!form.setup.problem.is_empty());
    try testing.expectEqual(@as(u32, 0), port.saved);

    // A valid one, then Ctrl+S saves.
    form.setup.address.set("me@example.com");
    _ = rig.session.settings_key(form, .enter);
    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("me");
    form.setup.password.append_codepoint('s');
    rig.session.save_settings(form);

    try testing.expectEqual(@as(u32, 1), port.saved);
    try testing.expectEqualStrings("me", port.last_label[0..port.last_label_len]);
    try testing.expect(port.last_replaces == null);
    try testing.expect(rig.session.settings == null);
    // Memory.connect reports no Mail, so the account is saved but not attached.
    try testing.expect(std.mem.indexOf(u8, rig.session.state.status.slice(), "did not connect") != null);
}

test "the form shows the servers the source reported" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "work",
        .mail = rig.fake_mail.mail(),
        .imap_host = "imap.example.com",
        .imap_port = 993,
        .username = "alvaro",
        .smtp_host = "smtp.example.com",
        .smtp_port = 587,
        .smtp = true,
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 0,
    });
    defer rig.deinit();
    rig.session.boot();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = core.id.AccountId.from_int(1) } }});
    const form = &rig.session.settings.?;
    // No '?' and no blanks: the values survive into the form.
    try testing.expectEqualStrings("imap.example.com", form.setup.imap_host.slice());
    try testing.expectEqualStrings("smtp.example.com", form.setup.smtp_host.slice());
    try testing.expectEqualStrings("alvaro", form.setup.username.slice());
    try testing.expectEqualStrings("587", form.setup.smtp_port.slice());
    try testing.expectEqualStrings("993", form.setup.imap_port.slice());
}

test "a save failure says what failed, not 'fix the reason above'" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // A port that refuses without a reason: the form still names the stage.
    var port: core.accounts_port.Memory = .{ .fail = true };
    rig.session.deps.accounts_file = port.accounts();
    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;
    form.setup.address.set("new@example.com");
    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    try core.secret.Secret.init("pw", &form.setup.password);
    rig.session.save_settings(form);

    try testing.expect(rig.session.settings != null);
    const shown = rig.session.settings.?.setup.problem.slice();
    try testing.expect(shown.len > 0);
    try testing.expect(std.mem.indexOf(u8, shown, "Could not write") != null);
}

test "the form reads sign in, then password, then the fold" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;

    // Walking down: hosts, Sign in, Password, Advanced, and then nothing rare.
    form.field = .smtp_port;
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.sign_in, form.field);
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.password, form.field);
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.advanced, form.field);
    _ = rig.session.settings_key(form, .tab);
    // Username and the client id sit below the fold: folded, we wrap around.
    try testing.expectEqual(Session.Field.address, form.field);

    // Opened, they appear after it, never above.
    form.field = .advanced;
    _ = rig.session.settings_key(form, .enter);
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.username, form.field);
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.client_id, form.field);
}

test "with OAuth the password row is skipped" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;

    // Sign in sits right before Password: Tab walks from one to the other.
    form.field = .sign_in;
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.password, form.field);

    // With OAuth there is no password to type, so that row disappears.
    form.field = .sign_in;
    _ = rig.session.settings_key(form, .{ .char = ' ' });
    try testing.expect(form.setup.oauth);
    _ = rig.session.settings_key(form, .tab);
    try testing.expectEqual(Session.Field.advanced, form.field);

    // ...and back up lands on Sign in, not on the hidden row.
    _ = rig.session.settings_key(form, .back_tab);
    try testing.expectEqual(Session.Field.sign_in, form.field);
}

test "a new OAuth account saves without a password and signs in" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var port: core.accounts_port.Memory = .{ .connect_mail = rig.fake_mail.mail() };
    rig.session.deps.accounts_file = port.accounts();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;
    form.setup.address.set("new@example.com");
    form.setup.imap_host.set("outlook.office365.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("new@example.com");
    form.setup.set_oauth(true);

    // The account saves without a client id (it is optional); the sign-in is
    // what needs one, and the session says so.
    rig.session.save_settings(form);
    try testing.expectEqual(@as(u32, 1), port.saved);
    try testing.expectEqual(core.id.AccountId.unknown, port.oauth);
    try testing.expect(std.mem.indexOf(u8, rig.session.state.status.slice(), "Client ID") != null);

    // With one, it signs in and attaches.
    form.setup.oauth_client_id.set("client-123");
    rig.session.state.accounts.items[0].oauth_client.set("client-123");
    rig.session.oauth_account(core.id.AccountId.from_int(1));
    try testing.expectEqual(core.id.AccountId.from_int(1), port.oauth);
    // Signed in and attached: its mail is fetched from now on.
    try testing.expectEqual(@as(u8, 2), rig.session.source_count);
}

test "a new account is connected and listed without a restart" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var port: core.accounts_port.Memory = .{ .connect_mail = rig.fake_mail.mail() };
    rig.session.deps.accounts_file = port.accounts();
    const before = rig.session.source_count;

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;
    form.setup.address.set("new@example.com");
    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("new");
    form.setup.password.append_codepoint('s');
    rig.session.save_settings(form);

    // It is in the list, and its mail is on its way.
    try testing.expectEqual(before + 1, rig.session.source_count);
    try testing.expect(rig.session.state.accounts.len > 0);
    try testing.expect(std.mem.indexOf(u8, rig.session.state.status.slice(), "added") != null);
    rig.session.settle_refresh_for_test();
}

test "a refused save keeps the form and its contents" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;
    form.setup.address.set("me@example.com");
    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("me");
    form.setup.password.append_codepoint('s');
    form.field = .username;

    // No port (the demo): the form must not close nor forget anything.
    rig.session.save_settings(form);
    try testing.expect(rig.session.settings != null);
    try testing.expectEqual(Session.Field.username, rig.session.settings.?.field);
    try testing.expectEqualStrings("me", rig.session.settings.?.setup.username.slice());
    try testing.expectEqualStrings("me@example.com", rig.session.settings.?.setup.address.slice());
    try testing.expect(rig.session.settings.?.setup.problem.len > 0);

    // Fixing it and saving works, and only then does the form close.
    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();
    rig.session.save_settings(&rig.session.settings.?);
    try testing.expect(rig.session.settings == null);
    try testing.expectEqual(@as(u32, 1), port.saved);
}

test "editing prefills the form and replaces the account" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();
    rig.session.state.accounts.items[0].imap_host.set("imap.example.com");
    rig.session.state.accounts.items[0].imap_port = 993;
    rig.session.state.accounts.items[0].username.set("me");
    rig.session.state.accounts.items[0].smtp_host.set("smtp.example.com");
    rig.session.state.accounts.items[0].smtp_port = 465;
    rig.session.state.accounts.items[0].smtp = true;

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = core.id.AccountId.from_int(1) } }});
    const form = &rig.session.settings.?;
    try testing.expectEqualStrings("me@amail.local", form.setup.address.slice());
    try testing.expectEqualStrings("imap.example.com", form.setup.imap_host.slice());
    try testing.expectEqualStrings("993", form.setup.imap_port.slice());
    try testing.expectEqualStrings("me", form.setup.username.slice());
    try testing.expectEqualStrings("smtp.example.com", form.setup.smtp_host.slice());
    try testing.expectEqualStrings("465", form.setup.smtp_port.slice());
    try testing.expect(form.setup.send_enabled);
    try testing.expectEqual(core.id.AccountId.from_int(1), form.editing.?);

    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("me");
    form.setup.password.append_codepoint('s');
    rig.session.save_settings(form);

    try testing.expectEqual(@as(u32, 1), port.saved);
    try testing.expectEqual(core.id.AccountId.from_int(1), port.last_replaces.?);
    try testing.expect(rig.session.settings == null);
    try testing.expect(std.mem.indexOf(u8, rig.session.state.status.slice(), "saved") != null);
}

test "the rename prompt is painted while it is open" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.open_rename(core.id.AccountId.from_int(1));
    try testing.expect(rig.session.renaming != null);
    // Render straight through: the prompt row and its caret.
    rig.session.render();
    try testing.expect(rig.fake_system.output_len > 0);
    try testing.expect(std.mem.indexOf(u8, rig.fake_system.output_text(), "Account name") != null);
}

test "renaming an account touches only its label" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();

    rig.session.run_effects_for_test(&.{.{ .rename_account = .{ .account = core.id.AccountId.from_int(1) } }});
    try testing.expect(rig.session.renaming != null);
    try testing.expectEqualStrings("account", rig.session.renaming.?.text.slice());

    // Typing replaces nothing: the old name is the starting point.
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .ctrl = 'u' });
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .char = 'w' });
    _ = rig.session.rename_key(&rig.session.renaming.?, .backspace);
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .char = 'w' });
    _ = rig.session.step();
    try testing.expectEqualStrings("w", rig.session.renaming.?.text.slice());

    _ = rig.session.rename_key(&rig.session.renaming.?, .enter);
    try testing.expectEqual(@as(u32, 1), port.saved);
    try testing.expectEqualStrings("w", port.last_label[0..port.last_label_len]);
    try testing.expectEqual(core.id.AccountId.from_int(1), port.renamed);
    try testing.expect(rig.session.renaming == null);
    try testing.expectEqualStrings("w", rig.session.state.accounts.items[0].label.slice());

    // An empty name is refused, and so is a failing port.
    rig.session.run_effects_for_test(&.{.{ .rename_account = .{ .account = core.id.AccountId.from_int(1) } }});
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .ctrl = 'u' });
    _ = rig.session.rename_key(&rig.session.renaming.?, .enter);
    try testing.expectEqualStrings("A name cannot be empty", rig.session.state.status.slice());

    port.fail = true;
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .char = 'x' });
    _ = rig.session.rename_key(&rig.session.renaming.?, .enter);
    try testing.expectEqualStrings("Could not rename the account", rig.session.state.status.slice());

    // Other keys are ignored, and an account that is not in the list is a no-op.
    rig.session.open_rename(core.id.AccountId.from_int(1));
    rig.session.needs_render = true;
    _ = rig.session.step(); // paints the prompt row
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .char = 0x1f600 });
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .ctrl = 'c' });
    try testing.expect(rig.session.state.quit);
    rig.session.state.quit = false;
    rig.session.open_rename(core.id.AccountId.from_int(9));
    try testing.expect(rig.session.renaming != null);

    // Escape cancels; without a port it refuses.
    rig.session.open_rename(core.id.AccountId.from_int(1));
    _ = rig.session.rename_key(&rig.session.renaming.?, .escape);
    try testing.expect(rig.session.renaming == null);
    rig.session.deps.accounts_file = null;
    rig.session.open_rename(core.id.AccountId.from_int(1));
    _ = rig.session.rename_key(&rig.session.renaming.?, .{ .ctrl = 'x' });
    _ = rig.session.rename_key(&rig.session.renaming.?, .enter);
    try testing.expectEqualStrings("Accounts cannot be changed here", rig.session.state.status.slice());
}

test "the form's keys edit, submit, back out, and quit" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    var form = &rig.session.settings.?;

    rig.session.render(); // the form row
    _ = rig.session.settings_key(form, .{ .char = 'a' });
    _ = rig.session.settings_key(form, .backspace);
    try testing.expect(form.setup.address.is_empty());

    _ = rig.session.settings_key(form, .{ .ctrl = 'x' });
    _ = rig.session.settings_key(form, .{ .mouse = .{ .x = 0, .y = 0, .kind = .press, .button = .left } });
    try testing.expect(!rig.session.state.quit);

    // Ctrl+Q quits from the form, like everywhere else.
    _ = rig.session.settings_key(&rig.session.settings.?, .{ .ctrl = 'q' });
    try testing.expect(rig.session.state.quit);

    rig.session.state.quit = false;
    rig.session.close_settings();
    try testing.expect(rig.session.settings == null);
}

test "closing the form twice, and after a failed save, is safe" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // No port at all: the save path closes the form and reports it.
    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;
    form.setup.address.set("me@example.com");
    // Escape on the address step closes it too.
    _ = rig.session.settings_key(form, .escape);
    try testing.expect(rig.session.settings == null);

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    rig.session.save_settings(&rig.session.settings.?);
    // The form stays open with the reason inside it, so nothing typed is lost.
    try testing.expect(rig.session.settings != null);
    try testing.expectEqualStrings(
        "Accounts cannot be changed here",
        rig.session.settings.?.setup.problem.slice(),
    );
}

test "Enter moves between fields and saves on the last one" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const form = &rig.session.settings.?;

    // Enter is "next field", not "save", until the last row.
    _ = rig.session.settings_key(form, .enter);
    try testing.expectEqual(Session.Field.imap_host, form.field);
    try testing.expectEqual(@as(u32, 0), port.saved);

    form.setup.address.set("me@example.com");
    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("me");
    form.setup.password.append_codepoint('s');

    // On Password, Enter saves the form.
    form.field = .password;
    _ = rig.session.settings_key(form, .enter);
    try testing.expectEqual(@as(u32, 1), port.saved);
    try testing.expect(rig.session.settings == null);
}

test "Ctrl+U clears the current field, and Esc cancels the form" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    var form = &rig.session.settings.?;
    _ = rig.session.settings_key(form, .{ .char = 'm' });
    _ = rig.session.settings_key(form, .{ .char = 'e' });
    _ = rig.session.settings_key(form, .{ .ctrl = 'u' });
    try testing.expect(form.setup.address.is_empty());

    // The last field saves on Enter; a fresh form is closed by Esc.
    form.setup.address.set("me@example.com");
    form.setup.imap_host.set("imap.example.com");
    form.setup.imap_port.set("993");
    form.setup.username.set("me");
    form.setup.password.append_codepoint('s');
    form.field = .password;
    _ = rig.session.settings_key(form, .enter);
    try testing.expectEqual(@as(u32, 1), port.saved);

    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    _ = rig.session.settings_key(&rig.session.settings.?, .escape);
    try testing.expect(rig.session.settings == null);
}

test "removing an account rewrites the config and drops its mail" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "home",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 0,
        .accounts_file = null,
    });
    defer rig.deinit();
    rig.session.boot();
    rig.session.render();

    // No port: refuse and say so.
    rig.session.run_effects_for_test(&.{.{ .remove_account = .{ .account = core.id.AccountId.from_int(1) } }});
    try testing.expectEqualStrings("Accounts cannot be changed here", rig.session.state.status.slice());

    var port: core.accounts_port.Memory = .{};
    rig.session.deps.accounts_file = port.accounts();
    rig.session.state.account_filter = core.id.AccountId.from_int(1);
    const before = rig.session.store.len;
    rig.session.run_effects_for_test(&.{.{ .remove_account = .{ .account = core.id.AccountId.from_int(1) } }});

    try testing.expectEqual(@as(u32, 1), port.removed);
    try testing.expectEqual(@as(u32, 0), rig.session.store.len);
    try testing.expectEqual(@as(u8, 0), rig.session.state.accounts.len);
    try testing.expect(rig.session.state.account_filter == null);
    try testing.expect(before > 0);
    try testing.expect(std.mem.endsWith(u8, rig.session.state.status.slice(), "removed · restart to apply"));

    // A failing port leaves everything alone. Adding is deferred, so it runs
    // on the next step.
    port.fail = true;
    rig.session.run_effects_for_test(&.{.{ .edit_account = .{ .account = null } }});
    const failing = &rig.session.settings.?;
    failing.setup.address.set("me@example.com");
    failing.setup.imap_host.set("imap.example.com");
    failing.setup.imap_port.set("993");
    failing.setup.username.set("me");
    failing.setup.password.append_codepoint('s');
    rig.session.save_settings(failing);
    try testing.expect(rig.session.settings != null);
    // The reason now names the stage instead of saying "fix the reason above".
    try testing.expect(std.mem.indexOf(u8, rig.session.settings.?.setup.problem.slice(), "Could not write") != null);
    rig.session.close_settings();
    rig.session.run_effects_for_test(&.{.{ .remove_account = .{ .account = core.id.AccountId.from_int(2) } }});
    try testing.expectEqualStrings("Could not rewrite the config", rig.session.state.status.slice());
}

test "delete and empty report server errors and unknown accounts" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.fake_mail.fail_flags = true;

    rig.session.run_effects_for_test(&.{.{ .delete_message = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqualStrings("Could not delete on the server", rig.session.state.status.slice());

    rig.fake_mail.fail_flags = false;
    rig.session.run_effects_for_test(&.{.{ .empty_mailbox = .{
        .account = core.id.AccountId.from_int(9),
        .mailbox = .trash,
    } }});
    try testing.expectEqualStrings("That account is not connected", rig.session.state.status.slice());

    rig.session.run_effects_for_test(&.{.{ .delete_message = .{
        .account = core.id.AccountId.from_int(9),
        .mailbox = .trash,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqualStrings("That account is not connected", rig.session.state.status.slice());

    rig.fake_mail.fail_flags = true;
    rig.session.run_effects_for_test(&.{.{ .empty_mailbox = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .trash,
    } }});
    try testing.expectEqualStrings("Could not empty Trash on the server", rig.session.state.status.slice());
    rig.fake_mail.fail_flags = false;

    rig.session.source_count = 0; // no accounts connected
    rig.session.run_effects_for_test(&.{.{ .empty_mailbox = .{
        .account = null,
        .mailbox = .trash,
    } }});
    try testing.expectEqualStrings("That account is not connected", rig.session.state.status.slice());
}

test "a notice is shown as an alert from the first frame" {
    var rig: Rig = .{};
    try rig.seed();
    try rig.session.init(testing.allocator, .{
        .accounts = &.{},
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 0,
        .notice = "The config file is invalid",
    });
    defer rig.deinit();

    try testing.expectEqualStrings("The config file is invalid", rig.session.state.status.slice());
    try testing.expect(rig.session.state.status_alert);
}

test "an effect paints the spinner, even when it is instant" {
    var rig: Rig = .{};
    try rig.seed();
    rig.sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = rig.fake_mail.mail(),
    };
    try rig.session.init(testing.allocator, .{
        .accounts = &rig.sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 5,
    });
    defer rig.deinit();
    rig.session.boot();
    rig.session.settle_refresh_for_test();
    rig.session.render();
    rig.fake_system.output_len = 0;

    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});

    // A spinner frame was written before the work, and the flag is cleared.
    try testing.expect(rig.fake_system.output_len > 0);
    try testing.expect(rig.session.body_len > 0);
    try testing.expect(!rig.session.state.loading);
}

test "a body asked for during a refresh is delivered when it finishes" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Start the refresh but do not wait for it.
    rig.fake_system.push_input("\x12");
    _ = rig.session.step();
    try testing.expect(rig.session.refreshing);

    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});

    // Deferred, not refused and not blocking.
    try testing.expect(rig.session.refreshing);
    try testing.expect(rig.session.pending_body != null);
    try testing.expect(rig.session.body_len == 0);

    rig.session.settle_refresh_for_test();
    try testing.expect(!rig.session.refreshing);
    try testing.expect(rig.session.pending_body == null);
    try testing.expect(rig.session.body_len > 0);
}

test "init frees what it took when a buffer cannot be allocated" {
    var fakery: Fake = .{ .size_value = .{ .columns = 100, .rows = 24 } };
    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var session: Session = undefined;
        const result = session.init(failing.allocator(), .{
            .accounts = &.{},
            .system = fakery.system(),
            .theme = theme_mod.Theme.dark(),
            .now = fixed_now,
        });
        if (result) |_| {
            session.deinit();
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "deinit waits for a running refresh" {
    var rig: Rig = .{};
    try rig.start();
    rig.fake_system.push_input("\x12");
    _ = rig.session.step();
    try testing.expect(rig.session.refreshing);
    // No settle: deinit must join the worker itself.
    rig.deinit();
}

test "a failed refresh becomes an alert and keeps the cache" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.fake_mail.fail_fetch = true;

    rig.send("\x12");
    try testing.expectEqualStrings("Could not refresh Inbox", rig.session.state.status.slice());
    try testing.expectEqual(@as(u32, 2), rig.session.store.len);
}

test "a successful refresh refreshes the mailbox" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // The server gains a message; refresh picks it up.
    const extra = Message{ .id = MessageId.from_int(9), .account = core.id.AccountId.from_int(1), .mailbox = .inbox, .timestamp_unix = 1_699_999_950 };
    try rig.fake_mail.inner.seed(&extra);

    rig.send("\x12");
    try testing.expectEqual(@as(u32, 3), rig.session.store.len);
    try testing.expectEqual(@as(u32, 3), rig.session.state.visible_len);
}

test "switching mailbox loads it from the server" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    const sent = Message{ .id = MessageId.from_int(3), .account = core.id.AccountId.from_int(1), .mailbox = .sent, .timestamp_unix = 1_699_999_700 };
    try rig.fake_mail.inner.seed(&sent);

    rig.send("\t");
    try testing.expectEqual(Mailbox.sent, rig.session.state.mailbox);
    try testing.expectEqual(@as(u32, 1), rig.session.state.visible_len);
}

test "a resize re-renders at the new size" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    const before = rig.fake_system.output_len;

    rig.fake_system.size_value = .{ .columns = 80, .rows = 20 };
    _ = rig.session.step();
    try testing.expect(rig.fake_system.output_len > before);
    try testing.expectEqual(@as(u16, 80), rig.session.screen.columns);
}

test "a size read failure keeps the last known size" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_system.size_failure = error.NotATerminal;
    _ = rig.session.step();
    try testing.expectEqual(@as(u16, 100), rig.session.size.columns);
}

test "clicking a row selects it; clicking it again opens it" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Row y=3 is the second message; the body starts at y=2.
    rig.send("\x1b[<0;40;4M");
    try testing.expectEqual(@as(u32, 1), rig.session.state.cursor);
    try testing.expectEqual(core.state.View.list, rig.session.state.view);

    rig.send("\x1b[<0;40;4M");
    try testing.expectEqual(core.state.View.reader, rig.session.state.view);
}

test "releasing the mouse never activates anything" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.send("\x1b[<0;40;3m");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);
    try testing.expectEqual(core.state.View.list, rig.session.state.view);
}

test "clicking the selected row opens the message" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);

    rig.send("\x1b[<0;40;3M");
    try testing.expectEqual(core.state.View.reader, rig.session.state.view);
}

test "clicking a mailbox tab switches mailbox" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Sent tab starts at x = 8 + 11 = 19.
    rig.send("\x1b[<0;20;1M");
    try testing.expectEqual(Mailbox.sent, rig.session.state.mailbox);
}

test "clicking the header outside a tab does nothing" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.send("\x1b[<0;2;1M");
    try testing.expectEqual(Mailbox.inbox, rig.session.state.mailbox);
}

test "clicking past the last row does nothing" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.send("\x1b[<0;40;20M");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);
}

test "the wheel scrolls the list and the reader" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();

    // A short terminal makes the body taller than the viewport, so scrolling
    // has somewhere to go.
    rig.fake_system.size_value = .{ .columns = 100, .rows = 12 };
    _ = rig.session.step();

    rig.send("\x1b[<65;10;10M");
    try testing.expectEqual(@as(u32, 1), rig.session.state.cursor);
    rig.send("\x1b[<64;10;10M");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);

    rig.send("\r");
    rig.send("\x1b[<65;10;10M");
    try testing.expectEqual(@as(u32, 1), rig.session.state.reader_scroll);
}

test "mouse buttons other than left are ignored" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.send("\x1b[<2;40;3M");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);
}

test "a click in the footer or in the reader is ignored" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Footer row: not a message row.
    rig.send("\x1b[<0;40;24M");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);

    rig.send("\r");
    rig.send("\x1b[<0;40;5M");
    try testing.expectEqual(core.state.View.reader, rig.session.state.view);
}

test "a mouse event on a too-small terminal is ignored" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_system.size_value = .{ .columns = 20, .rows = 5 };
    _ = rig.session.step();
    rig.send("\x1b[<0;3;3M");
    try testing.expectEqual(@as(u32, 0), rig.session.state.cursor);
}

test "a long paste is decoded in bounded chunks" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    const paste: [200]u8 = @splat('j');
    rig.fake_system.push_input(&paste);
    _ = rig.session.step();
    // Two messages: the cursor saturates at the last row instead of overflowing.
    try testing.expectEqual(@as(u32, 1), rig.session.state.cursor);
}

test "search mode filters from the keyboard" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.send("/");
    try testing.expectEqual(core.state.Mode.search, rig.session.state.mode);
    rig.send("1");
    try testing.expectEqualStrings("1", rig.session.state.query.slice());
    try testing.expectEqual(@as(u32, 1), rig.session.state.visible_len);
}

test "fixed_now is deterministic" {
    try testing.expectEqual(@as(i64, 1_700_000_000), fixed_now());
    try testing.expectEqual(fixed_now(), fixed_now());
}

test "init reports allocation failure without leaking" {
    var fake_system: Fake = .{};
    var fake_mail: FakeMail = .{};
    const sources = [_]MailSource{.{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = fake_mail.mail(),
    }};
    const deps: Deps = .{ .accounts = &sources, .system = fake_system.system() };

    var session: Session = undefined;
    try testing.expectError(error.OutOfMemory, session.init(testing.failing_allocator, deps));
}

test "init frees the store when the scratch buffer cannot be allocated" {
    var fake_system: Fake = .{};
    var fake_mail: FakeMail = .{};
    const sources = [_]MailSource{.{
        .id = core.id.AccountId.from_int(1),
        .label = "account",
        .mail = fake_mail.mail(),
    }};
    const deps: Deps = .{ .accounts = &sources, .system = fake_system.system() };

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var session: Session = undefined;
    try testing.expectError(error.OutOfMemory, session.init(failing.allocator(), deps));
}

test "loop runs until quit" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    rig.fake_system.push_input("\x11");
    rig.session.loop();
    try testing.expect(rig.session.state.quit);
}

const LinkSink = struct {
    opened: u8 = 0,
    last: [128]u8 = undefined,
    last_len: usize = 0,

    fn open(context: *anyopaque, url: []const u8) void {
        const self: *LinkSink = @ptrCast(@alignCast(context));
        self.opened += 1;
        self.last_len = @min(url.len, self.last.len);
        @memcpy(self.last[0..self.last_len], url[0..self.last_len]);
    }
};

test "clicking a link in the body opens it" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    const body = "See https://example.com/a for details";
    // A plain message with no HTML: the text view is what the reader shows.
    rig.session.set_raw(body);
    rig.session.state.view = .reader;
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();
    try testing.expect(rig.session.wrapped.len > 0);

    const lay = layout_mod.Layout.compute(100, 24, 0);
    // Column 4 is the 'h' of "https": inside the link.
    _ = rig.session.handle_mouse(.{ .x = 5, .y = lay.reader_body_y, .kind = .press, .button = .left, .ctrl = true });
    _ = rig.session.handle_mouse(.{ .x = 5, .y = lay.reader_body_y, .kind = .release, .button = .left, .ctrl = true });
    try testing.expectEqual(@as(u8, 1), sink.opened);
    try testing.expectEqualStrings("https://example.com/a", sink.last[0..sink.last_len]);

    // A click on the words around it opens nothing.
    // A click on the words around it opens nothing, with or without ctrl.
    _ = rig.session.handle_mouse(.{ .x = 2, .y = lay.reader_body_y, .kind = .press, .button = .left });
    _ = rig.session.handle_mouse(.{ .x = 2, .y = lay.reader_body_y, .kind = .release, .button = .left });
    try testing.expectEqual(@as(u8, 1), sink.opened);
}

test "mail with an HTML part opens as HTML, and H goes back to the text" {
    const raw =
        \\Content-Type: multipart/alternative; boundary="b"
        \\
        \\--b
        \\Content-Type: text/plain
        \\
        \\plain version
        \\--b
        \\Content-Type: text/html
        \\
        \\<p>Read <a href="https://example.com/a">the docs</a></p>
        \\--b--
    ;

    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw(raw);

    // What a mail client shows: the HTML part, laid out.
    try testing.expect(rig.session.html_view);
    try testing.expectEqualStrings(
        "Read the docs",
        rig.session.reader_text(),
    );

    // H shows the text/plain alternative.
    rig.send("H");
    try testing.expect(!rig.session.html_view);
    try testing.expectEqualStrings("plain version", rig.session.reader_text());
    try testing.expectEqualStrings("Plain text", rig.session.state.status.slice());

    // And back.
    rig.send("H");
    try testing.expect(rig.session.html_view);
}

test "mail with no HTML part stays on its text" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw("Content-Type: text/plain\n\njust words");

    try testing.expect(!rig.session.html_view);
    try testing.expectEqualStrings("just words", rig.session.reader_text());
}

test "H on a text-only message says there is no HTML" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw("Content-Type: text/plain\n\njust words");

    rig.send("H");
    try testing.expectEqualStrings("This message has no HTML version", rig.session.state.status.slice());
    try testing.expect(!rig.session.html_view);
}

test "a message with an HTML part renders both views from one fetch" {
    const raw =
        \\Content-Type: multipart/alternative; boundary="b"
        \\
        \\--b
        \\Content-Type: text/plain
        \\
        \\plain version
        \\--b
        \\Content-Type: text/html
        \\
        \\<p>Read <a href="https://example.com/a">the docs</a></p>
        \\--b--
    ;

    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();
    rig.session.state.view = .reader;
    rig.session.set_raw(raw);

    // Both views come from the same fetch, and HTML is the one shown first.
    try testing.expectEqualStrings(
        "Read the docs",
        rig.session.reader_text(),
    );
    rig.send("H");
    try testing.expectEqualStrings("plain version", rig.session.reader_text());
    try testing.expectEqualStrings(
        "Read the docs",
        rig.session.html_text[0..rig.session.html_len],
    );
}

test "a link split by the wrap is still one link, and clicks anywhere on it" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    const body = "see https://example.com/a/really/long/path here";
    rig.session.set_raw(body);
    rig.session.state.view = .reader;
    rig.session.state.opened = MessageId.from_int(1);
    // A narrow width is what breaks the address across lines.
    wrap.wrap(rig.session.reader_text(), 18, &rig.session.wrapped);
    try testing.expect(rig.session.wrapped.len >= 3);

    const lay = layout_mod.Layout.compute(100, 24, 0);
    // Find the line that holds the middle of the address (no scheme in sight):
    // that is the half the old per-line scan could not see.
    var continuation: ?u16 = null;
    for (0..rig.session.wrapped.len) |row| {
        const line = rig.session.wrapped.at(@intCast(row), rig.session.reader_text());
        if (std.mem.indexOf(u8, line, "/a/") != null) continuation = @intCast(row);
    }
    try testing.expect(continuation != null);
    _ = rig.session.handle_mouse(.{
        .x = 2,
        .y = lay.reader_body_y + continuation.?,
        .kind = .press,
        .button = .left,
        .ctrl = true,
    });
    _ = rig.session.handle_mouse(.{
        .x = 2,
        .y = lay.reader_body_y + continuation.?,
        .kind = .release,
        .button = .left,
        .ctrl = true,
    });
    try testing.expectEqual(@as(u8, 1), sink.opened);
    try testing.expectEqualStrings("https://example.com/a/really/long/path", sink.last[0..sink.last_len]);
}

test "a drag in the reader copies the text to the clipboard" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    const body = "alpha beta\ngamma delta";
    rig.session.set_raw(body);
    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();

    const lay = layout_mod.Layout.compute(100, 24, 0);
    rig.fake_system.output_len = 0;

    // Press at the start of the first line, drag over the first word, release.
    _ = rig.session.handle_mouse(.{ .x = 1, .y = lay.reader_body_y, .kind = .press, .button = .left });
    _ = rig.session.handle_mouse(.{ .x = 5, .y = lay.reader_body_y, .kind = .motion, .button = .left });
    _ = rig.session.handle_mouse(.{ .x = 5, .y = lay.reader_body_y, .kind = .release, .button = .left });

    const written = rig.fake_system.output_text();
    try testing.expect(std.mem.indexOf(u8, written, "\x1b]52;c;") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b]52;p;") != null);
    // "alpha" is "YWxwaGE=".
    try testing.expect(std.mem.indexOf(u8, written, "YWxwaGE=") != null);
    try testing.expect(std.mem.indexOf(u8, rig.session.state.status.slice(), "Copied 5 characters") != null);
    try testing.expect(rig.session.selection == null);
}

test "a click on a link opens it exactly once" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    const body = "see https://example.com/a";
    rig.session.set_raw(body);
    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();

    const lay = layout_mod.Layout.compute(100, 24, 0);
    const y = lay.reader_body_y;
    // Column 6 is inside the address: ctrl, press and release on one cell.
    _ = rig.session.handle_mouse(.{ .x = 7, .y = y, .kind = .press, .button = .left, .ctrl = true });
    _ = rig.session.handle_mouse(.{ .x = 7, .y = y, .kind = .release, .button = .left, .ctrl = true });
    try testing.expectEqual(@as(u8, 1), sink.opened);
    try testing.expectEqualStrings("Opened https://example.com/a", rig.session.state.status.slice());

    // The same click without ctrl opens nothing: ctrl is the key to the browser.
    sink.opened = 0;
    _ = rig.session.handle_mouse(.{ .x = 7, .y = y, .kind = .press, .button = .left });
    _ = rig.session.handle_mouse(.{ .x = 7, .y = y, .kind = .release, .button = .left });
    try testing.expectEqual(@as(u8, 0), sink.opened);
}

test "the account picked last time is the one the reader opens on" {
    var rig: Rig = .{};
    var scope: core.scope_port.Memory = .{};
    // Two accounts, so the scope has something to choose between.
    try scope.scope().save("home");

    const second_source = MailSource{
        .id = core.id.AccountId.from_int(2),
        .label = "home",
        .from = core.address.Address.init("me@home.example") catch .{},
        .mail = rig.fake_mail.mail(),
    };
    var sources = [_]MailSource{ undefined, undefined };
    try rig.seed();
    sources[0] = .{
        .id = core.id.AccountId.from_int(1),
        .label = "work",
        .from = core.address.Address.init("me@work.example") catch .{},
        .mail = rig.fake_mail.mail(),
    };
    sources[1] = second_source;
    try rig.session.init(testing.allocator, .{
        .accounts = &sources,
        .system = rig.fake_system.system(),
        .theme = theme_mod.Theme.dark(),
        .now = fixed_now,
        .loading_ms = 0,
        .scope = scope.scope(),
    });
    defer rig.session.deinit();

    // Opened on "home", not on every account.
    try testing.expectEqual(core.id.AccountId.from_int(2), rig.session.state.account_filter.?);
}

test "picking all accounts is remembered too" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var scope: core.scope_port.Memory = .{};
    rig.session.deps.scope = scope.scope();

    // Choose the account (row 1), then all of them (row 0).
    rig.send("A");
    rig.send("j");
    _ = rig.session.apply(.accounts_select);
    try testing.expectEqualStrings("account", scope.remembered.slice());

    rig.send("A");
    _ = rig.session.apply(.accounts_select);
    try testing.expect(scope.remembered.is_empty());
    try testing.expectEqual(@as(u32, 2), scope.save_calls);
}

test "a message whose sender wrapped the address shows one whole link" {
    const raw = "Content-Type: text/plain; charset=utf-8\n" ++
        "\n" ++
        "unsubscribe here:\n" ++
        "https://www1.ema.rsys.net/u/nrd.php?p=0vDm90jZvy_1780192_7260070_1_893&ems\n" ++
        "l=1055472&d=MTM5M2E1MzU0OTM3MDc1M2FhNDY2YWNlYjNj&esuh=11\n";

    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw(raw);
    rig.session.needs_render = true;
    _ = rig.session.step();

    // The address is one link, and the reader shows it unbroken.
    try testing.expectEqual(@as(usize, 1), rig.session.reader_links().len);
    try testing.expect(std.mem.indexOf(u8, rig.session.reader_text(), "&emsl=1055472") != null);

    // A click on the second line of it opens the whole address.
    const lay = layout_mod.Layout.compute(100, 24, 0);
    _ = rig.session.handle_mouse(.{
        .x = 6,
        .y = lay.reader_body_y + 1,
        .kind = .press,
        .button = .left,
        .ctrl = true,
    });
    _ = rig.session.handle_mouse(.{
        .x = 6,
        .y = lay.reader_body_y + 1,
        .kind = .release,
        .button = .left,
        .ctrl = true,
    });
    try testing.expectEqual(@as(u8, 1), sink.opened);
    try testing.expect(std.mem.indexOf(u8, sink.last[0..sink.last_len], "&emsl=1055472") != null);
}

test "an account out of scope is never connected" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Two sources, the second one out of scope.
    var second = FakeMail{};
    _ = try rig.seed();
    rig.session.sources[1] = .{
        .id = core.id.AccountId.from_int(2),
        .label = "other",
        .from = core.address.Address.init("me@other.example") catch .{},
        .mail = second.mail(),
    };
    rig.session.source_count = 2;
    rig.session.state.account_filter = core.id.AccountId.from_int(1);

    rig.fake_mail.fetch_calls = 0;
    rig.session.needs_boot = true;
    rig.session.boot();
    _ = rig.session.state.mailbox;
    try testing.expectEqual(@as(u32, 1), rig.fake_mail.fetch_calls);
}

test "an image marker is only painted when it came with the message" {
    try testing.expect(is_local_image("logo@x"));
    try testing.expect(!is_local_image("https://example.com/logo.png"));
    try testing.expect(!is_local_image(""));
}

test "a PNG knows how big it is, and how many cells that is" {
    var png: [33]u8 = @splat(0);
    png[0] = 0x89;
    png[1] = 'P';
    png[2] = 'N';
    png[3] = 'G';
    std.mem.writeInt(u32, png[16..20], 90, .big);
    std.mem.writeInt(u32, png[20..24], 36, .big);

    const size = png_size(&png).?;
    try testing.expectEqual(@as(u32, 90), size.width);
    try testing.expectEqual(@as(u32, 36), size.height);
    const cells = image_cells(size);
    try testing.expectEqual(@as(u16, 10), cells.columns);
    try testing.expectEqual(@as(u16, 2), cells.rows);

    // Not a PNG: refused rather than painted as garbage.
    try testing.expect(png_size("GIF89a") == null);
    const tiny: [4]u8 = @splat(0);
    try testing.expect(png_size(&tiny) == null);
}

test "a tall image is scaled down to the reader, not to the page" {
    var png: [33]u8 = @splat(0);
    png[0] = 0x89;
    png[1] = 'P';
    png[2] = 'N';
    png[3] = 'G';
    std.mem.writeInt(u32, png[16..20], 900, .big);
    std.mem.writeInt(u32, png[20..24], 1800, .big);

    const cells = image_cells(png_size(&png).?);
    try testing.expectEqual(@as(u16, 12), cells.rows);
    try testing.expect(cells.columns > 0 and cells.columns < 100);
}

const ImageSink = struct {
    calls: u8 = 0,
    columns: u16 = 0,
    rows: u16 = 0,
    bytes: usize = 0,
    cleared: u8 = 0,

    fn draw(
        context: *anyopaque,
        png: []const u8,
        id: u32,
        x: u16,
        y: u16,
        columns: u16,
        rows: u16,
    ) bool {
        const self: *ImageSink = @ptrCast(@alignCast(context));
        _ = .{ id, x, y };
        self.calls += 1;
        self.bytes = png.len;
        self.columns = columns;
        self.rows = rows;
        return true;
    }

    fn clear(context: *anyopaque) void {
        const self: *ImageSink = @ptrCast(@alignCast(context));
        self.cleared += 1;
    }
};

test "an image that came with the message is painted where its marker landed" {
    // A 90x36 PNG, one pixel per byte of IHDR plus a body.
    const png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAFoAAAAkCAYAAABlLQxSAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    const raw = "Content-Type: multipart/related; boundary=\"b\"\n" ++
        "\n" ++
        "--b\n" ++
        "Content-Type: text/html\n" ++
        "\n" ++
        "<p>Antes</p><img src=\"cid:logo@x\" alt=\"Logo\">\n" ++
        "--b\n" ++
        "Content-Type: image/png\n" ++
        "Content-Transfer-Encoding: base64\n" ++
        "Content-ID: <logo@x>\n" ++
        "\n" ++ png_base64 ++ "\n" ++
        "--b--\n";

    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: ImageSink = .{};
    rig.session.deps.draw_image = ImageSink.draw;
    rig.session.deps.draw_image_context = &sink;
    rig.session.deps.clear_images = ImageSink.clear;
    rig.session.deps.clear_images_context = &sink;

    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw(raw);

    // The marker is in the laid-out text, so the reader has somewhere to paint.
    try testing.expect(std.mem.indexOf(u8, rig.session.html_text[0..rig.session.html_len], "[IMG:logo@x]") != null);

    rig.session.needs_render = true;
    _ = rig.session.step();

    try testing.expectEqual(@as(u8, 1), sink.calls);
    try testing.expect(sink.bytes > 50);
    try testing.expect(sink.columns > 0 and sink.rows > 0);
    try testing.expect(sink.cleared >= 1);
}

test "an image with an address is not fetched, so it is not painted" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: ImageSink = .{};
    rig.session.deps.draw_image = ImageSink.draw;
    rig.session.deps.draw_image_context = &sink;

    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw("Content-Type: text/html\n\n<p><img src=\"https://example.com/x.png\" alt=\"Foto\"></p>");

    rig.session.needs_render = true;
    _ = rig.session.step();
    try testing.expectEqual(@as(u8, 0), sink.calls);
}

const RemoteSink = struct {
    fetches: u8 = 0,
    png: [128]u8 = undefined,
    png_len: usize = 0,
    calls: u8 = 0,

    fn fetch(context: *anyopaque, url: []const u8, out: []u8) ?[]const u8 {
        const self: *RemoteSink = @ptrCast(@alignCast(context));
        self.fetches += 1;
        _ = url;
        // A 90x36 PNG header is enough for the reader to place it.
        @memset(out[0..33], 0);
        out[0] = 0x89;
        out[1] = 'P';
        out[2] = 'N';
        out[3] = 'G';
        std.mem.writeInt(u32, out[16..20], 90, .big);
        std.mem.writeInt(u32, out[20..24], 36, .big);
        self.png_len = 33;
        @memcpy(self.png[0..33], out[0..33]);
        return out[0..33];
    }

    fn draw(
        context: *anyopaque,
        png: []const u8,
        id: u32,
        x: u16,
        y: u16,
        columns: u16,
        rows: u16,
    ) bool {
        const self: *RemoteSink = @ptrCast(@alignCast(context));
        _ = .{ png, id, x, y, columns, rows };
        self.calls += 1;
        return true;
    }
};

test "a picture with an address is downloaded once and painted" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: RemoteSink = .{};
    rig.session.deps.fetch_image = RemoteSink.fetch;
    rig.session.deps.fetch_image_context = &sink;
    rig.session.deps.draw_image = RemoteSink.draw;
    rig.session.deps.draw_image_context = &sink;

    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw("Content-Type: text/html\n\n<p><img src=\"https://example.com/logo.png\"></p>");

    rig.session.needs_render = true;
    _ = rig.session.step();
    try testing.expectEqual(@as(u8, 1), sink.fetches);
    try testing.expectEqual(@as(u8, 1), sink.calls);

    // The same picture in the next frame is not downloaded again.
    rig.session.needs_render = true;
    _ = rig.session.step();
    try testing.expectEqual(@as(u8, 1), sink.fetches);
}

test "clicking a reference number opens the address it points at" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    rig.session.state.view = .reader;
    rig.session.state.opened_account = core.id.AccountId.from_int(1);
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.set_raw("Content-Type: text/plain\n\nRead [1]the docs\n\nReferences:\n\n[1] https://example.com/a\n");
    rig.session.needs_render = true;
    _ = rig.session.step();

    // Find the "[1]" in the body and click on its digit.
    const text = rig.session.reader_text();
    const row = std.mem.indexOf(u8, text, "[1]").?;
    const lay = layout_mod.Layout.compute(100, 24, 0);
    const line_text = rig.session.wrapped.at(0, text);
    const column = row - (@intFromPtr(line_text.ptr) - @intFromPtr(text.ptr));

    _ = rig.session.handle_mouse(.{
        .x = @intCast(1 + column + 1),
        .y = lay.reader_body_y,
        .kind = .press,
        .button = .left,
        .ctrl = true,
    });
    _ = rig.session.handle_mouse(.{
        .x = @intCast(1 + column + 1),
        .y = lay.reader_body_y,
        .kind = .release,
        .button = .left,
        .ctrl = true,
    });

    try testing.expectEqual(@as(u8, 1), sink.opened);
    try testing.expectEqualStrings("https://example.com/a", sink.last[0..sink.last_len]);
}

test "the same marker in another message gets another picture id" {
    const account = core.id.AccountId.from_int(1);
    const first = image_id(account, MessageId.from_int(10), "r0");
    const second = image_id(account, MessageId.from_int(11), "r0");

    // A terminal keeps one picture per id: two messages cannot share one.
    try testing.expect(first != second);
    try testing.expect(first != 0);
    try testing.expect(image_id(account, MessageId.from_int(10), "r0") == first);
    try testing.expect(image_id(account, MessageId.from_int(10), "r1") != first);
    try testing.expect(image_id(core.id.AccountId.from_int(2), MessageId.from_int(10), "r0") != first);
}

test "a marker with the same name in another message is another picture" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();

    // Two parts, both called "logo", with different bytes.
    const first = "From: a@b\r\nContent-Type: text/plain\r\n\r\nhi";
    rig.session.set_raw(first);
    try testing.expectEqual(@as(u8, 0), rig.session.image_slot_count);

    // The cache remembers what the message carried…
    _ = rig.session.image_png("logo");
    try testing.expectEqual(@as(u8, 1), rig.session.image_slot_count);
    // …and forgets it as soon as another message is opened.
    rig.session.set_raw(first);
    try testing.expectEqual(@as(u8, 0), rig.session.image_slot_count);
}

test "the pointer lights a link up, and the light goes when it leaves" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.set_raw("go to https://example.com/a now");
    rig.session.state.view = .reader;
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();

    const lay = layout_mod.Layout.compute(100, 24, 0);
    // Column 6 sits inside the address.
    // Without ctrl the pointer changes nothing: reading is never disturbed.
    try testing.expect(!rig.session.hover_link(.{ .x = 7, .y = lay.reader_body_y, .kind = .motion, .button = .none }));
    try testing.expect(rig.session.hovered == null);
    try testing.expect(rig.session.hover_link(.{ .x = 7, .y = lay.reader_body_y, .kind = .motion, .button = .none, .ctrl = true }));
    try testing.expect(rig.session.hovered != null);
    // And the popup knows where it goes.
    try testing.expectEqualStrings("https://example.com/a", rig.session.hover_url.slice());

    // Leaving the link, or hovering plain text, puts the light out.
    try testing.expect(rig.session.hover_link(.{ .x = 1, .y = lay.reader_body_y, .kind = .motion, .button = .none, .ctrl = true }));
    try testing.expect(rig.session.hovered == null);
    try testing.expect(rig.session.hover_url.is_empty());

    // Moving between cells of the same link does not repaint.
    _ = rig.session.hover_link(.{ .x = 7, .y = lay.reader_body_y, .kind = .motion, .button = .none, .ctrl = true });
    try testing.expect(!rig.session.hover_link(.{ .x = 9, .y = lay.reader_body_y, .kind = .motion, .button = .none, .ctrl = true }));
}

test "a ctrl click reported by the terminal reaches the link" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    rig.session.set_raw("see https://example.com/a here");
    rig.session.state.view = .reader;
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();

    // The bytes a terminal sends for ctrl+left press: 16 is ctrl, 1-based cells.
    const lay = layout_mod.Layout.compute(100, 24, 0);
    var report: [32]u8 = undefined;
    const bytes = std.fmt.bufPrint(&report, "\x1b[<16;7;{d}M", .{lay.reader_body_y + 1}) catch unreachable;
    rig.session.handle_bytes(bytes);
    try testing.expectEqual(@as(u8, 1), sink.opened);
}

test "in the HTML view, clicking the words of a link opens its address" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    var sink: LinkSink = .{};
    rig.session.deps.open_url = LinkSink.open;
    rig.session.deps.open_url_context = &sink;

    rig.session.set_raw(
        "Content-Type: text/html\r\n\r\n<p>See <a href=\"https://example.com/x\">the notes</a> now</p>",
    );
    rig.session.state.view = .reader;
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();
    try testing.expect(rig.session.html_view);
    try testing.expectEqual(@as(usize, 1), rig.session.html_anchor_count);

    // The click lands on the words, not on the address in parentheses.
    const lay = layout_mod.Layout.compute(100, 24, 0);
    const text = rig.session.reader_text();
    const anchor = rig.session.html_anchors[0];

    // Find the wrapped line the anchor starts on.
    var row: u16 = 0;
    var column: u16 = 0;
    while (row < rig.session.wrapped.len) : (row += 1) {
        const line = rig.session.wrapped.at(row, text);
        const line_start: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(text.ptr));
        if (anchor.span.start < line_start or anchor.span.start >= line_start + line.len) continue;
        column = @intCast(anchor.span.start - line_start);
        break;
    }
    const y = lay.reader_body_y + row;
    _ = rig.session.handle_mouse(.{ .x = column + 2, .y = y, .kind = .press, .button = .left, .ctrl = true });

    try testing.expectEqual(@as(u8, 1), sink.opened);
    try testing.expectEqualStrings("https://example.com/x", sink.last[0..sink.last_len]);

    // Without ctrl the same click on the same words opens nothing.
    sink.opened = 0;
    _ = rig.session.handle_mouse(.{ .x = column + 2, .y = y, .kind = .press, .button = .left });
    _ = rig.session.handle_mouse(.{ .x = column + 2, .y = y, .kind = .release, .button = .left });
    try testing.expectEqual(@as(u8, 0), sink.opened);
}

test "in the HTML view the pointer lights up the words of a link" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.set_raw(
        "Content-Type: text/html\r\n\r\n<p>See <a href=\"https://example.com/x\">the notes</a> now</p>",
    );
    rig.session.state.view = .reader;
    rig.session.state.opened = MessageId.from_int(1);
    rig.session.needs_render = true;
    _ = rig.session.step();

    const lay = layout_mod.Layout.compute(100, 24, 0);
    const text = rig.session.reader_text();
    const anchor = rig.session.html_anchors[0];

    var row: u16 = 0;
    var column: u16 = 0;
    while (row < rig.session.wrapped.len) : (row += 1) {
        const line = rig.session.wrapped.at(row, text);
        const line_start: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(text.ptr));
        if (anchor.span.start < line_start or anchor.span.start >= line_start + line.len) continue;
        column = @intCast(anchor.span.start - line_start);
        break;
    }

    const hover = input.Mouse{ .x = column + 2, .y = lay.reader_body_y + row, .kind = .motion, .button = .none, .ctrl = true };
    try testing.expect(rig.session.hover_link(hover));
    // The lit span is the words of the anchor, not the address in parentheses.
    const lit = rig.session.hovered.?;
    try testing.expectEqual(anchor.span.start, lit.start);
    try testing.expectEqual(anchor.span.end, lit.end);
}

test "a text body with HTML spacing entities is readable" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    rig.session.set_raw("Content-Type: text/plain\r\n\r\n&emsp;&#8203;Hola&nbsp;mundo");
    // "&emsp;" is a space, "&#8203;" is nothing, "&nbsp;" is a space.
    try testing.expectEqualStrings(" Hola mundo", rig.session.reader_text());
}
