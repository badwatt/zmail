//! Account configuration: a strict `key = value` file with optional
//! `[account <label>]` sections.
//!
//! Strict on purpose. An unknown key or section is an error (a typo must not
//! silently disable TLS), transport security has no default, and passwords are
//! refused outright: they belong in the secret store, never in a file that gets
//! committed, shared, or backed up in the clear.
//!
//! A file with no sections is one account labelled "account", so older configs
//! keep working.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("limits.zig");
const Text = @import("domain/text.zig").Text;
const Address = @import("domain/address.zig").Address;
const account = @import("domain/account.zig");

pub const max_accounts: u8 = 4;

/// Words in a `password_command`: enough for `gopass show -o mail/work`.
pub const argv_max: u8 = 8;

/// A command line split into arguments. The slices point into the config text
/// the caller parsed, so they live as long as that buffer does.
pub const Argv = struct {
    items: [argv_max][]const u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Argv) []const []const u8 {
        assert(self.len <= argv_max);
        return self.items[0..self.len];
    }
};

/// Splits a `password_command` into argv on runs of spaces. No quoting, no
/// escapes, and above all no shell: a value in a config file must not be able
/// to become a program with arguments the user did not write. The cost is that
/// a path with a space in it cannot be expressed, which is the honest limit of
/// this shortcut.
pub fn split_argv(value: []const u8, out: *Argv) Error!void {
    out.len = 0;
    var rest = value;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " ");
        if (rest.len == 0) return;
        if (out.len == argv_max) return error.TooManyArguments;
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        out.items[out.len] = rest[0..end];
        out.len += 1;
        rest = rest[end..];
    }
}

pub const Entry = struct {
    label: Text(limits.label_max) = .{},
    account: account.Account = .{},
    /// Optional: an account without SMTP can read but not send.
    smtp: ?account.Server = null,
    /// OAuth2 client id for providers that need one (Microsoft, Google).
    oauth_client_id: Text(256) = .{},
    /// Microsoft tenant for the authorize URL (`common`, `consumers`, an id).
    oauth_tenant: Text(64) = .{},
    /// Optional: a command whose standard output is the password (`pass show`,
    /// `gopass`, an `age` script). Run as an argv list, never through a shell.
    password_command: Text(limits.password_command_max) = .{},
    policy: account.Policy = .{},

    pub fn validate(self: *const Entry) account.RuleError!void {
        try account.validate_server(&self.account.imap, self.policy);
        if (self.smtp) |smtp| try account.validate_server(&smtp, self.policy);
    }
};

pub const File = struct {
    entries: [max_accounts]Entry = undefined,
    len: u8 = 0,

    pub fn items(self: *const File) []const Entry {
        assert(self.len <= max_accounts);
        return self.entries[0..self.len];
    }

    pub fn validate(self: *const File) account.RuleError!void {
        for (self.items()) |*entry| try entry.validate();
    }
};

pub const Error = error{
    MissingKey,
    UnknownKey,
    UnknownSection,
    MissingEquals,
    InvalidValue,
    PasswordInConfig,
    InvalidLabel,
    DuplicateLabel,
    TooManyAccounts,
    MixedFormat,
    TooLong,
    TooManyArguments,
};

const Pending = struct {
    seen_address: bool = false,
    seen_host: bool = false,
    seen_port: bool = false,
    seen_security: bool = false,
    seen_username: bool = false,
    seen_smtp_host: bool = false,
    seen_smtp_port: bool = false,
    seen_smtp_security: bool = false,
};

