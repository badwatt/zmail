//! First-run setup: a small wizard that produces a valid config file.
//!
//! The wizard never writes files and never talks to a network. It collects
//! fields, validates each step, and renders the config text; the caller writes
//! it. Validation at the last step runs the same parser as a hand-written file,
//! so the wizard cannot produce something the client would refuse to load.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../limits.zig");
const Text = @import("../domain/text.zig").Text;
const Secret = @import("../domain/secret.zig").Secret;
const Address = @import("../domain/address.zig").Address;
const config = @import("../config.zig");

pub const Step = enum {
    address,
    imap_host,
    imap_port,
    smtp_host,
    smtp_port,
    username,
    password,
    review,

    pub fn number(self: Step) u8 {
        return @as(u8, @backingInt(self)) + 1;
    }

    pub fn count() u8 {
        return @typeInfo(Step).@"enum".field_names.len;
    }
};

pub const Setup = struct {
    step: Step = .address,
    address: Text(limits.address_max) = .{},
    imap_host: Text(limits.host_max) = .{},
    imap_port: Text(6) = .{},
    smtp_host: Text(limits.host_max) = .{},
    smtp_port: Text(6) = .{},
    username: Text(limits.username_max) = .{},
    password: Secret = .{},
    /// Reason the current step cannot advance; empty when it can.
    problem: Text(limits.status_max) = .{},
    /// False when the user skips SMTP.
    send_enabled: bool = true,
    /// Sign in with OAuth2 instead of a password.
    oauth: bool = false,
    /// The provider's client id (from the app you registered).
    oauth_client_id: Text(256) = .{},
    /// The advanced rows (the OAuth client id) start folded away.
    show_advanced: bool = false,
    done: bool = false,
    cancelled: bool = false,

    pub fn init() Setup {
        var setup = Setup{};
        setup.imap_port.set("993");
        setup.smtp_port.set("465");
        return setup;
    }

    /// Editing an existing account starts at the summary: Enter saves as is,
    /// Esc walks back to the field that needs changing. No retyping.
    /// Password or OAuth2: one switch, no extra step.
    /// Rows the form shows. The password is meaningless with OAuth, and the
    /// client id is too rare to be on screen by default.
    pub fn field_visible(self: *const Setup, index: u8) bool {
        // Order: address, hosts, sign in, password, advanced, then the rare
        // rows (username, OAuth client id) below the fold.
        return switch (index) {
            6 => !self.oauth, // password, when signing in with one
            8, 9 => self.show_advanced, // username, OAuth client id
            else => true,
        };
    }

    pub fn toggle_advanced(self: *Setup) void {
        self.show_advanced = !self.show_advanced;
        self.problem.set("");
    }

    pub fn set_oauth(self: *Setup, enabled: bool) void {
        self.oauth = enabled;
        self.problem.clear();
    }

    pub fn start_at_review(self: *Setup) void {
        self.step = .review;
    }

    pub fn deinit(self: *Setup) void {
        self.password.deinit();
    }

    pub fn append(self: *Setup, codepoint: u21) void {
        self.problem.clear();
        switch (self.step) {
            .address => self.address.append_codepoint(codepoint),
            .imap_host => self.imap_host.append_codepoint(codepoint),
            .imap_port => self.imap_port.append_codepoint(codepoint),
            .smtp_host => self.smtp_host.append_codepoint(codepoint),
            .smtp_port => self.smtp_port.append_codepoint(codepoint),
            .username => self.username.append_codepoint(codepoint),
            .password => self.password.append_codepoint(codepoint),
            .review => {},
        }
    }

    pub fn backspace(self: *Setup) void {
        self.problem.clear();
        switch (self.step) {
            .address => self.address.pop_codepoint(),
            .imap_host => self.imap_host.pop_codepoint(),
            .imap_port => self.imap_port.pop_codepoint(),
            .smtp_host => self.smtp_host.pop_codepoint(),
            .smtp_port => self.smtp_port.pop_codepoint(),
            .username => self.username.pop_codepoint(),
            .password => self.password.pop_codepoint(),
            .review => {},
        }
    }

    /// Advances one step, validating the current field first.
    pub fn clear_field(self: *Setup) void {
        self.problem.clear();
        switch (self.step) {
            .address => self.address.clear(),
            .imap_host => self.imap_host.clear(),
            .imap_port => self.imap_port.clear(),
            .smtp_host => self.smtp_host.clear(),
            .smtp_port => self.smtp_port.clear(),
            .username => self.username.clear(),
            .password => self.password.deinit(),
            .review => {},
        }
    }

    /// Fields are typed by humans: "  me@example.com  " is the same account.
    /// Passwords are never trimmed (a space can be part of a secret).
    fn trim_fields(self: *Setup) void {
        switch (self.step) {
            .address, .imap_host, .imap_port, .smtp_host, .smtp_port, .username => {},
            .password, .review => return,
        }
        // Copy through a scratch buffer: Text.set cannot take an aliased slice.
        var buffer: [limits.address_max]u8 = undefined;
        switch (self.step) {
            .address => self.address.set(trim_copy(self.address.slice(), &buffer)),
            .imap_host => self.imap_host.set(trim_copy(self.imap_host.slice(), &buffer)),
            .imap_port => self.imap_port.set(trim_copy(self.imap_port.slice(), &buffer)),
            .smtp_host => self.smtp_host.set(trim_copy(self.smtp_host.slice(), &buffer)),
            .smtp_port => self.smtp_port.set(trim_copy(self.smtp_port.slice(), &buffer)),
            .username => self.username.set(trim_copy(self.username.slice(), &buffer)),
            .password, .review => {},
        }
    }

    pub fn next(self: *Setup) void {
        self.problem.clear();
        self.trim_fields();
        switch (self.step) {
            .address => {
                const address = Address.init(self.address.slice()) catch {
                    self.problem.set("That email address does not look right");
                    return;
                };
                self.fill_defaults(address);
                self.step = .imap_host;
            },
            .imap_host => {
                if (!valid_host(&self.imap_host)) {
                    self.problem.set("Enter the IMAP server, for example imap.example.com");
                    return;
                }
                self.step = .imap_port;
            },
            .imap_port => {
                if (!valid_port(&self.imap_port)) {
                    self.problem.set("The IMAP port must be a number between 1 and 65535");
                    return;
                }
                self.step = .smtp_host;
            },
            .smtp_host => {
                if (self.smtp_host.is_empty()) {
                    self.send_enabled = false;
                    self.step = .username;
                    return;
                }
                if (!valid_host(&self.smtp_host)) {
                    self.problem.set("Enter the SMTP server, or leave it empty to skip sending");
                    return;
                }
                self.send_enabled = true;
                self.step = .smtp_port;
            },
            .smtp_port => {
                if (!self.send_enabled) {
                    self.step = .username;
                    return;
                }
                if (!valid_port(&self.smtp_port)) {
                    self.problem.set("The SMTP port must be a number between 1 and 65535");
                    return;
                }
                self.step = .username;
            },
            .username => {
                // Empty means "the same as the address", which is what nearly
                // every provider expects. No reason to type it twice.
                if (self.username.is_empty()) self.username.set(self.address.slice());
                self.step = .password;
            },
            .password => {
                // An OAuth account has no password: the token comes later.
                if (self.password.is_empty() and !self.oauth) {
                    self.problem.set("Enter the password for the account");
                    return;
                }
                self.step = .review;
            },
            .review => self.commit(),
        }
    }

    /// Goes back one step; from the first step it cancels the wizard.
    pub fn back(self: *Setup) void {
        self.problem.clear();
        self.step = switch (self.step) {
            .address => {
                self.cancelled = true;
                return;
            },
            .imap_host => .address,
            .imap_port => .imap_host,
            .smtp_host => .imap_port,
            .smtp_port => .smtp_host,
            .username => if (self.send_enabled) .smtp_port else .smtp_host,
            .password => .username,
            .review => .password,
        };
    }

    fn commit(self: *Setup) void {
        var buffer: [4096]u8 = undefined;
        const text = self.config_text(&buffer);
        _ = config.parse(text) catch |err| {
            self.problem.set(config_problem(err));
            return;
        };
        self.done = true;
    }

    /// Label for the new account: the local part when it is a valid label.
    pub fn account_label(self: *const Setup, buffer: []u8) []const u8 {
        const local = self.address_local();
        var length: usize = 0;
        for (local) |byte| {
            if (length == buffer.len) break;
            const clean: u8 = if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else switch (byte) {
                '-', '_' => byte,
                else => '-',
            };
            buffer[length] = clean;
            length += 1;
        }
        if (length == 0) {
            @memcpy(buffer[0.."account".len], "account");
            return buffer[0.."account".len];
        }
        return buffer[0..length];
    }

    /// Providers take the address as the username unless told otherwise, so an
    /// empty field means "the address".
    pub fn username_or_address(self: *const Setup) []const u8 {
        return if (self.username.is_empty()) self.address.slice() else self.username.slice();
    }

    fn address_local(self: *const Setup) []const u8 {
        const raw = self.address.slice();
        const at = std.mem.indexOfScalar(u8, raw, '@') orelse return raw;
        return raw[0..at];
    }

    /// Renders the file the caller should write. Contains no password.
    pub fn config_text(self: *const Setup, buffer: []u8) []const u8 {
        var label_buffer: [limits.label_max]u8 = undefined;
        const label = self.account_label(&label_buffer);
        var writer = std.Io.Writer.fixed(buffer);
        writer.print(
            \\# zmail account. Created by the setup assistant.
            \\[account {s}]
            \\address = {s}
            \\username = {s}
            \\imap_host = {s}
            \\imap_port = {s}
            \\imap_security = tls
            \\
        , .{
            label,
            self.address.slice(),
            self.username_or_address(),
            self.imap_host.slice(),
            self.imap_port.slice(),
        }) catch return "";

        // Only when there is one: an empty value is not a valid config line.
        if (self.oauth and !self.oauth_client_id.is_empty()) {
            writer.print("oauth_client_id = {s}\n", .{self.oauth_client_id.slice()}) catch return "";
        }
        if (self.send_enabled and !self.smtp_host.is_empty()) {
            writer.print(
                \\smtp_host = {s}
                \\smtp_port = {s}
                \\smtp_security = tls
                \\
            , .{ self.smtp_host.slice(), self.smtp_port.slice() }) catch return "";
        }
        return writer.buffered();
    }

    fn fill_defaults(self: *Setup, address: Address) void {
        var buffer: [limits.host_max]u8 = undefined;
        if (self.imap_host.is_empty()) {
            self.imap_host.set(std.fmt.bufPrint(&buffer, "imap.{s}", .{address.domain.slice()}) catch "");
        }
        var smtp_buffer: [limits.host_max]u8 = undefined;
        if (self.smtp_host.is_empty()) {
            self.smtp_host.set(std.fmt.bufPrint(&smtp_buffer, "smtp.{s}", .{address.domain.slice()}) catch "");
        }
        if (self.username.is_empty()) self.username.set(address.local.slice());
    }
};

