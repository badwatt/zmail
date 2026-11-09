//! Accounts and their servers.
//!
//! Validation returns an error instead of sanitizing silently, because the user
//! must be told when zmail refuses a configuration. Plaintext transport is
//! rejected unless the caller explicitly opts in.

const std = @import("std");
const assert = std.debug.assert;
const limits = @import("../limits.zig");
const Text = @import("text.zig").Text;
const Address = @import("address.zig").Address;

pub const Security = enum {
    /// Implicit TLS (IMAPS on 993, SMTPS on 465).
    tls,
    /// Upgrade with STARTTLS on the plaintext port (143, 587).
    starttls,
    /// No transport security. Only for a server on the same machine.
    plain,
};

pub const Server = struct {
    host: Text(limits.host_max) = .{},
    port: u16 = 0,
    security: Security = .tls,
};

pub const Account = struct {
    label: Text(limits.label_max) = .{},
    address: Address = .{},
    username: Text(limits.username_max) = .{},
    imap: Server = .{},
    smtp: Server = .{},
};

pub const Policy = struct {
    allow_plaintext: bool = false,
};

pub const RuleError = error{
    EmptyHost,
    InvalidHost,
    InvalidPort,
    PlaintextForbidden,
};

/// The port actually dialled for a server, given how it is protected.
///
/// 587 and 25 are the plaintext submission ports: TLS there starts with
/// `STARTTLS`, which this client does not speak yet, so a config that asks for
/// implicit TLS on one of them cannot connect -- not rarely, never. The port that
/// can is 465, and the setup assistant used to write exactly the pair that cannot
/// work. Answering 465 is not a guess: it is the only port on which the security
/// the user chose means anything.
pub fn dialPort(server: Server) u16 {
    if (server.security != .tls) return server.port;
    return switch (server.port) {
        25, 587 => 465,
        else => server.port,
    };
}

/// Whether the port had to be corrected, so the caller can say so instead of
/// connecting to a number the user never wrote.
pub fn portCorrected(server: Server) bool {
    return dialPort(server) != server.port;
}

pub fn validate(account: *const Account, policy: Policy) RuleError!void {
    try validate_server(&account.imap, policy);
    try validate_server(&account.smtp, policy);
}

pub fn validate_server(server: *const Server, policy: Policy) RuleError!void {
    if (server.host.is_empty()) return error.EmptyHost;
    if (!valid_host(server.host.slice())) return error.InvalidHost;
    if (server.port == 0) return error.InvalidPort;
    if (server.security == .plain) {
        if (!policy.allow_plaintext) return error.PlaintextForbidden;
    }
}

/// A host name or IP literal. No spaces, no slashes, no controls: the host is
/// interpolated into a URL-like string for the network adapter.
fn valid_host(host: []const u8) bool {
    assert(host.len > 0);
    for (host) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '-', '_', ':', '[', ']' => continue,
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn make_server(host: []const u8, port: u16, security: Security) Server {
    var result = Server{ .port = port, .security = security };
    result.host.set(host);
    return result;
}

fn account_with(imap: Server, smtp: Server) Account {
    return .{
        .label = Text(limits.label_max).init("work"),
        .address = Address.init("alice@example.com") catch unreachable,
        .username = Text(limits.username_max).init("alice"),
        .imap = imap,
        .smtp = smtp,
    };
}

test "validate accepts implicit TLS on both servers" {
    const account = account_with(
        make_server("imap.example.com", 993, .tls),
        make_server("smtp.example.com", 465, .tls),
    );
    try validate(&account, .{});
}

test "validate accepts STARTTLS on both servers" {
    const account = account_with(
        make_server("imap.example.com", 143, .starttls),
        make_server("smtp.example.com", 587, .starttls),
    );
    try validate(&account, .{});
}

test "validate rejects plaintext transport by default" {
    const account = account_with(
        make_server("imap.example.com", 143, .plain),
        make_server("smtp.example.com", 587, .starttls),
    );
    try testing.expectError(error.PlaintextForbidden, validate(&account, .{}));
}

test "validate allows plaintext only with an explicit opt-in" {
    const account = account_with(
        make_server("localhost", 1143, .plain),
        make_server("localhost", 1025, .plain),
    );
    try validate(&account, .{ .allow_plaintext = true });
}

test "validate rejects an empty host" {
    const account = account_with(
        Server{ .port = 993, .security = .tls },
        make_server("smtp.example.com", 465, .tls),
    );
    try testing.expectError(error.EmptyHost, validate(&account, .{}));
}

test "validate rejects a host with characters that are not a host" {
    const account = account_with(
        make_server("imap example.com", 993, .tls),
        make_server("smtp.example.com", 465, .tls),
    );
    try testing.expectError(error.InvalidHost, validate(&account, .{}));
}

test "validate rejects port zero" {
    const account = account_with(
        make_server("imap.example.com", 0, .tls),
        make_server("smtp.example.com", 465, .tls),
    );
    try testing.expectError(error.InvalidPort, validate(&account, .{}));
}

test "validate_server accepts IP literals and bracketed IPv6 hosts" {
    var ipv4 = make_server("192.0.2.10", 993, .tls);
    try validate_server(&ipv4, .{});
    var ipv6 = make_server("[2001:db8::1]", 993, .tls);
    try validate_server(&ipv6, .{});
    var internal = make_server("mail.internal_lan", 993, .tls);
    try validate_server(&internal, .{});
}

test "the port dialled is the one the security can work on" {
    var implicit = Server{ .port = 465 };
    implicit.host.set("smtp.example.com");
    try testing.expectEqual(@as(u16, 465), dialPort(implicit));
    try testing.expect(!portCorrected(implicit));

    // The pair the assistant wrote for Gmail, and which cannot connect: a TLS
    // handshake on a plaintext submission port.
    var broken = implicit;
    broken.port = 587;
    try testing.expectEqual(@as(u16, 465), dialPort(broken));
    try testing.expect(portCorrected(broken));

    broken.port = 25;
    try testing.expectEqual(@as(u16, 465), dialPort(broken));

    // Something that is not a submission port is left alone: a server may really
    // speak implicit TLS on a number of its own.
    var custom = implicit;
    custom.port = 8465;
    try testing.expectEqual(@as(u16, 8465), dialPort(custom));
    try testing.expect(!portCorrected(custom));

    // STARTTLS is a different security, and the port is the user's.
    var upgrade = implicit;
    upgrade.security = .starttls;
    upgrade.port = 587;
    try testing.expectEqual(@as(u16, 587), dialPort(upgrade));
}
