//! IMAP responses: one complete line in, one typed value out.
//!
//! The transport hands the parser a line (or a line plus its inline literals)
//! and the parser classifies it. Anything it does not model is still reported
//! as data (`other`, `unknown`) instead of being dropped, so the adapter can log
//! it and move on.
//!
//! This layer is deliberately pure: no sockets, no TLS, no clock. That is what
//! makes a protocol conversation a unit test.

const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const time = @import("../../domain/time.zig");
const Flags = @import("../../domain/message.zig").Flags;
const Mailbox = @import("../../domain/mailbox.zig").Mailbox;

pub const Kind = enum { ok, no, bad };

pub const Tagged = struct {
    tag: []const u8,
    kind: Kind,
    text: []const u8,
};

/// IMAP ENVELOPE, only the fields the list and the reader need.
pub const Envelope = struct {
    date: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    from_name: ?[]const u8 = null,
    from_mailbox: ?[]const u8 = null,
    from_host: ?[]const u8 = null,
};

pub const Fetch = struct {
    sequence: u32 = 0,
    uid: ?u32 = null,
    flags: ?Flags = null,
    /// Unix seconds from INTERNALDATE, or null when absent.
    internal_date: ?i64 = null,
    size_bytes: ?u32 = null,
    envelope: ?Envelope = null,
    /// Payload of a `BODY[...]` attribute, borrowed from the response buffer.
    body: ?[]const u8 = null,
    /// `BODY[<section>.MIME]`: a part's own headers, fetched on their own.
    mime: ?[]const u8 = null,
    /// `BODYSTRUCTURE`: the shape of the message, still as wire bytes.
    structure: ?[]const u8 = null,
};

/// One `LIST` result: the mailbox name plus, when the server supports
/// SPECIAL-USE, which logical mailbox it is.
pub const ListEntry = struct {
    name: []const u8 = "",
    mailbox: ?Mailbox = null,
};

pub const Untagged = union(enum) {
    ok: []const u8,
    no: []const u8,
    bad: []const u8,
    bye: []const u8,
    preauth: []const u8,
    exists: u32,
    recent: u32,
    expunge: u32,
    fetch: Fetch,
    list: ListEntry,
    /// `* STATUS "Sent" (UNSEEN 3 MESSAGES 42)`: what a folder holds without
    /// selecting it.
    status: Status,
    capabilities: []const u8,
    other: []const u8,
};

/// A folder's numbers, from STATUS.
pub const Status = struct {
    unseen: u32 = 0,
    messages: u32 = 0,
};

pub const Response = union(enum) {
    continuation: []const u8,
    tagged: Tagged,
    untagged: Untagged,
    /// Structurally valid but not a shape we model.
    unknown: []const u8,
};

pub const Error = error{
    Malformed,
    InvalidDate,
};

/// Parses one complete response line (CRLF optional).
/// `scratch` holds unescaped envelope strings; it must outlive the response, so
/// the client owns it (a stack local here would dangle as soon as this returns).
pub fn parse(input: []const u8, scratch: []u8) Error!Response {
    const line = std.mem.trimEnd(u8, input, "\r\n");
    if (line.len == 0) return error.Malformed;

    if (line[0] == '+') {
        return .{ .continuation = trimLeft(line[1..]) };
    }
    if (line[0] == '*') {
        if (line.len < 2) return error.Malformed;
        if (line[1] != ' ') return error.Malformed;
        return .{ .untagged = try untagged(line[2..], scratch) };
    }
    return tagged(line);
}

fn tagged(line: []const u8) Error!Response {
    const tag_end = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Malformed;
    const rest = trimLeft(line[tag_end + 1 ..]);
    if (rest.len == 0) return error.Malformed;

    const status_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const status = rest[0..status_end];
    const text = if (status_end == rest.len) "" else trimLeft(rest[status_end + 1 ..]);

    return .{ .tagged = .{
        .tag = line[0..tag_end],
        .kind = kindFromWord(status) orelse return error.Malformed,
        .text = text,
    } };
}

