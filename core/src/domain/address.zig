//! Email addresses: parse, validate, render.
//!
//! This is an ingress point for attacker-controlled strings, so the parser is
//! strict on purpose. It accepts the forms a mail client actually shows
//! ("Alice <alice@example.com>") and rejects the rest with a specific error,
//! instead of guessing. Display text is sanitized by `Text` on the way in.

const std = @import("std");
const assert = std.debug.assert;
const limits = @import("../limits.zig");
const Text = @import("text.zig").Text;

pub const Address = struct {
    name: Text(limits.name_max) = .{},
    local: Text(limits.local_max) = .{},
    domain: Text(limits.domain_max) = .{},

    pub const ParseError = error{
        Empty,
        UnbalancedBrackets,
        MissingAt,
        MultipleAt,
        EmptyLocal,
        EmptyDomain,
        InvalidLocal,
        InvalidDomain,
        TooLong,
    };

    /// Parses `"Display Name" <local@domain>`, `Display Name <local@domain>`, or
    /// a bare `local@domain`.
    pub fn init(input: []const u8) ParseError!Address {
        const raw = std.mem.trim(u8, input, " \t\r\n");
        if (raw.len == 0) return error.Empty;

        const parts = try split_brackets(raw);
        if (parts.addr.len == 0) return error.EmptyLocal;
        const at_index = std.mem.indexOfScalar(u8, parts.addr, '@') orelse return error.MissingAt;
        if (std.mem.indexOfScalar(u8, parts.addr[at_index + 1 ..], '@') != null) return error.MultipleAt;

        const local = parts.addr[0..at_index];
        const domain = parts.addr[at_index + 1 ..];
        if (local.len == 0) return error.EmptyLocal;
        if (domain.len == 0) return error.EmptyDomain;
        if (local.len > limits.local_max) return error.TooLong;
        if (domain.len > limits.domain_max) return error.TooLong;
        if (local.len + 1 + domain.len > limits.address_max) return error.TooLong;
        if (!valid_local(local)) return error.InvalidLocal;
        if (!valid_domain(domain)) return error.InvalidDomain;

        var address: Address = .{};
        address.name.set(strip_quotes(parts.name));
        address.local.set(local);
        address.domain.set(domain);
        return address;
    }

    /// `local@domain`, written into `buffer`. Returns an empty slice if the
    /// buffer cannot hold it (the caller sizes it with `limits.address_max`).
    pub fn addr_spec(self: *const Address, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}@{s}", .{ self.local.slice(), self.domain.slice() }) catch "";
    }

    /// What the UI shows in a list: the display name, or the local part when the
    /// sender did not provide one.
    pub fn label(self: *const Address) []const u8 {
        if (!self.name.is_empty()) return self.name.slice();
        return self.local.slice();
    }

    pub fn format(self: *const Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.name.is_empty()) {
            try writer.print("{s}@{s}", .{ self.local.slice(), self.domain.slice() });
        } else {
            try writer.print("{s} <{s}@{s}>", .{ self.name.slice(), self.local.slice(), self.domain.slice() });
        }
    }

    pub fn eql(self: *const Address, other: *const Address) bool {
        return self.name.eql(&other.name) and self.local.eql(&other.local) and self.domain.eql(&other.domain);
    }
};

const Parts = struct { name: []const u8, addr: []const u8 };

fn split_brackets(raw: []const u8) Address.ParseError!Parts {
    const open = std.mem.indexOfScalar(u8, raw, '<');
    const close = std.mem.indexOfScalar(u8, raw, '>');
    if (open == null and close == null) return .{ .name = "", .addr = raw };

    const open_index = open orelse return error.UnbalancedBrackets;
    const close_index = close orelse return error.UnbalancedBrackets;
    if (close_index <= open_index) return error.UnbalancedBrackets;
    if (std.mem.trim(u8, raw[close_index + 1 ..], " \t").len != 0) return error.UnbalancedBrackets;

    const name = std.mem.trim(u8, raw[0..open_index], " \t");
    const addr = std.mem.trim(u8, raw[open_index + 1 .. close_index], " \t");
    return .{ .name = name, .addr = addr };
}

