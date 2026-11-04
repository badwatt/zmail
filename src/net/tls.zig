//! TLS transport: IMAP over TLS, behind the `Transport` port.
//!
//! Certificate verification is mandatory and uses the system CA bundle. The
//! host name is checked against the certificate. There is no "insecure" mode.
//!
//! Reads poll the socket first, so a silent server becomes a timeout at the
//! port instead of a blocked thread. TLS can return zero bytes when a record is
//! not fully buffered (for example a post-handshake ticket), so the read loop
//! retries with a bounded number of attempts.

const std = @import("std");
const core = @import("core");
const transport_mod = core.transport_port;
const Transport = transport_mod.Transport;

pub const OpenError = error{
    InvalidHost,
    ResolveFailed,
    ConnectFailed,
    TlsFailed,
    OutOfMemory,
};

pub const TlsTransport = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    stream: std.Io.net.Stream = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    tls: std.crypto.tls.Client = undefined,
    ca: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined,
    net_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    net_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    opened: bool = false,

    /// Initializes in place: the TLS client captures pointers to this struct's
    /// readers and buffers, so it must never be moved after `open`.
    pub fn open(self: *TlsTransport, gpa: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) OpenError!void {
        // The caller declares this in place and may not have run the field
        // defaults, so establish them here before touching the bundle.
        self.* = .{ .gpa = gpa, .io = io };
        const host_name = std.Io.net.HostName.init(host) catch return error.InvalidHost;
        self.stream = host_name.connect(io, port, .{ .mode = .stream, .timeout = .none }) catch
            return error.ConnectFailed;
        self.stream_reader = self.stream.reader(io, &self.net_read_buffer);
        self.stream_writer = self.stream.writer(io, &self.net_write_buffer);

        self.ca.rescan(gpa, io, std.Io.Timestamp.now(io, .real)) catch return error.TlsFailed;
        io.random(&self.entropy);

        self.tls = std.crypto.tls.Client.init(&self.stream_reader.interface, &self.stream_writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{
                .gpa = gpa,
                .io = io,
                .lock = &self.ca_lock,
                .bundle = &self.ca,
            } },
            .write_buffer = &self.tls_write_buffer,
            .read_buffer = &self.tls_read_buffer,
            .entropy = &self.entropy,
            .realtime_now = std.Io.Timestamp.now(io, .real),
        }) catch return error.TlsFailed;
        // The client Finished may still be sitting in the socket writer's
        // buffer; without this flush the server never answers.
        self.stream_writer.interface.flush() catch return error.TlsFailed;
        self.opened = true;
    }

    pub fn transport(self: *TlsTransport) Transport {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .close = closeThunk,
        } };
    }

    pub fn deinit(self: *TlsTransport) void {
        self.ca.deinit(self.gpa);
        self.opened = false;
    }

    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) transport_mod.Error!usize {
        const self: *TlsTransport = @ptrCast(@alignCast(context));
        var attempts: u32 = 0;
        while (attempts < 64) : (attempts += 1) {
            // Decrypted bytes are ready: hand them over without touching the
            // socket.
            // Decrypted bytes are already in the TLS reader's buffer. Copy them
            // directly: calling readVec here would try to fill the rest of the
            // caller's buffer and block on the socket.
            const plaintext = self.tls.reader.buffered();
            if (plaintext.len > 0) {
                const count = @min(plaintext.len, buffer.len);
                @memcpy(buffer[0..count], plaintext[0..count]);
                self.tls.reader.seek += count;
                return count;
            }

            // Only call into TLS when a whole encrypted record is buffered.
            // Otherwise TLS would block inside its own read, which we cannot
            // time out.
            if (!has_complete_record(&self.stream_reader.interface)) {
                var fds = [1]std.posix.pollfd{
                    .{ .fd = self.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
                };
                const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return error.Unavailable;
                if (ready == 0) return 0;
                if ((fds[0].revents & std.posix.POLL.HUP) != 0) return error.Closed;

                // Poll said there are bytes, so this read returns promptly.
                self.stream_reader.interface.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return error.Closed,
                    else => return error.Unavailable,
                };
                continue;
            }

            var slices = [_][]u8{buffer};
            const count = self.tls.reader.readVec(&slices) catch return error.Unavailable;
            if (count > 0) return count;
        }
        return 0;
    }

    /// True when the buffer holds a complete TLS record (header included).
    fn has_complete_record(reader: *std.Io.Reader) bool {
        const buffered = reader.buffered();
        if (buffered.len < 5) return false;
        const record_len = std.mem.readInt(u16, buffered[3..5], .big);
        return 5 + @as(usize, record_len) <= buffered.len;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) transport_mod.Error!void {
        const self: *TlsTransport = @ptrCast(@alignCast(context));
        self.tls.writer.writeAll(bytes) catch return error.Unavailable;
        self.tls.writer.flush() catch return error.Unavailable;
        self.stream_writer.interface.flush() catch return error.Unavailable;
    }

    fn closeThunk(context: *anyopaque) void {
        const self: *TlsTransport = @ptrCast(@alignCast(context));
        self.stream.close(self.io);
        self.opened = false;
    }
};
