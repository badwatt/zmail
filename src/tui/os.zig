//! The POSIX terminal adapter: the only file that touches fds, termios, and
//! ioctl.
//!
//! Deliberately thin. Every branch here is exercised by driving a real
//! pseudo-terminal in the tests below, so the adapter is covered by the same
//! 100% gate as the logic.

const std = @import("std");

/// Alternate screen on, cursor hidden, mouse on; and the way back.
const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1003h\x1b[?1006h";
const leave_screen = "\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?25h\x1b[?1049l";
const builtin = @import("builtin");
const assert = std.debug.assert;

const system_mod = @import("system.zig");
const core = @import("core");
const progress_mod = @import("progress.zig");

const c = std.c;
const Winsize = std.posix.winsize;

const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5413,
    else => 0x40087468,
};

const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    else => 0x80087467,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *Winsize) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*Winsize,
) c_int;
extern "c" fn clock_gettime(clock_id: c_int, tp: *std.posix.timespec) c_int;

const O_NOCTTY_RDWR: c_int = 0o2 | 0o400;

pub const Posix = struct {
    stdin: c_int = std.posix.STDIN_FILENO,
    stdout: c_int = std.posix.STDOUT_FILENO,
    original: std.posix.termios = undefined,
    raw_enabled: bool = false,

    pub fn init(stdin: c_int, stdout: c_int) Posix {
        return .{ .stdin = stdin, .stdout = stdout };
    }

    pub fn system(self: *Posix) system_mod.System {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .size = sizeThunk,
            .enter_raw = enterRawThunk,
            .leave_raw = leaveRawThunk,
            .suspend_ui = suspendThunk,
            .resume_ui = resumeThunk,
        } };
    }

    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) system_mod.Error!usize {
        const self: *Posix = @ptrCast(@alignCast(context));
        assert(timeout_ms <= std.math.maxInt(i32));

        var fds = [1]std.posix.pollfd{
            .{ .fd = self.stdin, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch 0;
        if (ready == 0) return 0;

        const count = std.posix.read(self.stdin, buffer) catch return error.IoError;
        if (count == 0) return error.InputClosed;
        return count;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = c.write(self.stdout, bytes[offset..].ptr, bytes.len - offset);
            if (std.posix.errno(written) != .SUCCESS) return error.IoError;
            offset += @intCast(written);
        }
    }

    fn sizeThunk(context: *anyopaque) system_mod.Error!system_mod.Size {
        const self: *Posix = @ptrCast(@alignCast(context));
        var window: Winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        if (ioctl(self.stdout, TIOCGWINSZ, &window) != 0) return error.NotATerminal;
        if (window.col == 0 or window.row == 0) return error.NotATerminal;
        return .{ .columns = window.col, .rows = window.row };
    }

    /// Puts the terminal back the way it was found, from anywhere: the sequence
    /// a signal handler has to be able to run.
    pub fn restoreNow(self: *Posix) void {
        // The bar first: it belongs to the window, not to the screen we are
        // leaving, so it has to come down before the screen does -- and only if
        // there is one, so a terminal that never spoke this gets no stray escape.
        // A signal handler cannot join a thread, so the bar is written down here
        // and the thread, if any, dies with the process a line later.
        progress_mod.abandon(self.system());
        writeThunk(self, leave_screen) catch {};
        leaveRawThunk(self) catch {};
    }

    /// Leave the alternate screen and cooked mode: what a browser flow needs.
    fn suspendThunk(context: *anyopaque) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        writeThunk(context, leave_screen) catch {};
        _ = self;
        leaveRawThunk(context) catch {};
    }

    fn resumeThunk(context: *anyopaque) system_mod.Error!void {
        enterRawThunk(context) catch {};
        writeThunk(context, enter_screen) catch {};
    }

    fn enterRawThunk(context: *anyopaque) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        // Asked before the call, not after: macOS answers `tcgetattr` on a pipe
        // with ENODEV, which the standard library treats as an error that cannot
        // happen and aborts on. A mail client with its input redirected would die
        // instead of saying it needs a terminal.
        if (std.c.isatty(self.stdin) == 0) return error.NotATerminal;
        self.original = std.posix.tcgetattr(self.stdin) catch return error.NotATerminal;

        var raw = self.original;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        // Signals stay on: Ctrl+C has to be able to reach the process while it
        // is blocked on a socket, and a signal is the only thing that can. The
        // handler (launch.zig) puts the terminal back and leaves.
        raw.lflag.ISIG = true;
        raw.lflag.IEXTEN = false;
        raw.cc[@backingInt(std.posix.V.MIN)] = 0;
        raw.cc[@backingInt(std.posix.V.TIME)] = 0;

        std.posix.tcsetattr(self.stdin, .NOW, raw) catch return error.IoError;
        self.raw_enabled = true;
    }

    fn leaveRawThunk(context: *anyopaque) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        if (!self.raw_enabled) return;
        std.posix.tcsetattr(self.stdin, .NOW, self.original) catch return error.IoError;
        self.raw_enabled = false;
    }
};