fn strip_quotes(name: []const u8) []const u8 {
    if (name.len < 2) return name;
    if (name[0] != '"') return name;
    if (name[name.len - 1] != '"') return name;
    return name[1 .. name.len - 1];
}

fn valid_local(local: []const u8) bool {
    assert(local.len > 0);
    if (local[0] == '.') return false;
    if (local[local.len - 1] == '.') return false;

    var previous_was_dot = false;
    for (local) |byte| {
        if (byte == '.') {
            if (previous_was_dot) return false;
            previous_was_dot = true;
            continue;
        }
        previous_was_dot = false;
        if (!is_atext(byte)) return false;
    }
    return true;
}

/// RFC 5322 atext, the characters allowed in the local part.
fn is_atext(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn valid_domain(domain: []const u8) bool {
    assert(domain.len > 0);
    // Require a dot: catches "user@localhost" typos while still allowing any
    // private server (mail.example.lan, mail.example.org, ...).
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return false;

    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0) return false;
        if (label.len > 63) return false;
        if (label[0] == '-') return false;
        if (label[label.len - 1] == '-') return false;
        for (label) |byte| {
            if (std.ascii.isAlphanumeric(byte)) continue;
            if (byte == '-') continue;
            return false;
        }
    }
    // A trailing dot produces a final empty label, already rejected above, so
    // reaching here means two or more labels.
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expect_rejected(raw: []const u8, expected: Address.ParseError) !void {
    try testing.expectError(expected, Address.init(raw));
}

test "Address: bare addr-spec" {
    const address = try Address.init("alice@example.com");
    try testing.expectEqualStrings("alice", address.local.slice());
    try testing.expectEqualStrings("example.com", address.domain.slice());
    try testing.expect(address.name.is_empty());
    try testing.expectEqualStrings("alice", address.label());
}

test "Address: display name in brackets" {
    const address = try Address.init("Alice Rivera <alice@example.com>");
    try testing.expectEqualStrings("Alice Rivera", address.name.slice());
    try testing.expectEqualStrings("Alice Rivera", address.label());
}

test "Address: quoted display name loses its quotes" {
    const address = try Address.init("\"Rivera, Alice\" <alice@example.com>");
    try testing.expectEqualStrings("Rivera, Alice", address.name.slice());
}

test "Address: surrounding whitespace is ignored" {
    const address = try Address.init("  alice@example.com \r\n");
    try testing.expectEqualStrings("alice", address.local.slice());
}

test "Address: local part accepts RFC atext and single dots" {
    const address = try Address.init("a.b+c_d-e=f@mail.example.org");
    try testing.expectEqualStrings("a.b+c_d-e=f", address.local.slice());
}

test "Address: addr_spec renders local@domain" {
    const address = try Address.init("Alice <alice@example.com>");
    var buffer: [limits.address_max]u8 = undefined;
    try testing.expectEqualStrings("alice@example.com", address.addr_spec(&buffer));
}

test "Address: addr_spec returns empty when the buffer is too small" {
    const address = try Address.init("alice@example.com");
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("", address.addr_spec(&buffer));
}

test "Address: format includes the name only when there is one" {
    var buffer: [128]u8 = undefined;

    const named = try Address.init("Alice <alice@example.com>");
    var writer = std.Io.Writer.fixed(&buffer);
    try named.format(&writer);
    try testing.expectEqualStrings("Alice <alice@example.com>", writer.buffered());

    const bare = try Address.init("alice@example.com");
    writer = std.Io.Writer.fixed(&buffer);
    try bare.format(&writer);
    try testing.expectEqualStrings("alice@example.com", writer.buffered());
}

test "Address: eql compares every component" {
    const a = try Address.init("Alice <alice@example.com>");
    const b = try Address.init("Alice <alice@example.com>");
    const c = try Address.init("Alice <alice@example.org>");
    try testing.expect(a.eql(&b));
    try testing.expect(!a.eql(&c));
}

