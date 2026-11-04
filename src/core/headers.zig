//! The headers a reader wants and a list never does: who else was on the message, and
//! what it is called in the mailbox's own bookkeeping.
//!
//! Parsed from the raw message the reader already has in memory, bounded like everything
//! else: `Text` truncates, so a header of four kilobytes costs four kilobytes of buffer
//! and nothing more.

const std = @import("std");
const limits = @import("limits.zig");
const mime = @import("mime.zig");
const Text = @import("domain/text.zig").Text;

pub const Details = struct {
    to: Text(limits.header_max) = .{},
    cc: Text(limits.header_max) = .{},
    reply_to: Text(limits.header_max) = .{},
    message_id: Text(limits.header_max) = .{},
    /// The `Date:` header as written, which is not always the envelope's idea of it.
    date: Text(limits.header_max) = .{},

    pub fn is_empty(self: *const Details) bool {
        return self.to.is_empty() and self.cc.is_empty() and
            self.reply_to.is_empty() and self.message_id.is_empty() and self.date.is_empty();
    }
};

/// Reads the headers out of a whole raw message. Anything missing stays empty rather
/// than becoming a guess.
pub fn parse(raw: []const u8) Details {
    var details = Details{};
    if (mime.header(raw, "to")) |value| details.to.set(clean(value));
    if (mime.header(raw, "cc")) |value| details.cc.set(clean(value));
    if (mime.header(raw, "reply-to")) |value| details.reply_to.set(clean(value));
    if (mime.header(raw, "message-id")) |value| details.message_id.set(clean(value));
    if (mime.header(raw, "date")) |value| details.date.set(clean(value));
    return details;
}

/// A header value with its folded lines flattened to one line and its padding removed:
/// `To: a@b,\n\tc@d` is one list of two people, not two paragraphs.
fn clean(value: []const u8) []const u8 {
    var out = value;
    // `mime.header` already joins folded lines with a space; what is left is the padding.
    out = std.mem.trim(u8, out, " \t\r\n");
    return out;
}

const testing = std.testing;

test "the details are the headers a list never shows" {
    const raw = "From: Alice <alice@example.com>\r\n" ++
        "To: bob@example.com, Carol <carol@example.com>\r\n" ++
        "Cc: dave@example.com\r\n" ++
        "Reply-To: replies@example.com\r\n" ++
        "Date: Tue, 4 Nov 2026 10:00:00 +0000\r\n" ++
        "Message-ID: <abc123@example.com>\r\n" ++
        "Subject: hello\r\n\r\nbody";
    const details = parse(raw);
    try testing.expectEqualStrings("bob@example.com, Carol <carol@example.com>", details.to.slice());
    try testing.expectEqualStrings("dave@example.com", details.cc.slice());
    try testing.expectEqualStrings("replies@example.com", details.reply_to.slice());
    try testing.expectEqualStrings("<abc123@example.com>", details.message_id.slice());
    try testing.expectEqualStrings("Tue, 4 Nov 2026 10:00:00 +0000", details.date.slice());
    try testing.expect(!details.is_empty());
}

test "a message with no headers has empty details, not guessed ones" {
    const details = parse("Subject: only this\r\n\r\nbody");
    try testing.expect(details.is_empty());
    try testing.expect(details.to.is_empty());
}
