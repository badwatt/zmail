//! Terminal lifecycle and the two ways to get mail: the demo account or a live
//! IMAP account. This is the process boundary: it sets raw mode, switches to
//! the alternate screen, enables mouse reporting, and restores everything
//! before reporting a setup failure. Covered by the end-to-end PTY test.

const std = @import("std");
const core = @import("core");
const net = @import("net");

const cli = @import("cli.zig");
const graphics = @import("graphics.zig");
const progress = @import("progress.zig");
const halfblocks = @import("halfblocks.zig");
const os = @import("os.zig");
const session_mod = @import("session.zig");
const setup_session = @import("setup_session.zig");
const theme_mod = @import("theme.zig");

const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1003h\x1b[?1006h";
const leave_screen = "\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?25h\x1b[?1049l";

const Failure = struct {
    message: []const u8,
    code: u8 = 1,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch) !u8 {
    ignore_sigpipe();
    var posix = os.Posix.init(std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    const system = posix.system();

    // `--oauth` talks to a human in a browser: it runs on the normal screen,
    // before the alternate one, so the URL and the QR are actually visible.
    if (options.oauth) {
        const failure = run_oauth(gpa, io, options, system);
        if (failure) |problem| {
            std.debug.print("{s}: {s}\n", .{ core.meta.name, problem.message });
            return problem.code;
        }
        return 0;
    }

    try system.enter_raw();
    install_panic_button(&posix);
    // Asked while the terminal is raw and before anything reads keys: both
    // answers come on stdin, and a parser would read them as typing.
    // Both of these block before a single cell is painted, and a terminal answers
    // in microseconds or never: one short try each, not two long ones.
    graphics.detect(system);
    background = os.query_background(system);
    // A pipe, a log, or a `dumb` terminal must not be sent a progress bar; one
    // that shows it must be told when the work stops, which is what restoreNow
    // and deinit are for.
    progress.enable(!std.mem.eql(u8, os.env("TERM") orelse "", "dumb"));
    try system.write(enter_screen);

    const failure = run_inside(gpa, io, options, system);

    system.write(leave_screen) catch {};
    system.leave_raw() catch {};

    if (failure) |problem| {
        std.debug.print("{s}: {s}\n", .{ core.meta.name, problem.message });
        return problem.code;
    }
    return 0;
}

/// Ctrl+C, as a way out that always works.
///
/// The loop that would have noticed the keystroke is the one blocked on a
/// socket, a login, or the first connection of a cold start, so a quit sent as a
/// key can only be honoured when that call returns. A signal is not blocked by
/// anything: the handler puts the terminal back the way it was found and leaves,
/// which is what "quit now" has to mean when "now" is inside a TLS read.
/// A socket that closes under a write is an error, not a corpse.
///
/// `SIGPIPE` terminates the process by default, and the one place it is raised is a
/// `write` to a server that has gone -- a mail server that times out, a link that
/// drops. Linux lets a caller opt out per call with `MSG_NOSIGNAL`; macOS has no
/// such flag and only this, so ignoring the signal is the portable answer. Every
/// write in this program checks its result, so there is nothing left to notice.
fn ignore_sigpipe() void {
    const ignored = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignored, null);
}

fn install_panic_button(posix: *os.Posix) void {
    interrupting = posix;

    var action = std.posix.Sigaction{
        .handler = .{ .handler = onInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &action, null);

    // Ctrl+Z would suspend into a screen nobody repaints on the way back: keep
    // it inert, the way it was while Ctrl turned it into a byte.
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TSTP, &ignore, null);
}

/// What the handler needs: the terminal it has to give back.
var interrupting: ?*os.Posix = null;

fn onInterrupt(_: std.posix.SIG) callconv(.c) void {
    // Only a write and a syscall here: the terminal is the whole point, and the
    // process is about to end, so there is nothing to free and nothing to join.
    if (interrupting) |posix| posix.restoreNow();
    std.c._exit(130);
}

/// Returns null on a clean exit, or what to report once the terminal is back.
fn run_inside(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    if (options.set_password) return run_set_password(io, options, system);
    if (options.add_account) return run_add_account(io, options, system);
    // The demo is the one thing the client is not by default, and it is asked for by
    // name: there is no flag for "be what you are".
    if (options.demo) return run_demo(gpa, io, system);
    return run_live(gpa, io, options, system);
}

const SessionSystem = @import("system.zig").System;

const Demo = struct {
    mail: [2]core.memory_mail.MemoryMail = undefined,
    outbox: [2]core.memory_outbox.MemoryOutbox = undefined,
    sources: [2]session_mod.MailSource = undefined,
    outboxes: [2]session_mod.OutboxSource = undefined,
};

fn run_demo(gpa: std.mem.Allocator, io: std.Io, system: SessionSystem) ?Failure {
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

    const personal = core.address.Address.init("Me <me@" ++ core.meta.name ++ ".local>") catch core.address.Address{};
    const work = core.address.Address.init("Me <me@work.example>") catch core.address.Address{};

    demo.sources[0] = .{ .id = core.id.AccountId.from_int(1), .label = "personal", .from = personal, .mail = demo.mail[0].mail() };
    demo.sources[1] = .{ .id = core.id.AccountId.from_int(2), .label = "work", .from = work, .mail = demo.mail[1].mail() };
    demo.outboxes[0] = .{ .id = core.id.AccountId.from_int(1), .outbox = demo.outbox[0].outbox() };
    demo.outboxes[1] = .{ .id = core.id.AccountId.from_int(2), .outbox = demo.outbox[1].outbox() };

    return run_session(gpa, io, system, &demo.sources, &demo.outboxes, null, null, null, null, null, false, null);
}

fn run_session(
    gpa: std.mem.Allocator,
    io: std.Io,
    system: SessionSystem,
    accounts: []const session_mod.MailSource,
    outboxes: []const session_mod.OutboxSource,
    cache: ?core.cache_port.Cache,
    bodies: ?core.bodies_port.BodyCache,
    accounts_file: ?core.accounts_port.Accounts,
    scope: ?core.scope_port.Scope,
    prefs: ?core.prefs_port.Preferences,
    splash: bool,
    notice: ?[]const u8,
) ?Failure {
    // The session owns megabytes of bounded buffers; keeping it on the stack
    // next to the adapters overflows it.
    var dir_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&dir_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));
    var browser = Browser{ .io = io, .cache_dir = cache_dir, .gpa = gpa, .system = system };
    var editor = Editor{ .io = io };
    const session = gpa.create(session_mod.Session) catch
        return .{ .message = "Not enough memory to start" };
    defer gpa.destroy(session);
    session.init(gpa, .{
        .accounts = accounts,
        .outboxes = outboxes,
        .cache = cache,
        .bodies = bodies,
        .accounts_file = accounts_file,
        .scope = scope,
        .prefs = prefs,
        .notice = notice,
        .splash = splash,
        .system = system,
        .theme = theme_for_environment(),
        .reduced_motion = os.env("ZMAIL_NO_MOTION") != null,
        .now = os.now_unix,
        .open_url = openUrlThunk,
        .open_url_context = &browser,
        .open_external = openExternalThunk,
        .open_external_context = &browser,
        .edit_text = editTextThunk,
        .edit_text_context = &editor,
        .fetch_image = fetchImageThunk,
        .fetch_image_context = &browser,
        // Wired only where the terminal said it can paint: the session then has an
        // honest answer for a key that asks for pictures.
        .draw_image = if (graphics.supported()) drawImageThunk else null,
        .draw_image_context = &browser,
        .clear_images = clearImagesThunk,
        .clear_images_context = &browser,
    }) catch return .{ .message = "Not enough memory to start" };
    defer session.deinit();

    // The folders the accounts have, on the left, where a mail client keeps
    // them. Off in the fixtures: a test that draws 100x24 is testing the list.
    session.sidebar = true;

    session.loop();
    // The terminal belongs to the shell again: the pointer shape and the bar are ours to
    // put back, and a chain left behind is a chain in every later command.
    system.write(core.osc.Pointer.default.sequence()) catch {};
    return null;
}

