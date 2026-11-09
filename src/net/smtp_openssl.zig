//! SMTP over `openssl s_client`: the system's TLS, in a child process.
//!
//! Zig 0.17's TLS client is refused by Google's SMTP frontend -- the same client
//! handshakes with its IMAP -- so the sending half talks to the TLS Google accepts.
//! The dialogue is unchanged: this is a `Transport` like the others, and the SMTP
//! client above it cannot tell the difference.
//!
//! Two shapes, because the protocols are two:
//!   465: the socket is TLS from the first byte.
//!   587: openssl says `EHLO`, `STARTTLS`, and only then encrypts, which is why the
//!        client must speak first after the upgrade.
//!
//! No shell: an argv list, exactly like the `curl` that fetches pictures.
//! `-verify_return_error` is not optional -- without it `s_client` warns about a
//! bad certificate and carries on, which is the one thing this project does not do.

const std = @import("std");
const core = @import("core");
const transport_mod = core.transport_port;
const Transport = transport_mod.Transport;

pub const OpenError = error{
    /// The host and port did not fit, or openssl could not be started.
    SpawnFailed,
    /// `openssl` is not installed: the caller says so instead of failing obscurely.
    NotFound,
};

pub const ProcessTransport = struct {
    io: std.Io = undefined,
    child: std.process.Child = undefined,
    alive: bool = false,

    pub fn open(
        self: *ProcessTransport,
        io: std.Io,
        host: []const u8,
        port: u16,
        starttls: bool,
    ) OpenError!void {
        self.* = .{ .io = io };

        var endpoint_buffer: [320]u8 = undefined;
        const endpoint = std.fmt.bufPrint(&endpoint_buffer, "{s}:{d}", .{ host, port }) catch
            return error.SpawnFailed;

        // One list, built in order: the flags do not depend on the host, and the
        // host is already bounded by the account limit.
        var argv: [10][]const u8 = undefined;
        var count: usize = 0;
        argv[count] = "openssl";
        count += 1;
        argv[count] = "s_client";
        count += 1;
        argv[count] = "-quiet";
        count += 1;
        argv[count] = "-verify_return_error";
        count += 1;
        argv[count] = "-servername";
        count += 1;
        argv[count] = host;
        count += 1;
        if (starttls) {
            argv[count] = "-starttls";
            count += 1;
            argv[count] = "smtp";
            count += 1;
        }
        argv[count] = "-connect";
        count += 1;
        argv[count] = endpoint;
        count += 1;

        self.child = std.process.spawn(io, .{
            .argv = argv[0..count],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            else => error.SpawnFailed,
        };
        self.alive = true;
    }

    pub fn transport(self: *ProcessTransport) Transport {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .close = closeThunk,
        } };
    }

    pub fn close(self: *ProcessTransport) void {
        closeThunk(self);
    }

    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) transport_mod.Error!usize {
        const self: *ProcessTransport = @ptrCast(@alignCast(context));
        if (!self.alive) return error.Closed;
        const stdout = self.child.stdout orelse return error.Closed;
        // Poll first, like every other transport: a child that stops talking must
        // become the protocol's timeout, not a thread asleep on a pipe forever.
        var fds = [1]std.posix.pollfd{
            .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return error.Unavailable;
        if (ready == 0) return 0;
        if ((fds[0].revents & std.posix.POLL.HUP) != 0) return error.Closed;
        const slices = [_][]u8{buffer};
        return stdout.readStreaming(self.io, &slices) catch return error.Unavailable;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) transport_mod.Error!void {
        const self: *ProcessTransport = @ptrCast(@alignCast(context));
        if (!self.alive) return error.Closed;
        const stdin = self.child.stdin orelse return error.Closed;
        stdin.writeStreamingAll(self.io, bytes) catch return error.Unavailable;
    }

    fn closeThunk(context: *anyopaque) void {
        const self: *ProcessTransport = @ptrCast(@alignCast(context));
        if (!self.alive) return;
        // `kill` reaps as well as signals: waiting after it would be waiting twice,
        // which the standard library asserts against.
        self.child.kill(self.io);
        self.alive = false;
    }
};
