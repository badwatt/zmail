//! Drawing a picture of the mail in the terminal.
//!
//! A terminal cannot lay out HTML: there is no CSS, no fonts, no images. What it
//! can do is show a picture, and the kitty graphics protocol (kitty, ghostty,
//! wezterm) takes PNG bytes inline. So the HTML is rendered by a headless
//! browser into a PNG and that PNG is painted over the reader's body area.
//!
//! Everything is streamed in chunks: a full-page screenshot is megabytes, and
//! amail does not allocate per frame.

const std = @import("std");
const assert = std.debug.assert;
const system_mod = @import("system.zig");
const System = system_mod.System;

/// One escape sequence carries at most this many base64 characters.
const chunk_max: usize = 4096;
const raw_chunk_max: usize = chunk_max / 4 * 3;

/// Whether this terminal speaks the kitty graphics protocol.
pub fn supported() bool {
    // The escape hatch, for setups that know what they are doing.
    if (Env.get("AMAIL_IMAGES")) |value| {
        if (std.mem.eql(u8, value, "blocks")) return false;
        if (std.mem.eql(u8, value, "kitty")) return true;
    }
    // Inside a multiplexer the sequences belong to the multiplexer, and what it
    // makes of them is its business: half blocks never break there.
    if (Env.get("TMUX") != null or Env.get("STY") != null) return false;
    if (Env.get("KITTY_WINDOW_ID")) |_| return true;
    const term = Env.get("TERM") orelse "";
    if (std.mem.indexOf(u8, term, "kitty") != null) return true;
    if (std.mem.indexOf(u8, term, "ghostty") != null) return true;
    if (Env.get("TERM_PROGRAM")) |program| {
        if (std.mem.indexOf(u8, program, "ghostty") != null) return true;
        if (std.mem.indexOf(u8, program, "WezTerm") != null) return true;
    }
    return false;
}

/// The environment, behind a name so tests can replace it.
pub const Env = struct {
    pub var get: *const fn (name: [:0]const u8) ?[]const u8 = default_get;

    fn default_get(name: [:0]const u8) ?[]const u8 {
        return @import("os.zig").env(name);
    }
};

/// Sends a picture to the terminal once, under `id`. Placing it afterwards is
/// a few dozen bytes: that is the difference between a reader that scrolls and
/// one that stutters.
pub fn transmit(system: System, png: []const u8, id: u32) bool {
    if (png.len == 0 or id == 0) return false;

    var encoded: [chunk_max]u8 = undefined;
    var offset: usize = 0;
    var first = true;
    while (offset < png.len) {
        const take = @min(raw_chunk_max, png.len - offset);
        const base64 = std.base64.standard.Encoder.encode(&encoded, png[offset..][0..take]);
        const more = offset + take < png.len;
        offset += take;

        var header: [64]u8 = undefined;
        const text = if (first)
            std.fmt.bufPrint(&header, "\x1b_Ga=t,f=100,i={d},m={d};", .{ id, @intFromBool(more) }) catch
                return false
        else
            std.fmt.bufPrint(&header, "\x1b_Gm={d};", .{@intFromBool(more)}) catch return false;
        first = false;

        system.write(text) catch return false;
        system.write(base64) catch return false;
        system.write("\x1b\\") catch return false;
    }
    return true;
}