fn untagged(rest: []const u8, scratch: []u8) Error!Untagged {
    const first_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const first = rest[0..first_end];
    const tail = if (first_end == rest.len) "" else trimLeft(rest[first_end + 1 ..]);

    if (std.fmt.parseInt(u32, first, 10)) |sequence| {
        return sequenceResponse(sequence, tail, scratch);
    } else |_| {}

    if (std.ascii.eqlIgnoreCase(first, "OK")) return .{ .ok = tail };
    if (std.ascii.eqlIgnoreCase(first, "NO")) return .{ .no = tail };
    if (std.ascii.eqlIgnoreCase(first, "BAD")) return .{ .bad = tail };
    if (std.ascii.eqlIgnoreCase(first, "BYE")) return .{ .bye = tail };
    if (std.ascii.eqlIgnoreCase(first, "PREAUTH")) return .{ .preauth = tail };
    if (std.ascii.eqlIgnoreCase(first, "CAPABILITY")) return .{ .capabilities = tail };
    if (std.ascii.eqlIgnoreCase(first, "LIST")) {
        var list_len: usize = 0;
        return .{ .list = try parseList(tail, scratch, &list_len) };
    }
    if (std.ascii.eqlIgnoreCase(first, "STATUS")) return .{ .status = try parseStatus(tail) };
    return .{ .other = rest };
}

fn sequenceResponse(sequence: u32, tail: []const u8, scratch: []u8) Error!Untagged {
    const verb_end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    const verb = tail[0..verb_end];
    const rest = if (verb_end == tail.len) "" else trimLeft(tail[verb_end + 1 ..]);

    if (std.ascii.eqlIgnoreCase(verb, "EXISTS")) return .{ .exists = sequence };
    if (std.ascii.eqlIgnoreCase(verb, "RECENT")) return .{ .recent = sequence };
    if (std.ascii.eqlIgnoreCase(verb, "EXPUNGE")) return .{ .expunge = sequence };
    if (std.ascii.eqlIgnoreCase(verb, "FETCH")) return .{ .fetch = try parseFetch(sequence, rest, scratch) };
    return .{ .other = tail };
}

/// `"Sent" (UNSEEN 3 MESSAGES 42)`: the numbers a folder reports about itself.
/// Anything else in the list is skipped: a server may answer in any order.
fn parseStatus(text: []const u8) Error!Status {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return error.Malformed;
    const close = std.mem.indexOfScalarPos(u8, text, open, ')') orelse return error.Malformed;

    var status = Status{};
    var tokens = std.mem.tokenizeAny(u8, text[open + 1 .. close], " \t");
    while (tokens.next()) |key| {
        const value = tokens.next() orelse return error.Malformed;
        const number = std.fmt.parseInt(u32, value, 10) catch return error.Malformed;
        if (std.ascii.eqlIgnoreCase(key, "UNSEEN")) status.unseen = number;
        if (std.ascii.eqlIgnoreCase(key, "MESSAGES")) status.messages = number;
    }
    return status;
}

/// `(\Sent \HasNoChildren) "/" "Sent"`: flags, delimiter, name.
fn parseList(text: []const u8, scratch: []u8, scratch_len: *usize) Error!ListEntry {
    var tokens = tokenizer.Tokenizer.init(text);
    var entry = ListEntry{};

    const open = try next(&tokens);
    if (open != .open_paren) return error.Malformed;
    while (true) {
        const token = try next(&tokens);
        switch (token) {
            .close_paren => break,
            .atom => |flag| {
                if (specialUse(flag)) |mailbox| entry.mailbox = mailbox;
            },
            else => {},
        }
    }

    // Delimiter: NIL, a quoted string, or an atom. Unused.
    _ = try next(&tokens);

    // Unescape into the caller's scratch: the response buffer is reused, so a
    // borrowed slice would not survive the next read.
    const name = try next(&tokens);
    entry.name = switch (name) {
        .literal => |payload| payload,
        .quoted => |quoted| tokenizer.unescape(quoted, scratch[scratch_len.*..]) catch
            return error.Malformed,
        .atom => |atom| atom,
        else => return error.Malformed,
    };
    scratch_len.* += entry.name.len;
    return entry;
}

