//! IMAP wire tokenizer.
//!
//! IMAP is text until it is not: atoms, quoted strings with escapes, and
//! literals (`{42}\r\n<42 bytes>`). This tokenizer turns one buffer of wire
//! bytes into tokens without allocating, so the response parser above it stays
//! a pure function.
//!
//! The tokenizer never guesses. A truncated literal or an unterminated quoted
//! string is an error, not a partial token: the caller asks for more bytes.

const std = @import("std");
const assert = std.debug.assert;

pub const Token = union(enum) {
    /// Unquoted run of bytes: keywords, numbers, flags (`\Seen`).
    atom: []const u8,
    /// Contents between quotes, still escaped. Use `unescape` to read it.
    quoted: []const u8,
    /// Payload of a `{n}\r\n` literal.
    literal: []const u8,
    open_paren,
    close_paren,
};

pub const Error = error{
    UnexpectedCharacter,
    UnterminatedQuoted,
    InvalidEscape,
    UnterminatedLiteral,
    InvalidLiteralSize,
    NoSpaceLeft,
};

pub const Tokenizer = struct {
    input: []const u8,
    index: u32 = 0,

    pub fn init(input: []const u8) Tokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) Error!?Token {
        while (self.index < self.input.len and self.input[self.index] == ' ') {
            self.index += 1;
        }
        if (self.index == self.input.len) return null;

        return switch (self.input[self.index]) {
            '(' => blk: {
                self.index += 1;
                break :blk .open_paren;
            },
            ')' => blk: {
                self.index += 1;
                break :blk .close_paren;
            },
            '"' => try self.quoted(),
            '{' => try self.literal(),
            else => .{ .atom = self.atom() orelse return error.UnexpectedCharacter },
        };
    }

    fn atom(self: *Tokenizer) ?[]const u8 {
        const start = self.index;
        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '(', ')', '"', '{', '\r', '\n' => break,
                else => {},
            }
        }
        if (self.index == start) return null;
        return self.input[start..self.index];
    }

    fn quoted(self: *Tokenizer) Error!Token {
        self.index += 1; // Opening quote.
        const start = self.index;
        while (self.index < self.input.len) {
            switch (self.input[self.index]) {
                '\\' => {
                    self.index += 1;
                    if (self.index == self.input.len) return error.UnterminatedQuoted;
                    self.index += 1;
                },
                '"' => {
                    const content = self.input[start..self.index];
                    self.index += 1;
                    return .{ .quoted = content };
                },
                else => self.index += 1,
            }
        }
        return error.UnterminatedQuoted;
    }

    fn literal(self: *Tokenizer) Error!Token {
        assert(self.input[self.index] == '{');
        const size_start = self.index + 1;
        var size_end = size_start;
        while (size_end < self.input.len and std.ascii.isDigit(self.input[size_end])) {
            size_end += 1;
        }
        if (size_end == size_start) return error.InvalidLiteralSize;
        if (size_end == self.input.len) return error.InvalidLiteralSize;
        if (self.input[size_end] != '}') return error.InvalidLiteralSize;

        const size = std.fmt.parseInt(u32, self.input[size_start..size_end], 10) catch
            return error.InvalidLiteralSize;

        var cursor = size_end + 1;
        if (cursor + 2 > self.input.len) return error.UnterminatedLiteral;
        if (self.input[cursor] != '\r' or self.input[cursor + 1] != '\n') {
            return error.UnterminatedLiteral;
        }
        cursor += 2;
        if (size > self.input.len - cursor) return error.UnterminatedLiteral;
        if (size > std.math.maxInt(u31)) return error.InvalidLiteralSize;

        self.index = cursor + size;
        return .{ .literal = self.input[cursor..self.index] };
    }
};

/// Copies `source` without its quoting escapes. Returns the bytes written.
pub fn unescape(source: []const u8, out: []u8) Error![]const u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < source.len) {
        const byte = source[read];
        if (byte == '\\') {
            read += 1;
            if (read == source.len) return error.InvalidEscape;
            if (write == out.len) return error.NoSpaceLeft;
            out[write] = source[read];
            write += 1;
            read += 1;
            continue;
        }
        if (write == out.len) return error.NoSpaceLeft;
        out[write] = byte;
        write += 1;
        read += 1;
    }
    return out[0..write];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tokens(input: []const u8, buffer: []Token) ![]Token {
    var tokenizer = Tokenizer.init(input);
    var count: usize = 0;
    while (try tokenizer.next()) |token| {
        try testing.expect(count < buffer.len);
        buffer[count] = token;
        count += 1;
    }
    return buffer[0..count];
}

