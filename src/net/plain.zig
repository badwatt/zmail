//! Plaintext transport: the first leg of a STARTTLS exchange.
//!
//! This is not a way to read mail. It exists so the client can say `EHLO` or
//! `a1 STARTTLS` and hear the server agree; the moment it does, the socket is
//! handed to `TlsTransport.adopt` and nothing else crosses it in clear. The
//! client refuses to go on if the server never offers the upgrade.

const std = @import("std");
const core = @import("core");
const transport_mod = core.transport_port;
const Transport = transport_mod.Transport;

pub const OpenError = error{
    InvalidHost,
    ConnectFailed,
};

pub const PlainTransport = struct {
    stream: std.Io.net.Stream = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    write_buffer: [4096]u8 = undefined,

    pub fn open(self: *PlainTransport, io: std.Io, host: []const u8, port: u16) OpenError!void {
        self.* = .{};
        const host_name = std.Io.net.HostName.init(host) catch return error.InvalidHost;
        self.stream = host_name.connect(io, port, .{ .mode = .stream, .timeout = .none }) catch
            return error.ConnectFailed;
        self.writer = self.stream.writer(io, &self.write_buffer);
    }

    pub fn transport(self: *PlainTransport) Transport {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .close = closeThunk,
        } };
    }

    /// Pushes the plaintext prologue out: the server cannot answer a `STARTTLS`
    /// that is still sitting in a buffer.
    pub fn flush(self: *PlainTransport) void {
        self.writer.interface.flush() catch {};
    }

    /// The socket, once: the TLS client takes it from here.
    pub fn detach(self: *PlainTransport) std.Io.net.Stream {
        const stream = self.stream;
        self.stream = undefined;
        return stream;
    }

    /// A raw read, never a buffered one: whatever is pulled here belongs to the
    /// plaintext conversation, and anything read ahead would be lost the moment
    /// the socket changes hands -- which is exactly where the TLS ServerHello
    /// arrives. `read_buffer` exists only because the field was needed once; the
    /// socket is read directly, so no byte can hide in a reader.
    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) transport_mod.Error!usize {
        const self: *PlainTransport = @ptrCast(@alignCast(context));
        var fds = [1]std.posix.pollfd{
            .{ .fd = self.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return error.Unavailable;
        if (ready == 0) return 0;
        if ((fds[0].revents & std.posix.POLL.HUP) != 0) return error.Closed;
        return std.posix.read(self.stream.socket.handle, buffer) catch return error.Unavailable;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) transport_mod.Error!void {
        const self: *PlainTransport = @ptrCast(@alignCast(context));
        self.writer.interface.writeAll(bytes) catch return error.Unavailable;
        self.writer.interface.flush() catch return error.Unavailable;
    }

    fn closeThunk(context: *anyopaque) void {
        _ = context;
    }
};
