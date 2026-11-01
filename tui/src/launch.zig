//! Terminal lifecycle and the two ways to get mail: the demo account or a live
//! IMAP account. This is the process boundary: it sets raw mode, switches to
//! the alternate screen, enables mouse reporting, and restores everything
//! before reporting a setup failure. Covered by the end-to-end PTY test.

const std = @import("std");
const core = @import("core");
const net = @import("net");

const cli = @import("cli.zig");
const os = @import("os.zig");
const session_mod = @import("session.zig");
const setup_session = @import("setup_session.zig");
const theme_mod = @import("theme.zig");

const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h";
const leave_screen = "\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l";

const Failure = struct {
    message: []const u8,
    code: u8 = 1,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch) !u8 {
    var posix = os.Posix.init(std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    const system = posix.system();

    // `--oauth` talks to a human in a browser: it runs on the normal screen,
    // before the alternate one, so the URL and the QR are actually visible.
    if (options.oauth) {
        const failure = run_oauth(gpa, io, options, system);
        if (failure) |problem| {
            std.debug.print("amail: {s}\n", .{problem.message});
            return problem.code;
        }
        return 0;
    }

    try system.enter_raw();
    try system.write(enter_screen);

    const failure = run_inside(gpa, io, options, system);

    system.write(leave_screen) catch {};
    system.leave_raw() catch {};

    if (failure) |problem| {
        std.debug.print("amail: {s}\n", .{problem.message});
        return problem.code;
    }
    return 0;
}

/// Returns null on a clean exit, or what to report once the terminal is back.
fn run_inside(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    if (options.set_password) return run_set_password(io, options, system);
    if (options.add_account) return run_add_account(io, options, system);
    return switch (options.mode) {
        .demo => run_demo(gpa, system),
        .live => run_live(gpa, io, options, system),
    };
}

const SessionSystem = @import("system.zig").System;

const Demo = struct {
    mail: [2]core.memory_mail.MemoryMail = undefined,
    outbox: [2]core.memory_outbox.MemoryOutbox = undefined,
    sources: [2]session_mod.MailSource = undefined,
    outboxes: [2]session_mod.OutboxSource = undefined,
};

fn run_demo(gpa: std.mem.Allocator, system: SessionSystem) ?Failure {
    var demo: Demo = .{};
    const now = os.now_unix();

    demo.mail[0] = core.memory_mail.MemoryMail.init();
    demo.mail[1] = core.memory_mail.MemoryMail.init();
    core.demo.seed_for(&demo.mail[0], now, 1) catch
        return .{ .message = "Could not seed the demo account" };
    core.demo.seed_for(&demo.mail[1], now, 2) catch
        return .{ .message = "Could not seed the demo account" };

    demo.outbox[0] = core.memory_outbox.MemoryOutbox.init(&demo.mail[0], now);
    demo.outbox[1] = core.memory_outbox.MemoryOutbox.init(&demo.mail[1], now);

    const personal = core.address.Address.init("Me <me@amail.local>") catch core.address.Address{};
    const work = core.address.Address.init("Me <me@work.example>") catch core.address.Address{};

    demo.sources[0] = .{ .id = core.id.AccountId.from_int(1), .label = "personal", .from = personal, .mail = demo.mail[0].mail() };
    demo.sources[1] = .{ .id = core.id.AccountId.from_int(2), .label = "work", .from = work, .mail = demo.mail[1].mail() };
    demo.outboxes[0] = .{ .id = core.id.AccountId.from_int(1), .outbox = demo.outbox[0].outbox() };
    demo.outboxes[1] = .{ .id = core.id.AccountId.from_int(2), .outbox = demo.outbox[1].outbox() };

    return run_session(gpa, system, &demo.sources, &demo.outboxes, null, null, null, false, null);
}

fn run_session(
    gpa: std.mem.Allocator,
    system: SessionSystem,
    accounts: []const session_mod.MailSource,
    outboxes: []const session_mod.OutboxSource,
    cache: ?core.cache_port.Cache,
    bodies: ?core.bodies_port.BodyCache,
    accounts_file: ?core.accounts_port.Accounts,
    splash: bool,
    notice: ?[]const u8,
) ?Failure {
    // The session owns megabytes of bounded buffers; keeping it on the stack
    // next to the adapters overflows it.
    const session = gpa.create(session_mod.Session) catch
        return .{ .message = "Not enough memory to start" };
    defer gpa.destroy(session);
    session.init(gpa, .{
        .accounts = accounts,
        .outboxes = outboxes,
        .cache = cache,
        .bodies = bodies,
        .accounts_file = accounts_file,
        .notice = notice,
        .splash = splash,
        .system = system,
        .theme = theme_for_environment(),
        .now = os.now_unix,
    }) catch return .{ .message = "Not enough memory to start" };
    defer session.deinit();

    session.loop();
    return null;
}

const max_accounts = core.config.max_accounts;

/// One configured account, connected on demand.
///
/// Nothing here touches the network until a port call arrives: with a warm
/// cache the first frame is painted without a socket, and a connection that
/// fails becomes an ordinary port error (cached mail stays readable) instead of
/// a reason not to start.
const LiveAccount = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    id: core.id.AccountId = .unknown,
    label: []const u8 = "",
    from: core.address.Address = .{},
    host: core.text.Text(core.limits.host_max) = .{},
    port: u16 = 0,
    username: core.text.Text(core.limits.username_max) = .{},
    password: core.secret.Secret = .{},
    password_ready: bool = false,
    /// An OAuth2 token from the token file, when the provider gave us one.
    token: core.oauth.Token = .{},
    oauth_client_id: core.text.Text(256) = .{},
    smtp_host: core.text.Text(core.limits.host_max) = .{},
    smtp_port: u16 = 0,
    smtp_enabled: bool = false,

    imap_transport: net.tls.TlsTransport = undefined,
    smtp_transport: net.tls.TlsTransport = undefined,
    imap: core.imap_mail.ImapMail = undefined,
    smtp_client: core.smtp_outbox.SmtpOutbox = undefined,
    has_imap: bool = false,
    has_smtp: bool = false,

    /// Why the last connection attempt failed, for the exit message.
    failure: ?[]const u8 = null,
    connected: bool = false,

    fn openMail(context: *anyopaque) core.mail_port.Error!core.mail_port.Mail {
        const self: *LiveAccount = @ptrCast(@alignCast(context));
        if (self.has_imap) return self.imap.mail();
        // An OAuth account has a token, not a password: do not demand one.
        if (self.token.access.is_empty() and !self.password_ready) {
            self.failure = "No password for an account: run setup again or set AMAIL_PASSWORD";
            return error.Unavailable;
        }

        self.imap_transport.open(self.gpa, self.io, self.host.slice(), self.port) catch {
            self.failure = "Could not connect to an IMAP server over TLS";
            return error.Unavailable;
        };
        const opened = if (self.token.access.is_empty())
            core.imap_mail.ImapMail.open(
                self.imap_transport.transport(),
                self.id,
                self.username.slice(),
                self.password.expose(),
            )
        else
            core.imap_mail.ImapMail.open_token(
                self.imap_transport.transport(),
                self.id,
                self.username.slice(),
                self.token.access.slice(),
            );
        self.imap = opened catch |err| {
            self.imap_transport.deinit();
            self.failure = login_message(err);
            // A refused login is not "unavailable": say so.
            return switch (err) {
                error.LoginFailed, error.Rejected, error.ProtocolError => error.Rejected,
                else => error.Unavailable,
            };
        };
        self.has_imap = true;
        self.connected = true;
        return self.imap.mail();
    }

    fn closeMail(context: *anyopaque) void {
        const self: *LiveAccount = @ptrCast(@alignCast(context));
        if (!self.has_imap) return;
        self.imap.close();
        self.imap_transport.deinit();
        self.has_imap = false;
    }

    fn openOutbox(context: *anyopaque) core.outbox_port.Error!core.outbox_port.Outbox {
        const self: *LiveAccount = @ptrCast(@alignCast(context));
        if (self.has_smtp) return self.smtp_client.outbox();
        if (!self.smtp_enabled or !self.password_ready) return error.Unavailable;

        self.smtp_transport.open(self.gpa, self.io, self.smtp_host.slice(), self.smtp_port) catch
            return error.Unavailable;
        self.smtp_client = core.smtp_outbox.SmtpOutbox.connect(
            self.smtp_transport.transport(),
            "localhost",
            self.username.slice(),
            self.password.expose(),
            os.now_unix,
        ) catch {
            self.smtp_transport.deinit();
            return error.Unavailable;
        };
        self.has_smtp = true;
        return self.smtp_client.outbox();
    }

    fn closeOutbox(context: *anyopaque) void {
        const self: *LiveAccount = @ptrCast(@alignCast(context));
        if (!self.has_smtp) return;
        self.smtp_client.close();
        self.smtp_transport.deinit();
        self.has_smtp = false;
    }
};