test "atoms, numbers, and flags" {
    var buffer: [8]Token = undefined;
    const result = try tokens("* 12 FETCH \\Seen", &buffer);
    try testing.expectEqual(@as(usize, 4), result.len);
    try testing.expectEqualStrings("*", result[0].atom);
    try testing.expectEqualStrings("12", result[1].atom);
    try testing.expectEqualStrings("FETCH", result[2].atom);
    try testing.expectEqualStrings("\\Seen", result[3].atom);
}

test "parentheses are their own tokens" {
    var buffer: [8]Token = undefined;
    const result = try tokens("(FLAGS (\\Seen \\Flagged))", &buffer);
    try testing.expectEqual(Token.open_paren, result[0]);
    try testing.expectEqualStrings("FLAGS", result[1].atom);
    try testing.expectEqual(Token.open_paren, result[2]);
    try testing.expectEqualStrings("\\Seen", result[3].atom);
    try testing.expectEqualStrings("\\Flagged", result[4].atom);
    try testing.expectEqual(Token.close_paren, result[5]);
    try testing.expectEqual(Token.close_paren, result[6]);
}

test "runs of spaces collapse" {
    var buffer: [4]Token = undefined;
    const result = try tokens("  a    b  ", &buffer);
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "quoted strings keep their escapes" {
    var buffer: [4]Token = undefined;
    const result = try tokens("\"hello \\\"world\\\"\"", &buffer);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("hello \\\"world\\\"", result[0].quoted);
}

test "empty quoted strings are valid" {
    var buffer: [4]Token = undefined;
    const result = try tokens("\"\"", &buffer);
    try testing.expectEqualStrings("", result[0].quoted);
}

test "literals carry their payload" {
    var buffer: [4]Token = undefined;
    const result = try tokens("{5}\r\nhello after", &buffer);
    try testing.expectEqualStrings("hello", result[0].literal);
    try testing.expectEqualStrings("after", result[1].atom);
}

test "an empty literal is valid" {
    var buffer: [2]Token = undefined;
    const result = try tokens("{0}\r\n", &buffer);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("", result[0].literal);
}

test "a literal size mismatch is an error, never a partial token" {
    var tokenizer = Tokenizer.init("{9}\r\nshort");
    try testing.expectError(error.UnterminatedLiteral, tokenizer.next());
}

test "a literal without CRLF after the size is an error" {
    var tokenizer = Tokenizer.init("{3}abc");
    try testing.expectError(error.UnterminatedLiteral, tokenizer.next());
}

test "a malformed literal size is an error" {
    var tokenizer = Tokenizer.init("{x}\r\n");
    try testing.expectError(error.InvalidLiteralSize, tokenizer.next());

    tokenizer = Tokenizer.init("{12x}\r\n");
    try testing.expectError(error.InvalidLiteralSize, tokenizer.next());

    tokenizer = Tokenizer.init("{");
    try testing.expectError(error.InvalidLiteralSize, tokenizer.next());
}

test "an unterminated quoted string is an error" {
    var tokenizer = Tokenizer.init("\"no end");
    try testing.expectError(error.UnterminatedQuoted, tokenizer.next());
}

test "a trailing escape is an error" {
    var tokenizer = Tokenizer.init("\"abc\\");
    try testing.expectError(error.UnterminatedQuoted, tokenizer.next());
}

test "a bare line ending cannot start an atom" {
    var tokenizer = Tokenizer.init("\r\n");
    try testing.expectError(error.UnexpectedCharacter, tokenizer.next());
}

test "a quoted string followed by an atom is two tokens" {
    var tokenizer = Tokenizer.init("\"\"x");
    try testing.expectEqualStrings("", (try tokenizer.next()).?.quoted);
    try testing.expectEqualStrings("x", (try tokenizer.next()).?.atom);
}

test "the end of input yields null" {
    var tokenizer = Tokenizer.init("");
    try testing.expect(try tokenizer.next() == null);

    tokenizer = Tokenizer.init("   ");
    try testing.expect(try tokenizer.next() == null);
}

test "unescape removes backslashes" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("a\"b\\c", try unescape("a\\\"b\\\\c", &out));
}

test "unescape keeps plain bytes and reports a full buffer" {
    var out: [3]u8 = undefined;
    try testing.expectEqualStrings("abc", try unescape("abc", &out));
    try testing.expectError(error.NoSpaceLeft, unescape("abcd", &out));
}

test "unescape rejects a trailing escape" {
    var out: [8]u8 = undefined;
    try testing.expectError(error.InvalidEscape, unescape("abc\\", &out));
}
