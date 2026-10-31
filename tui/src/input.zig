//! Bytes in, keys out.
//!
//! A terminal delivers escape sequences in whatever chunks the kernel feels
//! like, so the parser is stateful across reads. It understands the sequences
//! that real terminals send: CSI/SS3 arrows and navigation keys, and SGR mouse
//! reports (`ESC [ < b ; x ; y M`). Mouse coordinates are converted to
//! zero-based cells here, so nothing downstream deals with 1-based input.

const std = @import("std");
const assert = std.debug.assert;

pub const Mouse = struct {
    kind: Kind,
    button: Button,
    /// Zero-based cell coordinates.
    x: u16,
    y: u16,

    pub const Kind = enum { press, release, motion };

    pub const Button = enum {
        left,
        middle,
        right,
        none,
        wheel_up,
        wheel_down,
        wheel_left,
        wheel_right,
    };
};

pub const Key = union(enum) {
    char: u21,
    enter,
    tab,
    back_tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    insert,
    /// `ctrl` with a letter, lowercase ('a'..'z'), or ' ' for Ctrl+Space.
    ctrl: u8,
    mouse: Mouse,
    unknown,
};

pub const keys_max: u32 = 32;

pub const Keys = struct {
    items: [keys_max]Key = undefined,
    len: u32 = 0,

    pub fn add(self: *Keys, key: Key) void {
        assert(self.len < keys_max);
        self.items[self.len] = key;
        self.len += 1;
    }

    pub fn slice(self: *const Keys) []const Key {
        return self.items[0..self.len];
    }
};

const State = enum { ground, escape, csi, ss3, utf8 };

pub const Parser = struct {
    state: State = .ground,
    csi: [24]u8 = undefined,
    csi_len: u8 = 0,
    utf8_bytes: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,

    /// Decodes a whole read buffer. Keys accumulate in `keys`.
    pub fn decode(self: *Parser, bytes: []const u8, keys: *Keys) void {
        for (bytes) |byte| self.step(byte, keys);
    }

    /// Resolves a dangling escape sequence after a read timeout.
    ///
    /// A lone ESC is the Escape key (terminals do not send anything else); a
    /// half-received CSI or UTF-8 sequence is dropped as `unknown`.
    pub fn flush(self: *Parser) ?Key {
        switch (self.state) {
            .ground => return null,
            .escape => {
                self.state = .ground;
                return .escape;
            },
            .csi, .ss3, .utf8 => {
                self.reset();
                return .unknown;
            },
        }
    }

    fn reset(self: *Parser) void {
        self.state = .ground;
        self.csi_len = 0;
        self.utf8_len = 0;
        self.utf8_need = 0;
    }

    fn step(self: *Parser, byte: u8, keys: *Keys) void {
        switch (self.state) {
            .ground => self.ground(byte, keys),
            .escape => self.escape(byte, keys),
            .csi => self.csi_byte(byte, keys),
            .ss3 => self.ss3_byte(byte, keys),
            .utf8 => self.utf8_byte(byte, keys),
        }
    }

    fn ground(self: *Parser, byte: u8, keys: *Keys) void {
        if (byte == 0x1b) {
            self.state = .escape;
            return;
        }
        if (byte == '\r' or byte == '\n') {
            keys.add(.enter);
            return;
        }
        if (byte == '\t') {
            keys.add(.tab);
            return;
        }
        if (byte == 0x7f or byte == 0x08) {
            keys.add(.backspace);
            return;
        }
        if (byte < 0x20) {
            keys.add(.{ .ctrl = ctrl_letter(byte) });
            return;
        }
        if (byte < 0x80) {
            keys.add(.{ .char = byte });
            return;
        }

        const need = std.unicode.utf8ByteSequenceLength(byte) catch {
            keys.add(.{ .char = '?' });
            return;
        };
        self.state = .utf8;
        self.utf8_bytes[0] = byte;
        self.utf8_len = 1;
        self.utf8_need = @intCast(need);
    }

    fn escape(self: *Parser, byte: u8, keys: *Keys) void {
        if (byte == '[') {
            self.state = .csi;
            self.csi_len = 0;
            return;
        }
        if (byte == 'O') {
            self.state = .ss3;
            return;
        }

        // Alt+key: report Escape, then the key itself.
        self.state = .ground;
        keys.add(.escape);
        self.ground(byte, keys);
    }

    fn csi_byte(self: *Parser, byte: u8, keys: *Keys) void {
        if (self.csi_len == self.csi.len) {
            self.reset();
            keys.add(.unknown);
            return;
        }
        self.csi[self.csi_len] = byte;
        self.csi_len += 1;

        // Parameter bytes are 0x30..0x3f; the final byte ends the sequence.
        if (byte < 0x40 or byte > 0x7e) return;

        const params = self.csi[0 .. self.csi_len - 1];
        const final = byte;
        self.reset();
        keys.add(csi_key(params, final));
    }

    fn ss3_byte(self: *Parser, byte: u8, keys: *Keys) void {
        self.state = .ground;
        keys.add(switch (byte) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => .unknown,
        });
    }

    fn utf8_byte(self: *Parser, byte: u8, keys: *Keys) void {
        assert(self.utf8_need <= self.utf8_bytes.len);
        assert(self.utf8_len < self.utf8_need);
        self.utf8_bytes[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len < self.utf8_need) return;

        const codepoint = std.unicode.utf8Decode(self.utf8_bytes[0..self.utf8_len]) catch {
            self.reset();
            keys.add(.unknown);
            return;
        };
        self.reset();
        keys.add(.{ .char = codepoint });
    }
};