/// Puts an already transmitted picture at a cell.
pub fn place(system: System, id: u32, x: u16, y: u16, columns: u16, rows: u16) bool {
    var position: [32]u8 = undefined;
    const at = std.fmt.bufPrint(&position, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch return false;
    system.write(at) catch return false;

    var escape: [96]u8 = undefined;
    const placed = std.fmt.bufPrint(&escape, "\x1b_Ga=p,i={d},c={d},r={d}\x1b\\", .{
        id, columns, rows,
    }) catch return false;
    system.write(placed) catch return false;
    return true;
}

/// Removes the placements and keeps the pictures: scrolling must not pay for
/// transmitting them again.
pub fn clear_placements(system: System) void {
    system.write("\x1b_Ga=d,d=p\x1b\\") catch {};
}

/// Forgets every picture: another message, another set.
pub fn clear_all(system: System) void {
    system.write("\x1b_Ga=d\x1b\\") catch {};
}

/// Paints `png` with its top-left corner at (x, y), `columns` by `rows` cells.
/// Returns false when the terminal refused it, so the caller can fall back.
pub fn draw(system: System, png: []const u8, x: u16, y: u16, columns: u16, rows: u16) bool {
    if (png.len == 0 or columns == 0 or rows == 0) return false;

    var position: [32]u8 = undefined;
    const at = std.fmt.bufPrint(&position, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch return false;
    system.write(at) catch return false;

    var encoded: [chunk_max]u8 = undefined;
    var offset: usize = 0;
    while (offset < png.len) {
        const take = @min(raw_chunk_max, png.len - offset);
        const base64 = std.base64.standard.Encoder.encode(&encoded, png[offset..][0..take]);
        const more = offset + take < png.len;
        offset += take;

        var header: [128]u8 = undefined;
        const text = if (offset == take)
            // First chunk: transmit and display, with its size in cells.
            std.fmt.bufPrint(&header, "\x1b_Ga=T,f=100,c={d},r={d},m={d};", .{
                columns, rows, @intFromBool(more),
            }) catch return false
        else
            std.fmt.bufPrint(&header, "\x1b_Gm={d};", .{@intFromBool(more)}) catch return false;

        system.write(text) catch return false;
        system.write(base64) catch return false;
        system.write("\x1b\\") catch return false;
    }
    return true;
}

/// Removes every image the terminal is holding: after this, repainting the
/// screen shows text again and nothing else.
pub fn clear(system: System) void {
    system.write("\x1b_Ga=d\x1b\\") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_kitty: bool = false;
var fake_term: []const u8 = "xterm-256color";
var fake_program: []const u8 = "";
var fake_tmux: bool = false;
var fake_images: []const u8 = "";

fn fakeGet(name: [:0]const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "AMAIL_IMAGES")) return if (fake_images.len > 0) fake_images else null;
    if (std.mem.eql(u8, name, "TMUX")) return if (fake_tmux) "/tmp/tmux-1000/default,1,0" else null;
    if (std.mem.eql(u8, name, "KITTY_WINDOW_ID")) return if (fake_kitty) "1" else null;
    if (std.mem.eql(u8, name, "TERM")) return fake_term;
    if (std.mem.eql(u8, name, "TERM_PROGRAM")) return if (fake_program.len > 0) fake_program else null;
    return null;
}

test "supported: the terminals that know the protocol, and the rest" {
    const previous = Env.get;
    Env.get = fakeGet;
    defer Env.get = previous;

    fake_kitty = false;
    fake_term = "xterm-256color";
    fake_program = "";
    fake_tmux = false;
    try testing.expect(!supported());

    // Inside tmux the protocol is the multiplexer's problem.
    fake_tmux = true;
    try testing.expect(!supported());
    fake_tmux = false;

    // And the override settles it either way.
    fake_kitty = true;
    fake_images = "blocks";
    try testing.expect(!supported());
    fake_images = "";
    fake_kitty = false;

    fake_kitty = true;
    try testing.expect(supported());

    fake_kitty = false;
    fake_term = "xterm-kitty";
    try testing.expect(supported());

    fake_term = "xterm-ghostty";
    try testing.expect(supported());

    fake_term = "xterm-256color";
    fake_program = "ghostty";
    try testing.expect(supported());

    fake_program = "Apple_Terminal";
    try testing.expect(!supported());
}

test "draw streams one image in chunks, then clears it" {
    var fake: system_mod.Fake = .{};
    var png: [7000]u8 = undefined;
    @memset(&png, 0x42);

    try testing.expect(draw(fake.system(), png[0..], 1, 2, 20, 10));
    const written = fake.output_text();
    // Positioned, then transmitted in 3 KiB chunks: three for 7000 bytes.
    try testing.expect(std.mem.startsWith(u8, written, "\x1b[3;2H\x1b_Ga=T,f=100,c=20,r=10,m=1;"));
    try testing.expect(std.mem.count(u8, written, "\x1b_G") == 3);
    // Only the last chunk ends the transmission.
    try testing.expect(std.mem.indexOf(u8, written, "m=0;") != null);
    try testing.expect(std.mem.endsWith(u8, written, "\x1b\\"));

    fake.output_len = 0;
    clear(fake.system());
    try testing.expectEqualStrings("\x1b_Ga=d\x1b\\", fake.output_text());
}

test "draw refuses an empty picture or no room for it" {
    var fake: system_mod.Fake = .{};
    try testing.expect(!draw(fake.system(), "", 1, 1, 10, 10));
    try testing.expect(!draw(fake.system(), "x", 1, 1, 0, 10));
    try testing.expectEqualStrings("", fake.output_text());
}