const Live = struct {
    accounts: [max_accounts]LiveAccount = undefined,
    len: u8 = 0,
    lazy_mail: [max_accounts]core.lazy_mail = undefined,
    lazy_outbox: [max_accounts]core.lazy_outbox = undefined,
    sources: [max_accounts]session_mod.MailSource = undefined,
    outboxes: [max_accounts]session_mod.OutboxSource = undefined,
    mail_count: u8 = 0,
    outbox_count: u8 = 0,

    fn add(self: *Live, account: LiveAccount) void {
        const index = self.len;
        self.accounts[index] = account;
        self.len += 1;
        // Slices must point at the stored account, not at the parameter: the
        // parameter dies when this returns, and the form would show garbage.
        const stored = &self.accounts[index];

        self.lazy_mail[index] = .{
            .context = &self.accounts[index],
            .open_fn = LiveAccount.openMail,
            .close_fn = LiveAccount.closeMail,
        };
        self.sources[self.mail_count] = .{
            .id = account.id,
            .label = stored.label,
            .from = account.from,
            .mail = self.lazy_mail[index].mail(),
            .imap_host = stored.host.slice(),
            .imap_port = stored.port,
            .username = stored.username.slice(),
            .smtp_host = stored.smtp_host.slice(),
            .smtp_port = stored.smtp_port,
            .smtp = stored.smtp_enabled,
            .oauth_client_id = stored.oauth_client_id.slice(),
            .hint = login_hint(stored.host.slice()),
        };
        self.mail_count += 1;

        if (account.smtp_enabled) {
            self.lazy_outbox[index] = .{
                .context = &self.accounts[index],
                .open_fn = LiveAccount.openOutbox,
                .close_fn = LiveAccount.closeOutbox,
            };
            self.outboxes[self.outbox_count] = .{
                .id = account.id,
                .outbox = self.lazy_outbox[index].outbox(),
            };
            self.outbox_count += 1;
        }
    }

    fn close(self: *Live) void {
        var index: u8 = 0;
        while (index < self.len) : (index += 1) {
            self.lazy_outbox[index].close();
        }
        index = 0;
        while (index < self.len) : (index += 1) {
            self.lazy_mail[index].close();
            self.accounts[index].password.deinit();
        }
    }

    fn firstFailure(self: *const Live) ?[]const u8 {
        var index: u8 = 0;
        while (index < self.len) : (index += 1) {
            if (self.accounts[index].connected) return null;
        }
        index = 0;
        while (index < self.len) : (index += 1) {
            if (self.accounts[index].failure) |message| return message;
        }
        return null;
    }
};

