//! Compile-time bounds for the whole product.
//!
//! Every buffer in amail is bounded before data enters it, because the data is
//! written by strangers on the internet. A mail server that sends us a 4 GiB
//! subject line must degrade to a truncated subject, never to an allocation
//! failure or an unbounded copy.

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

/// Maximum bytes of a host name (IMAP/SMTP server), per RFC 1035.
pub const host_max: u32 = 253;

/// Maximum bytes of a message body shown in the reader.
pub const body_max: u32 = 64 * 1024;

/// Maximum bytes of the search/filter query.
pub const filter_max: u32 = 48;

/// Maximum bytes of the one-line status message.
pub const status_max: u32 = 64;

/// Maximum bytes of an account label ("work").
pub const label_max: u32 = 24;

/// Maximum bytes of a secret (password or token) held in memory.
pub const secret_max: u32 = 512;

/// Maximum number of actions a single user command may produce.
pub const actions_max: u32 = 8;