/// Parses a config file. Returns the first problem; nothing is sanitized away.
pub fn parse(text: []const u8) (Error || account.RuleError || Address.ParseError)!File {
    var file = File{};
    var pending: [max_accounts]Pending = @splat(.{});
    var current: ?u8 = null;
    var saw_section = false;
    var implicit_created = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (line[0] == '[') {
            if (implicit_created) return error.MixedFormat;
            const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.UnknownSection;
            if (std.mem.trim(u8, line[close + 1 ..], " \t").len != 0) return error.UnknownSection;

            const inside = std.mem.trim(u8, line[1..close], " \t");
            if (std.mem.eql(u8, inside, "account")) return error.InvalidLabel;
            if (!std.mem.startsWith(u8, inside, "account ")) return error.UnknownSection;
            const label = std.mem.trim(u8, inside["account ".len..], " \t");
            if (!valid_label(label)) return error.InvalidLabel;
            if (file.len == max_accounts) return error.TooManyAccounts;
            for (file.items()) |entry| {
                if (std.mem.eql(u8, entry.label.slice(), label)) return error.DuplicateLabel;
            }

            file.entries[file.len] = .{};
            file.entries[file.len].label.set(label);
            current = file.len;
            file.len += 1;
            saw_section = true;
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingEquals;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidValue;

        if (current == null) {
            // Legacy flat file: create the single implicit account.
            if (saw_section) return error.MissingKey;
            if (file.len == max_accounts) return error.TooManyAccounts;
            file.entries[0] = .{};
            file.entries[0].label.set("account");
            current = 0;
            file.len = 1;
            implicit_created = true;
        }

        const index = current.?;
        assert(index < file.len);
        const entry = &file.entries[index];
        const pending_entry = &pending[index];

        if (std.mem.eql(u8, key, "address")) {
            entry.account.address = try Address.init(value);
            pending_entry.seen_address = true;
        } else if (std.mem.eql(u8, key, "label")) {
            if (!valid_label(value)) return error.InvalidLabel;
            entry.label.set(value);
        } else if (std.mem.eql(u8, key, "oauth_client_id")) {
            entry.oauth_client_id.set(value);
        } else if (std.mem.eql(u8, key, "oauth_tenant")) {
            entry.oauth_tenant.set(value);
        } else if (std.mem.eql(u8, key, "password_command")) {
            entry.password_command.set(value);
            var argv: Argv = .{};
            try split_argv(value, &argv);
        } else if (std.mem.eql(u8, key, "username")) {
            entry.account.username.set(value);
            pending_entry.seen_username = true;
        } else if (std.mem.eql(u8, key, "imap_host")) {
            entry.account.imap.host.set(value);
            pending_entry.seen_host = true;
        } else if (std.mem.eql(u8, key, "imap_port")) {
            entry.account.imap.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            pending_entry.seen_port = true;
        } else if (std.mem.eql(u8, key, "imap_security")) {
            entry.account.imap.security = parse_security(value) orelse return error.InvalidValue;
            pending_entry.seen_security = true;
        } else if (std.mem.eql(u8, key, "smtp_host")) {
            smtp_server(entry).host.set(value);
            pending_entry.seen_smtp_host = true;
        } else if (std.mem.eql(u8, key, "smtp_port")) {
            smtp_server(entry).port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            pending_entry.seen_smtp_port = true;
        } else if (std.mem.eql(u8, key, "smtp_security")) {
            smtp_server(entry).security = parse_security(value) orelse return error.InvalidValue;
            pending_entry.seen_smtp_security = true;
        } else if (std.mem.eql(u8, key, "allow_plaintext")) {
            entry.policy.allow_plaintext = parse_bool(value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "password")) {
            // Refused by name so the error is actionable.
            return error.PasswordInConfig;
        } else {
            return error.UnknownKey;
        }
    }

    if (file.len == 0) return error.MissingKey;

    for (pending[0..file.len]) |entry| {
        if (!entry.seen_address) return error.MissingKey;
        if (!entry.seen_host) return error.MissingKey;
        if (!entry.seen_port) return error.MissingKey;
        if (!entry.seen_security) return error.MissingKey;
        if (!entry.seen_username) return error.MissingKey;

        const smtp_seen = @as(u8, @intFromBool(entry.seen_smtp_host)) +
            @as(u8, @intFromBool(entry.seen_smtp_port)) +
            @as(u8, @intFromBool(entry.seen_smtp_security));
        if (smtp_seen != 0 and smtp_seen != 3) return error.MissingKey;
    }

    try file.validate();
    return file;
}

fn smtp_server(entry: *Entry) *account.Server {
    if (entry.smtp == null) entry.smtp = .{};
    return &entry.smtp.?;
}