fn run_live(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = options.config_path orelse cli.default_config_path(
        &path_buffer,
        os.env("XDG_CONFIG_HOME"),
        os.env("HOME"),
    );
    if (path.len == 0) {
        return .{ .message = "No config path: pass --config or set XDG_CONFIG_HOME" };
    }

    var config_buffer: [8193]u8 = undefined;
    var config_text: []const u8 = undefined;

    var saved_setup: setup_session.Saved = undefined;
    var have_saved_setup = false;
    defer if (have_saved_setup) saved_setup.password.deinit();

    if (read_file(io, path, &config_buffer)) |text| {
        if (text.len == config_buffer.len) return .{ .message = "Config file is too large" };
        config_text = text;
    } else |err| switch (err) {
        error.FileNotFound => {
            const outcome = setup_session.run(system, theme_for_environment(), path, "") catch
                return .{ .message = "Setup failed: terminal error" };
            switch (outcome) {
                .cancelled => return .{ .message = "Setup cancelled; no config was written" },
                .saved => |saved| {
                    saved_setup = saved;
                    have_saved_setup = true;
                    write_setup_files(io, path, &saved_setup) catch
                        return .{ .message = "Could not write the config file" };
                    config_text = saved_setup.config_text();
                },
            }
        },
        else => return .{ .message = "Could not read the config file" },
    }

    // A broken config must not lock the user out: open the client with no
    // accounts and say what is wrong, so the file can be fixed in another
    // window and the client restarted.
    const file = core.config.parse(config_text) catch |err| {
        return run_session(gpa, system, &.{}, &.{}, null, null, null, true, config_message(err));
    };
    if (file.len == 0) return .{ .message = "The config has no accounts" };

    var live: Live = .{};
    defer live.close();
    var missing_password: ?[]const u8 = null;

    for (file.items(), 0..) |entry, index_u| {
        const index: u8 = @intCast(index_u);
        if (entry.account.imap.security != .tls) {
            return .{ .message = "Only implicit TLS (imap_security = tls) is supported today" };
        }
        if (entry.smtp) |smtp| {
            if (smtp.security != .tls) {
                return .{ .message = "Only implicit TLS for SMTP (smtp_port = 465) is supported today" };
            }
        }

        var account = LiveAccount{
            .gpa = gpa,
            .io = io,
            .id = core.id.AccountId.from_int(index + 1),
            .label = entry.label.slice(),
            .from = entry.account.address,
            .port = entry.account.imap.port,
            .smtp_enabled = entry.smtp != null,
        };
        account.host.set(entry.account.imap.host.slice());
        account.username.set(entry.account.username.slice());
        if (entry.smtp) |smtp| {
            account.smtp_host.set(smtp.host.slice());
            account.smtp_port = smtp.port;
        }
        read_password(io, path, entry.label.slice(), file.len == 1, &account.password) catch {};
        account.password_ready = !account.password.is_empty();
        account.oauth_client_id.set(entry.oauth_client_id.slice());
        if (read_token(io, path, entry.label.slice())) |stored| {
            var token = stored;
            if (!token.is_fresh(os.now_unix())) {
                // Expired: exchange the refresh token, and keep the new one.
                const provider = provider_for(entry.account.imap.host.slice());
                const client_id = entry.oauth_client_id.slice();
                if (net.oauth_flow.refresh(gpa, io, provider, client_id, &token)) {
                    write_token(io, path, entry.label.slice(), &token) catch {};
                }
            }
            if (token.is_fresh(os.now_unix())) account.token = token;
        } else |_| {}
        // An OAuth account lives on its token: a missing password is expected.
        if (!account.password_ready and account.token.access.is_empty() and missing_password == null) {
            missing_password = "No password for an account: set AMAIL_PASSWORD or run amail --add-account";
        }

        live.add(account);
    }

    // On-disk cache: startup and mailbox switches read from here, so the first
    // frame never waits for the network. `R` refreshes from the server.
    var labels: [max_accounts]net.cache_file.Label = undefined;
    for (file.items(), 0..) |entry, index| {
        labels[index] = .{
            .id = core.id.AccountId.from_int(@intCast(index + 1)),
            .label = entry.label.slice(),
        };
    }

    var cache_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&cache_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));

    var file_cache: net.cache_file.FileCache = undefined;
    var cache: ?core.cache_port.Cache = null;
    var file_bodies: net.bodies.FileBodies = undefined;
    var bodies: ?core.bodies_port.BodyCache = null;
    if (cache_dir.len > 0) {
        file_cache = net.cache_file.FileCache.init(gpa, io, cache_dir, labels[0..file.len]);
        cache = file_cache.cache();
        file_bodies = net.bodies.FileBodies.init(gpa, io, cache_dir, labels[0..file.len]);
        bodies = file_bodies.cache();
    }

    var accounts_file = FileAccounts{ .io = io, .path = path, .system = system, .gpa = gpa };
    const account_port: ?core.accounts_port.Accounts = if (live.len > 0) accounts_file.accounts() else null;

    const outcome = run_session(
        gpa,
        system,
        live.sources[0..live.mail_count],
        live.outboxes[0..live.outbox_count],
        cache,
        bodies,
        account_port,
        true,
        missing_password,
    );
    if (outcome != null) return outcome;
    // A connection that never worked left nothing on screen: say why.
    if (live.firstFailure()) |reason| return .{ .message = reason };
    return null;
}

