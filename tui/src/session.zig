//! The terminal session: read, translate, update, execute effects, render.
//!
//! All policy lives in `core.update`; this file owns the loop and the wiring.
//! It is driven through the `System` port, so the whole loop is unit tested with
//! scripted keystrokes and captured output.

const std = @import("std");
const core = @import("core");

const input = @import("input.zig");
const keymap = @import("keymap.zig");
const layout_mod = @import("layout.zig");
const render_mod = @import("render.zig");
const screen_mod = @import("screen.zig");
const system_mod = @import("system.zig");
const theme_mod = @import("theme.zig");
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
    system: System,
    theme: theme_mod.Theme = theme_mod.Theme.dark(),
    now: Now = fixed_now,
    /// Fallback sender when an account has no address configured.
    from_address: core.address.Address = .{},
};

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
    body_loaded: bool = false,
    wrapped: wrap.Wrapped = .{},

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
    refresh_mailbox: Mailbox = .inbox,

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
        for (deps.accounts) |source| {
            self.state.accounts.add(source.id, source.label, source.from);
        }
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
        self.load_cached(self.state.mailbox);
    }

    /// Fills the store from the on-disk cache and remembers whether the network
    /// is still needed.
    fn load_cached(self: *Session, mailbox: Mailbox) void {
        for (self.deps.accounts, 0..) |source, index| {
            const mask = mask_bit(@intCast(index), @backingInt(mailbox));
            if (self.deps.cache) |cache| {
                const cached = cache.load(source.id, mailbox, self.scratch) catch 0;
                if (cached > 0) {
                    core.sync.replace_mailbox(&self.store, source.id, mailbox, self.scratch[0..cached]);
                    self.loaded_mask |= mask;
                    continue;
                }
            }
            self.needs_boot = true;
        }

        self.state.rebuild(&self.store);
        self.needs_render = true;
    }

    /// Runs once, right after the first frame: opens the connections the cache
    /// could not replace. The splash is on screen while this blocks.
    pub fn boot(self: *Session) void {
        if (!self.needs_boot) return;
        self.needs_boot = false;

        // `loop` already painted the splash for this boot; only paint it here
        // when boot is driven from somewhere else (tests, future front ends).
        if (self.deps.splash and !self.state.booting) {
            self.state.booting = true;
            self.render();
        }

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
        if (self.deps.splash) {
            // Paint first (cached mail, or the splash), then do the slow part.
            self.state.booting = self.needs_boot;
            self.render();
            self.boot();
        } else {
            // Nothing here can block: no empty frame, no splash.
            self.boot();
            self.render();
        }
        while (self.step()) {}
    }

    fn start_refresh(self: *Session) void {
        if (self.refreshing) return;
        const count = self.deps.accounts.len;
        if (count == 0) return;

        for (self.deps.accounts, 0..) |source, index| {
            self.refresh_sources[index] = .{ .id = source.id, .mail = source.mail };
        }
        // Paint what the cache has first: switching mailboxes stays instant.
        self.load_cached(self.state.mailbox);

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

        for (self.deps.accounts, 0..) |source, index| {
            // A failed account keeps whatever the cache already showed.
            if (!self.refresh_job.ok[index]) continue;

            const offset = self.refresh_job.offsets[index];
            const count = self.refresh_job.counts[index];
            const fetched = self.refresh_scratch[offset..][0..count];

            core.sync.replace_mailbox(&self.store, source.id, self.refresh_mailbox, fetched);
            self.loaded_mask |= mask_bit(@intCast(index), @backingInt(self.refresh_mailbox));
            if (self.deps.cache) |cache| {
                cache.save(source.id, self.refresh_mailbox, fetched) catch {};
            }
        }

        const failures = self.refresh_job.failures;
        self.refreshing = false;
        self.state.refreshing = false;
        self.state.rebuild(&self.store);
        self.needs_render = true;

        if (failures > 0) {
            self.state.set_alert("Could not refresh {s}", .{self.refresh_mailbox.title()});
        }
    }

    /// Test helper: waits for the worker, then applies its results.
    pub fn settle_refresh_for_test(self: *Session) void {
        while (self.refreshing) {
            self.poll_refresh();
            std.atomic.spinLoopHint();
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
        if (key == .mouse) return self.handle_mouse(key.mouse);
        const command = keymap.translate(key, .{ .mode = self.state.mode, .view = self.state.view }) orelse return false;
        return self.apply(command);
    }

    fn handle_mouse(self: *Session, mouse: input.Mouse) bool {
        if (mouse.kind == .release) return false;

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
        return false;
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
        return true;
    }

    /// Test hook: run effects the way the loop does.
    pub fn run_effects_for_test(self: *Session, effects: []const core.effect.Effect) void {
        self.run_effects(effects);
    }

    fn run_effects(self: *Session, effects: []const core.effect.Effect) void {
        for (effects) |effect| {
            // One connection: while the worker uses it, cached mail is readable
            // but no other request may touch the transport.
            if (self.refreshing) {
                switch (effect) {
                    .refresh => {},
                    else => {
                        self.state.set_alert("Refreshing mail…", .{});
                        continue;
                    },
                }
            }

            switch (effect) {
                .fetch_body => |args| self.fetch_body(args.account, args.mailbox, args.id),
                .sync_flags => |args| self.sync_flags(args.account, args.id, args.flags),
                .move_message => |args| self.move_message(args.account, args.id, args.to),
                .refresh => self.start_refresh(),
                .send => |outgoing| self.send(&outgoing),
            }
        }
    }

    fn source_for(self: *Session, account: core.id.AccountId) ?core.mail_port.Mail {
        for (self.deps.accounts) |source| {
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
        const mail = self.source_for(account) orelse {
            self.state.set_alert("That account is not connected", .{});
            return;
        };
        const body = mail.fetch_body(mailbox, id, &self.body) catch {
            self.body_len = 0;
            self.body_loaded = true;
            self.wrapped = .{};
            self.state.set_alert("Could not load this message", .{});
            return;
        };
        self.body_len = @intCast(body.len);
        self.body_loaded = true;
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

        for (self.deps.accounts, 0..) |source, index| {
            const count = source.mail.fetch(mailbox, self.scratch) catch {
                failed = true;
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
            self.state.set_alert("Could not load {s}", .{mailbox.title()});
        }
        self.needs_render = true;
    }

    fn render(self: *Session) void {
        const lay = layout_mod.Layout.compute(self.size.columns, self.size.rows, self.state.accounts.max_label());
        if (self.body_loaded) {
            wrap.wrap(self.body[0..self.body_len], lay.reader_text_width, &self.wrapped);
        }

        _ = core.update.apply(&self.state, &self.store, .{ .set_viewport = .{
            .list_rows = lay.list_rows,
            .reader_rows = lay.reader_rows,
            .body_rows = if (self.body_loaded) self.wrapped.len else 0,
        } });

        render_mod.frame(.{
            .state = &self.state,
            .store = &self.store,
            .theme = &self.deps.theme,
            .body = self.body[0..self.body_len],
            .wrapped = if (self.body_loaded) &self.wrapped else null,
            .now_unix = self.now_unix,
            .columns = self.size.columns,
            .rows = self.size.rows,
        }, &self.screen);

        self.flush();
        self.needs_render = false;
    }

    fn flush(self: *Session) void {
        const system = self.deps.system;
        system.write("\x1b[H") catch return;

        var row: u16 = 0;
        while (row < self.screen.rows) : (row += 1) {
            var writer = std.Io.Writer.fixed(&self.row_buffer);
            self.screen.encode_row(row, &writer, self.deps.theme.colored) catch return;
            if (row > 0) system.write("\r\n") catch return;
            system.write(writer.buffered()) catch return;
        }
        system.write("\x1b[0m") catch {};
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
    fail_fetch: bool = false,
    fail_body: bool = false,
    fail_flags: bool = false,
    fail_move: bool = false,

    fn mail(self: *FakeMail) core.mail_port.Mail {
        return .{ .context = self, .vtable = &.{
            .fetch = fetchThunk,
            .fetch_body = fetchBodyThunk,
            .set_flags = setFlagsThunk,
            .move_message = moveThunk,
        } };
    }

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) core.mail_port.Error!u32 {
        const self: *FakeMail = @ptrCast(@alignCast(context));
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

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: core.message.Flags) core.mail_port.Error!void {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_flags) return error.Unavailable;
        return self.inner.mail().set_flags(id, flags);
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) core.mail_port.Error!void {
        const self: *FakeMail = @ptrCast(@alignCast(context));
        if (self.fail_move) return error.Rejected;
        return self.inner.mail().move_message(id, to);
    }
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
        });
        // Tests exercise the steady state: the cache is empty, so boot fetches.
        self.session.boot();
    }

    fn deinit(self: *Rig) void {
        self.session.deinit();
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
    defer rig.deinit();

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
}

test "a request while the refresh runs is refused, not raced" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.deinit();
    _ = rig.session.step();

    // Start the refresh but do not wait for it.
    rig.fake_system.push_input("\x12");
    _ = rig.session.step();
    try testing.expect(rig.session.refreshing);
    try testing.expect(rig.session.state.refreshing);

    rig.session.run_effects_for_test(&.{.{ .fetch_body = .{
        .account = core.id.AccountId.from_int(1),
        .mailbox = .inbox,
        .id = MessageId.from_int(1),
    } }});
    try testing.expectEqualStrings("Refreshing mail…", rig.session.state.status.slice());

    rig.session.settle_refresh_for_test();
    try testing.expect(!rig.session.refreshing);
    try testing.expect(!rig.session.state.refreshing);
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