fn specialUse(flag: []const u8) ?Mailbox {
    if (std.ascii.eqlIgnoreCase(flag, "\\Sent")) return .sent;
    if (std.ascii.eqlIgnoreCase(flag, "\\Drafts")) return .drafts;
    if (std.ascii.eqlIgnoreCase(flag, "\\Trash")) return .trash;
    if (std.ascii.eqlIgnoreCase(flag, "\\Junk")) return .junk;
    if (std.ascii.eqlIgnoreCase(flag, "\\Archive")) return .archive;
    if (std.ascii.eqlIgnoreCase(flag, "\\All")) return .archive;
    return null;
}

fn parseFetch(sequence: u32, text: []const u8, scratch: []u8) Error!Fetch {
    var result = Fetch{ .sequence = sequence };
    var tokens = tokenizer.Tokenizer.init(text);
    // Unescaped envelope strings live in the caller's scratch, which outlives
    // the response (a local buffer here would dangle once this returns).
    var string_len: usize = 0;

    const open = try next(&tokens);
    if (open != .open_paren) return error.Malformed;

    while (true) {
        const token = try next(&tokens);
        switch (token) {
            .close_paren => break,
            .atom => |key| {
                if (std.ascii.eqlIgnoreCase(key, "UID")) {
                    result.uid = try nextNumber(&tokens);
                } else if (std.ascii.eqlIgnoreCase(key, "RFC822.SIZE")) {
                    result.size_bytes = try nextNumber(&tokens);
                } else if (std.ascii.eqlIgnoreCase(key, "INTERNALDATE")) {
                    result.internal_date = try nextDate(&tokens);
                } else if (std.ascii.eqlIgnoreCase(key, "FLAGS")) {
                    result.flags = try parseFlags(&tokens);
                } else if (std.ascii.eqlIgnoreCase(key, "ENVELOPE")) {
                    result.envelope = try parseEnvelope(&tokens, scratch, &string_len);
                } else if (std.ascii.eqlIgnoreCase(key, "BODYSTRUCTURE")) {
                    result.structure = try captureGroup(&tokens);
                } else if (isPartHeaders(key)) {
                    result.mime = try parseBodyValue(&tokens);
                } else if (startsWithIgnoreCase(key, "BODY")) {
                    result.body = try parseBodyValue(&tokens);
                } else {
                    try skipValue(&tokens);
                }
            },
            else => return error.Malformed,
        }
    }
    return result;
}

/// Keeps a whole list as it arrived: `BODYSTRUCTURE` is a parse of its own, so
/// the response layer hands it over unread.
fn captureGroup(tokens: *tokenizer.Tokenizer) Error![]const u8 {
    const start = tokens.index;
    const token = try next(tokens);
    if (token != .open_paren) return error.Malformed;
    try skipGroup(tokens, 1);
    return tokens.input[start..tokens.index];
}

fn next(tokens: *tokenizer.Tokenizer) Error!tokenizer.Token {
    const maybe = tokens.next() catch return error.Malformed;
    if (maybe) |token| return token;
    return error.Malformed;
}

fn nextNumber(tokens: *tokenizer.Tokenizer) Error!u32 {
    const token = try next(tokens);
    const text = switch (token) {
        .atom => |atom| atom,
        else => return error.Malformed,
    };
    return std.fmt.parseInt(u32, text, 10) catch return error.Malformed;
}

fn nextDate(tokens: *tokenizer.Tokenizer) Error!i64 {
    const token = try next(tokens);
    const quoted = switch (token) {
        .quoted => |value| value,
        else => return error.Malformed,
    };
    var buffer: [32]u8 = undefined;
    const unescaped = tokenizer.unescape(quoted, &buffer) catch return error.Malformed;
    return parseInternalDate(unescaped) orelse error.InvalidDate;
}