/// Said once, used everywhere a config file turns out to be missing.
const no_config = "No config yet: run " ++ core.meta.name ++ " once to create one";

/// The Browser behind a Thunk's opaque context.
fn browser_of(context: *anyopaque) *Browser {
    return @ptrCast(@alignCast(context));
}

/// The editor behind the session's `edit_text` thunk.
fn editor_of(context: *anyopaque) *Editor {
    return @ptrCast(@alignCast(context));
}

/// The user's editor, as the session sees it: one function, no shell.
const Editor = struct {
    io: std.Io,
};

fn editTextThunk(context: *anyopaque, initial: []const u8, out: []u8) ?[]const u8 {
    return os.edit_text(editor_of(context).io, initial, out);
}

/// Clicking a link hands it to whatever opens browsers on this machine.
const Browser = struct {
    io: std.Io,
    /// Where a rendered page and its picture are written before being shown.
    cache_dir: []const u8 = "",
    gpa: std.mem.Allocator = undefined,
    system: SessionSystem = undefined,
};

/// Writes the page a second time with each anchor's address in the text, for
/// the browsers whose dump prints no references.
/// Downloads one picture the message points at, with `curl`.
///
/// Not with `src/net/tls.zig`: that client was written for a token endpoint, one small
/// POST, and it answers "Unavailable" to hosts that are perfectly happy -- github,
/// brave's asset host -- and 302 with no body where a plain request gets 200 and the
/// picture. `curl` is a web client; being one is its job.
///
/// Only ever called from the image worker, and it brings its own event loop: the one the
/// rest of the program uses is not something to poke from a thread, and the abort this
/// replaced was exactly that.
fn fetchImageThunk(context: *anyopaque, url: []const u8, out: []u8) ?[]const u8 {
    const self = browser_of(context);

    var threaded: std.Io.Threaded = .init(self.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Where curl is, from PATH: it is at `/usr/bin` on a distribution, at
    // `/opt/homebrew/bin` on a Mac and at a store path on Nix, and a list of
    // guesses only ever knows the first two.
    var path_buffer: [1024]u8 = undefined;
    var argv = [_][]const u8{
        "",
        "--silent",
        "--show-error",
        "--fail",
        "--location",
        "--max-time",
        "20",
        // The size the reader can hold, so a runaway response is cut rather than
        // buffered: a picture bigger than the screen is not a picture at this size.
        "--max-filesize",
        "4194304",
        "--user-agent",
        core.meta.name,
        "--header",
        "Accept: image/png",
        "--url",
        url,
    };
    const search = os.env("PATH") orelse return null;
    var dirs = std.mem.splitScalar(u8, search, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/curl", .{dir}) catch continue;
        argv[0] = path;
        const result = std.process.run(self.gpa, io, .{
            .argv = &argv,
            .stdout_limit = .limited(out.len),
            .stderr_limit = .limited(256),
        }) catch continue;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (!result.term.success() or result.stdout.len == 0) return null;
        @memcpy(out[0..result.stdout.len], result.stdout);
        return out[0..result.stdout.len];
    }
    return null;
}

/// One image of the message, painted where the layout left its marker.
///
/// Two ways to draw it, and the plain one goes first. Half blocks are text: every
/// terminal shows them, and they are what remains on screen if the terminal accepts
/// the graphics sequences and then paints nothing -- which is a thing terminals do,
/// silently, because the protocol lets a program ask for no answers.
///
/// The picture is then offered to the terminal's own protocol, which draws over the
/// blocks at full resolution where it works. Best case the blocks are hidden; worst
/// case they are the picture.
fn drawImageThunk(
    context: *anyopaque,
    png_bytes: []const u8,
    id: u32,
    x: u16,
    y: u16,
    columns: u16,
    rows: u16,
    ground: u32,
) bool {
    const self = browser_of(context);

    // The terminal's own protocol first: it paints the picture with its alpha, over
    // whatever is behind it. Blocks are the fallback, never both -- a transparent
    // pixel in the picture would show the blocks we drew under it, and a logo would
    // arrive with a checkerboard behind the letters.
    if (graphics.supported()) {
        if (graphics.transmit(self.system, png_bytes, id)) {
            if (graphics.place(self.system, id, x, y, columns, rows)) return true;
        }
    }

    const work = self.gpa.alloc(u8, png_bytes.len + core.limits.body_max * 2) catch return false;
    defer self.gpa.free(work);
    const rgba = self.gpa.alloc(u8, core.limits.body_max) catch return false;
    defer self.gpa.free(rgba);
    const image = core.png.decode(png_bytes, work, rgba) catch return false;
    return halfblocks.draw(self.system, image, x, y, columns, rows, ground);
}

fn clearImagesThunk(context: *anyopaque) void {
    const self = browser_of(context);
    if (graphics.supported()) graphics.clear_all(self.system);
}

fn openUrlThunk(context: *anyopaque, url: []const u8) void {
    const self = browser_of(context);
    net.oauth_flow.open_in_browser(self.io, url);
}

/// The chosen scope, in a one-line file next to the config. Not a secret: a
/// label the user picked, so it needs no sealing.
const FileScope = struct {
    io: std.Io,
    config_path: []const u8,

    fn scope(self: *FileScope) core.scope_port.Scope {
        return .{ .context = self, .vtable = &.{ .load = loadThunk, .save = saveThunk } };
    }

    fn file_path(self: *FileScope, buffer: []u8) []const u8 {
        const dir = cli.parent_dir(self.config_path);
        if (dir.len == 0) return "";
        return std.fmt.bufPrint(buffer, "{s}/scope", .{dir}) catch "";
    }

    fn loadThunk(context: *anyopaque, out: *core.text.Text(core.limits.label_max)) bool {
        const self: *FileScope = @ptrCast(@alignCast(context));
        var path_buffer: [512]u8 = undefined;
        const scope_path = self.file_path(&path_buffer);
        if (scope_path.len == 0) return false;

        var buffer: [core.limits.label_max + 8]u8 = undefined;
        const text = read_file(self.io, scope_path, &buffer) catch return false;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return false;
        out.set(trimmed);
        return true;
    }

    fn saveThunk(context: *anyopaque, label: []const u8) core.scope_port.Error!void {
        const self: *FileScope = @ptrCast(@alignCast(context));
        var path_buffer: [512]u8 = undefined;
        const scope_path = self.file_path(&path_buffer);
        if (scope_path.len == 0) return error.Unavailable;
        write_file(self.io, scope_path, std.mem.trim(u8, label, " \t\r\n")) catch
            return error.Unavailable;
    }
};

/// What the reader chose with a key, in a one-line file next to the config:
/// `images=on`. Not a secret -- a preference -- so it needs no sealing.
const FilePrefs = struct {
    io: std.Io,
    config_path: []const u8,

    fn prefs(self: *FilePrefs) core.prefs_port.Preferences {
        return .{ .context = self, .vtable = &.{ .load_images = loadThunk, .save_images = saveThunk } };
    }

    fn file_path(self: *FilePrefs, buffer: []u8) []const u8 {
        const dir = cli.parent_dir(self.config_path);
        if (dir.len == 0) return "";
        return std.fmt.bufPrint(buffer, "{s}/prefs", .{dir}) catch "";
    }

    fn loadThunk(context: *anyopaque) bool {
        const self: *FilePrefs = @ptrCast(@alignCast(context));
        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(&path_buffer);
        if (path.len == 0) return false;

        var buffer: [64]u8 = undefined;
        const text = read_file(self.io, path, &buffer) catch return false;
        return std.mem.indexOf(u8, text, "images=on") != null;
    }

    fn saveThunk(context: *anyopaque, on: bool) core.prefs_port.Error!void {
        const self: *FilePrefs = @ptrCast(@alignCast(context));
        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(&path_buffer);
        if (path.len == 0) return error.Unavailable;
        write_file(self.io, path, if (on) "images=on\n" else "images=off\n") catch
            return error.Unavailable;
    }
};

/// Hands the message to whatever shows pages on this machine.
fn openExternalThunk(context: *anyopaque, html: []const u8, link: []const u8) void {
    const self = browser_of(context);
    if (html.len > 0) {
        var path_buffer: [512]u8 = undefined;
        const path = writeHtmlFile(self, html, &path_buffer, 0) orelse return;
        var url_buffer: [600]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buffer, "file://{s}", .{path}) catch return;
        net.oauth_flow.open_in_browser(self.io, url);
        return;
    }
    if (link.len > 0) net.oauth_flow.open_in_browser(self.io, link);
}

