//! amail core: domain and application, the hexagon's inside.
//!
//! Nothing in this module tree performs I/O, reads the clock, or knows what a
//! terminal is. Adapters (TUI today, GUI tomorrow, IMAP/SMTP later) depend on
//! this module; it never depends on them.

const std = @import("std");

pub const limits = @import("limits.zig");
pub const meta = @import("meta.zig");
pub const text = @import("domain/text.zig");
pub const id = @import("domain/id.zig");
pub const mailbox = @import("domain/mailbox.zig");
pub const address = @import("domain/address.zig");
pub const message = @import("domain/message.zig");
pub const outgoing = @import("domain/outgoing.zig");
pub const secret = @import("domain/secret.zig");
pub const account = @import("domain/account.zig");
pub const store = @import("domain/store.zig");
pub const time = @import("domain/time.zig");

pub const mail_port = @import("ports/mail.zig");
pub const outbox_port = @import("ports/outbox.zig");
pub const transport_port = @import("ports/transport.zig");
pub const memory_mail = @import("adapters/memory_mail.zig");
pub const imap_mail = @import("adapters/imap_mail.zig");
pub const smtp_outbox = @import("adapters/smtp_outbox.zig");
pub const memory_outbox = @import("adapters/memory_outbox.zig");

pub const compose = @import("app/compose.zig");
pub const command = @import("app/command.zig");
pub const effect = @import("app/effect.zig");
pub const state = @import("app/state.zig");
pub const update = @import("app/update.zig");
pub const sync = @import("app/sync.zig");

pub const imap = @import("protocol/imap.zig");
pub const smtp = @import("protocol/smtp.zig");

pub const demo = @import("demo.zig");
pub const config = @import("config.zig");

// Referenced from the module root's test block so `zig build test` includes
// every submodule's tests.
test {
    _ = @import("limits.zig");
    _ = @import("meta.zig");
    _ = @import("domain/text.zig");
    _ = @import("domain/id.zig");
    _ = @import("domain/mailbox.zig");
    _ = @import("domain/address.zig");
    _ = @import("domain/message.zig");
    _ = @import("domain/outgoing.zig");
    _ = @import("domain/secret.zig");
    _ = @import("domain/account.zig");
    _ = @import("domain/store.zig");
    _ = @import("domain/time.zig");
    _ = @import("ports/mail.zig");
    _ = @import("ports/outbox.zig");
    _ = @import("adapters/memory_mail.zig");
    _ = @import("adapters/imap_mail.zig");
    _ = @import("adapters/smtp_outbox.zig");
    _ = @import("adapters/memory_outbox.zig");
    _ = @import("app/compose.zig");
    _ = @import("app/command.zig");
    _ = @import("app/effect.zig");
    _ = @import("app/state.zig");
    _ = @import("app/update.zig");
    _ = @import("app/sync.zig");
    _ = @import("protocol/imap.zig");
    _ = @import("protocol/smtp.zig");
    _ = @import("demo.zig");
    _ = @import("config.zig");
}