fn parseFlags(tokens: *tokenizer.Tokenizer) Error!Flags {
    var flags = Flags{};
    const open = try next(tokens);
    if (open != .open_paren) return error.Malformed;

    while (true) {
        const token = try next(tokens);
        switch (token) {
            .close_paren => return flags,
            .atom => |atom| {
                if (std.ascii.eqlIgnoreCase(atom, "\\Seen")) flags.unread = false;
                if (std.ascii.eqlIgnoreCase(atom, "\\Flagged")) flags.flagged = true;
            },
            else => return error.Malformed,
        }
    }
}

/// `BODY[1.2.MIME]` holds a part's own headers. The section sits inside the
/// brackets and the `]` is part of the key, so the suffix is not at the end of the
/// text.
fn isPartHeaders(key: []const u8) bool {
    if (key.len < 3 or key[key.len - 1] != ']') return false;
    return endsWithIgnoreCase(key[0 .. key.len - 1], ".MIME");
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn parseBodyValue(tokens: *tokenizer.Tokenizer) Error!?[]const u8 {
    const token = try next(tokens);
    return switch (token) {
        .literal => |payload| payload,
        .quoted => |value| value,
        .atom => null,
        .open_paren => {
            try skipGroup(tokens, 1);
            return null;
        },
        .close_paren => error.Malformed,
    };
}

/// Reads an nstring: NIL, an atom, a quoted string (unescaped into scratch), or
/// a literal.
fn readNString(tokens: *tokenizer.Tokenizer, scratch: []u8, scratch_len: *usize) Error!?[]const u8 {
    const token = try next(tokens);
    return switch (token) {
        .atom => |atom| if (std.ascii.eqlIgnoreCase(atom, "NIL")) null else atom,
        .quoted => |quoted| blk: {
            const unescaped = tokenizer.unescape(quoted, scratch[scratch_len.*..]) catch
                return error.Malformed;
            scratch_len.* += unescaped.len;
            break :blk unescaped;
        },
        .literal => |payload| payload,
        else => error.Malformed,
    };
}

const AddressParts = struct {
    name: ?[]const u8 = null,
    mailbox: ?[]const u8 = null,
    host: ?[]const u8 = null,
};

fn parseAddress(tokens: *tokenizer.Tokenizer, scratch: []u8, scratch_len: *usize) Error!AddressParts {
    const name = try readNString(tokens, scratch, scratch_len);
    _ = try readNString(tokens, scratch, scratch_len); // at-domain-list, unused
    const mailbox = try readNString(tokens, scratch, scratch_len);
    const host = try readNString(tokens, scratch, scratch_len);
    if (try next(tokens) != .close_paren) return error.Malformed;
    return .{ .name = name, .mailbox = mailbox, .host = host };
}

/// Parses an address list and returns the first address, or null for NIL/empty.
fn parseAddressList(tokens: *tokenizer.Tokenizer, scratch: []u8, scratch_len: *usize) Error!?AddressParts {
    const open = try next(tokens);
    switch (open) {
        .atom => |atom| {
            if (std.ascii.eqlIgnoreCase(atom, "NIL")) return null;
            return error.Malformed;
        },
        .open_paren => {},
        else => return error.Malformed,
    }

    var first: ?AddressParts = null;
    while (true) {
        const token = try next(tokens);
        switch (token) {
            .close_paren => return first,
            .open_paren => {
                const parts = try parseAddress(tokens, scratch, scratch_len);
                if (first == null) first = parts;
            },
            else => return error.Malformed,
        }
    }
}

fn parseEnvelope(tokens: *tokenizer.Tokenizer, scratch: []u8, scratch_len: *usize) Error!?Envelope {
    const open = try next(tokens);
    switch (open) {
        .atom => |atom| {
            if (std.ascii.eqlIgnoreCase(atom, "NIL")) return null;
            return error.Malformed;
        },
        .open_paren => {},
        else => return error.Malformed,
    }

    var envelope = Envelope{};
    envelope.date = try readNString(tokens, scratch, scratch_len);
    envelope.subject = try readNString(tokens, scratch, scratch_len);

    if (try parseAddressList(tokens, scratch, scratch_len)) |from| {
        envelope.from_name = from.name;
        envelope.from_mailbox = from.mailbox;
        envelope.from_host = from.host;
    }

    // sender, reply-to, to, cc, bcc.
    var index: u32 = 0;
    while (index < 5) : (index += 1) {
        _ = try parseAddressList(tokens, scratch, scratch_len);
    }

    _ = try readNString(tokens, scratch, scratch_len); // in-reply-to
    _ = try readNString(tokens, scratch, scratch_len); // message-id

    if (try next(tokens) != .close_paren) return error.Malformed;
    return envelope;
}

/// Consumes one value: a single token, or a balanced parenthesized group.
fn skipValue(tokens: *tokenizer.Tokenizer) Error!void {
    const token = try next(tokens);
    if (token != .open_paren) return;
    try skipGroup(tokens, 1);
}

fn skipGroup(tokens: *tokenizer.Tokenizer, depth_start: u32) Error!void {
    var depth = depth_start;
    while (depth > 0) {
        const inner = try next(tokens);
        if (inner == .open_paren) depth += 1;
        if (inner == .close_paren) depth -= 1;
    }
}

fn kindFromWord(word: []const u8) ?Kind {
    if (std.ascii.eqlIgnoreCase(word, "OK")) return .ok;
    if (std.ascii.eqlIgnoreCase(word, "NO")) return .no;
    if (std.ascii.eqlIgnoreCase(word, "BAD")) return .bad;
    return null;
}

fn trimLeft(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and text[start] == ' ') start += 1;
    return text[start..];
}

