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

fn run_demo(gpa: std.mem.Allocator, system: SessionSystem) ?Failure {
    var mail = core.memory_mail.MemoryMail.init();
    core.demo.seed(&mail, os.now_unix()) catch
        return .{ .message = "Could not seed the demo account" };

    var outbox = core.memory_outbox.MemoryOutbox.init(&mail, os.now_unix());
    const from = core.address.Address.init("Me <me@amail.local>") catch core.address.Address{};
    return run_session(gpa, system, mail.mail(), outbox.outbox(), from);
}

fn run_session(
    gpa: std.mem.Allocator,
    system: SessionSystem,
    mail: core.mail_port.Mail,
    outbox: ?core.outbox_port.Outbox,
    from: core.address.Address,
) ?Failure {
    var session: session_mod.Session = undefined;
    session.init(gpa, .{
        .mail = mail,
        .outbox = outbox,
        .system = system,
        .theme = theme_for_environment(),
        .now = os.now_unix,
        .from_address = from,
    }) catch return .{ .message = "Not enough memory to start" };
    defer session.deinit();

    session.loop();
    return null;
}

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
            // First run: create the config with the setup assistant.
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

    const config = core.config.parse(config_text) catch |err|
        return .{ .message = config_message(err) };

    var credential: core.secret.Secret = .{};
    var have_credential = false;
    defer if (have_credential) credential.deinit();

    const password: []const u8 = blk: {
        if (os.env("AMAIL_PASSWORD")) |value| break :blk value;
        if (have_saved_setup) break :blk saved_setup.password.expose();
        if (read_credential(io, path, &credential)) |_| {
            have_credential = true;
            break :blk credential.expose();
        } else |_| {}
        return .{ .message = "No password found: run setup again or set AMAIL_PASSWORD" };
    };

    if (config.imap.security != .tls) {
        return .{ .message = "Only implicit TLS (imap_security = tls) is supported today" };
    }

    var transport_impl: net.tls.TlsTransport = undefined;
    transport_impl.open(gpa, io, config.imap.host.slice(), config.imap.port) catch
        return .{ .message = "Could not connect to the IMAP server over TLS" };
    defer transport_impl.deinit();

    var imap = core.imap_mail.ImapMail.open(
        transport_impl.transport(),
        config.username.slice(),
        password,
    ) catch |err| return .{ .message = login_message(err) };
    defer imap.close();

    // Sending needs a second connection; without it the client still reads and
    // compose reports that it cannot send.
    var smtp_transport: net.tls.TlsTransport = undefined;
    var smtp_outbox: core.smtp_outbox.SmtpOutbox = undefined;
    var smtp_ready = false;
    if (config.smtp) |smtp| {
        if (smtp.security != .tls) {
            return .{ .message = "Only implicit TLS for SMTP (smtp_port = 465) is supported today" };
        }
        smtp_transport.open(gpa, io, smtp.host.slice(), smtp.port) catch
            return .{ .message = "Could not connect to the SMTP server over TLS" };
        smtp_outbox = core.smtp_outbox.SmtpOutbox.connect(
            smtp_transport.transport(),
            "localhost",
            config.username.slice(),
            password,
            os.now_unix,
        ) catch return .{ .message = "SMTP login failed: check username and AMAIL_PASSWORD" };
        smtp_ready = true;
    }
    defer if (smtp_ready) smtp_transport.deinit();
    defer if (smtp_ready) smtp_outbox.close();

    const outbox: ?core.outbox_port.Outbox = if (smtp_ready) smtp_outbox.outbox() else null;
    return run_session(gpa, system, imap.mail(), outbox, config.address);
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
    const credential = cli.credential_path(config_path, &credential_buffer);
    if (credential.len == 0) return error.NameTooLong;
    try write_file(io, credential, saved.password.expose());
}

fn write_file(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = file_mode });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn read_credential(io: std.Io, config_path: []const u8, out: *core.secret.Secret) !void {
    var path_buffer: [512]u8 = undefined;
    const path = cli.credential_path(config_path, &path_buffer);
    if (path.len == 0) return error.NameTooLong;

    var buffer: [1024]u8 = undefined;
    const text = try read_file(io, path, &buffer);
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    try core.secret.Secret.init(trimmed, out);
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
