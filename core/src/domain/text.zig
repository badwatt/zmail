//! Bounded, sanitized text.
//!
//! Mail content is attacker-controlled. Two rules make it safe to carry through
//! the whole program and out to a terminal:
//!
//!   1. Truncate to a fixed capacity at a UTF-8 boundary.
//!   2. Replace control characters (C0, DEL, C1) with a space, so a subject like
//!      "\x1b[2J" can never reach the terminal as an escape sequence.
//!
//! Sanitization happens on ingress, not on render, so no later code path can
//! accidentally print a raw control byte by forgetting to sanitize.

const std = @import("std");
const assert = std.debug.assert;

/// Returns a fixed-capacity text type.
pub fn Text(comptime capacity: u32) type {
    return struct {
        const Self = @This();

        pub const cap: u32 = capacity;

        buffer: [capacity]u8 = @splat(0),
        len: u32 = 0,

        /// Copies `bytes` in, truncating and sanitizing. Cannot fail.
        pub fn init(bytes: []const u8) Self {
            var text: Self = .{};
            text.set(bytes);
            return text;
        }

        /// Replaces the contents with `bytes`, truncating and sanitizing.
        pub fn set(self: *Self, bytes: []const u8) void {
            assert(self.len <= capacity);
            self.len = copy_sanitized(&self.buffer, bytes);
            // Zero the tail so a shorter value cannot leave the previous one
            // readable past `len` (buffer bled).
            @memset(self.buffer[self.len..], 0);
            assert(self.len <= capacity);
        }

        /// Appends one printable ASCII byte. Anything else is a programmer bug:
        /// the caller (a key decoder) only forwards printable keys.
        pub fn append_ascii(self: *Self, byte: u8) void {
            assert(byte >= 0x20);
            assert(byte <= 0x7e);
            if (self.len == capacity) return;
            self.buffer[self.len] = byte;
            self.len += 1;
        }

        /// Removes the last codepoint. Multi-byte codepoints are removed whole,
        /// so the buffer never holds a dangling continuation byte.
        pub fn pop_codepoint(self: *Self) void {
            assert(self.len <= capacity);
            if (self.len == 0) return;

            var index: u32 = self.len - 1;
            while (index > 0) : (index -= 1) {
                const byte = self.buffer[index];
                if (byte & 0b1100_0000 != 0b1000_0000) break;
            }
            self.len = index;
            assert(self.len < capacity);
        }

        /// Zeroes the buffer. Called on message eviction and on secret teardown,
        /// so a later message cannot observe the previous one's bytes.
        pub fn clear(self: *Self) void {
            assert(self.len <= capacity);
            @memset(&self.buffer, 0);
            self.len = 0;
        }

        /// Formats into the buffer. If the result does not fit it is truncated at
        /// a codepoint boundary, matching every other ingress path.
        pub fn set_fmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
            // One spare byte so a result that exactly fills `capacity` is not
            // mistaken for an overflow, and the writer reports the valid prefix
            // instead of leaving uninitialized bytes in the buffer.
            var scratch: [capacity + 1]u8 = undefined;
            var writer = std.Io.Writer.fixed(&scratch);
            writer.print(fmt, args) catch {}; // Truncation is acceptable here.
            self.set(writer.buffered());
        }

        pub fn slice(self: *const Self) []const u8 {
            assert(self.len <= capacity);
            return self.buffer[0..self.len];
        }

        pub fn is_empty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn eql_bytes(self: *const Self, bytes: []const u8) bool {
            return std.mem.eql(u8, self.slice(), bytes);
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            return self.eql_bytes(other.slice());
        }

        pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.slice());
        }
    };
}

/// Copies `source` into `dest`, truncating at a UTF-8 boundary and replacing
/// control characters with a space. Returns the number of bytes written.
pub fn copy_sanitized(dest: []u8, source: []const u8) u32 {
    assert(dest.len <= std.math.maxInt(u32));
    var out: u32 = 0;
    var index: u32 = 0;
    while (index < source.len) {
        assert(index < source.len);
        const maybe_len = std.unicode.utf8ByteSequenceLength(source[index]) catch 0;
        const sequence_len: u32 = maybe_len;
        if (sequence_len == 0) {
            writeByte(dest, &out, '?');
            index += 1;
            continue;
        }
        const sequence_end = index + sequence_len;
        if (sequence_end > source.len) {
            writeByte(dest, &out, '?');
            break;
        }
        const codepoint = std.unicode.utf8Decode(source[index..sequence_end]) catch {
            writeByte(dest, &out, '?');
            index += 1;
            continue;
        };
        if (isControl(codepoint)) {
            writeByte(dest, &out, ' ');
        } else {
            if (out + sequence_len > dest.len) break;
            @memcpy(dest[out..][0..sequence_len], source[index..][0..sequence_len]);
            out += sequence_len;
        }
        index = sequence_end;
    }
    assert(out <= dest.len);
    return out;
}

