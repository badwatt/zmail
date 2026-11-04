//! The single key that seals everything zmail writes: cache, bodies, and the
//! password file. One file, 32 random bytes, mode 0600.
//!
//! Trust boundary, stated plainly: the key sits next to the data. This protects
//! against a stray backup, a synced cache directory, or another user on the
//! machine; it does not protect against code running as you. An OS keyring
//! (libsecret, kernel keyring) is the next step up.

const std = @import("std");
const core = @import("core");

const sealed = core.sealed;

pub const KeyFile = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    key: sealed.Key = @splat(0),
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8) KeyFile {
        return .{ .gpa = gpa, .io = io, .base_dir = base_dir };
    }

    /// Returns the key, creating it on first use. Null when the filesystem says
    /// no; callers treat that as "no cache" rather than failing to start.
    pub fn get(self: *KeyFile) ?sealed.Key {
        if (self.loaded) return self.key;

        var buffer: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/key", .{self.base_dir}) catch return null;

        if (std.Io.Dir.cwd().openFile(self.io, path, .{})) |file| {
            defer file.close(self.io);
            const read = file.readPositionalAll(self.io, &self.key, 0) catch return null;
            if (read != sealed.key_len) return null;
            self.loaded = true;
            return self.key;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return null,
        }

        self.io.random(&self.key);
        _ = std.Io.Dir.cwd().createDirPathStatus(self.io, self.base_dir, directory_mode) catch
            return null;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .permissions = file_mode }) catch
            return null;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, &self.key) catch return null;
        self.loaded = true;
        return self.key;
    }
};

pub const file_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));
pub const directory_mode: std.Io.Dir.Permissions = @fromBackingInt(@intCast(0o700));
