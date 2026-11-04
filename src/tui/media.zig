//! What a picture is, in a terminal: how big, how many cells it takes, and an id the
//! terminal will not confuse with the last one it was given.
//!
//! No I/O and no session: these are the questions the session asks about bytes, and
//! the answers are the same whoever asks.

const std = @import("std");
const core = @import("core");

/// The cell the terminal paints in, and the tallest a picture may be drawn.
pub const cell_width: u32 = 9;
pub const cell_height: u32 = 18;
pub const max_image_rows: u32 = 12;

pub const ImageSize = struct { width: u32, height: u32 };
const ImageCells = struct { columns: u16, rows: u16 };

/// A picture's id in the terminal. It has to be unique per message as well as
/// per marker: a terminal ignores a transmission for an id it already holds, so
/// "r0" in another mail would quietly show the previous logo.
pub fn image_id(account: core.id.AccountId, message: core.id.MessageId, key: []const u8) u32 {
    var hash = std.hash.Wyhash.init(0xa5a5);
    hash.update(std.mem.asBytes(&account));
    hash.update(std.mem.asBytes(&message));
    hash.update(key);
    return @intCast((hash.final() & 0x7fffffff) | 1);
}

/// The marker a numbered network image gets: "r0", "r1", …
pub fn is_remote_marker(key: []const u8) bool {
    if (key.len < 2 or key[0] != 'r') return false;
    for (key[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// An image that came with the message can be painted; one with an address
/// cannot, without fetching it.
pub fn is_local_image(key: []const u8) bool {
    if (key.len == 0) return false;
    return std.mem.indexOf(u8, key, "://") == null and
        std.mem.indexOfScalar(u8, key, '/') == null and
        std.mem.indexOfScalar(u8, key, '.') == null;
}

/// Width and height from a PNG's IHDR chunk. Anything else is refused: the
/// terminal paints PNG, and a terminal cannot transcode a JPEG.
pub fn png_size(bytes: []const u8) ?ImageSize {
    if (bytes.len < 24) return null;
    if (bytes[0] != 0x89 or bytes[1] != 'P' or bytes[2] != 'N' or bytes[3] != 'G') return null;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

pub fn image_cells(size: ImageSize) ImageCells {
    const wanted_rows = (size.height + cell_height - 1) / cell_height;
    const scale = if (wanted_rows > max_image_rows)
        @as(f64, @floatFromInt(max_image_rows)) / @as(f64, @floatFromInt(wanted_rows))
    else
        1.0;

    const columns_f = @as(f64, @floatFromInt(size.width)) / @as(f64, @floatFromInt(cell_width)) * scale;
    const rows_f = @as(f64, @floatFromInt(wanted_rows)) * scale;
    return .{
        .columns = @intFromFloat(@max(1.0, @min(columns_f, 255.0))),
        .rows = @intFromFloat(@max(1.0, @min(rows_f, 255.0))),
    };
}

const testing = std.testing;

test "a PNG says how big it is, and nothing else answers" {
    var bytes: [32]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x89PNG");
    std.mem.writeInt(u32, bytes[16..20], 640, .big);
    std.mem.writeInt(u32, bytes[20..24], 480, .big);
    const size = png_size(&bytes).?;
    try testing.expectEqual(@as(u32, 640), size.width);
    try testing.expectEqual(@as(u32, 480), size.height);

    // A JPEG, a truncated header, a zero side: a terminal paints PNG, so all three
    // are refused rather than guessed at.
    var jpeg = bytes;
    jpeg[1] = 'J';
    try testing.expect(png_size(&jpeg) == null);
    try testing.expect(png_size(bytes[0..20]) == null);
    var empty = bytes;
    std.mem.writeInt(u32, empty[16..20], 0, .big);
    try testing.expect(png_size(&empty) == null);
}

test "a picture is drawn in cells, and tall ones are scaled down to fit" {
    const small = image_cells(.{ .width = 90, .height = 36 });
    try testing.expectEqual(@as(u16, 10), small.columns);
    try testing.expectEqual(@as(u16, 2), small.rows);

    // Taller than the screen allows: it keeps its shape and loses height.
    const tall = image_cells(.{ .width = 900, .height = 3_600 });
    try testing.expect(tall.rows <= max_image_rows);
    try testing.expect(tall.columns >= 1);
}

test "two markers in two messages never share an id" {
    const first = image_id(core.id.AccountId.from_int(1), core.id.MessageId.from_int(7), "r0");
    const second = image_id(core.id.AccountId.from_int(1), core.id.MessageId.from_int(8), "r0");
    try testing.expect(first != second);
    // Odd, so a terminal never reads it as an animation frame.
    try testing.expectEqual(@as(u32, 1), first & 1);
    try testing.expect(first != 0);
}

test "a marker is a local file name, not an address" {
    try testing.expect(is_local_image("logo"));
    // "r0" is a bare name too: the caller asks `is_remote_marker` first, which is
    // what makes the two kinds of key different.
    try testing.expect(is_remote_marker("r0"));
    try testing.expect(is_local_image("r0"));
    try testing.expect(!is_local_image("https://example.com/a.png"));
    try testing.expect(!is_local_image("dir/logo"));
    try testing.expect(!is_local_image("logo.png"));
    try testing.expect(!is_local_image(""));
    try testing.expect(is_remote_marker("r12"));
    try testing.expect(!is_remote_marker("r1a"));
    try testing.expect(!is_remote_marker("x0"));
    try testing.expect(!is_remote_marker("r"));
}