/// C0 control bytes map onto `Ctrl+<letter>`.
fn ctrl_letter(byte: u8) u8 {
    assert(byte < 0x20);
    return switch (byte) {
        0x00 => ' ',
        0x1c => '\\',
        0x1d => ']',
        0x1e => '^',
        0x1f => '_',
        else => 'a' + (byte - 1),
    };
}

fn csi_key(params: []const u8, final: u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .back_tab,
        'M', 'm' => parse_mouse(params, final) orelse .unknown,
        '~' => tilde_key(params),
        else => .unknown,
    };
}

fn tilde_key(params: []const u8) Key {
    if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) return .home;
    if (std.mem.eql(u8, params, "2")) return .insert;
    if (std.mem.eql(u8, params, "3")) return .delete;
    if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) return .end;
    if (std.mem.eql(u8, params, "5")) return .page_up;
    if (std.mem.eql(u8, params, "6")) return .page_down;
    return .unknown;
}

/// SGR mouse: `ESC [ < button ; x ; y M` for press/motion, `m` for release.
fn parse_mouse(params: []const u8, final: u8) ?Key {
    if (params.len < 2) return null;
    if (params[0] != '<') return null;

    var fields = std.mem.splitScalar(u8, params[1..], ';');
    const code = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;

    const button: Mouse.Button = if (code & 64 != 0)
        switch (code & 3) {
            0 => .wheel_up,
            1 => .wheel_down,
            2 => .wheel_left,
            else => .wheel_right,
        }
    else switch (code & 3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };

    const kind: Mouse.Kind = if (code & 32 != 0)
        .motion
    else if (final == 'm')
        .release
    else
        .press;

    return .{ .mouse = .{
        .kind = kind,
        .button = button,
        .x = @intCast(x -| 1),
        .y = @intCast(y -| 1),
    } };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn decode(bytes: []const u8) !Keys {
    var parser: Parser = .{};
    var keys: Keys = .{};
    parser.decode(bytes, &keys);
    return keys;
}

fn single(bytes: []const u8) !Key {
    const keys = try decode(bytes);
    try testing.expectEqual(@as(u32, 1), keys.len);
    return keys.items[0];
}

/// For malformed sequences that legitimately decode into several keys.
fn first(bytes: []const u8) !Key {
    const keys = try decode(bytes);
    try testing.expect(keys.len > 0);
    return keys.items[0];
}

test "printable ASCII becomes a character key" {
    try testing.expectEqual(@as(u21, 'j'), (try single("j")).char);
    try testing.expectEqual(@as(u21, ' '), (try single(" ")).char);
    try testing.expectEqual(@as(u21, '~'), (try single("~")).char);
}

test "control keys are recognized" {
    try testing.expectEqual(Key.enter, try single("\r"));
    try testing.expectEqual(Key.enter, try single("\n"));
    try testing.expectEqual(Key.tab, try single("\t"));
    try testing.expectEqual(Key.backspace, try single("\x7f"));
    try testing.expectEqual(Key.backspace, try single("\x08"));
}

test "ctrl letters map to their lowercase letter" {
    try testing.expectEqual(@as(u8, 'a'), (try single("\x01")).ctrl);
    try testing.expectEqual(@as(u8, 'c'), (try single("\x03")).ctrl);
    try testing.expectEqual(@as(u8, 'd'), (try single("\x04")).ctrl);
    try testing.expectEqual(@as(u8, 'z'), (try single("\x1a")).ctrl);
}

test "ctrl punctuation maps to its printable key" {
    try testing.expectEqual(@as(u8, ' '), (try single("\x00")).ctrl);
    try testing.expectEqual(@as(u8, '\\'), (try single("\x1c")).ctrl);
    try testing.expectEqual(@as(u8, ']'), (try single("\x1d")).ctrl);
    try testing.expectEqual(@as(u8, '^'), (try single("\x1e")).ctrl);
    try testing.expectEqual(@as(u8, '_'), (try single("\x1f")).ctrl);
}

test "CSI arrows and navigation keys" {
    try testing.expectEqual(Key.up, try single("\x1b[A"));
    try testing.expectEqual(Key.down, try single("\x1b[B"));
    try testing.expectEqual(Key.right, try single("\x1b[C"));
    try testing.expectEqual(Key.left, try single("\x1b[D"));
    try testing.expectEqual(Key.home, try single("\x1b[H"));
    try testing.expectEqual(Key.end, try single("\x1b[F"));
    try testing.expectEqual(Key.back_tab, try single("\x1b[Z"));
}

test "SS3 arrows are understood too" {
    try testing.expectEqual(Key.up, try single("\x1bOA"));
    try testing.expectEqual(Key.down, try single("\x1bOB"));
    try testing.expectEqual(Key.right, try single("\x1bOC"));
    try testing.expectEqual(Key.left, try single("\x1bOD"));
    try testing.expectEqual(Key.home, try single("\x1bOH"));
    try testing.expectEqual(Key.end, try single("\x1bOF"));
    try testing.expectEqual(Key.unknown, try single("\x1bOP"));
}

test "tilde sequences cover insert, delete, and paging" {
    try testing.expectEqual(Key.insert, try single("\x1b[2~"));
    try testing.expectEqual(Key.delete, try single("\x1b[3~"));
    try testing.expectEqual(Key.page_up, try single("\x1b[5~"));
    try testing.expectEqual(Key.page_down, try single("\x1b[6~"));
    try testing.expectEqual(Key.home, try single("\x1b[1~"));
    try testing.expectEqual(Key.home, try single("\x1b[7~"));
    try testing.expectEqual(Key.end, try single("\x1b[4~"));
    try testing.expectEqual(Key.end, try single("\x1b[8~"));
    try testing.expectEqual(Key.unknown, try single("\x1b[9~"));
}

test "modified arrows still report the arrow" {
    try testing.expectEqual(Key.up, try single("\x1b[1;5A"));
    try testing.expectEqual(Key.down, try single("\x1b[1;2B"));
}

test "unknown CSI sequences are reported as unknown, not dropped silently" {
    try testing.expectEqual(Key.unknown, try single("\x1b[?25h"));
    try testing.expectEqual(Key.unknown, try single("\x1b[200~"));
}

test "SGR mouse press, release, and wheel" {
    const press = try single("\x1b[<0;10;5M");
    try testing.expectEqual(Mouse.Kind.press, press.mouse.kind);
    try testing.expectEqual(Mouse.Button.left, press.mouse.button);
    try testing.expectEqual(@as(u16, 9), press.mouse.x);
    try testing.expectEqual(@as(u16, 4), press.mouse.y);

    const release = try single("\x1b[<0;10;5m");
    try testing.expectEqual(Mouse.Kind.release, release.mouse.kind);

    const wheel_up = try single("\x1b[<64;3;4M");
    try testing.expectEqual(Mouse.Button.wheel_up, wheel_up.mouse.button);
    const wheel_down = try single("\x1b[<65;3;4M");
    try testing.expectEqual(Mouse.Button.wheel_down, wheel_down.mouse.button);
    const wheel_left = try single("\x1b[<66;3;4M");
    try testing.expectEqual(Mouse.Button.wheel_left, wheel_left.mouse.button);
    const wheel_right = try single("\x1b[<67;3;4M");
    try testing.expectEqual(Mouse.Button.wheel_right, wheel_right.mouse.button);
}

test "SGR mouse drag is reported as motion" {
    const drag = try single("\x1b[<32;8;9M");
    try testing.expectEqual(Mouse.Kind.motion, drag.mouse.kind);
    try testing.expectEqual(Mouse.Button.left, drag.mouse.button);
}

test "SGR mouse other buttons" {
    try testing.expectEqual(Mouse.Button.middle, (try single("\x1b[<1;1;1M")).mouse.button);
    try testing.expectEqual(Mouse.Button.right, (try single("\x1b[<2;1;1M")).mouse.button);
    try testing.expectEqual(Mouse.Button.none, (try single("\x1b[<3;1;1M")).mouse.button);
}

test "malformed mouse reports are unknown" {
    try testing.expectEqual(Key.unknown, try first("\x1b[Mxy"));
    try testing.expectEqual(Key.unknown, try first("\x1b[<a;1;1M"));
    try testing.expectEqual(Key.unknown, try single("\x1b[<1;1;1;1M"));
    try testing.expectEqual(Key.unknown, try single("\x1b[<1;1M"));
}

test "a lone escape is resolved by flush" {
    var parser: Parser = .{};
    var keys: Keys = .{};
    parser.decode("\x1b", &keys);
    try testing.expectEqual(@as(u32, 0), keys.len);
    try testing.expectEqual(Key.escape, parser.flush().?);
    try testing.expect(parser.flush() == null);
}

test "alt+key reports escape and the key" {
    const keys = try decode("\x1bx");
    try testing.expectEqual(@as(u32, 2), keys.len);
    try testing.expectEqual(Key.escape, keys.items[0]);
    try testing.expectEqual(@as(u21, 'x'), keys.items[1].char);
}

test "a partial CSI sequence is dropped on flush" {
    var parser: Parser = .{};
    var keys: Keys = .{};
    parser.decode("\x1b[1;", &keys);
    try testing.expectEqual(@as(u32, 0), keys.len);
    try testing.expectEqual(Key.unknown, parser.flush().?);
}

test "a partial UTF-8 sequence is dropped on flush" {
    var parser: Parser = .{};
    var keys: Keys = .{};
    parser.decode("\xc3", &keys);
    try testing.expectEqual(@as(u32, 0), keys.len);
    try testing.expectEqual(Key.unknown, parser.flush().?);
}

test "UTF-8 characters decode whole, even split across reads" {
    var parser: Parser = .{};
    var keys: Keys = .{};
    parser.decode("a", &keys);
    parser.decode("\xc3", &keys);
    parser.decode("\xa9", &keys);
    try testing.expectEqual(@as(u32, 2), keys.len);
    try testing.expectEqual(@as(u21, 'a'), keys.items[0].char);
    try testing.expectEqual(@as(u21, 0xe9), keys.items[1].char);
}

test "three-byte characters decode whole" {
    const key = try single("\xe2\x82\xac");
    try testing.expectEqual(@as(u21, 0x20ac), key.char);
}

test "invalid UTF-8 bytes report unknown" {
    try testing.expectEqual(Key.unknown, try single("\xc3\x28"));
    try testing.expectEqual(@as(u21, '?'), (try single("\xff")).char);
}

test "a full CSI buffer overflows to unknown without corrupting the parser" {
    var parser: Parser = .{};
    var keys: Keys = .{};
    var index: u32 = 0;
    parser.decode("\x1b[", &keys);
    while (index < 32) : (index += 1) parser.decode("1", &keys);
    try testing.expectEqual(Key.unknown, keys.items[0]);
    parser.decode("x", &keys);
    try testing.expectEqual(@as(u21, 'x'), keys.items[keys.len - 1].char);
}

test "a long paste decodes into many keys" {
    var keys: Keys = .{};
    var parser: Parser = .{};
    parser.decode("the quick", &keys);
    try testing.expectEqual(@as(u32, 9), keys.len);
    try testing.expectEqual(@as(u21, 't'), keys.items[0].char);
    try testing.expectEqual(@as(u21, 'k'), keys.items[8].char);
}