/// The HTML part on disk, wrapped enough to look like paper in a browser.
fn writeHtmlFile(
    self: *Browser,
    html: []const u8,
    path_buffer: []u8,
    offset_px: u32,
) ?[]const u8 {
    if (self.cache_dir.len == 0) return null;
    const path = std.fmt.bufPrint(path_buffer, "{s}/{s}/message.html", .{ self.cache_dir, core.meta.name }) catch
        return null;

    const dir = cli.parent_dir(path);
    if (dir.len > 0) {
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, dir, directory_mode) catch .existing;
    }
    const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .permissions = file_mode }) catch
        return null;
    // The page is shifted up by the scroll, because a screenshot can only be
    // taken from the top: the offset is what makes the picture scrollable.
    var style_buffer: [256]u8 = undefined;
    const style = std.fmt.bufPrint(&style_buffer, "<!doctype html><meta charset=utf-8>" ++
        "<style>body{{background:#fff;color:#111;font-family:sans-serif;margin:16px}}" ++
        "img{{max-width:100%}}#mail{{position:relative;top:-{d}px}}</style><div id=\"mail\">", .{offset_px}) catch
        return null;
    file.writeStreamingAll(self.io, style) catch {};
    file.writeStreamingAll(self.io, html) catch {};
    file.writeStreamingAll(self.io, "</div>") catch {};
    file.close(self.io);
    return path;
}

const max_accounts = core.config.max_accounts;

/// One configured account, connected on demand.
///
/// Nothing here touches the network until a port call arrives: with a warm
/// cache the first frame is painted without a socket, and a connection that
/// fails becomes an ordinary port error (cached mail stays readable) instead of
/// a reason not to start.
/// What a config entry says about an account, copied into the live one that will run
/// it. The SMTP half is only filled when the entry has a server: an account that can
/// read but not send leaves those fields empty.
fn wire_account(
    account: *LiveAccount,
    gpa: std.mem.Allocator,
    io: std.Io,
    id: core.id.AccountId,
    entry: *const core.config.Entry,
) void {
    account.gpa = gpa;
    account.io = io;
    account.id = id;
    account.from = entry.account.address;
    account.port = entry.account.imap.port;
    account.smtp_enabled = entry.smtp != null;
    account.label.set(entry.label.slice());
    account.host.set(entry.account.imap.host.slice());
    account.username.set(entry.account.username.slice());
    if (entry.smtp) |smtp| {
        account.smtp_host.set(smtp.host.slice());
        // The port the security can work on, here as everywhere: implicit TLS on
        // 587 is a handshake nobody answers, and STARTTLS is a plaintext first leg.
        account.smtp_starttls = smtp.security == .starttls;
        account.smtp_port = if (account.smtp_starttls) smtp.port else core.account.dialPort(smtp);
    }
}

/// What the SMTP client needs to finish a STARTTLS exchange: the plaintext leg to
/// flush, the socket it leaves behind, and where to put the encrypted one.
const UpgradeContext = struct {
    account: *LiveAccount,
    host: []const u8,

    fn upgrade(context: *anyopaque) ?core.transport_port.Transport {
        const self: *UpgradeContext = @ptrCast(@alignCast(context));
        self.account.smtp_plain.flush();
        const stream = self.account.smtp_plain.detach();
        self.account.smtp_transport.adopt(
            self.account.gpa,
            self.account.io,
            self.host,
            stream,
        ) catch return null;
        return self.account.smtp_transport.transport();
    }
};

