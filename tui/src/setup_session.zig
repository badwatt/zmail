//! First-run wizard: its own small event loop, driven by the System port.
//!
//! It collects the account fields with `core.setup`, shows one step at a time,
//! and returns the config text plus the password in memory. Writing files and
//! connecting are the caller's job, so this whole loop is a unit test with a
//! scripted terminal.

const std = @import("std");
const core = @import("core");

const input = @import("input.zig");
const screen_mod = @import("screen.zig");
const system_mod = @import("system.zig");
const theme_mod = @import("theme.zig");

pub const Outcome = union(enum) {
    cancelled,
    saved: Saved,
};

pub const Saved = struct {
    config: [4096]u8 = undefined,
    config_len: u32 = 0,
    label: core.text.Text(core.limits.label_max) = .{},
    password: core.secret.Secret = .{},

    pub fn config_text(self: *const Saved) []const u8 {
        return self.config[0..self.config_len];
    }
};

pub const Error = error{Terminal};

pub fn run(system: system_mod.System, theme: theme_mod.Theme, config_path: []const u8) Error!Outcome {
    var setup = core.setup.Setup.init();
    defer setup.deinit();

    var parser: input.Parser = .{};
    var screen = screen_mod.Screen.init(80, 24);

    while (true) {
        const size = system.size() catch system_mod.Size{};
        if (screen.columns != size.columns or screen.rows != size.rows) {
            screen.resize(size.columns, size.rows);
        }
        render(&setup, theme, config_path, &screen);
        flush(system, &screen, theme);

        var read_buffer: [128]u8 = undefined;
        const count = system.read(&read_buffer, system_mod.read_timeout_ms) catch
            return error.Terminal;
        if (count == 0) {
            // A lone Esc is ambiguous until the read times out.
            if (parser.flush()) |key| handle_key(&setup, key);
        } else {
            var index: usize = 0;
            while (index < count) {
                const end = @min(count, index + input.keys_max);
                var keys: input.Keys = .{};
                parser.decode(read_buffer[index..end], &keys);
                for (keys.slice()) |key| handle_key(&setup, key);
                index = end;
            }
        }

        if (setup.cancelled) return .cancelled;
        if (setup.done) {
            var saved = Saved{};
            const text = setup.config_text(&saved.config);
            saved.config_len = @intCast(text.len);
            var label_buffer: [core.limits.label_max]u8 = undefined;
            saved.label.set(setup.account_label(&label_buffer));
            saved.password = setup.password;
            setup.password = .{};
            return .{ .saved = saved };
        }
    }
}

fn handle_key(setup: *core.setup.Setup, key: input.Key) void {
    switch (key) {
        .char => |codepoint| {
            if (codepoint >= 0x20 and codepoint != 0x7f) setup.append(codepoint);
        },
        .enter => setup.next(),
        .escape => setup.back(),
        .backspace => setup.backspace(),
        .ctrl => |letter| switch (letter) {
            'u' => setup.clear_field(),
            'c', 'q' => setup.cancelled = true,
            else => {},
        },
        else => {},
    }
}

pub fn render(setup: *const core.setup.Setup, theme: theme_mod.Theme, config_path: []const u8, out: *screen_mod.Screen) void {
    _ = out.put_text(1, 0, "amail setup", 16, theme.accent.with_bold());
    var progress_buffer: [16]u8 = undefined;
    const progress = std.fmt.bufPrint(&progress_buffer, "step {d}/{d}", .{ setup.step.number(), core.setup.Step.count() }) catch "";
    put_right(out, out.columns -| 2, 0, progress, theme.dim);
    out.hline(0, 1, out.columns, '─', theme.border);

    if (setup.step == .review) {
        render_review(setup, theme, config_path, out);
    } else {
        render_step(setup, theme, out);
    }

    const footer = if (setup.step == .review)
        " Enter saves  ·  Esc back  ·  Ctrl+Q quit "
    else
        " Enter next  ·  Esc back  ·  Ctrl+U clear  ·  Ctrl+Q quit ";
    _ = out.put_text(1, out.rows -| 1, footer, out.columns -| 2, theme.dim);
}

