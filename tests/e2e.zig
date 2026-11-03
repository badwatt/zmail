//! End-to-end tests: spawn the real `zmail` binary.
//!
//! These cover the process boundary that unit tests cannot: argv handling,
//! stdout/stderr, and exit codes. The interactive session is covered separately
//! by driving the binary through a pseudo-terminal.

const std = @import("std");
const core = @import("core");
const meta = core.meta;
const exe_path = @import("build_options").zmail_exe;

const testing = std.testing;

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !Run {
    const result = try std.process.run(gpa, io, .{ .argv = args });
    const code = switch (result.term) {
        .exited => |value| value,
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = code };
}

test "--version prints the name and version from build.zig.zon" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try run(testing.allocator, io, &.{ exe_path, "--version" });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.code);
    var expected_buffer: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "{s} {s}\n", .{
        core.meta.name, core.meta.version,
    }) catch unreachable;
    try testing.expectEqualStrings(expected, result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "--help prints usage and exits 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try run(testing.allocator, io, &.{ exe_path, "--help" });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage: zmail") != null);
}

test "an unknown option exits 2 and explains itself on stderr" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try run(testing.allocator, io, &.{ exe_path, "--nope" });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown option: --nope") != null);
}

const pty = struct {
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
};

/// Allocates a pseudo-terminal pair: the master is ours, the slave is the
/// child's terminal.
fn open_pty() !struct { master: c_int, slave: c_int } {
    const master = pty.posix_openpt(0o2 | 0o400);
    if (master < 0) return error.SkipZigTest;
    if (pty.grantpt(master) != 0) return error.SkipZigTest;
    if (pty.unlockpt(master) != 0) return error.SkipZigTest;
    const name = pty.ptsname(master) orelse return error.SkipZigTest;
    const slave = std.c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.SkipZigTest;
    return .{ .master = master, .slave = slave };
}

test "the TUI starts, renders, and quits through a pseudo-terminal" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const terminal = try open_pty();
    defer _ = std.c.close(terminal.master);
    defer _ = std.c.close(terminal.slave);

    const slave_file: std.Io.File = .{ .handle = terminal.slave, .flags = .{ .nonblocking = false } };
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe_path, "--demo" },
        .stdin = .{ .file = slave_file },
        .stdout = .{ .file = slave_file },
        .stderr = .{ .file = slave_file },
    });

    // Read until the first frame arrives, instead of sleeping: deterministic
    // and fast. Writes can be split by the terminal, so accumulate.
    var fds = [1]std.posix.pollfd{
        .{ .fd = terminal.master, .events = std.posix.POLL.IN, .revents = 0 },
    };
    var frame: [16384]u8 = undefined;
    var total: usize = 0;
    var attempts: u32 = 0;
    while (attempts < 20 and total < frame.len) : (attempts += 1) {
        const ready = try std.posix.poll(&fds, 200);
        if (ready == 0) continue;
        const count = std.posix.read(terminal.master, frame[total..]) catch 0;
        if (count == 0) break;
        total += count;
        if (std.mem.indexOf(u8, frame[0..total], meta.name) != null) break;
    }
    if (total == 0) {
        child.kill(io);
        return error.TestExpectedFrame;
    }
    try testing.expect(std.mem.indexOf(u8, frame[0..total], meta.name) != null);
    try testing.expect(std.mem.indexOf(u8, frame[0..total], "Inbox") != null);

    // Ctrl+C is a signal, not a key: it reaches the process even while a socket
    // is being read, restores the terminal, and leaves with 130.
    try std.posix.kill(child.id.?, std.posix.SIG.INT);
    try testing.expectEqual(std.process.Child.Term{ .exited = 130 }, try child.wait(io));
}

test "a live session with a dead server still quits cleanly" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A config with one account whose server refuses the connection: the list
    // comes up with a failure on the status line, and quitting must give the
    // terminal back instead of aborting somewhere in teardown.
    const config_path = "/tmp/zmail-e2e-live.conf";
    const config_text =
        "address = alice@example.com\n" ++
        "username = alice\n" ++
        "imap_host = 127.0.0.1\n" ++
        "imap_port = 9\n" ++
        "imap_security = tls\n";
    {
        const file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, config_text);
    }
    defer std.Io.Dir.cwd().deleteFile(io, config_path) catch {};

    const terminal = try open_pty();
    defer _ = std.c.close(terminal.master);
    defer _ = std.c.close(terminal.slave);

    const slave_file: std.Io.File = .{ .handle = terminal.slave, .flags = .{ .nonblocking = false } };
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe_path, "--config", config_path },
        .stdin = .{ .file = slave_file },
        .stdout = .{ .file = slave_file },
        .stderr = .{ .file = slave_file },
    });

    var fds = [1]std.posix.pollfd{
        .{ .fd = terminal.master, .events = std.posix.POLL.IN, .revents = 0 },
    };
    var frame: [65536]u8 = undefined;
    var total: usize = 0;
    var attempts: u32 = 0;
    // The list, after the failed connection: the point at which the old code
    // read an uninitialised outbox on the way out.
    while (attempts < 60 and total < frame.len) : (attempts += 1) {
        const ready = try std.posix.poll(&fds, 200);
        if (ready == 0) continue;
        const count = std.posix.read(terminal.master, frame[total..]) catch 0;
        if (count == 0) break;
        total += count;
        if (std.mem.indexOf(u8, frame[0..total], "Inbox") != null) break;
    }
    if (total == 0) {
        child.kill(io);
        return error.TestExpectedFrame;
    }

    // A dead server is reported, and Ctrl+C still gets out of it.
    try std.posix.kill(child.id.?, std.posix.SIG.INT);
    try testing.expectEqual(std.process.Child.Term{ .exited = 130 }, try child.wait(io));

    var rest: [4096]u8 = undefined;
    var seen: usize = 0;
    while (seen < rest.len) {
        const count = std.posix.read(terminal.master, rest[seen..]) catch 0;
        if (count == 0) break;
        seen += count;
    }
    const all = std.mem.concat(testing.allocator, u8, &.{ frame[0..total], rest[0..seen] }) catch return;
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "\x1b[?1049l") != null);
}

test "the product name and version come from the same source of truth" {
    try testing.expect(meta.name.len > 0);
    var expected: [32]u8 = undefined;
    const version_line = try std.fmt.bufPrint(&expected, "{s} {s}\n", .{ meta.name, meta.version });
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const result = try run(testing.allocator, threaded.io(), &.{ exe_path, "--version" });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings(version_line, result.stdout);
}