/// `"14-Nov-2023 22:13:20 +0200"` → Unix seconds. Null when the shape is wrong.
pub fn parseInternalDate(text: []const u8) ?i64 {
    if (text.len != 26) return null;
    if (text[2] != '-' or text[6] != '-') return null;
    if (text[11] != ' ' or text[14] != ':' or text[17] != ':' or text[20] != ' ') return null;

    const month = time.month_from_abbrev(text[3..6]) orelse return null;
    const day = std.fmt.parseInt(u8, text[0..2], 10) catch return null;
    const year = std.fmt.parseInt(i32, text[7..11], 10) catch return null;
    const hour = std.fmt.parseInt(u8, text[12..14], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[15..17], 10) catch return null;
    const second = std.fmt.parseInt(u8, text[18..20], 10) catch return null;
    const offset = parseZone(text[21..26]) orelse return null;

    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return time.unix_from_parts(year, month, day, hour, minute, second, offset);
}

fn parseZone(text: []const u8) ?i32 {
    if (text.len != 5) return null;
    const sign: i32 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const hours = std.fmt.parseInt(i32, text[1..3], 10) catch return null;
    const minutes = std.fmt.parseInt(i32, text[3..5], 10) catch return null;
    if (hours > 23 or minutes > 59) return null;
    return sign * (hours * 3600 + minutes * 60);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// One response is inspected at a time, so one scratch buffer serves the tests.
/// It must outlive the assertions, which a per-test local would not.
var test_scratch: [1024]u8 = undefined;

fn parse_test(text: []const u8) Error!Response {
    return parse(text, &test_scratch);
}

test "a continuation response carries its text" {
    const response = try parse_test("+ send the literal\r\n");
    try testing.expectEqualStrings("send the literal", response.continuation);
}

test "an empty continuation is valid" {
    const response = try parse_test("+\r\n");
    try testing.expectEqualStrings("", response.continuation);
}

test "tagged OK, NO, and BAD" {
    const ok = try parse_test("a1 OK LOGIN completed\r\n");
    try testing.expectEqualStrings("a1", ok.tagged.tag);
    try testing.expectEqual(Kind.ok, ok.tagged.kind);
    try testing.expectEqualStrings("LOGIN completed", ok.tagged.text);

    const no = try parse_test("a2 NO [AUTHENTICATIONFAILED] nope");
    try testing.expectEqual(Kind.no, no.tagged.kind);
    try testing.expectEqualStrings("[AUTHENTICATIONFAILED] nope", no.tagged.text);

    const bad = try parse_test("a3 BAD unknown command");
    try testing.expectEqual(Kind.bad, bad.tagged.kind);
}

test "a tagged status without text is valid" {
    const response = try parse_test("a4 OK");
    try testing.expectEqualStrings("", response.tagged.text);
}

test "tagged responses validate their structure" {
    try testing.expectError(error.Malformed, parse_test("notag"));
    try testing.expectError(error.Malformed, parse_test("a1 "));
    try testing.expectError(error.Malformed, parse_test("a1 MAYBE whatever"));
}

test "untagged status responses" {
    const ok = try parse_test("* OK [CAPABILITY IMAP4rev1] ready");
    try testing.expectEqualStrings("[CAPABILITY IMAP4rev1] ready", ok.untagged.ok);

    const no = try parse_test("* NO quota exceeded");
    try testing.expectEqualStrings("quota exceeded", no.untagged.no);

    const bad = try parse_test("* BAD what");
    try testing.expectEqualStrings("what", bad.untagged.bad);

    const bye = try parse_test("* BYE logging out");
    try testing.expectEqualStrings("logging out", bye.untagged.bye);

    const preauth = try parse_test("* PREAUTH welcome");
    try testing.expectEqualStrings("welcome", preauth.untagged.preauth);
}

test "mailbox counts" {
    try testing.expectEqual(@as(u32, 3), (try parse_test("* 3 EXISTS")).untagged.exists);
    try testing.expectEqual(@as(u32, 1), (try parse_test("* 1 RECENT")).untagged.recent);
    try testing.expectEqual(@as(u32, 5), (try parse_test("* 5 EXPUNGE")).untagged.expunge);
}

test "capabilities and unknown untagged data are reported, not dropped" {
    const caps = try parse_test("* CAPABILITY IMAP4rev1 IDLE MOVE");
    try testing.expectEqualStrings("IMAP4rev1 IDLE MOVE", caps.untagged.capabilities);

    const other = try parse_test("* XSOMETHING new");
    try testing.expectEqualStrings("XSOMETHING new", other.untagged.other);

    const unknown_verb = try parse_test("* 12 UNKNOWN");
    try testing.expectEqualStrings("UNKNOWN", unknown_verb.untagged.other);
}

test "a full FETCH response parses every attribute" {
    const line = "* 12 FETCH (UID 42 FLAGS (\\Seen \\Flagged) RFC822.SIZE 4096 " ++
        "INTERNALDATE \"14-Nov-2023 22:13:20 +0000\")";
    const fetch = (try parse_test(line)).untagged.fetch;

    try testing.expectEqual(@as(u32, 12), fetch.sequence);
    try testing.expectEqual(@as(u32, 42), fetch.uid.?);
    try testing.expectEqual(@as(u32, 4096), fetch.size_bytes.?);
    try testing.expectEqual(@as(i64, 1_700_000_000), fetch.internal_date.?);
    try testing.expect(!fetch.flags.?.unread);
    try testing.expect(fetch.flags.?.flagged);
}

test "FETCH attributes may arrive in any order and be absent" {
    const fetch = (try parse_test("* 1 FETCH (UID 7)")).untagged.fetch;
    try testing.expectEqual(@as(u32, 7), fetch.uid.?);
    try testing.expect(fetch.flags == null);
    try testing.expect(fetch.internal_date == null);
    try testing.expect(fetch.size_bytes == null);
}

test "FETCH with empty flags means unread and unflagged" {
    const fetch = (try parse_test("* 2 FETCH (FLAGS () UID 9)")).untagged.fetch;
    try testing.expect(fetch.flags.?.unread);
    try testing.expect(!fetch.flags.?.flagged);
}

test "FETCH skips unknown attributes, including nested lists" {
    const fetch = (try parse_test("* 3 FETCH (X-UNKNOWN (NIL NIL) UID 11 X-OTHER \"x\")")).untagged.fetch;
    try testing.expectEqual(@as(u32, 11), fetch.uid.?);
}

test "FETCH parses ENVELOPE: subject unescaped, first from address" {
    const line = "* 1 FETCH (UID 42 ENVELOPE (\"Tue, 14 Nov 2023 22:13:20 +0000\" " ++
        "\"Hello \\\"world\\\"\" " ++
        "((\"Alice Rivera\" NIL \"alice\" \"example.com\")) " ++
        "((\"Alice Rivera\" NIL \"alice\" \"example.com\")) " ++
        "((\"Alice Rivera\" NIL \"alice\" \"example.com\")) " ++
        "((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL \"<id@example.com>\") " ++
        "FLAGS (\\Seen) RFC822.SIZE 4096 INTERNALDATE \"14-Nov-2023 22:13:20 +0000\")";
    const fetch = (try parse_test(line)).untagged.fetch;

    const envelope = fetch.envelope.?;
    try testing.expectEqualStrings("Hello \"world\"", envelope.subject.?);
    try testing.expectEqualStrings("Tue, 14 Nov 2023 22:13:20 +0000", envelope.date.?);
    try testing.expectEqualStrings("Alice Rivera", envelope.from_name.?);
    try testing.expectEqualStrings("alice", envelope.from_mailbox.?);
    try testing.expectEqualStrings("example.com", envelope.from_host.?);
    try testing.expectEqual(@as(i64, 1_700_000_000), fetch.internal_date.?);
    try testing.expect(!fetch.flags.?.unread);
}

test "FETCH with a NIL envelope and an empty address list" {
    const nil = (try parse_test("* 1 FETCH (UID 1 ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL))")).untagged.fetch;
    try testing.expect(nil.envelope.?.subject == null);
    try testing.expect(nil.envelope.?.from_mailbox == null);

    const empty = (try parse_test("* 1 FETCH (UID 2 ENVELOPE (NIL NIL () () () () () NIL NIL NIL))")).untagged.fetch;
    try testing.expect(empty.envelope.?.from_name == null);
}

test "LIST carries the name and the special-use flag" {
    var scratch: [256]u8 = undefined;
    const response = try parse("* LIST (\\Sent \\HasNoChildren) \"/\" \"Sent Items\"\r\n", &scratch);
    try testing.expectEqualStrings("Sent Items", response.untagged.list.name);
    try testing.expectEqual(Mailbox.sent, response.untagged.list.mailbox.?);

    const plain = try parse("* LIST () \"/\" \"INBOX\"\r\n", &scratch);
    try testing.expect(plain.untagged.list.mailbox == null);
    try testing.expectEqualStrings("INBOX", plain.untagged.list.name);
}

test "FETCH captures a body literal" {
    const fetch = (try parse_test("* 1 FETCH (UID 7 BODY[TEXT] {11}\r\nhello world)")).untagged.fetch;
    try testing.expectEqual(@as(u32, 7), fetch.uid.?);
    try testing.expectEqualStrings("hello world", fetch.body.?);
}

test "FETCH captures a quoted body and ignores NIL" {
    const quoted = (try parse_test("* 1 FETCH (BODY[] \"tiny\")")).untagged.fetch;
    try testing.expectEqualStrings("tiny", quoted.body.?);

    const nil = (try parse_test("* 1 FETCH (BODY[] NIL UID 3)")).untagged.fetch;
    try testing.expect(nil.body == null);
    try testing.expectEqual(@as(u32, 3), nil.uid.?);
}

test "a body value that is a group is skipped, and ENVELOPE NIL is accepted" {
    const grouped = (try parse_test("* 1 FETCH (BODY[] (NIL) UID 3)")).untagged.fetch;
    try testing.expect(grouped.body == null);
    try testing.expectEqual(@as(u32, 3), grouped.uid.?);

    const nil = (try parse_test("* 2 FETCH (UID 4 ENVELOPE NIL)")).untagged.fetch;
    try testing.expect(nil.envelope == null);
}

test "an ENVELOPE that is neither a list nor NIL is malformed" {
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (ENVELOPE \"x\")"));
}