fn read_password(
    io: std.Io,
    config_path: []const u8,
    label: []const u8,
    allow_env: bool,
    out: *core.secret.Secret,
) !void {
    var buffer: [1024]u8 = undefined;
    var path_buffer: [512]u8 = undefined;

    const path = cli.credential_path(config_path, label, &path_buffer);

    // The environment wins: it is how a password is set or repaired without
    // trusting whatever is on disk, and it re-seals itself for next time.
    if (allow_env) {
        if (os.env("AMAIL_PASSWORD")) |value| {
            if (value.len > 0) {
                try core.secret.Secret.init(value, out);
                if (path.len > 0) seal_in_place(io, config_path, path, value) catch {};
                return;
            }
        }
    }

    if (path.len > 0) {
        if (read_file(io, path, &buffer)) |text| {
            if (try open_credential(io, text, out, config_path)) return;
        } else |_| {}
    }

    if (allow_env) {
        if (os.env("AMAIL_PASSWORD")) |value| {
            try core.secret.Secret.init(value, out);
            // Re-seal it: a lost or replaced key heals on the next start.
            if (path.len > 0) seal_in_place(io, config_path, path, value) catch {};
            return;
        }
    }

    var legacy_buffer: [512]u8 = undefined;
    const legacy = cli.legacy_credential_path(config_path, &legacy_buffer);
    if (legacy.len > 0) {
        if (read_file(io, legacy, &buffer)) |text| {
            // Sealed first; then a real plaintext file from an older install.
            if (try open_credential(io, text, out, config_path)) return;

            const trimmed = std.mem.trimEnd(u8, text, "\r\n");
            // Only accept it as a password if it *looks* like one: a sealed
            // blob that cannot be opened must not become a garbage password.
            if (!looks_like_password(trimmed)) return error.NoPassword;
            try core.secret.Secret.init(trimmed, out);
            seal_in_place(io, config_path, legacy, trimmed) catch {};
            if (path.len > 0) write_sealed_credential(io, config_path, out, label) catch {};
            return;
        } else |_| {}
    }

    return error.NoPassword;
}

/// The key that protects credentials lives next to the config: the cache is
/// disposable, and deleting it must never make a password unreadable.
fn key_dir(io: std.Io, config_path: []const u8, buffer: []u8) ?[]const u8 {
    const dir = cli.parent_dir(config_path);
    if (dir.len == 0) return null;

    // Migration: an older build kept the key in the cache directory. Copy it
    // over the first time so sealed credentials keep opening.
    var target_buffer: [512]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buffer, "{s}/key", .{dir}) catch return null;
    if (std.Io.Dir.cwd().openFile(io, target, .{})) |file| {
        file.close(io);
        return std.fmt.bufPrint(buffer, "{s}", .{dir}) catch null;
    } else |_| {}

    var cache_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&cache_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));
    if (cache_dir.len > 0) {
        var source_buffer: [512]u8 = undefined;
        const source = std.fmt.bufPrint(&source_buffer, "{s}/key", .{cache_dir}) catch "";
        if (source.len > 0) {
            if (std.Io.Dir.cwd().openFile(io, source, .{})) |file| {
                defer file.close(io);
                var key: [32]u8 = undefined;
                if (file.readPositionalAll(io, &key, 0) catch 0 == 32) {
                    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, directory_mode) catch {};
                    const copy = std.Io.Dir.cwd().createFile(io, target, .{ .permissions = file_mode }) catch null;
                    if (copy) |out| {
                        defer out.close(io);
                        out.writeStreamingAll(io, &key) catch {};
                    }
                }
            } else |_| {}
        }
    }
    return std.fmt.bufPrint(buffer, "{s}", .{dir}) catch null;
}

/// Seals `secret` into `dest`. The key always comes from the *config*
/// directory: deriving it from the destination made the read key differ from
/// the write key, so a freshly saved password could never be opened again.
fn seal_in_place(io: std.Io, config_path: []const u8, dest: []const u8, secret: []const u8) !void {
    var dir_buffer: [512]u8 = undefined;
    const dir = key_dir(io, config_path, &dir_buffer) orelse return error.NameTooLong;

    var keys = net.keyfile.KeyFile.init(undefined, io, dir);
    const key = keys.get() orelse return error.NameTooLong;

    var sealed_buffer: [core.limits.secret_max + core.sealed.overhead]u8 = undefined;
    var nonce: core.sealed.Nonce = undefined;
    io.random(&nonce);
    const sealed_secret = try core.sealed.seal(key, nonce, secret, &sealed_buffer);
    try write_file(io, dest, sealed_secret);
}

/// A password typed by a human: printable UTF-8, no control bytes.
fn looks_like_password(text: []const u8) bool {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

/// Writes (or rewrites) the sealed credential for `label`.
fn write_sealed_credential(io: std.Io, config_path: []const u8, password: *const core.secret.Secret, label: []const u8) !void {
    var credential_buffer: [512]u8 = undefined;
    const credential = cli.credential_path(config_path, label, &credential_buffer);
    if (credential.len == 0) return error.NameTooLong;

    const dir = cli.parent_dir(credential);
    if (dir.len > 0) {
        std.Io.Dir.cwd().createDir(io, dir, directory_mode) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    try seal_in_place(io, config_path, credential, password.expose());
}

/// Writes (or rewrites) a sealed credential from raw bytes.
fn write_credential_bytes(io: std.Io, config_path: []const u8, label: []const u8, password: []const u8) !void {
    var secret: core.secret.Secret = .{};
    defer secret.deinit();
    try core.secret.Secret.init(password, &secret);
    try write_sealed_credential(io, config_path, &secret, label);
}

/// Opens a sealed credential; a plaintext file from an older version is still
/// accepted so nobody is locked out by the upgrade.
fn open_credential(io: std.Io, text: []const u8, out: *core.secret.Secret, config_path: []const u8) !bool {
    var dir_buffer: [512]u8 = undefined;
    const dir = key_dir(io, config_path, &dir_buffer) orelse return false;

    var keys = net.keyfile.KeyFile.init(undefined, io, dir);
    const key = keys.get() orelse return false;

    var plain: [core.limits.secret_max]u8 = undefined;
    if (core.sealed.open(key, text, &plain)) |value| {
        try core.secret.Secret.init(value, out);
        return true;
    } else |_| {}

    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    if (trimmed.len == 0 or trimmed.len > core.limits.secret_max) return false;
    try core.secret.Secret.init(trimmed, out);
    return true;
}

const file_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));
const directory_mode: std.Io.Dir.Permissions = @fromBackingInt(@intCast(0o700));

