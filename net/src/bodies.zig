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

const KeyFile = @import("keyfile.zig").KeyFile;
const sealed_max: usize = limits.body_max + sealed.overhead;

pub const Label = @import("cache_file.zig").Label;

/// What is sealed is the message as the server sent it, and only that. Older
/// builds stored the already-flattened text here, which cannot be told apart
/// from a message without headers: the marker is what makes the difference
/// visible, and an entry without it is ignored (and refetched).
const raw_marker = "AMAIL-RAW-1\n";

pub const FileBodies = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    labels: []const Label,
    keys: KeyFile,
    buffer: [sealed_max]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8, labels: []const Label) FileBodies {
        return .{
            .gpa = gpa,
            .io = io,
            .base_dir = base_dir,
            .labels = labels,
            .keys = KeyFile.init(gpa, io, base_dir),
        };
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

    fn loadThunk(
        context: *anyopaque,
        account: AccountId,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) port.Error!?[]const u8 {
        const self: *FileBodies = @ptrCast(@alignCast(context));
        const key = self.keys.get() orelse return error.Unavailable;

        var path_buffer: [512]u8 = undefined;
        const path = self.file_path(account, mailbox, id, &path_buffer) orelse return null;

        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.Unavailable,
        };
        defer file.close(self.io);

        const size = file.readPositionalAll(self.io, &self.buffer, 0) catch return error.Unavailable;
        var staged: [limits.body_max]u8 = undefined;
        const opened = sealed.open(key, self.buffer[0..size], &staged) catch return null;
        if (opened.len < raw_marker.len or !std.mem.eql(u8, opened[0..raw_marker.len], raw_marker)) {
            return null;
        }
        const body = opened[raw_marker.len..];
        if (body.len > out.len) return error.Unavailable;
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }

    fn saveThunk(
        context: *anyopaque,
        account: AccountId,
        mailbox: Mailbox,
        id: MessageId,
        body: []const u8,
    ) port.Error!void {
        const self: *FileBodies = @ptrCast(@alignCast(context));
        if (body.len == 0 or body.len > limits.body_max - raw_marker.len) return;
        const key = self.keys.get() orelse return error.Unavailable;

        var marked: [limits.body_max]u8 = undefined;
        @memcpy(marked[0..raw_marker.len], raw_marker);
        @memcpy(marked[raw_marker.len..][0..body.len], body);

        var nonce: sealed.Nonce = undefined;
        self.io.random(&nonce);
        const sealed_body = sealed.seal(key, nonce, marked[0 .. raw_marker.len + body.len], &self.buffer) catch
            return;

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

const file_mode = @import("keyfile.zig").file_mode;
const directory_mode = @import("keyfile.zig").directory_mode;

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