fn render_step(setup: *const core.setup.Setup, theme: theme_mod.Theme, out: *screen_mod.Screen) void {
    const label = switch (setup.step) {
        .address => "Email address",
        .imap_host => "IMAP server",
        .imap_port => "IMAP port",
        .smtp_host => "SMTP server (empty skips sending)",
        .smtp_port => "SMTP port",
        .username => "Username",
        .password => "Password",
        .review => "Review",
    };
    _ = out.put_text(1, 3, label, out.columns -| 2, theme.text.with_bold());

    const width = out.columns -| 3;
    if (setup.step == .password) {
        var masked: [core.limits.secret_max * 2]u8 = undefined;
        const length = @min(@as(usize, setup.password.len), 64);
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const dots = "••";
            @memcpy(masked[index * dots.len ..][0..dots.len], dots);
        }
        const written = out.put_text(1, 4, masked[0 .. length * 2], width, theme.text);
        out.put(1 + written, 4, ' ', theme.text.with_reverse());
    } else {
        const value = active_value(setup);
        if (value.len == 0) {
            out.put(1, 4, ' ', theme.text.with_reverse());
        } else {
            const written = out.put_text(1, 4, value, width, theme.text);
            out.put(1 + written, 4, ' ', theme.text.with_reverse());
        }
    }

    if (!setup.problem.is_empty()) {
        _ = out.put_text(1, 6, setup.problem.slice(), out.columns -| 2, theme.alert);
    } else {
        const hint = switch (setup.step) {
            .address => "The address people see, for example alice@example.com",
            .imap_host => "Where mail is read from; TLS is required",
            .imap_port => "993 for implicit TLS",
            .smtp_host => "Leave empty if you only want to read mail",
            .smtp_port => "465 for implicit TLS",
            .username => "Usually the part before @ in your address",
            .password => "Kept in memory only; written to a 0600 file if you save",
            .review => "",
        };
        _ = out.put_text(1, 6, hint, out.columns -| 2, theme.dim);
    }
}

fn active_value(setup: *const core.setup.Setup) []const u8 {
    return switch (setup.step) {
        .address => setup.address.slice(),
        .imap_host => setup.imap_host.slice(),
        .imap_port => setup.imap_port.slice(),
        .smtp_host => setup.smtp_host.slice(),
        .smtp_port => setup.smtp_port.slice(),
        .username => setup.username.slice(),
        .password, .review => "",
    };
}

fn render_review(setup: *const core.setup.Setup, theme: theme_mod.Theme, config_path: []const u8, out: *screen_mod.Screen) void {
    _ = out.put_text(1, 3, "Save this account?", out.columns -| 2, theme.text.with_bold());

    var buffer: [4096]u8 = undefined;
    const text = setup.config_text(&buffer);
    const line_buffer: [256]u8 = undefined;
    var row: u16 = 4;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (row + 3 >= out.rows) break;
        const clean = std.mem.trimEnd(u8, line, "\r");
        _ = out.put_text(1, row, clean[0..@min(clean.len, line_buffer.len)], out.columns -| 2, theme.dim);
        row += 1;
        if (row - 4 >= 14) break;
    }

    var path_buffer: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "Config: {s}", .{config_path}) catch "";
    _ = out.put_text(1, out.rows -| 4, path, out.columns -| 2, theme.dim);
    _ = out.put_text(1, out.rows -| 3, "Password: saved next to it in a 0600 file (AMAIL_PASSWORD overrides)", out.columns -| 2, theme.dim);
}

fn flush(system: system_mod.System, screen: *const screen_mod.Screen, theme: theme_mod.Theme) void {
    system.write("\x1b[H") catch return;
    var row_buffer: [screen_mod.max_columns * 40]u8 = undefined;
    var row: u16 = 0;
    while (row < screen.rows) : (row += 1) {
        var writer = std.Io.Writer.fixed(&row_buffer);
        screen.encode_row(row, &writer, theme.colored) catch return;
        if (row > 0) system.write("\r\n") catch return;
        system.write(writer.buffered()) catch return;
    }
    system.write("\x1b[0m") catch {};
}

fn put_right(out: *screen_mod.Screen, x_right: u16, y: u16, text: []const u8, style: screen_mod.Style) void {
    const width = screen_mod.text_columns(text);
    if (width > x_right) return;
    _ = out.put_text(x_right - width, y, text, width, style);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Fake = system_mod.Fake;

fn run_with(fake: *Fake, path: []const u8) !Outcome {
    return run(fake.system(), theme_mod.Theme.dark(), path);
}

test "a complete wizard saves the config and the password" {
    var fake: Fake = .{};
    const keys = "alice@example.com\r" ++ "\r\r\r\r\r" ++ "hunter2\r" ++ "\r";
    fake.push_input(keys);

    var outcome = try run_with(&fake, "/tmp/amail/config");
    defer switch (outcome) {
        .saved => |*saved| saved.password.deinit(),
        .cancelled => {},
    };
    const saved = &outcome.saved;

    try testing.expect(std.mem.indexOf(u8, saved.config_text(), "address = alice@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, saved.config_text(), "imap_host = imap.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, saved.config_text(), "smtp_host = smtp.example.com") != null);
    try testing.expectEqualStrings("hunter2", saved.password.expose());
}

test "escape on the first step cancels and writes nothing" {
    var fake: Fake = .{};
    fake.push_input("\x1b");
    try testing.expectEqual(Outcome.cancelled, try run_with(&fake, "/tmp/c"));
}

test "ctrl+q cancels at any step" {
    var fake: Fake = .{};
    fake.push_input("alice@example.com\r\x11");
    try testing.expectEqual(Outcome.cancelled, try run_with(&fake, "/tmp/c"));
}

test "an invalid address keeps the step and shows the problem" {
    var fake: Fake = .{};
    fake.push_input("nope\r");
    // No further input: the loop would block; the rendered frame is checked
    // through a direct render instead.
    var setup = core.setup.Setup.init();
    defer setup.deinit();
    setup.address.set("nope");
    setup.next();

    var screen = screen_mod.Screen.init(80, 24);
    render(&setup, theme_mod.Theme.dark(), "/tmp/c", &screen);
    var buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screen.row_text(6, &buffer), "does not look right") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(0, &buffer), "step 1/8") != null);
}

