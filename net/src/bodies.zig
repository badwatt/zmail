//! File body cache: one sealed file per message, one key per cache.
//!
//! Layout: `<cache>/<label>/bodies/<mailbox>/<uid>.bin`, containing
//! `nonce || ciphertext || tag` (see core/sealed.zig). The key is
//! `<cache>/key`, 32 random bytes, mode 0600, created on first use. Nothing
//! secret is written in the clear, so a stray copy of the directory is not a
//! copy of the mail.

const std = @import("std");
const core = @import("core");

const port = core.bodies_port;
const sealed = core.sealed;
const Message = core.message.Message;
const AccountId = core.id.AccountId;
const MessageId = core.id.MessageId;
const Mailbox = core.mailbox.Mailbox;
const limits = core.limits;

const sealed_max: usize = limits.body_max + sealed.overhead;

pub const Label = @import("cache_file.zig").Label;

pub const FileBodies = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    labels: []const Label,
    key: sealed.Key = @splat(0),
    have_key: bool = false,
    buffer: [sealed_max]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8, labels: []const Label) FileBodies {
        return .{ .gpa = gpa, .io = io, .base_dir = base_dir, .labels = labels };
    }

    pub fn cache(self: *FileBodies) port.BodyCache {
        return .{ .context = self, .vtable = &.{ .load = loadThunk, .save = saveThunk } };
    }

    fn label_for(self: *const FileBodies, id: AccountId) ?[]const u8 {
        for (self.labels) |entry| {
            if (entry.id == id) return entry.label;
        }
        return null;
    }

    fn file_path(self: *const FileBodies, account: AccountId, mailbox: Mailbox, id: MessageId, buffer: []u8) ?[]const u8 {
        const label = self.label_for(account) orelse return null;
        return std.fmt.bufPrint(buffer, "{s}/{s}/bodies/{s}/{d}.bin", .{
            self.base_dir,
            label,
            mailbox_file_name(mailbox),
            id.to_int(),
        }) catch null;
    }

    /// Reads the key, creating it the first time. Not a secret to hide from the
    /// process owner (the password file has the same trust boundary), only from
    /// backups and other users.
    fn ensure_key(self: *FileBodies) bool {
        if (self.have_key) return true;

        var key_buffer: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&key_buffer, "{s}/key", .{self.base_dir}) catch return false;

        if (std.Io.Dir.cwd().openFile(self.io, path, .{})) |file| {
            defer file.close(self.io);
            const read = file.readPositionalAll(self.io, &self.key, 0) catch return false;
            if (read != sealed.key_len) return false;
            self.have_key = true;
            return true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return false,
        }

        self.io.random(&self.key);
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, self.base_dir, directory_mode) catch return false;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .permissions = file_mode }) catch
            return false;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, &self.key) catch return false;
        self.have_key = true;
        return true;
    }

    fn loadThunk(
        context: *anyopaque,
        account: AccountId,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) port.Error!?[]const u8 {
        const self: *FileBodies = @ptrCast(@alignCast(context));
        if (!self.ensure_key()) return error.Unavailable;

        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(account, mailbox, id, &path_buffer) orelse return null;

        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.Unavailable,
        };
        defer file.close(self.io);

        const size = file.readPositionalAll(self.io, &self.buffer, 0) catch return error.Unavailable;
        return sealed.open(self.key, self.buffer[0..size], out) catch null;
    }

    fn saveThunk(
        context: *anyopaque,
        account: AccountId,
        mailbox: Mailbox,
        id: MessageId,
        body: []const u8,
    ) port.Error!void {
        const self: *FileBodies = @ptrCast(@alignCast(context));
        if (body.len == 0 or body.len > limits.body_max) return;
        if (!self.ensure_key()) return error.Unavailable;

        var nonce: sealed.Nonce = undefined;
        self.io.random(&nonce);
        const sealed_body = sealed.seal(self.key, nonce, body, &self.buffer) catch return;

        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(account, mailbox, id, &path_buffer) orelse return;

        const label = self.label_for(account) orelse return;
        var dir_buffer: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buffer, "{s}/{s}/bodies/{s}", .{
            self.base_dir,
            label,
            mailbox_file_name(mailbox),
        }) catch return;
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, dir, directory_mode) catch
            return error.Unavailable;

        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .permissions = file_mode }) catch
            return error.Unavailable;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, sealed_body) catch return error.Unavailable;
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
