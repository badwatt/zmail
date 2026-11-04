//! Compile-time bounds for the whole product.
//!
//! Every buffer in zmail is bounded before data enters it, because the data is
//! written by strangers on the internet. A mail server that sends us a 4 GiB
//! subject line must degrade to a truncated subject, never to an allocation
//! failure or an unbounded copy.

/// Longest address the reader will hand to a browser.
pub const url_max: usize = 2048;

/// Maximum number of messages cached from one account at a time.
pub const messages_max: u32 = 4096;

/// Maximum bytes kept from a subject line.
pub const subject_max: u32 = 160;

/// Maximum bytes kept from a message preview line.
pub const snippet_max: u32 = 120;

/// Maximum bytes of a display name ("Alice Rivera").
pub const name_max: u32 = 48;

/// Maximum bytes of the local part of an address, per RFC 5321.
pub const local_max: u32 = 64;

/// Maximum bytes of a domain, per RFC 1035.
pub const domain_max: u32 = 255;

/// Maximum bytes of an addr-spec (`local@domain`), per RFC 5321.
pub const address_max: u32 = 254;
/// A header's value: `To:` can list a crowd, and `Message-ID:` is not short either.
pub const header_max: u32 = 512;

/// Maximum bytes of a host name (IMAP/SMTP server), per RFC 1035.
pub const host_max: u32 = 253;

/// Maximum mailboxes learned from a server's LIST.
pub const mailboxes_max: u32 = 64;

/// Maximum bytes of a server mailbox name ("[Gmail]/Sent Mail"). IMAP itself
/// has no limit; 128 bytes holds every real-world name.
pub const mailbox_name_max: u32 = 128;

/// Maximum bytes of a message body shown in the reader. Mail from a web client
/// is not a 2 KiB note any more: a newsletter with inline images runs to a few
/// hundred KiB of markup and base64, and a message that cannot be framed cannot
/// be read at all. The text part is almost always in the first part of that.
pub const body_max: u32 = 512 * 1024;

/// Maximum bytes of the help overlay's filter.
pub const help_query_max: u32 = 24;

/// Maximum bytes of the search/filter query.
pub const filter_max: u32 = 48;

/// Maximum bytes of the one-line status message.
pub const status_max: u32 = 64;

/// Maximum bytes of an account label ("work").
pub const label_max: u32 = 24;

/// Maximum bytes of a username sent to an IMAP/SMTP server.
pub const username_max: u32 = 128;

/// Maximum bytes of a secret (password or token) held in memory.
pub const secret_max: u32 = 512;

/// Maximum bytes of a `password_command` line (an argv to run, never a shell
/// line, so a space in a path cannot be expressed and quoting is unnecessary).
pub const password_command_max: u32 = 200;

/// Seconds a send waits after Ctrl+S, so a message addressed to the wrong
/// person can still be stopped. Short on purpose: a longer window is a longer
/// wait before the mail that was meant to go, goes.
pub const send_hold_seconds: i64 = 5;

/// Maximum number of actions a single user command may produce.
pub const actions_max: u32 = 8;
