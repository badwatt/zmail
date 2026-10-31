//! Account configuration: a strict `key = value` file.
//!
//! Strict on purpose. An unknown key is an error (a typo must not silently
//! disable TLS), transport security has no default (it must be stated), and
//! passwords are refused outright: they belong in the secret store, never in a
//! file that gets committed, shared, or backed up in the clear.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("limits.zig");
const Text = @import("domain/text.zig").Text;
const Address = @import("domain/address.zig").Address;
const account = @import("domain/account.zig");

pub const Config = struct {
    label: Text(limits.label_max) = .{},
    address: Address = .{},
    username: Text(limits.username_max) = .{},
    imap: account.Server = .{},
    policy: account.Policy = .{},

    pub fn validate(self: *const Config) account.RuleError!void {
        try account.validate_server(&self.imap, self.policy);
    }
};

pub const Error = error{
    MissingKey,
    UnknownKey,
    MissingEquals,
    InvalidValue,
    PasswordInConfig,
    TooLong,
};

/// Parses a config file. Returns the first problem; nothing is sanitized away.
pub fn parse(text: []const u8) (Error || account.RuleError || Address.ParseError)!Config {
    var config = Config{};
    var seen_address = false;
    var seen_host = false;
    var seen_port = false;
    var seen_security = false;
    var seen_username = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingEquals;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidValue;

        if (std.mem.eql(u8, key, "address")) {
            config.address = try Address.init(value);
            seen_address = true;
        } else if (std.mem.eql(u8, key, "label")) {
            config.label.set(value);
        } else if (std.mem.eql(u8, key, "username")) {
            config.username.set(value);
            seen_username = true;
        } else if (std.mem.eql(u8, key, "imap_host")) {
            config.imap.host.set(value);
            seen_host = true;
        } else if (std.mem.eql(u8, key, "imap_port")) {
            config.imap.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            seen_port = true;
        } else if (std.mem.eql(u8, key, "imap_security")) {
            config.imap.security = parseSecurity(value) orelse return error.InvalidValue;
            seen_security = true;
        } else if (std.mem.eql(u8, key, "allow_plaintext")) {
            config.policy.allow_plaintext = parseBool(value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "password")) {
            // Refused by name so the error is actionable.
            return error.PasswordInConfig;
        } else {
            return error.UnknownKey;
        }
    }

    if (!seen_address) return error.MissingKey;
    if (!seen_host) return error.MissingKey;
    if (!seen_port) return error.MissingKey;
    if (!seen_security) return error.MissingKey;
    if (!seen_username) return error.MissingKey;
    if (config.label.is_empty()) config.label.set("account");

    try config.validate();
    return config;
}

fn parseSecurity(value: []const u8) ?account.Security {
    if (std.mem.eql(u8, value, "tls")) return .tls;
    if (std.mem.eql(u8, value, "starttls")) return .starttls;
    if (std.mem.eql(u8, value, "plain")) return .plain;
    return null;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const full_config =
    \\# amail account
    \\address = alice@example.com
    \\label = work
    \\username = alice
    \\imap_host = imap.example.com
    \\imap_port = 993
    \\imap_security = tls
    \\
;

test "a complete config parses into an account" {
    const config = try parse(full_config);
    var addr_buffer: [limits.address_max]u8 = undefined;
    try testing.expectEqualStrings("alice@example.com", config.address.addr_spec(&addr_buffer));
    try testing.expectEqualStrings("work", config.label.slice());
    try testing.expectEqualStrings("alice", config.username.slice());
    try testing.expectEqualStrings("imap.example.com", config.imap.host.slice());
    try testing.expectEqual(@as(u16, 993), config.imap.port);
    try testing.expectEqual(account.Security.tls, config.imap.security);
    try testing.expect(!config.policy.allow_plaintext);
    try config.validate();
}

test "comments, blank lines, and surrounding whitespace are ignored" {
    const text =
        \\
        \\   # a comment
        \\  address   =   alice@example.com
        \\
        \\# another
        \\username=alice
        \\imap_host = imap.example.com
        \\imap_port = 143
        \\imap_security = starttls
        \\
    ;
    const config = try parse(text);
    try testing.expectEqual(@as(u16, 143), config.imap.port);
    try testing.expectEqual(account.Security.starttls, config.imap.security);
}

test "label defaults to account and allow_plaintext is parsed" {
    const text =
        \\address = alice@example.com
        \\username = alice
        \\imap_host = 127.0.0.1
        \\imap_port = 1143
        \\imap_security = plain
        \\allow_plaintext = true
    ;
    const config = try parse(text);
    try testing.expectEqualStrings("account", config.label.slice());
    try testing.expect(config.policy.allow_plaintext);
    try config.validate();
}

test "plaintext is refused without an explicit opt-in" {
    const text =
        \\address = alice@example.com
        \\username = alice
        \\imap_host = imap.example.com
        \\imap_port = 143
        \\imap_security = plain
    ;
    try testing.expectError(error.PlaintextForbidden, parse(text));
}

test "a password in the config is refused by name" {
    try testing.expectError(error.PasswordInConfig, parse(
        \\address = alice@example.com
        \\password = hunter2
    ));
}

test "unknown keys and missing keys are errors" {
    try testing.expectError(error.UnknownKey, parse(
        \\address = alice@example.com
        \\imap_tls = yes
    ));
    try testing.expectError(error.MissingKey, parse(""));
    try testing.expectError(error.MissingKey, parse(
        \\address = alice@example.com
        \\username = alice
        \\imap_host = imap.example.com
    ));
}

test "malformed lines and values are errors" {
    try testing.expectError(error.MissingEquals, parse("address alice@example.com"));
    try testing.expectError(error.InvalidValue, parse("= alice@example.com"));
    try testing.expectError(error.InvalidValue, parse("address = "));
    try testing.expectError(error.InvalidValue, parse(
        \\address = alice@example.com
        \\imap_port = 99999
    ));
    try testing.expectError(error.InvalidValue, parse(
        \\address = alice@example.com
        \\imap_security = maybe
    ));
    try testing.expectError(error.InvalidValue, parse(
        \\address = alice@example.com
        \\allow_plaintext = yes
    ));
}

test "an invalid address is reported by the address parser" {
    try testing.expectError(error.MissingAt, parse(
        \\address = not-an-address
        \\username = alice
        \\imap_host = imap.example.com
        \\imap_port = 993
        \\imap_security = tls
    ));
}

test "zero ports and invalid hosts are refused by the account rules" {
    try testing.expectError(error.InvalidPort, parse(
        \\address = alice@example.com
        \\username = alice
        \\imap_host = imap.example.com
        \\imap_port = 0
        \\imap_security = tls
    ));
    try testing.expectError(error.InvalidHost, parse(
        \\address = alice@example.com
        \\username = alice
        \\imap_host = imap example.com
        \\imap_port = 993
        \\imap_security = tls
    ));
}