fn trimmed(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

/// Trimmed copy in `buffer` (Text.set must not read from its own storage).
fn trim_copy(value: []const u8, buffer: []u8) []const u8 {
    const text = trimmed(value);
    const length = @min(text.len, buffer.len);
    @memcpy(buffer[0..length], text[0..length]);
    return buffer[0..length];
}

fn valid_host(host: *const Text(limits.host_max)) bool {
    if (host.is_empty()) return false;
    for (host.slice()) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '-', '_', ':', '[', ']' => continue,
            else => return false,
        }
    }
    return true;
}

fn valid_port(text: *const Text(6)) bool {
    const port = std.fmt.parseInt(u16, text.slice(), 10) catch return false;
    return port != 0;
}

fn config_problem(err: anyerror) []const u8 {
    return switch (err) {
        error.PlaintextForbidden => "Plaintext transport is not allowed",
        error.InvalidHost, error.EmptyHost => "Check the server host",
        error.InvalidPort => "Check the server port",
        error.MissingKey, error.InvalidValue => "Something is missing or invalid",
        else => "The config is not valid yet",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestSetup = Setup;

fn fill_valid(setup: *Setup) void {
    setup.address.set("alice@example.com");
    setup.next(); // defaults from the address
    setup.next(); // imap host
    setup.next(); // imap port
    setup.next(); // smtp host
    setup.next(); // smtp port
    setup.next(); // username
    setup.append('s');
    setup.append('e');
    setup.append('c');
    setup.next(); // password
}

test "a full run produces the config text and reaches review" {
    var setup = Setup.init();
    defer setup.deinit();
    try testing.expectEqualStrings("993", setup.imap_port.slice());
    try testing.expectEqualStrings("465", setup.smtp_port.slice());

    fill_valid(&setup);
    try testing.expectEqual(Step.review, setup.step);
    try testing.expect(setup.send_enabled);
    try testing.expectEqualStrings("imap.example.com", setup.imap_host.slice());
    try testing.expectEqualStrings("smtp.example.com", setup.smtp_host.slice());
    try testing.expectEqualStrings("alice", setup.username.slice());

    var buffer: [1024]u8 = undefined;
    const text = setup.config_text(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, "[account alice]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "address = alice@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, text, "imap_host = imap.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, text, "smtp_host = smtp.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, text, "password") == null);

    setup.next(); // review: commit
    try testing.expect(setup.done);
    try testing.expect(!setup.cancelled);
}

test "skipping the SMTP host omits the SMTP block and the port step" {
    var setup = Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    setup.next();
    setup.next(); // imap host
    setup.next(); // imap port
    setup.smtp_host.clear();
    setup.next(); // smtp host empty: skip sending
    try testing.expect(!setup.send_enabled);
    try testing.expectEqual(Step.username, setup.step);

    var buffer: [1024]u8 = undefined;
    const text = setup.config_text(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, "smtp_") == null);
    try testing.expect(std.mem.indexOf(u8, text, "username = alice") != null);
}