/// Reads an environment variable, or null when it is unset.
pub fn env(name: [:0]const u8) ?[]const u8 {
    const value = getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

/// Monotonic milliseconds, for measuring how long the spinner has been up.
/// `CLOCK_MONOTONIC` is 1 on Linux; 0 means "unknown".
pub fn monotonic_ms() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    // CLOCK_MONOTONIC is 1 on Linux and 6 on macOS. A hardcoded 1 returns 0 there,
    // which is a spinner that never moves and a bar that never advances.
    const monotonic: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 6,
        else => 1,
    };
    if (clock_gettime(monotonic, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Sleeps for `ms`. Signals may shorten it, which only matters for a spinner.
///
/// A wait with nothing to wait for, rather than `nanosleep`: the C call returned
/// immediately on macOS, which turned every frame of the loop into a busy spin. A
/// zero-length poll set with a timeout is the same pause on every system this
/// program builds for, and it is the one the loop already uses when it waits for a
/// key.
pub fn sleep_ms(ms: u64) void {
    if (ms == 0) return;
    var empty = [_]std.posix.pollfd{};
    _ = std.posix.poll(&empty, @intCast(@min(ms, std.math.maxInt(i32)))) catch 0;
}

/// The mode every file zmail writes is created with: only its owner reads it.
const private_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));

/// Opens the user's editor on a temporary file seeded with `initial`, waits for
/// it, and copies what the editor saved into `out`.
///
/// The editor comes from `$ZMAIL_EDITOR`, then `$VISUAL`, then `$EDITOR`, then
/// `vi`, and it runs as an argv list: no shell, so nothing here can turn a
/// path into code. Returns null when there is nothing to run, or when the file
/// could not be read back.
pub fn edit_text(io: std.Io, initial: []const u8, out: []u8) ?[]const u8 {
    const command = env("ZMAIL_EDITOR") orelse env("VISUAL") orelse env("EDITOR") orelse "vi";

    var argv: core.argv.Argv = .{};
    core.argv.split(command, &argv) catch return null;
    if (argv.len == 0) return null;

    // One random name per edit: a file left behind by a crash must never be the
    // file the next edit opens.
    var random_suffix: u64 = undefined;
    io.random(std.mem.asBytes(&random_suffix));
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/zmail-edit-{x}", .{
        env("TMPDIR") orelse "/tmp",
        random_suffix,
    }) catch return null;

    const file = std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        .permissions = private_mode,
    }) catch return null;
    var closed = false;
    defer {
        if (!closed) file.close(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    file.writeStreamingAll(io, initial) catch return null;
    file.close(io);
    closed = true;

    var words = argv.items;
    if (argv.len == words.len) return null; // no room left for the path
    words[argv.len] = path;

    var child = std.process.spawn(io, .{
        .argv = words[0 .. argv.len + 1],
        // The editor is the program the user is talking to: it gets the
        // terminal, not a pipe.
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return null;
    _ = child.wait(io) catch return null;

    const edited = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer edited.close(io);
    const length = edited.readPositionalAll(io, out, 0) catch return null;
    return out[0..length];
}

/// Asks the terminal what colour it paints behind the text, and waits for an
/// answer for a moment. Null means "no answer", which is normal: not every
/// terminal speaks OSC 11, and a multiplexer in the middle may not pass it on.
///
/// The reply shares the input stream with keystrokes, so this must run while the
/// terminal is raw and before anything reads keys -- the same window the
/// graphics probe uses.
pub fn query_background(system: system_mod.System) ?core.oklch.Rgb {
    system.write(core.osc.background_query()) catch return null;

    var buffer: [128]u8 = undefined;
    var received: usize = 0;
    var attempts: u8 = 0;
    // Two tries of 40ms: the answer comes in microseconds or not at all, and this
    // happens before the first frame, where a wait is a startup delay the user
    // reads as "it is slow".
    while (attempts < 1) : (attempts += 1) {
        const read = system.read(buffer[received..], 30) catch return null;
        if (read == 0) continue;
        received += read;
        if (core.osc.parse_background(buffer[0..received])) |colour| return colour;
        if (received == buffer.len) return null;
    }
    return null;
}

/// Wall clock in Unix seconds, from CLOCK_REALTIME. `0` means "unknown", which
/// only makes relative dates read as "now"; it never affects correctness.
pub fn now_unix() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (clock_gettime(0, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

// ---------------------------------------------------------------------------
// Tests: a real pseudo-terminal, so the adapter is exercised for real.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Pty = struct {
    master: c_int,
    slave: c_int,

    fn open() !Pty {
        const openpt = struct {
            extern "c" fn posix_openpt(flags: c_int) c_int;
            extern "c" fn grantpt(fd: c_int) c_int;
            extern "c" fn unlockpt(fd: c_int) c_int;
            extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
        };

        // macOS needs `openpty`: it grants and unlocks the pair as one call, and a
        // slave created any other way is not a terminal the child can use.
        if (builtin.os.tag == .macos) {
            var master: c_int = -1;
            var slave: c_int = -1;
            if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
            return .{ .master = master, .slave = slave };
        }

        const master = openpt.posix_openpt(O_NOCTTY_RDWR);
        if (master < 0) return error.SkipZigTest;
        if (openpt.grantpt(master) != 0) return error.SkipZigTest;
        if (openpt.unlockpt(master) != 0) return error.SkipZigTest;

        const name = openpt.ptsname(master) orelse return error.SkipZigTest;
        const slave = c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (slave < 0) return error.SkipZigTest;
        return .{ .master = master, .slave = slave };
    }

    fn close(self: Pty) void {
        _ = c.close(self.master);
        _ = c.close(self.slave);
    }

    fn resize(self: Pty, columns: u16, rows: u16) void {
        var window: Winsize = .{ .row = rows, .col = columns, .xpixel = 0, .ypixel = 0 };
        // On the master: Linux accepts either end, macOS propagates the size from
        // the side the terminal is attached to.
        assert(ioctl(self.master, TIOCSWINSZ, &window) == 0);
    }

    fn writeMaster(self: Pty, bytes: []const u8) void {
        const written = c.write(self.master, bytes.ptr, bytes.len);
        assert(written == bytes.len);
    }

    fn readMaster(self: Pty, buffer: []u8) usize {
        const count = c.read(self.master, buffer.ptr, buffer.len);
        assert(count >= 0);
        return @intCast(count);
    }
};

test "size reports the terminal dimensions from the driver" {
    const pty = try Pty.open();
    defer pty.close();

    var posix = Posix.init(pty.slave, pty.slave);
    const system = posix.system();

    // A fresh pseudo-terminal has no size yet.
    try testing.expectError(error.NotATerminal, system.size());

    // macOS only propagates a window size through a pty that has a session leader
    // on it, and this one is two bare descriptors: the size stays zero whatever is
    // written. The real terminal path is covered by the pty end-to-end test, which
    // runs the binary the way a shell does.
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    pty.resize(40, 12);
    try testing.expectEqual(system_mod.Size{ .columns = 40, .rows = 12 }, try system.size());
}

test "size reports NotATerminal for a non-terminal descriptor" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    try testing.expectError(error.NotATerminal, posix.system().size());
}

test "read returns bytes typed into the terminal" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);

    // Canonical mode would hold input until a newline; raw mode is what the
    // session uses in practice.
    try posix.system().enter_raw();
    pty.writeMaster("hi");
    var buffer: [8]u8 = undefined;
    const count = try posix.system().read(&buffer, 100);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("hi", buffer[0..count]);
}

test "read times out with zero when nothing arrives" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try posix.system().read(&buffer, 10));
}