/// The same file with one account's label changed.
/// A label that is not taken yet: `alvaro`, `alvaro2`, `alvaro3`... Returns an
/// empty slice when every candidate is used, which the caller reports.
pub fn unique_label(text: []const u8, wanted: []const u8, buffer: []u8) []const u8 {
    if (!has_label(text, wanted)) {
        if (wanted.len > buffer.len) return "";
        @memcpy(buffer[0..wanted.len], wanted);
        return buffer[0..wanted.len];
    }
    var attempt: u8 = 2;
    while (attempt < 100) : (attempt += 1) {
        const candidate = std.fmt.bufPrint(buffer, "{s}{d}", .{ wanted, attempt }) catch return "";
        if (!has_label(text, candidate)) return candidate;
    }
    return "";
}

/// The label of an `[account <label>]` header line, if that is what it is.
fn section_label(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[') return null;
    const inside = std.mem.trim(u8, line[1..], " \t]");
    if (!std.mem.startsWith(u8, inside, "account ")) return null;
    return std.mem.trim(u8, inside["account ".len..], " \t");
}

pub fn rename_label(text: []const u8, old: []const u8, new: []const u8, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (section_label(line)) |label| {
            if (std.mem.eql(u8, label, old)) {
                writer.print("[account {s}]\n", .{new}) catch return "";
                continue;
            }
        }
        writer.print("{s}\n", .{raw_line}) catch return "";
    }
    return writer.buffered();
}

/// The same file with the `[account label]` section removed. A flat
/// (section-less) file has nothing to remove, so it yields "".
pub fn without(text: []const u8, label: []const u8, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var skipping = false;
    var saw_section = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (section_label(line)) |name| {
            saw_section = true;
            skipping = std.mem.eql(u8, name, label);
            if (skipping) continue;
        }
        if (skipping) continue;
        writer.print("{s}\n", .{raw_line}) catch return "";
    }
    if (!saw_section) return "";
    const trimmed = std.mem.trim(u8, writer.buffered(), "\r\n");
    if (trimmed.len == 0) return "";
    // Keep a trailing newline so the file stays well-formed.
    writer.writeByte('\n') catch return "";
    return writer.buffered();
}

/// Whether a config file already uses `label`, so an added account cannot
/// silently shadow or collide with an existing one.
pub fn has_label(text: []const u8, label: []const u8) bool {
    const file = parse(text) catch return false;
    for (file.items()) |entry| {
        if (std.mem.eql(u8, entry.label.slice(), label)) return true;
    }
    return false;
}

fn valid_label(label: []const u8) bool {
    if (label.len == 0 or label.len > limits.label_max) return false;
    for (label) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '_' => continue,
            else => return false,
        }
    }
    return true;
}

fn parse_security(value: []const u8) ?account.Security {
    if (std.mem.eql(u8, value, "tls")) return .tls;
    if (std.mem.eql(u8, value, "starttls")) return .starttls;
    if (std.mem.eql(u8, value, "plain")) return .plain;
    return null;
}

fn parse_bool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const minimal =
    \\address = alice@example.com
    \\username = alice
    \\imap_host = imap.example.com
    \\imap_port = 993
    \\imap_security = tls
    \\
;

test "rename_label changes one section header only" {
    const text =
        "[account work]\naddress = a@work.example\n\n[account home]\naddress = a@home.example\n";
    var buffer: [512]u8 = undefined;
    const renamed = rename_label(text, "work", "office", &buffer);
    try testing.expect(std.mem.indexOf(u8, renamed, "[account office]") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "[account work]") == null);
    try testing.expect(std.mem.indexOf(u8, renamed, "[account home]") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "a@work.example") != null);

    var untouched: [512]u8 = undefined;
    const same = rename_label(text, "missing", "x", &untouched);
    try testing.expect(std.mem.indexOf(u8, same, "[account work]") != null);
}