test "the password is masked and never printed" {
    var fake: Fake = .{};
    fake.push_input("alice@example.com\r\r\r\r\r" ++ "secret\r");
    // Cancel from the review screen; every frame so far was rendered.
    fake.push_input("\x11");
    const outcome = try run_with(&fake, "/tmp/c");
    try testing.expectEqual(Outcome.cancelled, outcome);
    try testing.expect(std.mem.indexOf(u8, fake.output_text(), "secret") == null);
}

test "the review screen shows the config, the path, and warns about the password" {
    var setup = core.setup.Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    setup.next();
    setup.next();
    setup.next();
    setup.next();
    setup.next();
    setup.username.set("alice");
    setup.next();
    setup.password.append_codepoint('x');
    setup.next();
    try testing.expectEqual(core.setup.Step.review, setup.step);

    var screen = screen_mod.Screen.init(100, 30);
    render(&setup, theme_mod.Theme.dark(), "/tmp/amail/config", &screen);
    var buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screen.row_text(3, &buffer), "Save this account?") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(4, &buffer), "# amail account") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(5, &buffer), "[account alice]") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(6, &buffer), "address = alice@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(26, &buffer), "/tmp/amail/config") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(27, &buffer), "0600 file") != null);
}

test "every step renders its own value and the password is masked" {
    var setup = core.setup.Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");
    setup.imap_host.set("imap.example.com");
    setup.imap_port.set("993");
    setup.smtp_host.set("smtp.example.com");
    setup.smtp_port.set("465");
    setup.username.set("alice");
    setup.password.append_codepoint('x');
    setup.password.append_codepoint('y');

    var screen = screen_mod.Screen.init(100, 30);
    const steps = [_]core.setup.Step{ .address, .imap_host, .imap_port, .smtp_host, .smtp_port, .username, .password };
    for (steps) |step| {
        setup.step = step;
        render(&setup, theme_mod.Theme.dark(), "/tmp/c", &screen);
        var buffer: [512]u8 = undefined;
        const row = screen.row_text(4, &buffer);
        if (step == .password) {
            try testing.expect(row.len > 0);
            try testing.expect(std.mem.indexOf(u8, row, "xy") == null);
            try testing.expect(std.mem.indexOf(u8, row, "•") != null);
        } else if (step != .review) {
            try testing.expect(row.len > 0);
        }
    }
}

test "backspace, clear, and a resize are handled by the loop" {
    var fake: Fake = .{ .size_value = .{ .columns = 100, .rows = 30 } };
    // Type, go to the next step, delete, clear, then cancel.
    fake.push_input("alice@example.com\r" ++ "\x7f\x15" ++ "\x11");
    try testing.expectEqual(Outcome.cancelled, try run_with(&fake, "/tmp/c"));
    try testing.expect(fake.output_len > 0);
}

test "render_step also accepts the review step without crashing" {
    var setup = core.setup.Setup.init();
    defer setup.deinit();
    setup.step = .review;

    var screen = screen_mod.Screen.init(80, 24);
    render_step(&setup, theme_mod.Theme.dark(), &screen);
    var buffer: [128]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screen.row_text(3, &buffer), "Review") != null);
    try testing.expectEqualStrings("", setup.password.expose());
}

test "the step screen shows the label, the value, and the cursor" {
    var setup = core.setup.Setup.init();
    defer setup.deinit();
    setup.address.set("alice@example.com");

    var screen = screen_mod.Screen.init(80, 24);
    render(&setup, theme_mod.Theme.dark(), "/tmp/c", &screen);

    var buffer: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screen.row_text(3, &buffer), "Email address") != null);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(4, &buffer), "alice@example.com") != null);
    try testing.expect(screen.cells[4][18].style.attrs.reverse);
    try testing.expect(std.mem.indexOf(u8, screen.row_text(23, &buffer), "Enter next") != null);
}
