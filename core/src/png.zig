//! Just enough PNG to draw a picture in a terminal.
//!
//! A terminal that speaks no graphics protocol can still show a picture: two
//! pixels per character cell, using the upper half block. yazi does exactly
//! this, and it is why it shows images everywhere. For that we need the pixels,
//! so this decodes the PNGs that arrive inside a message: 8-bit RGB or RGBA,
//! non-interlaced, which is what mail actually carries.
//!
//! No I/O, no allocation, and every buffer bounded by the caller.

const std = @import("std");
const assert = std.debug.assert;

pub const Image = struct {
    width: u32,
    height: u32,
    /// Tightly packed RGBA, `width * height * 4` bytes of `out`.
    rgba: []const u8,
};

pub const Error = error{
    NotAPng,
    Unsupported,
    Corrupt,
    TooBig,
    NoRoom,
};

/// Largest picture kept: a mail logo is small, and a 4-megapixel one is not a
/// logo. Anything bigger is refused rather than decoded for a screen of cells.
pub const max_pixels: u32 = 4 * 1024 * 1024;

/// Decodes `png` into RGBA in `out`. `work` holds the compressed stream and the
/// filtered scanlines while decoding; it must be at least `png.len + raw_needed`,
/// and `raw_needed` is `height * (1 + width * bytes_per_pixel)`.
pub fn decode(png: []const u8, work: []u8, out: []u8) Error!Image {
    if (!std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n")) return error.NotAPng;

    var header: ?Header = null;
    var compressed: usize = 0;
    var palette: [768]u8 = undefined;
    var palette_len: usize = 0;

    var index: usize = 8;
    while (index + 8 <= png.len) {
        const length = std.mem.readInt(u32, png[index..][0..4], .big);
        const kind = png[index + 4 ..][0..4];
        const body_start = index + 8;
        if (body_start + length > png.len) return error.Corrupt;
        const body = png[body_start..][0..length];
        index = body_start + length + 4; // + CRC

        if (std.mem.eql(u8, kind, "IHDR")) {
            header = try parseHeader(body);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_len = @min(body.len, palette.len);
            @memcpy(palette[0..palette_len], body[0..palette_len]);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (compressed + body.len > work.len) return error.NoRoom;
            @memcpy(work[compressed..][0..body.len], body);
            compressed += body.len;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }

    const head = header orelse return error.Corrupt;
    if (compressed == 0) return error.Corrupt;

    const channels: usize = switch (head.color) {
        .rgb => 3,
        .rgba => 4,
        .palette => 1,
    };
    if (head.color == .palette and palette_len == 0) return error.Corrupt;

    const stride = @as(usize, head.width) * channels;
    const raw_size = @as(usize, head.height) * (stride + 1);
    if (work.len < compressed + raw_size) return error.NoRoom;

    // Inflate the IDAT stream right after the compressed bytes.
    const raw_start = alignedStart(work.ptr, compressed);
    if (raw_start + raw_size > work.len) return error.NoRoom;
    const raw = work[raw_start..][0..raw_size];

    {
        var in: std.Io.Reader = .fixed(work[0..compressed]);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress = std.compress.flate.Decompress.init(&in, .zlib, &window);
        decompress.reader.readSliceAll(raw) catch return error.Corrupt;
    }

    const needed = @as(usize, head.width) * head.height * 4;
    if (needed > out.len) return error.NoRoom;
    try unfilter(head, raw, channels, palette[0..palette_len], out);
    return .{ .width = head.width, .height = head.height, .rgba = out[0..needed] };
}

const Color = enum { rgb, rgba, palette };

const Header = struct {
    width: u32,
    height: u32,
    color: Color,
};

fn parseHeader(body: []const u8) Error!Header {
    if (body.len < 13) return error.Corrupt;
    const width = std.mem.readInt(u32, body[0..4], .big);
    const height = std.mem.readInt(u32, body[4..8], .big);
    if (width == 0 or height == 0) return error.Corrupt;
    if (width * height > max_pixels) return error.TooBig;

    // 8 bits per channel, no interlacing: what mail images use.
    if (body[8] != 8 or body[10] != 0 or body[11] != 0 or body[12] != 0) return error.Unsupported;
    const color: Color = switch (body[9]) {
        2 => .rgb,
        6 => .rgba,
        3 => .palette,
        else => return error.Unsupported,
    };
    return .{ .width = width, .height = height, .color = color };
}

fn alignedStart(base: [*]u8, offset: usize) usize {
    const address = @intFromPtr(base);
    const aligned = std.mem.alignForward(usize, address + offset, @alignOf(u64));
    return aligned - address;
}

/// PNG filters, per scanline: none, sub, up, average, paeth.
fn unfilter(
    head: Header,
    raw: []u8,
    channels: usize,
    palette: []const u8,
    out: []u8,
) Error!void {
    const stride = @as(usize, head.width) * channels;
    var previous: [4096]u8 = @splat(0);
    if (stride > previous.len) return error.Unsupported;

    var y: usize = 0;
    while (y < head.height) : (y += 1) {
        const filter = raw[y * (stride + 1)];
        const line = raw[y * (stride + 1) + 1 ..][0..stride];

        var x: usize = 0;
        while (x < stride) : (x += 1) {
            const left: u8 = if (x >= channels) line[x - channels] else 0;
            const up: u8 = previous[x];
            const up_left: u8 = if (x >= channels) previous[x - channels] else 0;
            const add: u8 = switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, up_left),
                else => return error.Corrupt,
            };
            // The bytes are written back in place: each value depends on the
            // ones already reconstructed on this line. `previous` is read, never
            // written, until the row is done -- overwriting it here would make
            // every filtered row predict from its own left neighbour.
            line[x] +%= add;
        }

        writeLine(head, line, palette, out, y);
        // The in-place filtering above already left the reconstructed bytes in
        // `line`; copy them into `previous` for the next row.
        @memcpy(previous[0..stride], line);
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn writeLine(
    head: Header,
    line: []const u8,
    palette: []const u8,
    out: []u8,
    y: usize,
) void {
    var x: usize = 0;
    while (x < head.width) : (x += 1) {
        const target = (y * @as(usize, head.width) + x) * 4;
        switch (head.color) {
            .rgb => {
                out[target] = line[x * 3];
                out[target + 1] = line[x * 3 + 1];
                out[target + 2] = line[x * 3 + 2];
                out[target + 3] = 255;
            },
            .rgba => {
                out[target] = line[x * 4];
                out[target + 1] = line[x * 4 + 1];
                out[target + 2] = line[x * 4 + 2];
                out[target + 3] = line[x * 4 + 3];
            },
            .palette => {
                const entry = line[x] * 3;
                if (entry + 3 > palette.len) {
                    out[target] = 0;
                    out[target + 1] = 0;
                    out[target + 2] = 0;
                } else {
                    out[target] = palette[entry];
                    out[target + 1] = palette[entry + 1];
                    out[target + 2] = palette[entry + 2];
                }
                out[target + 3] = 255;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a tiny RGBA PNG decodes to its pixels" {
    const png = @embedFile("testdata/tiny.png");

    var work: [4096]u8 = undefined;
    var out: [64]u8 = undefined;
    const image = try decode(png, &work, &out);
    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
    // Red, green, blue, white.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.rgba[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, image.rgba[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.rgba[8..12]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, image.rgba[12..16]);
}

test "a picture with no room is refused, not written past the buffer" {
    const png = @embedFile("testdata/tiny.png");
    var work: [4096]u8 = undefined;
    var out: [4]u8 = undefined;
    try testing.expectError(error.NoRoom, decode(png, &work, &out));
}

test "something that is not a PNG is refused" {
    var work: [256]u8 = undefined;
    var out: [64]u8 = undefined;
    try testing.expectError(error.NotAPng, decode("GIF89a", &work, &out));
    try testing.expectError(error.NotAPng, decode(&[_]u8{}, &work, &out));
}

test "paeth picks the neighbour the predictor points at" {
    // p is the predictor; the closest of a, b or c wins.
    try testing.expectEqual(@as(u8, 10), paeth(10, 20, 30));
    try testing.expectEqual(@as(u8, 10), paeth(20, 10, 30));
    try testing.expectEqual(@as(u8, 30), paeth(30, 20, 10));
    // Down-left is the closest here, which is the case that only happens when
    // the predictor sits between b and c.
    try testing.expectEqual(@as(u8, 15), paeth(10, 20, 15));
}

test "a picture without an alpha channel is opaque" {
    var work: [4096]u8 = undefined;
    var out: [64]u8 = undefined;
    const image = try decode(@embedFile("testdata/rgb.png"), &work, &out);
    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.rgba[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.rgba[4..8]);
}

test "a palette picture takes its colours from the palette" {
    var work: [4096]u8 = undefined;
    var out: [64]u8 = undefined;
    const image = try decode(@embedFile("testdata/palette.png"), &work, &out);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.rgba[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, image.rgba[4..8]);
}

test "a palette index past the end is black, not a read past the buffer" {
    var work: [4096]u8 = undefined;
    var out: [64]u8 = undefined;
    const image = try decode(@embedFile("testdata/palette_bad_index.png"), &work, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, image.rgba[0..4]);
}

test "a palette longer than the decoder keeps is cut, not trusted" {
    var work: [8192]u8 = undefined;
    var out: [64]u8 = undefined;
    const image = try decode(@embedFile("testdata/long_plte.png"), &work, &out);
    try testing.expectEqual(@as(u32, 1), image.width);
    // The entries past the bound were dropped, so this one is black.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, image.rgba[0..4]);
}

test "average and paeth filters are undone, and an invented one is refused" {
    var work: [4096]u8 = undefined;
    var out: [64]u8 = undefined;
    const image = try decode(@embedFile("testdata/filters.png"), &work, &out);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, image.rgba[0..4]);
    try testing.expectEqualSlices(u8, &.{ 40, 50, 60, 255 }, image.rgba[4..8]);
    // The second row was filtered against the first.
    try testing.expectEqualSlices(u8, &.{ 70, 80, 90, 255 }, image.rgba[8..12]);
    try testing.expectEqualSlices(u8, &.{ 100, 110, 120, 255 }, image.rgba[12..16]);

    try testing.expectError(error.Corrupt, decode(@embedFile("testdata/bad_filter.png"), &work, &out));
}