test "malformed envelopes are refused" {
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (ENVELOPE (NIL NIL))"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (ENVELOPE (NIL NIL 5 NIL NIL NIL NIL NIL NIL NIL))"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (ENVELOPE (NIL NIL (NIL) NIL NIL NIL NIL NIL NIL NIL))"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (ENVELOPE (NIL NIL ((NIL)) NIL NIL NIL NIL NIL NIL NIL))"));
}

test "FETCH tolerates a literal value" {
    const fetch = (try parse_test("* 4 FETCH (BODY[HEADER] {3}\r\nabc UID 12)")).untagged.fetch;
    try testing.expectEqual(@as(u32, 12), fetch.uid.?);
}

test "FETCH date parsing applies the zone" {
    const fetch = (try parse_test("* 5 FETCH (INTERNALDATE \"14-Nov-2023 22:13:20 +0200\")")).untagged.fetch;
    try testing.expectEqual(@as(i64, 1_699_992_800), fetch.internal_date.?);
}

test "malformed FETCH responses are refused" {
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH UID 7"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (UID)"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (UID notanumber)"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (FLAGS \\Seen)"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (INTERNALDATE notquoted)"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (UID 7"));
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (ENVELOPE (NIL) UID 7"));
}

test "a non-atom attribute key is malformed" {
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (\"quoted\" UID 7)"));
}