const LiveAccount = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    id: core.id.AccountId = .unknown,
    /// Owned, not borrowed: the config text outlives neither the loop nor the
    /// temporary entry it was parsed into.
    label: core.text.Text(core.limits.label_max) = .{},
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
    /// The plaintext leg of a STARTTLS exchange, alive only until the swap.
    smtp_plain: net.plain.PlainTransport = undefined,
    /// Whether TLS starts mid-conversation on this server's port.
    smtp_starttls: bool = false,
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
            self.failure = "No password for an account: run setup again or set ZMAIL_PASSWORD";
            return error.Unavailable;
        }

        self.imap_transport.open(self.gpa, self.io, self.host.slice(), self.port) catch {
            self.failure = "Could not connect to an IMAP server over TLS";
            return error.Unavailable;
        };
        const opened: core.imap.client.Error!void = if (self.token.access.is_empty())
            core.imap_mail.ImapMail.open(
                &self.imap,
                self.imap_transport.transport(),
                self.id,
                self.username.slice(),
                self.password.expose(),
            )
        else
            core.imap_mail.ImapMail.open_token(
                &self.imap,
                self.imap_transport.transport(),
                self.id,
                self.username.slice(),
                self.token.access.slice(),
            );
        opened catch |err| {
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

        if (self.smtp_starttls) {
            self.smtp_plain.open(self.io, self.smtp_host.slice(), self.smtp_port) catch
                return error.Unavailable;
            var upgrader: UpgradeContext = .{
                .account = self,
                .host = self.smtp_host.slice(),
            };
            self.smtp_client = core.smtp_outbox.SmtpOutbox.connect_starttls(
                self.smtp_plain.transport(),
                "localhost",
                self.username.slice(),
                self.password.expose(),
                UpgradeContext.upgrade,
                &upgrader,
                os.now_unix,
            ) catch {
                self.smtp_plain.flush();
                return error.Unavailable;
            };
        } else {
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
        }
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

// A `Live` is only a table of owned copies plus borrowed slices: the test below
// is what keeps those slices from pointing at a loop variable.
const testing = std.testing;

const Live = struct {
    accounts: [max_accounts]LiveAccount = undefined,
    len: u8 = 0,
    lazy_mail: [max_accounts]core.lazy_mail = undefined,
    lazy_outbox: [max_accounts]core.lazy_outbox = undefined,
    sources: [max_accounts]session_mod.MailSource = undefined,
    outboxes: [max_accounts]session_mod.OutboxSource = undefined,
    mail_count: u8 = 0,
    outbox_count: u8 = 0,

    /// Room for one more account, already cleared. The struct holds the IMAP
    /// client and its buffers, so it is built where it lives and never passed
    /// by value: copying it is what a stack overflow looks like.
    fn reserve(self: *Live, gpa: std.mem.Allocator, io: std.Io) ?*LiveAccount {
        if (self.len >= self.accounts.len) return null;
        const slot = &self.accounts[self.len];
        slot.* = .{ .gpa = gpa, .io = io };
        return slot;
    }

    fn add(self: *Live, account: *LiveAccount) void {
        const index = self.len;
        self.len += 1;
        const stored = account;

        self.lazy_mail[index] = .{
            .context = &self.accounts[index],
            .open_fn = LiveAccount.openMail,
            .close_fn = LiveAccount.closeMail,
        };
        self.sources[self.mail_count] = .{
            .id = stored.id,
            .label = stored.label.slice(),
            .from = stored.from,
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

        // Always initialised, even without SMTP: `close` walks accounts, not
        // outboxes, and an undefined slot is a function pointer into nowhere.
        self.lazy_outbox[index] = .{
            .context = &self.accounts[index],
            .open_fn = LiveAccount.openOutbox,
            .close_fn = LiveAccount.closeOutbox,
        };
        if (stored.smtp_enabled) {
            self.outboxes[self.outbox_count] = .{
                .id = stored.id,
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

/// `zmail send`: one message, no terminal, no cache. The exit code is the whole
/// answer -- 0 when the server took it, 1 when it did not -- so a script can
/// tell the difference between "sent" and "silently did nothing".
pub fn send(gpa: std.mem.Allocator, io: std.Io, request: cli.Send) !u8 {
    // A CLI that pipes nowhere still talks to an SMTP server that can go away.
    ignore_sigpipe();
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var body_buffer: [core.limits.body_max]u8 = undefined;
    var body: []const u8 = request.body;
    if (request.body_from_stdin) {
        body = read_stdin(io, &body_buffer) catch {
            try stderr.print("{s}: could not read the body from stdin\n", .{core.meta.name});
            return 1;
        };
    }

    const typed = cli.outgoing(request, body) catch {
        try stderr.print("{s}: --to is not an address\n", .{core.meta.name});
        return 1;
    };

    var path_buffer: [512]u8 = undefined;
    const path = config_path_in(&path_buffer, request.config_path);
    if (path.len == 0) {
        try stderr.print("{s}: no config path: pass --config or set XDG_CONFIG_HOME\n", .{core.meta.name});
        return 1;
    }

    var config_buffer: [8193]u8 = undefined;
    const config_text = read_file(io, path, &config_buffer) catch {
        try stderr.print("{s}: no config at {s}\n", .{ core.meta.name, path });
        return 1;
    };
    const file = core.config.parse(config_text) catch |err| {
        try stderr.print("{s}: {s}\n", .{ core.meta.name, config_message(err) });
        return 1;
    };
    const entry = pick_account(&file, request.from) orelse {
        try stderr.print("{s}: no account matches --from {s}\n", .{ core.meta.name, request.from });
        return 1;
    };
    if (entry.smtp == null) {
        try stderr.print("{s}: account {s} has no SMTP server\n", .{ core.meta.name, entry.label.slice() });
        return 1;
    }

    // One account, built where it lives: the struct carries an IMAP client and
    // buffers as large as the body limit.
    const live = gpa.create(Live) catch return 1;
    defer gpa.destroy(live);
    live.* = .{};
    defer live.close();

    const account = live.reserve(gpa, io) orelse return 1;
    wire_account(account, gpa, io, core.id.AccountId.from_int(1), entry);
    const smtp = entry.smtp.?;
    // A pair that cannot work -- implicit TLS on a plaintext submission port -- is
    // dialled as 465, which is the port the security the user chose means, and the
    // one line below says so instead of dialling a number nobody typed.
    if (smtp.security == .tls and core.account.portCorrected(smtp)) {
        try stderr.print("{s}: smtp_port {d} is a STARTTLS port; using 465 for implicit TLS\n", .{
            core.meta.name, smtp.port,
        });
    }
    account.smtp_host.set(smtp.host.slice());
    account.smtp_starttls = smtp.security == .starttls;
    account.smtp_port = if (account.smtp_starttls) smtp.port else core.account.dialPort(smtp);

    read_password(
        gpa,
        io,
        path,
        entry.label.slice(),
        file.len == 1,
        entry.password_command.slice(),
        &account.password,
    ) catch {};
    account.password_ready = !account.password.is_empty();
    live.add(account);

    if (!account.password_ready) {
        try stderr.print("{s}: no password for {s}\n", .{ core.meta.name, entry.label.slice() });
        return 1;
    }

    const outbox = LiveAccount.openOutbox(account) catch {
        try stderr.print("{s}: could not connect to {s}:{d}\n", .{
            core.meta.name, smtp.host.slice(), smtp.port,
        });
        return 1;
    };
    defer LiveAccount.closeOutbox(account);

    var message = typed;
    message.account = account.id;
    message.from = entry.account.address;
    outbox.send(&message) catch {
        try stderr.print("{s}: the server refused the message\n", .{core.meta.name});
        return 1;
    };
    return 0;
}

/// `zmail watch`: one look every so often, and a notification when the mail grows.
///
/// This is the process boundary, like `send`: a socket, a clock and a subprocess.
/// What it decides -- when a number is news, and what to call the message -- lives
/// in `core.watch`, with no clock and no socket, and is tested there.
pub fn watch(gpa: std.mem.Allocator, io: std.Io, request: cli.Watch) !u8 {
    ignore_sigpipe();
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var path_buffer: [512]u8 = undefined;
    const path = config_path_in(&path_buffer, request.config_path);
    if (path.len == 0) {
        try stderr.print("{s}: no config path: pass --config or set XDG_CONFIG_HOME\n", .{core.meta.name});
        return 1;
    }
    var config_buffer: [8193]u8 = undefined;
    const config_text = read_file(io, path, &config_buffer) catch {
        try stderr.print("{s}: no config at {s}\n", .{ core.meta.name, path });
        return 1;
    };
    const file = core.config.parse(config_text) catch |err| {
        try stderr.print("{s}: {s}\n", .{ core.meta.name, config_message(err) });
        return 1;
    };
    if (file.len == 0) {
        try stderr.print("{s}: no accounts in {s}\n", .{ core.meta.name, path });
        return 1;
    }

    // One detached process, no terminal: a watcher that needs a window is not a
    // watcher. The child is this same program with the same question.
    if (request.detach) return detach_watch(io, request, path);

    const live = gpa.create(Live) catch return 1;
    defer gpa.destroy(live);
    live.* = .{};
    defer live.close();

    var index: u8 = 0;
    while (index < file.len and index < max_accounts) : (index += 1) {
        const account = live.reserve(gpa, io) orelse break;
        const entry = &file.entries[index];
        wire_account(account, gpa, io, core.id.AccountId.from_int(index + 1), entry);
        read_password(
            gpa,
            io,
            path,
            entry.label.slice(),
            file.len == 1,
            entry.password_command.slice(),
            &account.password,
        ) catch {};
        account.password_ready = !account.password.is_empty();
        live.add(account);
    }

    var watcher: core.watch.Watcher = .{};
    var folders: [core.limits.mailboxes_max]core.mail_port.Listed = undefined;
    const scratch = gpa.alloc(core.message.Message, core.limits.messages_max) catch return 1;
    defer gpa.free(scratch);

    var notifier = Notifier{ .io = io };
    while (true) {
        var account_index: u8 = 0;
        while (account_index < live.mail_count) : (account_index += 1) {
            const source = live.sources[account_index];
            const label = source.label;

            const count = source.mail.folders(&folders) catch 0;
            const inbox = inbox_of(folders[0..count]) orelse continue;
            const unread = inbox.unread;

            // The mail itself only when there is more of it: a poll that fetches
            // every envelope every minute is a poll that keeps the server awake.
            var messages: []const core.message.Message = &.{};
            if (source.mail.fetch(.{ .mailbox = .inbox, .name = inbox.name }, scratch)) |fetched| {
                messages = scratch[0..fetched];
            } else |_| {}

            var reports: [core.watch.reports_max]core.message.Message = undefined;
            const growth = watcher.observe(source.id, label, unread, messages, &reports) orelse continue;

            if (request.once) {
                print_count(source.label, growth.unread);
                continue;
            }
            notifier.tell(&growth);
        }

        if (request.once) return 0;
        os.sleep_ms(@as(u64, request.interval_s) * 1000);
    }
}

/// The Inbox row of a folder list: the server may call it `INBOX` and flag it, or
/// call it something else and flag it; either way there is one.
fn inbox_of(listed: []const core.mail_port.Listed) ?core.mail_port.Listed {
    for (listed) |folder| {
        if (folder.canonical) |mailbox| {
            if (mailbox == .inbox) return folder;
        }
    }
    for (listed) |folder| {
        if (std.ascii.eqlIgnoreCase(folder.name, "INBOX")) return folder;
    }
    return null;
}

/// One line to standard output: what a cron job or a script reads.
fn print_count(label: []const u8, unread: u32) void {
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}: {d} unread\n", .{ label, unread }) catch return;
    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line) catch {};
}

/// The desktop notification: a command, no shell, and a fallback that is a line of
/// text when there is nothing to tell.
const Notifier = struct {
    io: std.Io,
    buffers: core.notify.Buffers = .{},

    fn tell(self: *Notifier, growth: *const core.watch.Growth) void {
        var title: [96]u8 = undefined;
        const summary = if (growth.reports.len > 0)
            std.fmt.bufPrint(&title, "{d} new in {s}", .{ growth.reports.len, growth.label }) catch growth.label
        else
            std.fmt.bufPrint(&title, "{d} unread in {s}", .{ growth.unread, growth.label }) catch growth.label;

        // The newest message names itself; a count with no name is still news.
        var body: [256]u8 = undefined;
        const text = if (growth.reports.len > 0) blk: {
            const message = growth.reports[0];
            break :blk std.fmt.bufPrint(&body, "{s} — {s}", .{
                message.from.label(),
                message.subject.slice(),
            }) catch "";
        } else "";

        const kind: core.notify.Kind = switch (@import("builtin").os.tag) {
            .macos => .osascript,
            else => .notify_send,
        };
        const command_line = core.notify.command(kind, summary, text, &self.buffers) catch return;
        _ = spawn_quiet(self.io, command_line.slice()) orelse {
            // No desktop to talk to: the line is the notification.
            var line: [320]u8 = undefined;
            const fallback = std.fmt.bufPrint(&line, "{s}: {s}\n", .{ summary, text }) catch return;
            std.Io.File.stdout().writeStreamingAll(self.io, fallback) catch {};
        };
    }
};

/// Runs a command with nothing attached, and says whether it worked. The only way
/// a program is ever started here: an argv list, never a string for a shell.
fn spawn_quiet(io: std.Io, argv: []const []const u8) ?void {
    if (argv.len == 0) return null;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const status = child.wait(io) catch return null;
    return switch (status) {
        .exited => |code| if (code == 0) {} else null,
        else => null,
    };
}

/// Same program, same question, no terminal: this one returns and the child goes on.
fn detach_watch(io: std.Io, request: cli.Watch, path: []const u8) u8 {
    var interval: [8]u8 = undefined;
    const seconds = std.fmt.bufPrint(&interval, "{d}", .{request.interval_s}) catch "60";
    const argv = [_][]const u8{
        core.meta.name, "watch", "--interval", seconds, "--config", path,
    };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return 1;
    _ = child.wait(io) catch return 1;
    return 0;
}

/// The account `--from` names: a label, or the address it sends from. Empty
/// means the first one, which is what a one-account config always wants.
fn pick_account(file: *const core.config.File, wanted: []const u8) ?*const core.config.Entry {
    if (file.len == 0) return null;
    if (wanted.len == 0) return &file.entries[0];

    for (file.items(), 0..) |*entry, index| {
        if (std.mem.eql(u8, entry.label.slice(), wanted)) return &file.entries[index];
        var buffer: [core.limits.address_max]u8 = undefined;
        if (std.mem.eql(u8, entry.account.address.addr_spec(&buffer), wanted)) return &file.entries[index];
    }
    return null;
}

/// Everything a pipe writes, up to the body limit. A larger message is
/// truncated like any other ingress rather than refused: half a diff is still
/// a diff, and refusing it would lose the mail.
fn read_stdin(io: std.Io, buffer: []u8) ![]const u8 {
    var file_buffer: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &file_buffer);
    var total: usize = 0;
    while (total < buffer.len) {
        const read = try reader.interface.readSliceShort(buffer[total..]);
        if (read == 0) break;
        total += read;
    }
    return buffer[0..total];
}

/// Where the config lives: what the command line said, or the usual place. Empty when
/// there is nowhere to look -- no `--config`, no `XDG_CONFIG_HOME`, no `HOME`.
fn config_path_in(buffer: *[512]u8, given: ?[]const u8) []const u8 {
    return config_path_from(buffer, given, os.env("XDG_CONFIG_HOME"), os.env("HOME"));
}

/// The same, with the environment handed in so a test can say what it is.
fn config_path_from(
    buffer: *[512]u8,
    given: ?[]const u8,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) []const u8 {
    if (given) |path| return path;
    return cli.default_config_path(buffer, xdg_config_home, home);
}

fn run_live(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = config_path_in(&path_buffer, options.config_path);
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
        return run_session(gpa, io, system, &.{}, &.{}, null, null, null, null, null, true, config_message(err));
    };
    if (file.len == 0) return .{ .message = "The config has no accounts" };

    // Four accounts' clients live in here, each with the IMAP framer and the
    // message being read: it does not belong on the stack.
    const live_ptr = gpa.create(Live) catch return .{ .message = "Not enough memory to start" };
    defer gpa.destroy(live_ptr);
    live_ptr.* = .{};
    const live = live_ptr;
    defer live.close();
    var missing_password: ?[]const u8 = null;

    for (file.items(), 0..) |entry, index_u| {
        const index: u8 = @intCast(index_u);
        // IMAP has no plaintext leg yet: reading starts encrypted or not at all.
        if (entry.account.imap.security != .tls) {
            return .{ .message = "Only implicit TLS (imap_security = tls) is supported today" };
        }

        // Built in place: the struct carries the client and its buffers.
        const account = live.reserve(gpa, io) orelse
            return .{ .message = "Too many accounts in one config file" };
        wire_account(account, gpa, io, core.id.AccountId.from_int(index + 1), &entry);
        read_password(gpa, io, path, entry.label.slice(), file.len == 1, entry.password_command.slice(), &account.password) catch {};
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
            missing_password = "No password for an account: set ZMAIL_PASSWORD or run the add-account command";
        }

        live.add(account);
    }

    // On-disk cache: startup and mailbox switches read from here, so the first
    // frame never waits for the network. `R` refreshes from the server.
    // Owned copies: a slice into the loop variable is stack memory the next
    // iteration overwrites, and every cache would read the last account's.
    var label_text: [max_accounts]core.text.Text(core.limits.label_max) = @splat(.{});
    var labels: [max_accounts]net.cache_file.Label = undefined;
    for (file.items(), 0..) |entry, index| {
        label_text[index].set(entry.label.slice());
        labels[index] = .{
            .id = core.id.AccountId.from_int(@intCast(index + 1)),
            .label = label_text[index].slice(),
        };
    }

    var cache_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&cache_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));

    // These two hold buffers as large as the message limit: they belong on the
    // heap, or the first big limit increase becomes a stack overflow.
    const file_cache = gpa.create(net.cache_file.FileCache) catch
        return .{ .message = "Not enough memory to start" };
    defer gpa.destroy(file_cache);
    var cache: ?core.cache_port.Cache = null;
    const file_bodies = gpa.create(net.bodies.FileBodies) catch
        return .{ .message = "Not enough memory to start" };
    defer gpa.destroy(file_bodies);
    var bodies: ?core.bodies_port.BodyCache = null;
    if (cache_dir.len > 0) {
        file_cache.* = net.cache_file.FileCache.init(gpa, io, cache_dir, labels[0..file.len]);
        cache = file_cache.cache();
        file_bodies.* = net.bodies.FileBodies.init(gpa, io, cache_dir, labels[0..file.len]);
        bodies = file_bodies.cache();
    }

    var accounts_file = FileAccounts{ .io = io, .path = path, .system = system, .gpa = gpa };
    var preference = FileScope{ .io = io, .config_path = path };
    var chosen = FilePrefs{ .io = io, .config_path = path };
    const account_port: ?core.accounts_port.Accounts = if (live.len > 0) accounts_file.accounts() else null;

    const outcome = run_session(
        gpa,
        io,
        system,
        live.sources[0..live.mail_count],
        live.outboxes[0..live.outbox_count],
        cache,
        bodies,
        account_port,
        preference.scope(),
        chosen.prefs(),
        true,
        missing_password,
    );
    if (outcome != null) return outcome;
    // A connection that never worked left nothing on screen: say why.
    if (live.firstFailure()) |reason| return .{ .message = reason };
    return null;
}

