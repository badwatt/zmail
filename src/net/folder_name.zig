//! A folder's name on the filesystem.
//!
//! A server names its folders for itself: `[Gmail]/All Mail`, `Archive/2024`,
//! `My Folder`. None of that is a file name. The cache keeps one file per
//! folder, so the name is flattened to the characters every filesystem keeps,
//! with a hash of the original appended: two folders a flattening would merge
//! ("a b" and "a_b") stay two files.

const std = @import("std");

/// Writes the file-safe form of `name` into `out` and returns it. A buffer too
/// small for the name and its hash gets what fits, which is still a valid name.
pub fn file_name(name: []const u8, out: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(out);
    for (name) |byte| {
        const keep = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_';
        writer.writeByte(if (keep) byte else '_') catch return writer.buffered();
    }
    var hash: [16]u8 = undefined;
    const digest = std.fmt.bufPrint(&hash, "-{x}", .{std.hash.Fnv1a_32.hash(name)}) catch return writer.buffered();
    writer.writeAll(digest) catch {};
    return writer.buffered();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "folder name: separators and spaces become one safe character" {
    var buffer: [64]u8 = undefined;
    const name = file_name("[Gmail]/All Mail", &buffer);
    try testing.expect(std.mem.startsWith(u8, name, "_Gmail__All_Mail-"));
    for (name) |byte| {
        try testing.expect(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_');
    }
}

test "folder name: two names that flatten the same stay apart" {
    var first_buffer: [64]u8 = undefined;
    var second_buffer: [64]u8 = undefined;
    const first = file_name("a b", &first_buffer);
    const second = file_name("a_b", &second_buffer);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "folder name: a short buffer gets a short name, never a broken one" {
    var buffer: [8]u8 = undefined;
    const name = file_name("[Gmail]/All Mail", &buffer);
    try testing.expectEqual(@as(usize, 8), name.len);
    try testing.expectEqualStrings("_Gmail__", name);
}