/// `--oauth`: the provider round trip for the first account, then the token is
/// sealed next to the config and used at the next login.
fn run_oauth(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = options.config_path orelse cli.default_config_path(
        &path_buffer,
        os.env("XDG_CACHE_HOME"),
        os.env("HOME"),
    );
    if (path.len == 0) return .{ .message = "No config path" };

    var buffer: [8193]u8 = undefined;
    const text = read_file(io, path, &buffer) catch
        return .{ .message = "No config yet: run amail once to create one" };
    const file = core.config.parse(text) catch |err| return .{ .message = config_message(err) };
    if (file.len == 0) return .{ .message = "The config has no accounts" };

    const entry = file.items()[0];
    const provider = provider_for(entry.account.imap.host.slice());
    if (provider == .custom) {
        return .{ .message = "That host is not a known OAuth2 provider (Microsoft or Google)" };
    }

    const client_id = if (entry.oauth_client_id.is_empty())
        (os.env("AMAIL_OAUTH_CLIENT_ID") orelse "")
    else
        entry.oauth_client_id.slice();
    // Optional: without one we can still print the URL the user must build.
    if (client_id.len == 0) {
        return .{ .message = "Add oauth_client_id to the config (or set AMAIL_OAUTH_CLIENT_ID)" };
    }

    const Io = struct {
        system: SessionSystem,
        fn write(context: *anyopaque, bytes: []const u8) void {
            const this: *@This() = @ptrCast(@alignCast(context));
            this.system.write(bytes) catch {};
        }
        fn read(context: *anyopaque, out: []u8) net.oauth_flow.Error!usize {
            const this: *@This() = @ptrCast(@alignCast(context));
            var count: usize = 0;
            while (count < out.len) {
                const got = this.system.read(out[count..], 200) catch return error.Unavailable;
                if (got == 0) continue;
                count += got;
                if (std.mem.indexOfScalar(u8, out[0..count], '\n') != null) break;
            }
            return count;
        }
    };
    var callbacks = Io{ .system = system };

    var token: core.oauth.Token = .{};
    net.oauth_flow.run(gpa, io, .{
        .provider = provider,
        .client_id = client_id,
        .write = Io.write,
        .read = Io.read,
        .context = &callbacks,
    }, &token) catch |err| return .{ .message = switch (err) {
        error.Cancelled => "No authorization code in that URL: paste the whole address",
        else => "OAuth failed: check the client id, the redirect URI and try again",
    } };

    write_token(io, path, entry.label.slice(), &token) catch
        return .{ .message = "Could not save the token" };
    std.debug.print("amail: signed in {s}\n", .{entry.label.slice()});
    return null;
}

/// `--password`: one prompt, sealed, done. The escape hatch when the stored
/// credential cannot be opened (a wiped key, a moved config).
fn run_set_password(io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = options.config_path orelse cli.default_config_path(
        &path_buffer,
        os.env("XDG_CONFIG_HOME"),
        os.env("HOME"),
    );
    if (path.len == 0) return .{ .message = "No config path" };

    var config_buffer: [8193]u8 = undefined;
    const text = read_file(io, path, &config_buffer) catch
        return .{ .message = "No config yet: run amail once to create one" };
    const file = core.config.parse(text) catch |err| return .{ .message = config_message(err) };
    if (file.len == 0) return .{ .message = "The config has no accounts" };
    const label = file.items()[0].label.slice();

    var buffer: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&buffer, "Password for {s}: ", .{label}) catch "Password: ";
    system.write(prompt) catch {};
    system.write("\x1b[?25h") catch {};

    var secret: core.secret.Secret = .{};
    defer secret.deinit();
    var parser: @import("input.zig").Parser = .{};
    var typed: [128]u8 = undefined;

    while (true) {
        var keys: @import("input.zig").Keys = .{};
        const typed_count = system.read(&typed, 100) catch 0;
        if (typed_count == 0) continue;
        parser.decode(typed[0..typed_count], &keys);
        var done = false;
        for (keys.slice()) |key| switch (key) {
            .char => |codepoint| {
                if (codepoint >= 0x20 and codepoint != 0x7f) secret.append_codepoint(codepoint);
            },
            .backspace => secret.pop_codepoint(),
            .enter => done = true,
            .ctrl => |letter| if (letter == 'c' or letter == 'q') return .{ .message = "No password saved", .code = 0 },
            else => {},
        };
        if (done) break;
    }

    system.write("\n") catch {};
    if (secret.is_empty()) return .{ .message = "A password cannot be empty" };

    write_sealed_credential(io, path, &secret, label) catch
        return .{ .message = "Could not write the password file" };
    std.debug.print("amail: password saved for {s}\n", .{label});
    return null;
}

/// Reads a sealed OAuth2 token for one account.
fn read_token(io: std.Io, config_path: []const u8, label: []const u8) !core.oauth.Token {
    var path_buffer: [512]u8 = undefined;
    const path = token_path(config_path, label, &path_buffer);
    if (path.len == 0) return error.NameTooLong;

    var buffer: [core.oauth.token_max * 2 + 64]u8 = undefined;
    const sealed_text = try read_file(io, path, &buffer);

    var dir_buffer: [512]u8 = undefined;
    const dir = key_dir(io, config_path, &dir_buffer) orelse return error.NameTooLong;
    var keys = net.keyfile.KeyFile.init(undefined, io, dir);
    const key = keys.get() orelse return error.NameTooLong;

    var plain: [core.oauth.token_max * 2 + 64]u8 = undefined;
    const text = try core.sealed.open(key, sealed_text, &plain);

    // access, refresh, expires: one per line.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var token: core.oauth.Token = .{};
    token.access.set(lines.next() orelse return error.InvalidData);
    token.refresh.set(lines.next() orelse "");
    token.expires_unix = std.fmt.parseInt(i64, std.mem.trim(u8, lines.next() orelse "0", " \r\n"), 10) catch 0;
    return token;
}