test "the username is derived when it is not given" {
    var setup = Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    setup.imap_host.set("imap.example.com");
    setup.imap_port.set("993");

    // Hidden by default, because the address is what providers expect.
    try testing.expect(!setup.field_visible(8));
    try testing.expectEqualStrings("alice@example.com", setup.username_or_address());

    var buffer: [1024]u8 = undefined;
    const text = setup.config_text(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, "username = alice@example.com") != null);

    // Asked for, it wins.
    setup.toggle_advanced();
    try testing.expect(setup.field_visible(8));
    setup.username.set("alice");
    try testing.expectEqualStrings("alice", setup.username_or_address());
}

test "advanced rows fold away until asked for" {
    var setup = Setup.init();
    defer setup.deinit();
    // address, hosts, sign in, password, advanced ... then the fold.
    try testing.expect(setup.field_visible(7)); // advanced itself
    try testing.expect(!setup.field_visible(8)); // username
    try testing.expect(!setup.field_visible(9)); // client id
    setup.toggle_advanced();
    try testing.expect(setup.field_visible(8));
    try testing.expect(setup.field_visible(9));
    setup.toggle_advanced();
    try testing.expect(!setup.field_visible(9));
    // The password row disappears with OAuth, and it sits after Sign in.
    try testing.expect(setup.field_visible(6));
    setup.set_oauth(true);
    try testing.expect(!setup.field_visible(6));
}