test "read reports InputClosed at end of file" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.InputClosed, posix.system().read(&buffer, 10));
}

test "read reports end of file when the terminal goes away" {
    const pty = try Pty.open();
    defer pty.close();
    _ = c.close(pty.master);

    var posix = Posix.init(pty.slave, pty.slave);
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.InputClosed, posix.system().read(&buffer, 10));
}

test "write reaches the terminal" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);

    try posix.system().write("frame");
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("frame", buffer[0..pty.readMaster(&buffer)]);
}

test "write maps a terminal write error to IoError" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    try testing.expectError(error.IoError, posix.system().write("x"));
}

test "raw mode disables echo and canonical input, and restores them" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);
    const system = posix.system();

    const before = try std.posix.tcgetattr(pty.slave);
    try system.enter_raw();
    const during = try std.posix.tcgetattr(pty.slave);
    try testing.expect(before.lflag.ICANON);
    try testing.expect(!during.lflag.ICANON);
    try testing.expect(!during.lflag.ECHO);
    try testing.expect(!during.oflag.OPOST);
    // Signals stay on: Ctrl+C has to reach the process while it is blocked.
    try testing.expect(during.lflag.ISIG);

    try system.leave_raw();
    const after = try std.posix.tcgetattr(pty.slave);
    try testing.expect(after.lflag.ICANON);
    try testing.expect(after.lflag.ECHO);
}