test "Address: rejects empty and whitespace-only input" {
    try expect_rejected("", error.Empty);
    try expect_rejected("   \t\r\n", error.Empty);
}

test "Address: rejects unbalanced brackets" {
    try expect_rejected("Alice <alice@example.com", error.UnbalancedBrackets);
    try expect_rejected("Alice alice@example.com>", error.UnbalancedBrackets);
    try expect_rejected("Alice >alice@example.com<", error.UnbalancedBrackets);
    try expect_rejected("Alice <alice@example.com> trailing", error.UnbalancedBrackets);
}

test "Address: rejects empty brackets" {
    try expect_rejected("Alice <>", error.EmptyLocal);
}

test "Address: rejects a bracket pair with no at sign" {
    try expect_rejected("Alice <alice.example.com>", error.MissingAt);
}

test "Address: rejects missing and multiple at signs" {
    try expect_rejected("alice.example.com", error.MissingAt);
    try expect_rejected("a@@example.com", error.MultipleAt);
    try expect_rejected("a@b@example.com", error.MultipleAt);
}

test "Address: rejects an empty local part or domain" {
    try expect_rejected("@example.com", error.EmptyLocal);
    try expect_rejected("alice@", error.EmptyDomain);
}

test "Address: rejects invalid local parts" {
    try expect_rejected(".alice@example.com", error.InvalidLocal);
    try expect_rejected("alice.@example.com", error.InvalidLocal);
    try expect_rejected("a..b@example.com", error.InvalidLocal);
    try expect_rejected("alice smith@example.com", error.InvalidLocal);
    try expect_rejected("ali\x01ce@example.com", error.InvalidLocal);
    try expect_rejected("ali\"ce@example.com", error.InvalidLocal);
}

test "Address: rejects invalid domains" {
    try expect_rejected("alice@localhost", error.InvalidDomain);
    try expect_rejected("alice@example..com", error.InvalidDomain);
    try expect_rejected("alice@-example.com", error.InvalidDomain);
    try expect_rejected("alice@example-.com", error.InvalidDomain);
    try expect_rejected("alice@exam_ple.com", error.InvalidDomain);
    try expect_rejected("alice@exam ple.com", error.InvalidDomain);
    try expect_rejected("alice@example.com.", error.InvalidDomain);
}

test "Address: rejects labels longer than 63 bytes" {
    const long_label: [64]u8 = @splat('a');
    var buffer: [128]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buffer, "alice@{s}.com", .{long_label});
    try expect_rejected(raw, error.InvalidDomain);
}

test "Address: rejects parts longer than their RFC limits" {
    var buffer: [limits.local_max + 16]u8 = undefined;
    const long_local: [limits.local_max + 1]u8 = @splat('a');
    const raw = try std.fmt.bufPrint(&buffer, "{s}@example.com", .{long_local});
    try expect_rejected(raw, error.TooLong);

    const long_domain: [limits.domain_max + 1]u8 = @splat('b');
    var domain_buffer: [limits.domain_max + 16]u8 = undefined;
    const raw_domain = try std.fmt.bufPrint(&domain_buffer, "a@{s}", .{long_domain});
    try expect_rejected(raw_domain, error.TooLong);
}

test "Address: rejects a total address longer than RFC 5321" {
    // Each part is within its own limit: 64-byte local, 190-byte domain
    // (63 + 1 + 63 + 1 + 62). Together they exceed the 254-byte addr-spec cap.
    const local: [64]u8 = @splat('a');
    const label: [63]u8 = @splat('b');
    var domain_buffer: [300]u8 = undefined;
    const domain = try std.fmt.bufPrint(&domain_buffer, "{s}.{s}.{s}", .{ label, label, @as([62]u8, @splat('c')) });
    var buffer: [400]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buffer, "{s}@{s}", .{ local, domain });
    try expect_rejected(raw, error.TooLong);
}

test "Address: display name control bytes are neutralized" {
    const address = try Address.init("\x1b[2JEvil <evil@example.com>");
    try testing.expectEqualStrings(" [2JEvil", address.name.slice());
}