test "an empty username becomes the address, and OAuth needs no password" {
    var setup = Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    setup.next(); // imap_host
    setup.next(); // imap_port
    setup.next(); // smtp_host
    setup.next(); // smtp_port
    setup.next(); // username
    setup.username.clear();
    setup.next(); // username -> password, with the address filled in
    try testing.expectEqualStrings("alice@example.com", setup.username.slice());
    try testing.expectEqual(.password, setup.step);

    setup.set_oauth(true);
    setup.password = .{};
    setup.next();
    try testing.expectEqual(.review, setup.step);
    try testing.expect(setup.problem.is_empty());
}

test "each step validates before advancing" {
    var setup = Setup.init();
    defer setup.deinit();

    setup.next();
    try testing.expectEqual(Step.address, setup.step);
    try testing.expect(!setup.problem.is_empty());

    setup.address.set("not an address");
    setup.next();
    try testing.expectEqual(Step.address, setup.step);

    setup.address.set("alice@example.com");
    setup.next();
    try testing.expectEqual(Step.imap_host, setup.step);

    setup.imap_host.clear();
    setup.next();
    try testing.expectEqual(Step.imap_host, setup.step);
    try testing.expect(!setup.problem.is_empty());

    setup.imap_host.set("imap.example.com");
    setup.next();
    setup.imap_port.set("0");
    setup.next();
    try testing.expectEqual(Step.imap_port, setup.step);

    setup.imap_port.set("993");
    setup.next();
    setup.next(); // smtp host
    setup.smtp_port.set("nope");
    setup.next();
    try testing.expectEqual(Step.smtp_port, setup.step);

    setup.smtp_port.set("465");
    setup.next();
    // An empty username is not an error any more: it becomes the address.
    setup.username.clear();
    setup.next();
    try testing.expectEqual(Step.password, setup.step);
    try testing.expectEqualStrings("alice@example.com", setup.username.slice());

    setup.next(); // empty password, password mode
    try testing.expectEqual(Step.password, setup.step);
    try testing.expect(!setup.problem.is_empty());

    // In OAuth mode there is nothing to type.
    setup.set_oauth(true);
    setup.next();
    try testing.expectEqual(Step.review, setup.step);
}

test "back walks the steps and cancels from the first one" {
    var setup = Setup.init();
    defer setup.deinit();

    setup.back();
    try testing.expect(setup.cancelled);

    var other = Setup.init();
    defer other.deinit();
    other.address.set("alice@example.com");
    other.next();
    other.next();
    try testing.expectEqual(Step.imap_port, other.step);
    other.back();
    try testing.expectEqual(Step.imap_host, other.step);
    other.back();
    try testing.expectEqual(Step.address, other.step);
}