fn write_token(io: std.Io, config_path: []const u8, label: []const u8, token: *const core.oauth.Token) !void {
    var path_buffer: [512]u8 = undefined;
    const path = token_path(config_path, label, &path_buffer);
    if (path.len == 0) return error.NameTooLong;

    const dir = cli.parent_dir(path);
    if (dir.len > 0) {
        std.Io.Dir.cwd().createDir(io, dir, directory_mode) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var text_buffer: [core.oauth.token_max * 2 + 64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{s}\n{s}\n{d}", .{
        token.access.slice(),
        token.refresh.slice(),
        token.expires_unix,
    }) catch return error.NameTooLong;

    var dir_buffer: [512]u8 = undefined;
    const key_directory = key_dir(io, config_path, &dir_buffer) orelse return error.NameTooLong;
    var keys = net.keyfile.KeyFile.init(undefined, io, key_directory);
    const key = keys.get() orelse return error.NameTooLong;

    var sealed_buffer: [core.oauth.token_max * 2 + 64 + core.sealed.overhead]u8 = undefined;
    var nonce: core.sealed.Nonce = undefined;
    io.random(&nonce);
    const sealed_text = try core.sealed.seal(key, nonce, text, &sealed_buffer);
    try write_file(io, path, sealed_text);
}

fn token_path(config_path: []const u8, label: []const u8, buffer: []u8) []const u8 {
    const dir = cli.parent_dir(config_path);
    if (dir.len == 0) return "";
    return std.fmt.bufPrint(buffer, "{s}/tokens/{s}", .{ dir, label }) catch "";
}