fn writeByte(dest: []u8, out: *u32, byte: u8) void {
    assert(byte >= 0x20);
    if (out.* == dest.len) return;
    dest[out.*] = byte;
    out.* += 1;
}

/// C0 controls, DEL, and C1 controls. C1 matters because UTF-8 can encode
/// U+009B, which some terminals interpret as CSI.
fn isControl(codepoint: u21) bool {
    if (codepoint < 0x20) return true;
    if (codepoint == 0x7f) return true;
    return codepoint >= 0x80 and codepoint <= 0x9f;
}

/// ASCII case-insensitive substring search. Non-ASCII bytes are compared
/// exactly: we do not attempt Unicode case folding (and must not, for search
/// correctness on attacker-supplied text). An empty needle matches.
pub fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    const last_start = haystack.len - needle.len;
    while (start <= last_start) : (start += 1) {
        if (startsWithIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    assert(haystack.len >= needle.len);
    for (needle, 0..) |byte, index| {
        if (std.ascii.toLower(haystack[index]) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Text: init copies, slice round-trips, capacity is exact" {
    const Tiny = Text(8);
    const text = Tiny.init("hello");
    try testing.expectEqualStrings("hello", text.slice());
    try testing.expectEqual(@as(u32, 5), text.len);
    try testing.expect(!text.is_empty());
}

test "Text: empty input yields an empty slice" {
    const Tiny = Text(8);
    const text = Tiny.init("");
    try testing.expectEqualStrings("", text.slice());
    try testing.expect(text.is_empty());
}

test "Text: truncates at the capacity" {
    const Tiny = Text(4);
    const text = Tiny.init("abcdef");
    try testing.expectEqualStrings("abcd", text.slice());
}

test "Text: truncation never splits a UTF-8 codepoint" {
    const Tiny = Text(4);
    // "é" is two bytes, so a 4-byte budget fits exactly two of them.
    const text = Tiny.init("ééé");
    try testing.expectEqualStrings("éé", text.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
}

test "Text: a codepoint that does not fit is dropped whole" {
    const Tiny = Text(2);
    const text = Tiny.init("aé");
    try testing.expectEqualStrings("a", text.slice());
}

test "Text: a codepoint that exactly fills the capacity is kept" {
    const Tiny = Text(3);
    const text = Tiny.init("aé");
    try testing.expectEqualStrings("aé", text.slice());
}

test "Text: control bytes are replaced with spaces, so escapes are inert" {
    const Tiny = Text(16);
    const text = Tiny.init("\x1b[2J\x07ok");
    try testing.expectEqualStrings(" [2J ok", text.slice());
}

test "Text: C1 control codepoints (U+009B) are neutralized" {
    const Tiny = Text(8);
    const text = Tiny.init("\u{9b}31m");
    try testing.expectEqualStrings(" 31m", text.slice());
}

test "Text: DEL is neutralized" {
    const Tiny = Text(8);
    const text = Tiny.init("a\x7fb");
    try testing.expectEqualStrings("a b", text.slice());
}

test "Text: invalid UTF-8 becomes a visible placeholder" {
    const Tiny = Text(8);
    const text = Tiny.init("a\xffb");
    try testing.expectEqualStrings("a?b", text.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
}

test "Text: a truncated multibyte sequence at the end becomes a placeholder" {
    const Tiny = Text(8);
    const text = Tiny.init("a\xc3");
    try testing.expectEqualStrings("a?", text.slice());
}

test "Text: set replaces previous contents without bleeding the tail" {
    const Tiny = Text(8);
    var text = Tiny.init("longtext");
    text.set("hi");
    try testing.expectEqualStrings("hi", text.slice());
    try testing.expectEqualSlices(u8, &.{ 'h', 'i', 0, 0, 0, 0, 0, 0 }, &text.buffer);
}

test "Text: clear zeroes the buffer" {
    const Tiny = Text(8);
    var text = Tiny.init("secret");
    text.clear();
    try testing.expectEqual(@as(u32, 0), text.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &text.buffer);
}

test "Text: append_ascii appends printable bytes and stops at capacity" {
    const Tiny = Text(3);
    var text = Tiny.init("");
    text.append_ascii('a');
    text.append_ascii('b');
    text.append_ascii('c');
    text.append_ascii('d');
    try testing.expectEqualStrings("abc", text.slice());
}

test "Text: pop_codepoint removes one ASCII byte at a time" {
    const Tiny = Text(8);
    var text = Tiny.init("abc");
    text.pop_codepoint();
    try testing.expectEqualStrings("ab", text.slice());
    text.pop_codepoint();
    text.pop_codepoint();
    text.pop_codepoint();
    try testing.expect(text.is_empty());
}

test "Text: pop_codepoint removes a whole multibyte codepoint" {
    const Tiny = Text(8);
    var text = Tiny.init("aé");
    text.pop_codepoint();
    try testing.expectEqualStrings("a", text.slice());
}

test "Text: set_fmt writes formatted output" {
    const Tiny = Text(16);
    var text = Tiny.init("");
    text.set_fmt("{d} unread", .{@as(u32, 3)});
    try testing.expectEqualStrings("3 unread", text.slice());
}

test "Text: set_fmt truncates when the output does not fit" {
    const Tiny = Text(4);
    var text = Tiny.init("");
    text.set_fmt("abcdef", .{});
    try testing.expectEqualStrings("abcd", text.slice());
}

test "Text: set_fmt output that exactly fills capacity is kept whole" {
    const Tiny = Text(4);
    var text = Tiny.init("");
    text.set_fmt("abcd", .{});
    try testing.expectEqualStrings("abcd", text.slice());
}

// A fixed writer that cannot hold the value must report the error, not a
// partially initialized buffer (buffer bled).
test "Text: format propagates a full writer" {
    const Tiny = Text(8);
    const text = Tiny.init("hi");
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.WriteFailed, text.format(&writer));
}

test "Text: eql_bytes and eql compare contents" {
    const Tiny = Text(8);
    const text = Tiny.init("same");
    try testing.expect(text.eql_bytes("same"));
    try testing.expect(!text.eql_bytes("other"));
    var other = Tiny.init("same");
    try testing.expect(text.eql(&other));
    other.set("diff");
    try testing.expect(!text.eql(&other));
}

test "Text: format writes the current slice" {
    const Tiny = Text(8);
    const text = Tiny.init("hi");
    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try text.format(&writer);
    try testing.expectEqualStrings("hi", writer.buffered());
}

test "copy_sanitized: keeps tabs as spaces, keeps newlines out of metadata" {
    var dest: [8]u8 = @splat(0);
    const written = copy_sanitized(&dest, "a\tb\nc");
    try testing.expectEqualStrings("a b c", dest[0..written]);
}

test "copy_sanitized: empty input writes nothing" {
    var dest: [4]u8 = @splat(0);
    try testing.expectEqual(@as(u32, 0), copy_sanitized(&dest, ""));
}

test "copy_sanitized: invalid continuation byte becomes a placeholder" {
    var dest: [8]u8 = @splat(0);
    const written = copy_sanitized(&dest, "a\xc3(b");
    try testing.expectEqualStrings("a?(b", dest[0..written]);
}

test "copy_sanitized: a control byte past the capacity is dropped" {
    var dest: [1]u8 = @splat(0);
    const written = copy_sanitized(&dest, "\x1b\x1b");
    try testing.expectEqualStrings(" ", dest[0..written]);
}

test "isControl: covers C0, DEL, C1 and the printable boundary" {
    try testing.expect(isControl(0x00));
    try testing.expect(isControl(0x1f));
    try testing.expect(!isControl(0x20));
    try testing.expect(!isControl(0x7e));
    try testing.expect(isControl(0x7f));
    try testing.expect(isControl(0x80));
    try testing.expect(isControl(0x9f));
    try testing.expect(!isControl(0xa0));
}

test "contains_ignore_case: matches ignoring ASCII case" {
    try testing.expect(contains_ignore_case("Zig Release", "zig"));
    try testing.expect(contains_ignore_case("Zig Release", "RELEASE"));
    try testing.expect(!contains_ignore_case("Zig Release", "rust"));
}

test "contains_ignore_case: empty needle matches, oversized needle does not" {
    try testing.expect(contains_ignore_case("abc", ""));
    try testing.expect(!contains_ignore_case("ab", "abc"));
}

test "contains_ignore_case: matches at the final possible offset" {
    try testing.expect(contains_ignore_case("xxabc", "abc"));
    try testing.expect(!contains_ignore_case("xxab", "abc"));
}

test "contains_ignore_case: non-ASCII bytes compare exactly" {
    try testing.expect(contains_ignore_case("olé", "olé"));
    try testing.expect(!contains_ignore_case("olé", "OLE"));
}