fn read_password(
    gpa: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    label: []const u8,
    allow_env: bool,
    password_command: []const u8,
    out: *core.secret.Secret,
) !void {
    var buffer: [1024]u8 = undefined;
    var path_buffer: [512]u8 = undefined;

    const path = cli.credential_path(config_path, label, &path_buffer);

    // An account that names a command has said where its password lives: ask
    // it first, and never write the answer to disk. The command stays the one
    // source of truth (`pass` can rotate a password behind our back).
    if (password_command.len > 0 and run_password_command(gpa, io, password_command, out)) return;

    // The environment wins: it is how a password is set or repaired without
    // trusting whatever is on disk, and it re-seals itself for next time.
    if (allow_env) {
        if (os.env("ZMAIL_PASSWORD")) |value| {
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
        if (os.env("ZMAIL_PASSWORD")) |value| {
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

/// Runs an account's `password_command` and takes its first line as the
/// password. argv only, so nothing in the config can become a shell script;
/// a command that fails, or prints something that is not a password, leaves
/// the account without one rather than with a guess.
fn run_password_command(
    gpa: std.mem.Allocator,
    io: std.Io,
    command_line: []const u8,
    out: *core.secret.Secret,
) bool {
    var argv: core.config.Argv = .{};
    core.config.split_argv(command_line, &argv) catch return false;
    if (argv.len == 0) return false;

    const result = std.process.run(gpa, io, .{
        .argv = argv.slice(),
        .stdout_limit = .limited(core.limits.secret_max),
        .stderr_limit = .limited(256),
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return false;

    const password = std.mem.trimEnd(u8, result.stdout, "\r\n");
    if (!looks_like_password(password)) return false;
    core.secret.Secret.init(password, out) catch return false;
    return true;
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
    const path = config_path_in(&path_buffer, options.config_path);
    if (path.len == 0) return .{ .message = "No config path" };

    var buffer: [8193]u8 = undefined;
    const text = read_file(io, path, &buffer) catch
        return .{ .message = no_config };
    const file = core.config.parse(text) catch |err| return .{ .message = config_message(err) };
    if (file.len == 0) return .{ .message = "The config has no accounts" };

    const entry = file.items()[0];
    const provider = provider_for(entry.account.imap.host.slice());
    if (provider == .custom) {
        return .{ .message = "That host is not a known OAuth2 provider (Microsoft or Google)" };
    }

    const client_id = if (entry.oauth_client_id.is_empty())
        (os.env("ZMAIL_OAUTH_CLIENT_ID") orelse "")
    else
        entry.oauth_client_id.slice();
    // Optional: without one we can still print the URL the user must build.
    if (client_id.len == 0) {
        return .{ .message = "Add oauth_client_id to the config (or set ZMAIL_OAUTH_CLIENT_ID)" };
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
    var problem: core.text.Text(256) = .{};
    net.oauth_flow.run(gpa, io, .{
        .provider = provider,
        .tenant = if (entry.oauth_tenant.len > 0) entry.oauth_tenant.slice() else "common",
        .client_id = client_id,
        .problem = &problem,
        .write = Io.write,
        .read = Io.read,
        .context = &callbacks,
    }, &token) catch |err| return .{ .message = blk: {
        if (!problem.is_empty()) break :blk problem.slice();
        break :blk switch (err) {
            error.Cancelled => "No authorization code in that URL: paste the whole address",
            else => "OAuth failed: check the client id, the redirect URI and try again",
        };
    } };

    write_token(io, path, entry.label.slice(), &token) catch
        return .{ .message = "Could not save the token" };
    std.debug.print("{s}: signed in {s}\n", .{ core.meta.name, entry.label.slice() });
    return null;
}

/// `--password`: one prompt, sealed, done. The escape hatch when the stored
/// credential cannot be opened (a wiped key, a moved config).
fn run_set_password(io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = config_path_in(&path_buffer, options.config_path);
    if (path.len == 0) return .{ .message = "No config path" };

    var config_buffer: [8193]u8 = undefined;
    const text = read_file(io, path, &config_buffer) catch
        return .{ .message = no_config };
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
    std.debug.print("{s}: password saved for {s}\n", .{ core.meta.name, label });
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

    try make_parent(io, path);

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
            read_password(
                self.gpa,
                self.io,
                self.path,
                entry.label.slice(),
                file.len == 1,
                entry.password_command.slice(),
                &password,
            ) catch return error.Unavailable;
        }

        self.transport.open(self.gpa, self.io, entry.account.imap.host.slice(), entry.account.imap.port) catch
            return error.Unavailable;
        const opened: core.imap.client.Error!void = if (fresh and has_token != null)
            core.imap_mail.ImapMail.open_token(
                &self.imap,
                self.transport.transport(),
                account,
                entry.account.username.slice(),
                has_token.?.access.slice(),
            )
        else
            core.imap_mail.ImapMail.open(
                &self.imap,
                self.transport.transport(),
                account,
                entry.account.username.slice(),
                password.expose(),
            );
        opened catch |err| {
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

    fn oauthThunk(
        context: *anyopaque,
        account: core.id.AccountId,
        problem: *core.text.Text(256),
    ) core.accounts_port.Error!void {
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
        if (client_id.len == 0) {
            problem.set("OAuth needs a Client ID: set it under Advanced in the account form");
            return error.Unavailable;
        }
        // Microsoft needs the tenant that matches the app registration:
        // `common`, `consumers`, `organizations`, or the tenant id.
        const tenant = if (entry.oauth_tenant.len > 0) entry.oauth_tenant.slice() else "common";

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
            .tenant = tenant,
            .client_id = client_id,
            .problem = problem,
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
            else => {
                refuse(draft, "Could not read the config file");
                return error.Unavailable;
            },
        };
        const existing = core.config.parse(text) catch |err| {
            refuse(draft, config_message(err));
            return error.Unavailable;
        };

        if (draft.replaces) |account| {
            // Replace in place: drop the old section, then append the new one.
            const index: usize = @intCast(account.to_int() - 1);
            if (index >= existing.len) {
                refuse(draft, "That account is no longer in the config file");
                return error.Unavailable;
            }
            var kept_buffer: [8193]u8 = undefined;
            const kept = core.config.without(text, existing.items()[index].label.slice(), &kept_buffer);
            write_file(self.io, self.path, kept) catch {
                refuse(draft, "Could not write the config file");
                return error.Unavailable;
            };
        }

        // A taken label is not a dead end: pick the next free one and say so.
        var label_buffer: [core.limits.label_max]u8 = undefined;
        var final_label = draft.label;
        var text_to_append = draft.text;
        if (draft.replaces == null and core.config.has_label(text, draft.label)) {
            const unique = core.config.unique_label(text, draft.label, &label_buffer);
            if (unique.len == 0) {
                refuse(draft, "Too many accounts with that name: rename one of them");
                return error.Unavailable;
            }
            var rewritten: [8193]u8 = undefined;
            text_to_append = core.config.rename_label(draft.text, draft.label, unique, &rewritten);
            if (text_to_append.len == 0) {
                refuse(draft, "Could not rename the account");
                return error.Unavailable;
            }
            final_label = unique;
        }
        if (draft.label_out) |out| out.set(final_label);

        append_file(self.io, self.path, text_to_append) catch |err| {
            refuse(draft, if (err == error.AccessDenied)
                "No permission to write the config file"
            else
                "Could not write the config file");
            return error.Unavailable;
        };
        // No password in the draft means "keep the one on disk".
        if (draft.password) |password| {
            write_credential_bytes(self.io, self.path, final_label, password) catch {
                refuse(draft, "Could not write the sealed credential file");
                return error.Unavailable;
            };
        }

        // The new account's id is its position in the file.
        if (draft.replaces) |account| return account;
        return core.id.AccountId.from_int(@intCast(existing.len + 1));
    }
};

/// Puts the reason for a refusal where the form can show it.
fn refuse(draft: core.accounts_port.Accounts.Draft, message: []const u8) void {
    if (draft.problem) |slot| slot.set(message);
}

/// `--add-account`: ask for one more account and append it to the config.
/// Existing accounts, their credentials, and their cache are untouched.
fn run_add_account(io: std.Io, options: cli.Launch, system: SessionSystem) ?Failure {
    var path_buffer: [512]u8 = undefined;
    const path = config_path_in(&path_buffer, options.config_path);
    if (path.len == 0) {
        return .{ .message = "No config path: pass --config or set XDG_CONFIG_HOME" };
    }

    var config_buffer: [8193]u8 = undefined;
    const existing = read_file(io, path, &config_buffer) catch |err| switch (err) {
        error.FileNotFound => return .{ .message = no_config },
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

    std.debug.print("{s}: added account \"{s}\"\n", .{ core.meta.name, saved.label.slice() });
    return null;
}

fn append_file(io: std.Io, path: []const u8, text: []const u8) !void {
    // The very first save creates the directory too: without this a fresh
    // install failed with a message that named no cause.
    const dir = cli.parent_dir(path);
    if (dir.len > 0) {
        _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, directory_mode) catch .existing;
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const size = try file.stat(io);
    const separator = if (size.size > 0) "\n" else "";
    try file.writePositionalAll(io, separator, size.size);
    try file.writePositionalAll(io, text, size.size + separator.len);
}

/// The password, sealed with the cache key, in the credential file beside the
/// config (0600). No secret is ever written in the clear: the key file is the
/// trust boundary, see docs/SECURITY.
fn seal_credential(io: std.Io, config_path: []const u8, label: []const u8, password: []const u8) !void {
    var credential_buffer: [512]u8 = undefined;
    const credential = cli.credential_path(config_path, label, &credential_buffer);
    if (credential.len == 0) return error.NameTooLong;
    try make_parent(io, credential);

    var cache_buffer: [512]u8 = undefined;
    const cache_dir = cli.default_cache_dir(&cache_buffer, os.env("XDG_CACHE_HOME"), os.env("HOME"));
    if (cache_dir.len == 0) return error.NameTooLong;

    var keys = net.keyfile.KeyFile.init(undefined, io, cache_dir);
    const key = keys.get() orelse return error.NameTooLong;

    var sealed_buffer: [core.limits.secret_max + core.sealed.overhead]u8 = undefined;
    var nonce: core.sealed.Nonce = undefined;
    io.random(&nonce);
    const sealed_password = try core.sealed.seal(key, nonce, password, &sealed_buffer);
    try write_file(io, credential, sealed_password);
}

fn write_credential(io: std.Io, config_path: []const u8, saved: *const setup_session.Saved) !void {
    try seal_credential(io, config_path, saved.label.slice(), saved.password.expose());
}

fn write_setup_files(io: std.Io, config_path: []const u8, saved: *const setup_session.Saved) !void {
    try make_parent(io, config_path);
    try write_file(io, config_path, saved.config_text());
    try seal_credential(io, config_path, saved.label.slice(), saved.password.expose());
}

/// Creates the directory a path lives in, if it is not there already.
fn make_parent(io: std.Io, path: []const u8) !void {
    const dir = cli.parent_dir(path);
    if (dir.len == 0) return;
    std.Io.Dir.cwd().createDir(io, dir, directory_mode) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
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
        error.PasswordInConfig => "Remove the password from the config; use ZMAIL_PASSWORD",
        error.UnknownKey => "Unknown key in the config file",
        error.MissingKey => "Missing required key in the config file",
        error.InvalidValue, error.MissingEquals => "Invalid line in the config file",
        error.PlaintextForbidden => "Plaintext IMAP needs allow_plaintext = true",
        error.InvalidHost, error.EmptyHost => "Invalid imap_host in the config file",
        error.InvalidPort => "Invalid imap_port in the config file",
        error.DuplicateLabel => "Two accounts share a name: rename one of the [account ...] sections",
        error.InvalidLabel => "An [account ...] name has characters that cannot be used",
        error.UnknownSection => "Unknown section in the config file",
        error.MixedFormat => "The config mixes one-account and multi-account styles",
        error.TooManyAccounts => "Too many accounts in one config file",
        error.TooLong => "The config has a value that is too long",
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
        error.LoginFailed => "Login failed: check username and ZMAIL_PASSWORD",
        error.Unavailable => "The IMAP server could not be reached",
        error.Timeout => "The IMAP server stopped responding",
        else => "The IMAP server refused the session",
    };
}

/// The colour behind the text, asked once at startup. Everything the theme
/// needs is derived from it; when the terminal does not say, the built-in
/// palette is used instead of a guess.
var background: ?core.oklch.Rgb = null;

fn theme_for_environment() theme_mod.Theme {
    if (os.env("NO_COLOR") != null) return theme_mod.Theme.mono();
    if (os.env("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return theme_mod.Theme.mono();
    }
    return theme_mod.Theme.detect(false, background);
}

test "Live keeps one label per account, not the last one parsed" {
    // The real one lives on the heap (four clients' buffers); a test can afford
    // the stack, and it says what it needs.
    var live: Live = .{};
    defer live.close();

    // Exactly what run_live does: build in place from a temporary label, add,
    // then let the temporary go.
    for ([_][]const u8{ "work", "home" }, 0..) |wanted, index| {
        var entry_label: core.text.Text(core.limits.label_max) = .{};
        entry_label.set(wanted);
        const account = live.reserve(testing.allocator, undefined) orelse unreachable;
        account.id = core.id.AccountId.from_int(@intCast(index + 1));
        account.label.set(entry_label.slice());
        live.add(account);
    }

    try testing.expectEqualStrings("work", live.sources[0].label);
    try testing.expectEqualStrings("home", live.sources[1].label);
}

test "the config path: what was asked for, then the environment" {
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "/given/config",
        config_path_from(&buffer, "/given/config", "/xdg", "/home/me"),
    );
    try testing.expectEqualStrings(
        "/xdg/zmail/config",
        config_path_from(&buffer, null, "/xdg", "/home/me"),
    );
    try testing.expectEqualStrings(
        "/home/me/.config/zmail/config",
        config_path_from(&buffer, null, null, "/home/me"),
    );
    // Nothing to go on: the caller says so, rather than looking in the dark.
    try testing.expectEqualStrings("", config_path_from(&buffer, null, null, null));
    // And the wrapper is only the environment, read once.
    try testing.expectEqualStrings("/given/config", config_path_in(&buffer, "/given/config"));
}

test "an account is wired from its config entry, SMTP only when there is one" {
    const file = try core.config.parse(
        \\[account work]
        \\address = me@work.example
        \\imap_host = imap.work.example
        \\imap_port = 993
        \\imap_security = tls
        \\username = me
        \\smtp_host = smtp.work.example
        \\smtp_port = 465
        \\smtp_security = tls
    );
    var account: LiveAccount = .{ .gpa = testing.allocator, .io = undefined };
    wire_account(&account, testing.allocator, undefined, core.id.AccountId.from_int(2), &file.items()[0]);
    try testing.expectEqual(core.id.AccountId.from_int(2), account.id);
    try testing.expectEqualStrings("work", account.label.slice());
    try testing.expectEqualStrings("imap.work.example", account.host.slice());
    try testing.expectEqualStrings("smtp.work.example", account.smtp_host.slice());
    try testing.expectEqual(@as(u16, 465), account.smtp_port);
    try testing.expect(account.smtp_enabled);

    // No SMTP server: the account reads, and does not claim it can send.
    const read_only = try core.config.parse(
        \\[account home]
        \\address = me@home.example
        \\imap_host = imap.home.example
        \\imap_port = 993
        \\imap_security = tls
        \\username = me
    );
    var other: LiveAccount = .{ .gpa = testing.allocator, .io = undefined };
    wire_account(&other, testing.allocator, undefined, core.id.AccountId.from_int(1), &read_only.items()[0]);
    try testing.expect(!other.smtp_enabled);
    try testing.expectEqual(@as(u16, 0), other.smtp_port);
}