test "a non-atom flag is malformed" {
    try testing.expectError(error.Malformed, parse_test("* 1 FETCH (FLAGS (\"x\"))"));
}

test "a FETCH date with the wrong shape is reported as an invalid date" {
    try testing.expectError(error.InvalidDate, parse_test("* 1 FETCH (INTERNALDATE \"nope\")"));
}

test "empty and truncated responses are malformed" {
    try testing.expectError(error.Malformed, parse_test(""));
    try testing.expectError(error.Malformed, parse_test("\r\n"));
    try testing.expectError(error.Malformed, parse_test("*"));
}

test "internal dates: valid shapes" {
    try testing.expectEqual(@as(i64, 1_700_000_000), parseInternalDate("14-Nov-2023 22:13:20 +0000").?);
    try testing.expectEqual(@as(i64, 951_782_400), parseInternalDate("29-Feb-2000 00:00:00 +0000").?);
    try testing.expectEqual(@as(i64, 1_699_992_800), parseInternalDate("14-Nov-2023 22:13:20 +0200").?);
}

test "internal dates: every shape error returns null" {
    try testing.expect(parseInternalDate("short") == null);
    try testing.expect(parseInternalDate("14/Nov/2023 22:13:20 +0000") == null);
    try testing.expect(parseInternalDate("14-Xyz-2023 22:13:20 +0000") == null);
    try testing.expect(parseInternalDate("14-Nov-2023 22:13:20 00000") == null);
    try testing.expect(parseInternalDate("14-Nov-2023 22:13:20 +00x0") == null);
    try testing.expect(parseInternalDate("14-Nov-2023 22:13:20 +9900") == null);
    try testing.expect(parseInternalDate("00-Nov-2023 22:13:20 +0000") == null);
    try testing.expect(parseInternalDate("14-Nov-2023 24:13:20 +0000") == null);
}

test "negative zone offsets" {
    try testing.expectEqual(@as(i64, 1_700_018_000), parseInternalDate("14-Nov-2023 22:13:20 -0500").?);
}

test "STATUS says how much of a folder nobody has read" {
    const status = (try parse_test("* STATUS \"Clients\" (MESSAGES 42 UNSEEN 3)")).untagged.status;
    try testing.expectEqual(@as(u32, 3), status.unseen);
    try testing.expectEqual(@as(u32, 42), status.messages);

    // A key we do not model is skipped, not an error: the server may add more.
    const sparse = (try parse_test("* STATUS \"Sent\" (UNSEEN 1 RECENT 0)")).untagged.status;
    try testing.expectEqual(@as(u32, 1), sparse.unseen);
    try testing.expectEqual(@as(u32, 0), sparse.messages);

    // A malformed list is a malformed response, not a folder with no mail.
    try testing.expectError(error.Malformed, parse_test("* STATUS \"Sent\" UNSEEN 1"));
    try testing.expectError(error.Malformed, parse_test("* STATUS \"Sent\" (UNSEEN)"));
    try testing.expectError(error.Malformed, parse_test("* STATUS \"Sent\" (UNSEEN many)"));
}