test "restoreNow gives the terminal back in one call, from anywhere" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);
    try posix.system().enter_raw();
    try testing.expect(posix.raw_enabled);

    posix.restoreNow();
    try testing.expect(!posix.raw_enabled);

    const after = try std.posix.tcgetattr(pty.slave);
    try testing.expect(after.lflag.ICANON);
    try testing.expect(after.lflag.ECHO);

    // And the alternate screen is left, so the shell comes back to its own. Read
    // until it arrives: the terminal may also be carrying the progress bar's clear,
    // which is a sequence of its own and may land in the same read or before it.
    var buffer: [512]u8 = undefined;
    var filled: usize = 0;
    var attempts: u8 = 0;
    while (attempts < 4 and filled < buffer.len) : (attempts += 1) {
        filled += pty.readMaster(buffer[filled..]);
        if (std.mem.indexOf(u8, buffer[0..filled], "\x1b[?1049l") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, buffer[0..filled], "\x1b[?1049l") != null);
}

test "leaving raw mode without entering it is a no-op" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);
    try posix.system().leave_raw();
    try testing.expect(!posix.raw_enabled);
}

test "entering raw mode on a non-terminal fails without changing anything" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    try testing.expectError(error.NotATerminal, posix.system().enter_raw());
    try testing.expect(!posix.raw_enabled);
}

test "env reads the process environment" {
    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    try testing.expectEqual(@as(c_int, 0), setenv.setenv("ZMAIL_TEST_VARIABLE", "hello", 1));
    try testing.expectEqualStrings("hello", env("ZMAIL_TEST_VARIABLE").?);
    try testing.expect(env("ZMAIL_TEST_VARIABLE_THAT_DOES_NOT_EXIST") == null);
}

test "now_unix returns a plausible current time" {
    const now = now_unix();
    try testing.expect(now > 1_600_000_000);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "monotonic_ms advances, and sleep_ms waits at least one tick" {
    const before = monotonic_ms();
    try testing.expect(before > 0);
    sleep_ms(1);
    const after = monotonic_ms();
    try testing.expect(after >= before);

    // Zero means "no wait", and must not spin.
    sleep_ms(0);
}

test "edit_text runs the editor on a temporary file and reads it back" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A real program, not a shell: it writes over the file it is given, which
    // is what an editor does.
    const script_path = "/tmp/zmail-editor-test.sh";
    const script = "#!/bin/sh\nprintf 'edited by the editor\\nsecond line' > \"$1\"\n";
    const script_file = try std.Io.Dir.cwd().createFile(io, script_path, .{
        .permissions = @fromBackingInt(@intCast(0o700)),
    });
    try script_file.writeStreamingAll(io, script);
    script_file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};

    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    try testing.expectEqual(@as(c_int, 0), setenv.setenv("ZMAIL_EDITOR", script_path, 1));

    var out: [128]u8 = undefined;
    const edited = edit_text(io, "original", &out).?;
    try testing.expectEqualStrings("edited by the editor\nsecond line", edited);
}

test "edit_text reports nothing when the editor cannot run" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    try testing.expectEqual(
        @as(c_int, 0),
        setenv.setenv("ZMAIL_EDITOR", "/nonexistent/editor-that-does-not-exist", 1),
    );

    var out: [16]u8 = undefined;
    try testing.expect(edit_text(io, "original", &out) == null);
}

test "query_background asks once and reads the terminal's answer" {
    var fake = system_mod.Fake{};
    // What xterm and its friends send back, behind a graphics reply that had to
    // be read first.
    fake.push_input("\x1b_Gi=31;OK\x1b\\\x1b]11;rgb:1a1a/1b1b/2525\x1b\\");

    const colour = query_background(fake.system()).?;
    try testing.expectEqual(@as(u8, 0x1a), colour.r);
    try testing.expectEqual(@as(u8, 0x1b), colour.g);
    try testing.expectEqual(@as(u8, 0x25), colour.b);
    try testing.expect(std.mem.startsWith(u8, fake.output_text(), "\x1b]11;?"));
}

test "query_background gives up quietly when the terminal says nothing" {
    var fake = system_mod.Fake{};
    try testing.expect(query_background(fake.system()) == null);

    // A failure to write is not an error either: the theme falls back.
    var broken = system_mod.Fake{ .write_failure = error.IoError };
    try testing.expect(query_background(broken.system()) == null);

    // Garbage that never becomes a reply is drained and dropped.
    var noisy = system_mod.Fake{};
    noisy.push_input("not a reply at all");
    try testing.expect(query_background(noisy.system()) == null);
}

test "suspending and resuming write the escapes and never fail" {
    // /dev/null is not a terminal: the raw-mode calls cannot work, and the
    // escapes have nowhere to go. Neither may fail the caller -- it is on its way
    // to a browser.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{ .mode = .read_write });
    defer file.close(io);

    var posix = Posix.init(file.handle, file.handle);
    const system = posix.system();
    try system.suspend_ui();
    try system.resume_ui();
}
