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

    return run_session(gpa, system, &demo.sources, &demo.outboxes, null);
}

fn run_session(
    gpa: std.mem.Allocator,
    system: SessionSystem,
    accounts: []const session_mod.MailSource,
    outboxes: []const session_mod.OutboxSource,
    cache: ?core.cache_port.Cache,
) ?Failure {
    var session: session_mod.Session = undefined;
    session.init(gpa, .{
        .accounts = accounts,
        .outboxes = outboxes,
        .cache = cache,
        .system = system,
        .theme = theme_for_environment(),
        .now = os.now_unix,
    }) catch return .{ .message = "Not enough memory to start" };
    defer session.deinit();

    session.loop();
    return null;
}

const max_accounts = core.config.max_accounts;

const Live = struct {
    imap_transport: [max_accounts]net.tls.TlsTransport = undefined,
    imap: [max_accounts]core.imap_mail.ImapMail = undefined,
    smtp_transport: [max_accounts]net.tls.TlsTransport = undefined,
    smtp: [max_accounts]core.smtp_outbox.SmtpOutbox = undefined,
    has_imap: [max_accounts]bool = @splat(false),
    has_smtp: [max_accounts]bool = @splat(false),
    sources: [max_accounts]session_mod.MailSource = undefined,
    outboxes: [max_accounts]session_mod.OutboxSource = undefined,
    imap_count: u8 = 0,
    outbox_count: u8 = 0,

    fn close(self: *Live) void {
        var index: u8 = 0;
        while (index < max_accounts) : (index += 1) {
            if (self.has_smtp[index]) self.smtp[index].close();
        }
        index = 0;
        while (index < max_accounts) : (index += 1) {
            if (self.has_imap[index]) self.imap[index].close();
        }
        index = 0;
        while (index < max_accounts) : (index += 1) {
            if (self.has_smtp[index]) self.smtp_transport[index].deinit();
        }
        index = 0;
        while (index < max_accounts) : (index += 1) {
            if (self.has_imap[index]) self.imap_transport[index].deinit();
        }
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
            const outcome = setup_session.run(system, theme_for_environment(), path) catch
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

    const file = core.config.parse(config_text) catch |err|
        return .{ .message = config_message(err) };
    if (file.len == 0) return .{ .message = "The config has no accounts" };

    var live: Live = .{};
    defer live.close();

    for (file.items(), 0..) |entry, index_u| {
        const index: u8 = @intCast(index_u);
        if (entry.account.imap.security != .tls) {
            return .{ .message = "Only implicit TLS (imap_security = tls) is supported today" };
        }

        var password: core.secret.Secret = .{};
        defer password.deinit();
        read_password(io, path, entry.label.slice(), file.len == 1, &password) catch
            return .{ .message = "No password for an account: run setup again or set AMAIL_PASSWORD" };

        live.imap_transport[index].open(
            gpa,
            io,
            entry.account.imap.host.slice(),
            entry.account.imap.port,
        ) catch return .{ .message = "Could not connect to an IMAP server over TLS" };
        live.has_imap[index] = true;

        const id = core.id.AccountId.from_int(index + 1);
        live.imap[index] = core.imap_mail.ImapMail.open(
            live.imap_transport[index].transport(),
            id,
            entry.account.username.slice(),
            password.expose(),
        ) catch |err| return .{ .message = login_message(err) };
        live.sources[live.imap_count] = .{
            .id = id,
            .label = entry.label.slice(),
            .from = entry.account.address,
            .mail = live.imap[index].mail(),
        };
        live.imap_count += 1;

        if (entry.smtp) |smtp| {
            if (smtp.security != .tls) {
                return .{ .message = "Only implicit TLS for SMTP (smtp_port = 465) is supported today" };
            }
            live.smtp_transport[index].open(gpa, io, smtp.host.slice(), smtp.port) catch
                return .{ .message = "Could not connect to an SMTP server over TLS" };
            live.has_smtp[index] = true;
            live.smtp[index] = core.smtp_outbox.SmtpOutbox.connect(
                live.smtp_transport[index].transport(),
                "localhost",
                entry.account.username.slice(),
                password.expose(),
                os.now_unix,
            ) catch return .{ .message = "SMTP login failed: check the credentials" };

            live.outboxes[live.outbox_count] = .{ .id = id, .outbox = live.smtp[index].outbox() };
            live.outbox_count += 1;
        }
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
    if (cache_dir.len > 0) {
        file_cache = net.cache_file.FileCache.init(gpa, io, cache_dir, labels[0..file.len]);
        cache = file_cache.cache();
    }

    return run_session(
        gpa,
        system,
        live.sources[0..live.imap_count],
        live.outboxes[0..live.outbox_count],
        cache,
    );
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
    if (path.len > 0) {
        if (read_file(io, path, &buffer)) |text| {
            try core.secret.Secret.init(std.mem.trimEnd(u8, text, "\r\n"), out);
            return;
        } else |_| {}
    }

    if (allow_env) {
        if (os.env("AMAIL_PASSWORD")) |value| {
            try core.secret.Secret.init(value, out);
            return;
        }
    }

    var legacy_buffer: [512]u8 = undefined;
    const legacy = cli.legacy_credential_path(config_path, &legacy_buffer);
    if (legacy.len > 0) {
        if (read_file(io, legacy, &buffer)) |text| {
            try core.secret.Secret.init(std.mem.trimEnd(u8, text, "\r\n"), out);
            return;
        } else |_| {}
    }

    return error.NoPassword;
}

const file_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));
const directory_mode: std.Io.Dir.Permissions = @fromBackingInt(@intCast(0o700));

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
    try write_file(io, credential, saved.password.expose());
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