/// The accounts port for a real config file: removing rewrites the file and
/// deletes the credential, adding runs the assistant and appends the section.
const FileAccounts = struct {
    io: std.Io,
    path: []const u8,
    system: SessionSystem,
    gpa: std.mem.Allocator = undefined,
    // One runtime connection (the TUI adds one account at a time).
    transport: net.tls.TlsTransport = undefined,
    imap: core.imap_mail.ImapMail = undefined,
    open_account: ?core.id.AccountId = null,
    connected: core.accounts_port.Accounts.Connected = .{},
    // Owned copies: the config text they came from is a local buffer.
    owned_label: core.text.Text(core.limits.label_max) = .{},
    owned_host: core.text.Text(core.limits.host_max) = .{},
    owned_user: core.text.Text(core.limits.username_max) = .{},
    owned_address: core.text.Text(core.limits.address_max) = .{},
    connected_address_buffer: [core.limits.address_max]u8 = undefined,

    fn accounts(self: *FileAccounts) core.accounts_port.Accounts {
        return .{ .context = self, .vtable = &.{
            .remove = removeThunk,
            .save = saveThunk,
            .rename = renameThunk,
            .connect = connectThunk,
            .disconnect = disconnectThunk,
            .oauth_login = oauthThunk,
        } };
    }

    fn removeThunk(context: *anyopaque, account: core.id.AccountId) core.accounts_port.Error!void {
        const self: *FileAccounts = @ptrCast(@alignCast(context));
        const index: usize = @intCast(account.to_int() - 1);

        var buffer: [8193]u8 = undefined;
        const text = read_file(self.io, self.path, &buffer) catch return error.Unavailable;
        const file = core.config.parse(text) catch return error.Unavailable;
        const entry = file.items()[index];

        var rewritten: [8193]u8 = undefined;
        const kept = core.config.without(text, entry.label.slice(), &rewritten);
        write_file(self.io, self.path, kept) catch return error.Unavailable;

        var credential_buffer: [512]u8 = undefined;
        const credential = cli.credential_path(self.path, entry.label.slice(), &credential_buffer);
        std.Io.Dir.cwd().deleteFile(self.io, credential) catch {};
    }

    fn connectThunk(
        context: *anyopaque,
        account: core.id.AccountId,
        out: *core.accounts_port.Accounts.Connected,
    ) core.accounts_port.Error!void {
        const self: *FileAccounts = @ptrCast(@alignCast(context));

        // Only one at a time: close whatever was open.
        disconnectThunk(context, account) catch {};

        var buffer: [8193]u8 = undefined;
        const text = read_file(self.io, self.path, &buffer) catch return error.Unavailable;
        const file = core.config.parse(text) catch return error.Unavailable;
        const index: usize = @intCast(account.to_int() - 1);
        if (index >= file.len) return error.Unavailable;
        const entry = file.items()[index];
        if (entry.account.imap.security != .tls) return error.Unavailable;

        var stored_token = read_token(self.io, self.path, entry.label.slice()) catch null;
        if (stored_token) |*token| {
            if (!token.is_fresh(os.now_unix())) {
                const provider = provider_for(entry.account.imap.host.slice());
                const client_id = entry.oauth_client_id.slice();
                if (net.oauth_flow.refresh(self.gpa, self.io, provider, client_id, token)) {
                    write_token(self.io, self.path, entry.label.slice(), token) catch {};
                }
            }
        }
        const has_token = stored_token;
        const fresh = if (has_token) |value| value.is_fresh(os.now_unix()) else false;

        var password: core.secret.Secret = .{};
        defer password.deinit();
        if (!fresh) {
            read_password(self.io, self.path, entry.label.slice(), file.len == 1, &password) catch
                return error.Unavailable;
        }

        self.transport.open(self.gpa, self.io, entry.account.imap.host.slice(), entry.account.imap.port) catch
            return error.Unavailable;
        const opened = if (fresh and has_token != null)
            core.imap_mail.ImapMail.open_token(
                self.transport.transport(),
                account,
                entry.account.username.slice(),
                has_token.?.access.slice(),
            )
        else
            core.imap_mail.ImapMail.open(
                self.transport.transport(),
                account,
                entry.account.username.slice(),
                password.expose(),
            );
        self.imap = opened catch |err| {
            self.transport.deinit();
            return switch (err) {
                error.LoginFailed, error.Rejected, error.ProtocolError => error.Unavailable,
                else => error.Unavailable,
            };
        };
        self.open_account = account;

        self.owned_label.set(entry.label.slice());
        self.owned_host.set(entry.account.imap.host.slice());
        self.owned_user.set(entry.account.username.slice());
        self.owned_address.set(entry.account.address.addr_spec(
            &self.connected_address_buffer,
        ));
        self.connected = .{
            .id = account,
            .label = self.owned_label.slice(),
            .address_text = self.owned_address.slice(),
            .imap_host = self.owned_host.slice(),
            .imap_port = entry.account.imap.port,
            .username = self.owned_user.slice(),
            .smtp = entry.smtp != null,
            .mail = self.imap.mail(),
        };
        out.* = self.connected;
    }

    fn oauthThunk(context: *anyopaque, account: core.id.AccountId) core.accounts_port.Error!void {
        const self: *FileAccounts = @ptrCast(@alignCast(context));

        var buffer: [8193]u8 = undefined;
        const text = read_file(self.io, self.path, &buffer) catch return error.Unavailable;
        const file = core.config.parse(text) catch return error.Unavailable;
        const index: usize = @intCast(account.to_int() - 1);
        if (index >= file.len) return error.Unavailable;
        const entry = file.items()[index];

        const provider = provider_for(entry.account.imap.host.slice());
        if (provider == .custom) return error.Unavailable;
        const client_id = entry.oauth_client_id.slice();
        if (client_id.len == 0) return error.Unavailable;

        // A terminal writer, so the URL and the QR land on screen.
        const WriteContext = struct {
            system: SessionSystem,
            fn write(self_context: *anyopaque, bytes: []const u8) void {
                const this: *@This() = @ptrCast(@alignCast(self_context));
                this.system.write(bytes) catch {};
            }
        };
        var writer = WriteContext{ .system = self.system };

        var token: core.oauth.Token = .{};
        net.oauth_flow.run(self.gpa, self.io, .{
            .provider = provider,
            .client_id = client_id,
            .write = WriteContext.write,
            .context = &writer,
        }, &token) catch return error.Unavailable;

        write_token(self.io, self.path, entry.label.slice(), &token) catch return error.Unavailable;
    }

    fn disconnectThunk(context: *anyopaque, account: core.id.AccountId) core.accounts_port.Error!void {
        const self: *FileAccounts = @ptrCast(@alignCast(context));
        _ = account;
        if (self.open_account == null) return;
        self.imap.close();
        self.transport.deinit();
        self.open_account = null;
        self.connected.mail = null;
    }

    fn renameThunk(
        context: *anyopaque,
        account: core.id.AccountId,
        label: []const u8,
    ) core.accounts_port.Error!void {
        const self: *FileAccounts = @ptrCast(@alignCast(context));

        var buffer: [8193]u8 = undefined;
        const text = read_file(self.io, self.path, &buffer) catch return error.Unavailable;
        const file = core.config.parse(text) catch return error.Unavailable;
        if (!core.config.has_label(text, label)) {} else return error.Unavailable;

        const index: usize = @intCast(account.to_int() - 1);
        if (index >= file.len) return error.Unavailable;
        const old = file.items()[index].label.slice();

        var renamed_buffer: [8193]u8 = undefined;
        const renamed = core.config.rename_label(text, old, label, &renamed_buffer);
        if (renamed.len == 0) return error.Unavailable;
        write_file(self.io, self.path, renamed) catch return error.Unavailable;

        // The credential file follows the label.
        var old_buffer: [512]u8 = undefined;
        var new_buffer: [512]u8 = undefined;
        const from = cli.credential_path(self.path, old, &old_buffer);
        const to = cli.credential_path(self.path, label, &new_buffer);
        if (from.len > 0 and to.len > 0) {
            std.Io.Dir.cwd().rename(from, std.Io.Dir.cwd(), to, self.io) catch {};
        }
    }

    fn saveThunk(context: *anyopaque, draft: core.accounts_port.Accounts.Draft) core.accounts_port.Error!core.id.AccountId {
        const self: *FileAccounts = @ptrCast(@alignCast(context));

        var buffer: [8193]u8 = undefined;
        const text = read_file(self.io, self.path, &buffer) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return error.Unavailable,
        };
        const existing = core.config.parse(text) catch return error.Unavailable;

        if (draft.replaces) |account| {
            // Replace in place: drop the old section, then append the new one.
            const index: usize = @intCast(account.to_int() - 1);
            if (index >= existing.len) return error.Unavailable;
            var kept_buffer: [8193]u8 = undefined;
            const kept = core.config.without(text, existing.items()[index].label.slice(), &kept_buffer);
            write_file(self.io, self.path, kept) catch return error.Unavailable;
        } else if (core.config.has_label(text, draft.label)) {
            return error.Unavailable;
        }

        append_file(self.io, self.path, draft.text) catch return error.Unavailable;
        // No password in the draft means "keep the one on disk".
        if (draft.password) |password| {
            write_credential_bytes(self.io, self.path, draft.label, password) catch
                return error.Unavailable;
        }

        // The new account's id is its position in the file.
        if (draft.replaces) |account| return account;
        return core.id.AccountId.from_int(@intCast(existing.len + 1));
    }
};

