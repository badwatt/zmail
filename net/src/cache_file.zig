//! File cache adapter: one TSV file per (account, mailbox) under the cache dir.
//!
//! Best effort by design: any I/O problem is reported as `Unavailable` and the
//! session falls back to the network. The codec itself lives in core and is
//! covered by unit tests; this file is the glue.

const std = @import("std");
const core = @import("core");

const cache_mod = core.cache;
const sealed = core.sealed;
const KeyFile = @import("keyfile.zig").KeyFile;
const port = core.cache_port;
const Message = core.message.Message;
const AccountId = core.id.AccountId;
const Mailbox = core.mailbox.Mailbox;

pub const Label = struct {
    id: AccountId,
    label: []const u8,
};

pub const FileCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    labels: []const Label,
    keys: KeyFile,
    buffer: [1024 * 1024]u8 = undefined,
    /// Sealed bytes read from disk, opened into `plain` before decoding.
    plain: [1024 * 1024]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8, labels: []const Label) FileCache {
        return .{
            .gpa = gpa,
            .io = io,
            .base_dir = base_dir,
            .labels = labels,
            .keys = KeyFile.init(gpa, io, base_dir),
        };
    }

    pub fn cache(self: *FileCache) port.Cache {
        return .{ .context = self, .vtable = &.{ .load = loadThunk, .save = saveThunk } };
    }

    fn label_for(self: *const FileCache, id: AccountId) ?[]const u8 {
        for (self.labels) |entry| {
            if (entry.id == id) return entry.label;
        }
        return null;
    }

    fn file_path(self: *const FileCache, account: AccountId, mailbox: Mailbox, buffer: []u8) ?[]const u8 {
        const label = self.label_for(account) orelse return null;
        return std.fmt.bufPrint(buffer, "{s}/{s}/{s}.bin", .{
            self.base_dir,
            label,
            mailbox_file_name(mailbox),
        }) catch null;
    }

    fn loadThunk(context: *anyopaque, account: AccountId, mailbox: Mailbox, out: []Message) port.Error!u32 {
        const self: *FileCache = @ptrCast(@alignCast(context));
        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(account, mailbox, &path_buffer) orelse return 0;

        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return error.Unavailable,
        };
        defer file.close(self.io);

        const count = file.readPositionalAll(self.io, &self.buffer, 0) catch
            return error.Unavailable;

        // Envelopes are sealed too: senders and subjects are mail, not metadata.
        const key = self.keys.get() orelse return error.Unavailable;
        const text = sealed.open(key, self.buffer[0..count], &self.plain) catch return 0;
        return cache_mod.decode(text, out) catch 0;
    }

    fn saveThunk(context: *anyopaque, account: AccountId, mailbox: Mailbox, messages: []const Message) port.Error!void {
        const self: *FileCache = @ptrCast(@alignCast(context));
        if (messages.len == 0) return;

        var writer = std.Io.Writer.fixed(&self.plain);
        cache_mod.encode(&writer, messages) catch return error.Unavailable;

        const key = self.keys.get() orelse return error.Unavailable;
        var nonce: sealed.Nonce = undefined;
        self.io.random(&nonce);
        const sealed_text = sealed.seal(key, nonce, writer.buffered(), &self.buffer) catch
            return error.Unavailable;

        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(account, mailbox, &path_buffer) orelse return;

        const label = self.label_for(account) orelse return;
        var dir_buffer: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buffer, "{s}/{s}", .{ self.base_dir, label }) catch return;
        // createDirPath: the cache root may not exist yet (`~/.cache/zmail`).
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, dir, directory_mode) catch
            return error.Unavailable;

        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .permissions = file_mode }) catch
            return error.Unavailable;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, sealed_text) catch return error.Unavailable;
    }
};

const file_mode: std.Io.File.Permissions = @enumFromInt(0o600);
const directory_mode: std.Io.Dir.Permissions = @enumFromInt(0o700);

fn mailbox_file_name(mailbox: Mailbox) []const u8 {
    return switch (mailbox) {
        .inbox => "inbox",
        .sent => "sent",
        .drafts => "drafts",
        .archive => "archive",
        .trash => "trash",
        .junk => "junk",
    };
}