test "without removes exactly one section and keeps the rest" {
    const text =
        \\# zmail accounts
        \\[account work]
        \\address = a@work.example
        \\username = a
        \\
        \\[account home]
        \\address = a@home.example
        \\username = a
        \\
    ;
    var buffer: [1024]u8 = undefined;
    const kept = without(text, "work", &buffer);
    try testing.expect(std.mem.indexOf(u8, kept, "work.example") == null);
    try testing.expect(std.mem.indexOf(u8, kept, "[account home]") != null);
    try testing.expect(std.mem.indexOf(u8, kept, "home.example") != null);

    // Removing the last one leaves only the comment header: no accounts.
    var second: [1024]u8 = undefined;
    const last = without(kept, "home", &second);
    try testing.expect(std.mem.indexOf(u8, last, "[account") == null);
    try testing.expect(std.mem.indexOf(u8, last, "home.example") == null);

    // The kept text is a slice of the buffer it was written to: copying it into
    // a different buffer keeps both valid.
    var third: [1024]u8 = undefined;
    @memcpy(third[0..kept.len], kept);
    try testing.expect(std.mem.indexOf(u8, third[0..kept.len], "home.example") != null);

    // A flat file has no sections to remove.
    try testing.expectEqualStrings("", without("address = a@b.c\n", "account", &buffer));
}

test "has_label finds an account by its section" {
    const text =
        "[account work]\naddress = a@b.c\nusername = a\nimap_host = h\nimap_port = 993\nimap_security = tls\n";
    try testing.expect(has_label(text, "work"));
    try testing.expect(!has_label(text, "home"));
    try testing.expect(!has_label("not a config", "work"));
}

test "a flat file is one account labelled account" {
    const file = try parse(minimal);
    try testing.expectEqual(@as(u8, 1), file.len);
    const entry = file.items()[0];
    try testing.expectEqualStrings("account", entry.label.slice());
    var buffer: [limits.address_max]u8 = undefined;
    try testing.expectEqualStrings("alice@example.com", entry.account.address.addr_spec(&buffer));
    try testing.expectEqual(@as(u16, 993), entry.account.imap.port);
    try testing.expect(entry.smtp == null);
}

test "sections describe several accounts" {
    const text =
        \\[account work]
        \\address = alice@example.com
        \\username = alice
        \\imap_host = imap.example.com
        \\imap_port = 993
        \\imap_security = tls
        \\smtp_host = smtp.example.com
        \\smtp_port = 465
        \\smtp_security = tls
        \\
        \\[account personal]
        \\address = alice@home.example
        \\username = alice
        \\imap_host = imap.home.example
        \\imap_port = 993
        \\imap_security = tls
    ;
    const file = try parse(text);
    try testing.expectEqual(@as(u8, 2), file.len);
    try testing.expectEqualStrings("work", file.items()[0].label.slice());
    try testing.expect(file.items()[0].smtp != null);
    try testing.expectEqualStrings("personal", file.items()[1].label.slice());
    try testing.expect(file.items()[1].smtp == null);
    try file.validate();
}

test "comments, blank lines, and whitespace are ignored" {
    const text =
        \\# zmail
        \\
        \\[account  work ]
        \\  address   =   alice@example.com
        \\username=alice
        \\imap_host = imap.example.com
        \\imap_port = 143
        \\imap_security = starttls
        \\
    ;
    const file = try parse(text);
    try testing.expectEqualStrings("work", file.items()[0].label.slice());
    try testing.expectEqual(account.Security.starttls, file.items()[0].account.imap.security);
}

test "labels must be valid and unique" {
    try testing.expectError(error.InvalidLabel, parse("[account bad label]\n" ++ minimal));
    try testing.expectError(error.InvalidLabel, parse("[account ]\n" ++ minimal));
    try testing.expectError(error.InvalidLabel, parse("[account]\n" ++ minimal));
    try testing.expectError(error.DuplicateLabel, parse("[account work]\n" ++ minimal ++ "[account work]\n" ++ minimal));
    try testing.expectError(error.UnknownSection, parse("[section work]\n" ++ minimal));
}

test "unknown sections and mixed formats are errors" {
    try testing.expectError(error.UnknownSection, parse("[global]\n"));
    try testing.expectError(error.UnknownSection, parse("[account work] trailing\n" ++ minimal));
    try testing.expectError(error.MixedFormat, parse(minimal ++ "\n[account work]\n" ++ minimal));
}