/// `--add-account`: ask for one more account and append it to the config.
/// Existing accounts, their credentials, and their cache are untouched.
fn run_add_account(io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = options.config_path orelse cli.default_config_path(
        &path_buffer,
        os.env("XDG_CONFIG_HOME"),
        os.env("HOME"),
    );
    if (path.len == 0) {
        return .{ .message = "No config path: pass --config or set XDG_CONFIG_HOME" };
    }

    var config_buffer: [8193]u8 = undefined;
    const existing = read_file(io, path, &config_buffer) catch |err| switch (err) {
        error.FileNotFound => return .{ .message = "No config yet: run amail once to create one" },
        else => return .{ .message = "Could not read the config file" },
    };
    _ = core.config.parse(existing) catch |err| return .{ .message = config_message(err) };

    var saved: setup_session.Saved = undefined;
    const outcome = setup_session.run(system, theme_for_environment(), path, "") catch
        return .{ .message = "Setup failed: terminal error" };
    switch (outcome) {
        .cancelled => return .{ .message = "No account added", .code = 0 },
        .saved => |result| {
            saved = result;
        },
    }
    defer saved.password.deinit();

    if (core.config.has_label(existing, saved.label.slice())) {
        return .{ .message = "That account already exists; give the new one another label" };
    }

    append_file(io, path, saved.config_text()) catch
        return .{ .message = "Could not write the config file" };
    write_credential(io, path, &saved) catch
        return .{ .message = "Could not write the password file" };

    std.debug.print("amail: added account \"{s}\"\n", .{saved.label.slice()});
    return null;
}

fn append_file(io: std.Io, path: []const u8, text: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const size = try file.stat(io);
    const separator = if (size.size > 0) "\n" else "";
    try file.writePositionalAll(io, separator, size.size);
    try file.writePositionalAll(io, text, size.size + separator.len);
}

/// The password file is sealed with the cache key (0600), so no secret is ever
/// written in the clear. The key file is the trust boundary: see docs/SECURITY.
fn write_credential(io: std.Io, config_path: []const u8, saved: *const setup_session.Saved) !void {
    var credential_buffer: [512]u8 = undefined;
    const credential = cli.credential_path(config_path, saved.label.slice(), &credential_buffer);
    if (credential.len == 0) return error.NameTooLong;

    const dir = cli.parent_dir(credential);
    if (dir.len > 0) {
        std.Io.Dir.cwd().createDir(io, dir, directory_mode) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    var cache_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&cache_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));
    if (cache_dir.len == 0) return error.NameTooLong;

    var keys = net.keyfile.KeyFile.init(undefined, io, cache_dir);
    const key = keys.get() orelse return error.NameTooLong;

    var sealed_buffer: [core.limits.secret_max + core.sealed.overhead]u8 = undefined;
    var nonce: core.sealed.Nonce = undefined;
    io.random(&nonce);
    const sealed_password = try core.sealed.seal(key, nonce, saved.password.expose(), &sealed_buffer);
    try write_file(io, credential, sealed_password);
}

fn write_setup_files(io: std.Io, config_path: []const u8, saved: *const setup_session.Saved) !void {
    const dir = cli.parent_dir(config_path);
    if (dir.len > 0) {
        std.Io.Dir.cwd().createDir(io, dir, directory_mode) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    try write_file(io, config_path, saved.config_text());

    var credential_buffer: [512]u8 = undefined;
    const credential = cli.credential_path(config_path, saved.label.slice(), &credential_buffer);
    if (credential.len == 0) return error.NameTooLong;

    const credential_dir = cli.parent_dir(credential);
    if (credential_dir.len > 0) {
        std.Io.Dir.cwd().createDir(io, credential_dir, directory_mode) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    var cache_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&cache_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));
    if (cache_dir.len == 0) return error.NameTooLong;

    var keys = net.keyfile.KeyFile.init(undefined, io, cache_dir);
    const key = keys.get() orelse return error.NameTooLong;

    var sealed_buffer: [core.limits.secret_max + core.sealed.overhead]u8 = undefined;
    var nonce: core.sealed.Nonce = undefined;
    io.random(&nonce);
    const sealed_password = try core.sealed.seal(key, nonce, saved.password.expose(), &sealed_buffer);
    try write_file(io, credential, sealed_password);
}

fn write_file(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = file_mode });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn read_file(io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const count = try file.readPositionalAll(io, buffer, 0);
    return buffer[0..count];
}

fn config_message(err: anyerror) []const u8 {
    return switch (err) {
        error.PasswordInConfig => "Remove the password from the config; use AMAIL_PASSWORD",
        error.UnknownKey => "Unknown key in the config file",
        error.MissingKey => "Missing required key in the config file",
        error.InvalidValue, error.MissingEquals => "Invalid line in the config file",
        error.PlaintextForbidden => "Plaintext IMAP needs allow_plaintext = true",
        error.InvalidHost, error.EmptyHost => "Invalid imap_host in the config file",
        error.InvalidPort => "Invalid imap_port in the config file",
        else => "Invalid config file",
    };
}

/// Which OAuth2 provider a host belongs to.
fn provider_for(host: []const u8) core.oauth.Provider {
    if (containsIgnoreCase(host, "office365") or containsIgnoreCase(host, "outlook")) return .microsoft;
    if (containsIgnoreCase(host, "gmail") or containsIgnoreCase(host, "googlemail")) return .google;
    return .custom;
}

/// Some providers stopped accepting passwords: say which and how to fix it.
fn login_hint(host: []const u8) []const u8 {
    if (containsIgnoreCase(host, "office365") or containsIgnoreCase(host, "outlook")) {
        return "Microsoft needs OAuth2 or an app password";
    }
    if (containsIgnoreCase(host, "gmail") or containsIgnoreCase(host, "googlemail")) {
        return "Google needs an app password when 2FA is on";
    }
    if (containsIgnoreCase(host, "yahoo")) {
        return "Yahoo needs an app password";
    }
    return "check the password";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn login_message(err: core.imap.client.Error) []const u8 {
    return switch (err) {
        error.LoginFailed => "Login failed: check username and AMAIL_PASSWORD",
        error.Unavailable => "The IMAP server could not be reached",
        error.Timeout => "The IMAP server stopped responding",
        else => "The IMAP server refused the session",
    };
}

fn theme_for_environment() theme_mod.Theme {
    if (os.env("NO_COLOR") != null) return theme_mod.Theme.mono();
    if (os.env("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return theme_mod.Theme.mono();
    }
    return theme_mod.Theme.dark();
}
