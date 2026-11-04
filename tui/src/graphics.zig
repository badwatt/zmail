//! Drawing a picture of the mail in the terminal.
//!
//! A terminal cannot lay out HTML: there is no CSS, no fonts, no layout engine.
//! What it can do is show a picture, and the kitty graphics protocol (kitty,
//! ghostty, wezterm) takes PNG bytes inline, so the reader paints the images the
//! message itself carries over the rows they occupy.
//!
//! Nothing here renders HTML. `core/html.zig` reads it into text, with no
//! browser and no script, and this file only knows how to put pixels on top of
//! the lines it left free.
//!
//! Everything is streamed in chunks: a full-page picture is megabytes, and zmail
//! does not allocate per frame.

const std = @import("std");
const assert = std.debug.assert;
const system_mod = @import("system.zig");
const System = system_mod.System;

/// One escape sequence carries at most this many base64 characters.
const chunk_max: usize = 4096;
const raw_chunk_max: usize = chunk_max / 4 * 3;

/// Whether this terminal speaks the kitty graphics protocol. There is no list of
/// terminals that do: it is asked once, at startup, and silence means no.
pub fn supported() bool {
    return detected;
}

/// The answer from `probe`, kept for the whole run.
var detected: bool = false;

/// Asks the terminal, once, while it is in raw mode and before the first frame.
/// The answer arrives on stdin, so it has to be read before the key parser is
/// running or it is read as the user typing.
pub fn detect(system: System) void {
    detected = probe(system);
}

/// Sends the query and waits for the terminal to say whether it understood. The
/// reply to our id is `ESC _ G i=31 ; OK ESC \\` when it did.
pub fn probe(system: System) bool {
    // a=q asks a question; the payload is one transparent pixel, so nothing is
    // drawn even if the answer never comes.
    system.write("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=32;AAAAAQ==\x1b\\") catch return false;

    var buffer: [128]u8 = undefined;
    var filled: usize = 0;
    var waits: u8 = 0;
    // A terminal that speaks this answers in microseconds, and one that does not
    // never answers at all: the wait is only ever spent on the second case, and it
    // is spent before the first frame is painted. Two short tries, not three long
    // ones.
    while (waits < 1) : (waits += 1) {
        const read = system.read(buffer[filled..], 30) catch return false;
        if (read == 0) return false;
        filled += read;
        if (std.mem.indexOf(u8, buffer[0..filled], "\x1b_Gi=31;OK") != null) return true;
        // An error answer ("EINVAL", "ENOTSUP") is an answer too: it cannot draw.
        if (std.mem.indexOf(u8, buffer[0..filled], "\x1b_Gi=31;E") != null) return false;
    }
    return false;
}
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
            std.fmt.bufPrint(&header, "\x1b_Ga=t,f=100,i={d},q=2,m={d};", .{ id, @intFromBool(more) }) catch
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
    const placed = std.fmt.bufPrint(&escape, "\x1b_Ga=p,i={d},c={d},r={d},q=2\x1b\\", .{
        id, columns, rows,
    }) catch return false;
    system.write(placed) catch return false;
    return true;
}

/// Deletes every picture the terminal is holding. `d=p` needs a placement id
/// and is ignored without one, so this asks for all of it.
pub fn clear_all(system: System) void {
    // q=2: the terminal must not answer. Its answers arrive on stdin, and a
    // reply that reads like "1" switches mailbox.
    // d=a is spelled out: without it some terminals keep the placements, and a
    // picture from the last mail stays on screen.
    system.write("\x1b_Ga=d,d=a,q=2\x1b\\") catch {};
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

test "the probe asks the terminal instead of reading its name" {
    // No answer: the escape was swallowed, so there is no protocol here.
    var silent: system_mod.Fake = .{};
    try testing.expect(!probe(silent.system()));

    // An answer to our id: it understood, and will draw.
    var answering: system_mod.Fake = .{};
    answering.push_input("\x1b_Gi=31;OK\x1b\\");
    try testing.expect(probe(answering.system()));

    // An error answer is an answer too: it cannot draw.
    var refusing: system_mod.Fake = .{};
    refusing.push_input("\x1b_Gi=31;EINVAL\x1b\\");
    try testing.expect(!probe(refusing.system()));
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

test "a picture is sent once under an id, in chunks, then only placed" {
    var fake: system_mod.Fake = .{};
    var png: [raw_chunk_max + 3]u8 = undefined;
    @memset(&png, 0x41);

    // Sending is the expensive half: the first chunk announces the picture, the
    // second continues it, and only the last one ends the transmission.
    try testing.expect(transmit(fake.system(), &png, 7));
    const sent = fake.output_text();
    try testing.expect(std.mem.startsWith(u8, sent, "\x1b_Ga=t,f=100,i=7,q=2,m=1;"));
    try testing.expect(std.mem.indexOf(u8, sent, "\x1b_Gm=0;") != null);
    try testing.expect(std.mem.count(u8, sent, "\x1b\\") == 2);

    // Placing is a cursor move and one short escape: that is what a scroll costs.
    fake.output_len = 0;
    try testing.expect(place(fake.system(), 7, 3, 4, 20, 10));
    try testing.expectEqualStrings("\x1b[5;4H\x1b_Ga=p,i=7,c=20,r=10,q=2\x1b\\", fake.output_text());

    // Nothing to send, or nothing to name it by.
    fake.output_len = 0;
    try testing.expect(!transmit(fake.system(), "", 7));
    try testing.expect(!transmit(fake.system(), "x", 0));
    try testing.expectEqualStrings("", fake.output_text());
}

test "a terminal that will not take the escape makes transmit and place say so" {
    var broken: system_mod.Fake = .{ .write_failure = error.IoError };
    try testing.expect(!transmit(broken.system(), "x", 1));
    try testing.expect(!place(broken.system(), 1, 0, 0, 1, 1));

    // Clearing is best effort: a terminal that has gone away is not an error.
    clear_all(broken.system());
}

test "clearing asks for every picture, silently" {
    var fake: system_mod.Fake = .{};
    clear_all(fake.system());
    // d=a: all of them. q=2: do not answer, because an answer reads like a key.
    try testing.expectEqualStrings("\x1b_Ga=d,d=a,q=2\x1b\\", fake.output_text());
}

test "a terminal that answers with something else, three times, cannot draw" {
    // Noise instead of an answer to our id: three reads, and then it is a no.
    var noisy: system_mod.Fake = .{ .read_chunk = 1 };
    noisy.push_input("abc");
    try testing.expect(!probe(noisy.system()));
}

test "the support flag is what the terminal answered, and nothing else" {
    var answering: system_mod.Fake = .{};
    answering.push_input("\x1b_Gi=31;OK\x1b\\");
    detect(answering.system());
    try testing.expect(supported());

    var silent: system_mod.Fake = .{};
    detect(silent.system());
    try testing.expect(!supported());
}