test "too many accounts are refused" {
    var text: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    var index: u8 = 0;
    while (index < max_accounts + 1) : (index += 1) {
        writer.print("[account a{d}]\n", .{index}) catch unreachable;
        writer.writeAll(minimal) catch unreachable;
        writer.writeAll("\n") catch unreachable;
    }
    try testing.expectError(error.TooManyAccounts, parse(writer.buffered()));
}

test "a section without the required keys is refused" {
    try testing.expectError(error.MissingKey, parse("[account work]\naddress = alice@example.com\n"));
}

test "an empty file is refused" {
    try testing.expectError(error.MissingKey, parse(""));
    try testing.expectError(error.MissingKey, parse("# only a comment\n"));
}

test "a partial SMTP group is refused, a complete one is accepted" {
    try testing.expectError(error.MissingKey, parse(minimal ++ "smtp_host = smtp.example.com\n"));
    const file = try parse(minimal ++
        \\smtp_host = smtp.example.com
        \\smtp_port = 465
        \\smtp_security = tls
    );
    try testing.expectEqual(@as(u16, 465), file.items()[0].smtp.?.port);
}

test "a password in the config is refused by name" {
    try testing.expectError(error.PasswordInConfig, parse(minimal ++ "password = hunter2\n"));
}

test "a password_command is kept as an argv, never as a shell line" {
    const file = try parse(minimal ++ "password_command = pass show mail/work\n");
    try testing.expectEqualStrings("pass show mail/work", file.items()[0].password_command.slice());

    var argv: Argv = .{};
    try split_argv(file.items()[0].password_command.slice(), &argv);
    try testing.expectEqual(@as(u8, 3), argv.len);
    try testing.expectEqualStrings("pass", argv.slice()[0]);
    try testing.expectEqualStrings("mail/work", argv.slice()[2]);
}

test "split_argv runs of spaces are one separator, and too many words fail" {
    var argv: Argv = .{};
    try split_argv("  pass   show  mail  ", &argv);
    try testing.expectEqual(@as(usize, 3), argv.slice().len);
    try testing.expectEqualStrings("mail", argv.slice()[2]);

    // A command with more words than the client will run is refused, rather
    // than silently truncated into a different command.
    try testing.expectError(error.TooManyArguments, split_argv("a b c d e f g h i", &argv));
}

test "a password_command still cannot smuggle a password into the config" {
    try testing.expectError(error.PasswordInConfig, parse(minimal ++ "password = hunter2\n"));
}

test "unknown keys, malformed lines, and bad values are refused" {
    try testing.expectError(error.UnknownKey, parse(minimal ++ "imap_tls = yes\n"));
    try testing.expectError(error.MissingEquals, parse("address alice@example.com\n"));
    try testing.expectError(error.InvalidValue, parse(minimal ++ "imap_port = 99999\n"));
    try testing.expectError(error.InvalidValue, parse(minimal ++ "imap_security = maybe\n"));
    try testing.expectError(error.InvalidValue, parse(minimal ++ "allow_plaintext = yes\n"));
    try testing.expectError(error.InvalidValue, parse("= x\n"));
}

test "an invalid address is reported by the address parser" {
    try testing.expectError(error.MissingAt, parse("address = not-an-address\nusername = a\nimap_host = h.example\nimap_port = 993\nimap_security = tls\n"));
}

test "plaintext is refused without an explicit opt-in, per account" {
    try testing.expectError(error.PlaintextForbidden, parse(
        \\address = alice@example.com
        \\username = alice
        \\imap_host = imap.example.com
        \\imap_port = 143
        \\imap_security = plain
    ));

    const file = try parse(minimal ++ "allow_plaintext = true\n");
    try testing.expect(file.items()[0].policy.allow_plaintext);
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

test "a per-section label overrides the section name" {
    const file = try parse("[account work]\n" ++ minimal ++ "label = office\n");
    try testing.expectEqualStrings("office", file.items()[0].label.slice());
}