test "back from the username goes to the SMTP port only when sending" {
    var setup = Setup.init();
    defer setup.deinit();
    setup.step = .username;
    setup.send_enabled = true;
    setup.back();
    try testing.expectEqual(Step.smtp_port, setup.step);

    setup.step = .username;
    setup.send_enabled = false;
    setup.back();
    try testing.expectEqual(Step.smtp_host, setup.step);
}

test "typing and backspace target the active step" {
    var setup = Setup.init();
    defer setup.deinit();
    setup.append('a');
    setup.append('b');
    setup.backspace();
    try testing.expectEqualStrings("a", setup.address.slice());

    setup.step = .password;
    setup.append(0xe9);
    setup.append('x');
    try testing.expectEqualStrings("éx", setup.password.expose());
    setup.backspace();
    try testing.expectEqualStrings("é", setup.password.expose());

    setup.step = .review;
    setup.append('z');
    setup.backspace();
    try testing.expectEqual(Step.review, setup.step);

    setup.step = .smtp_host;
    setup.smtp_host.set("smtp.example.com");
    setup.clear_field();
    try testing.expect(setup.smtp_host.is_empty());

    setup.step = .password;
    setup.clear_field();
    try testing.expect(setup.password.is_empty());

    setup.step = .imap_port;
    setup.imap_port.set("143");
    setup.clear_field();
    try testing.expect(setup.imap_port.is_empty());
}

test "the review step re-parses the generated config" {
    var setup = Setup.init();
    defer setup.deinit();
    fill_valid(&setup);

    // Break a value after the per-step checks would have passed.
    setup.imap_port.set("99999");
    setup.next();
    try testing.expect(!setup.done);
    try testing.expect(!setup.problem.is_empty());
}

test "the account label comes from the address local part, sanitized" {
    var setup = Setup.init();
    defer setup.deinit();
    var buffer: [limits.label_max]u8 = undefined;

    try testing.expectEqualStrings("account", setup.account_label(&buffer));
    setup.address.set("Alice.Smith+tag@example.com");
    try testing.expectEqualStrings("alice-smith-tag", setup.account_label(&buffer));

    setup.address.set("@example.com");
    try testing.expectEqualStrings("account", setup.account_label(&buffer));

    var tiny: [4]u8 = undefined;
    setup.address.set("alice@example.com");
    try testing.expectEqualStrings("alic", setup.account_label(&tiny));
}

test "a tiny buffer degrades to empty rather than corrupt output" {
    var setup = Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("", setup.config_text(&buffer));
}

test "every step edits its own field" {
    const cases = [_]Step{ .address, .imap_host, .imap_port, .smtp_host, .smtp_port, .username, .password };
    for (cases) |step| {
        var setup = TestSetup.init();
        defer setup.deinit();
        setup.step = step;
        setup.append('x');
        setup.backspace();
        setup.append('y');
        setup.clear_field();

        const text = switch (step) {
            .address => setup.address.slice(),
            .imap_host => setup.imap_host.slice(),
            .imap_port => setup.imap_port.slice(),
            .smtp_host => setup.smtp_host.slice(),
            .smtp_port => setup.smtp_port.slice(),
            .username => setup.username.slice(),
            .password, .review => "",
        };
        if (step == .password) {
            try testing.expect(setup.password.is_empty());
        } else {
            try testing.expectEqualStrings("", text);
        }
    }
}

test "address and username clear through clear_field" {
    var setup = TestSetup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    setup.step = .address;
    setup.clear_field();
    try testing.expect(setup.address.is_empty());

    setup.username.set("alice");
    setup.step = .username;
    setup.clear_field();
    try testing.expect(setup.username.is_empty());
}

test "an invalid SMTP host is refused, and a skipped SMTP port is bypassed" {
    var setup = TestSetup.init();
    defer setup.deinit();
    setup.step = .smtp_host;
    setup.smtp_host.set("bad host");
    setup.next();
    try testing.expectEqual(Step.smtp_host, setup.step);
    try testing.expect(!setup.problem.is_empty());

    setup.step = .smtp_port;
    setup.send_enabled = false;
    setup.next();
    try testing.expectEqual(Step.username, setup.step);
}

test "step numbering is stable" {
    try testing.expectEqual(@as(u8, 1), Step.address.number());
    try testing.expectEqual(Step.count(), Step.review.number());
}
