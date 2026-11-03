//! zmail core: domain and application, the hexagon's inside.
//!
//! Nothing in this module tree performs I/O, reads the clock, or knows what a
//! terminal is. Adapters (TUI today, GUI tomorrow, IMAP/SMTP later) depend on
//! this module; it never depends on them.

const std = @import("std");

pub const limits = @import("limits.zig");
/// Accounts a single zmail process can talk to at once.
pub const app_max_accounts: u8 = 4;
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
pub const cache_port = @import("ports/cache.zig");
pub const bodies_port = @import("ports/bodies.zig");
pub const accounts_port = @import("ports/accounts.zig");
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
pub const setup = @import("app/setup.zig");
pub const sync = @import("app/sync.zig");

pub const imap = @import("protocol/imap.zig");
pub const smtp = @import("protocol/smtp.zig");

pub const demo = @import("demo.zig");
pub const cache = @import("cache.zig");
pub const html = @import("html.zig");
pub const png = @import("png.zig");
pub const scope_port = @import("ports/scope.zig");
pub const links = @import("links.zig");
pub const mime = @import("mime.zig");
pub const sealed = @import("sealed.zig");
pub const oauth = @import("oauth.zig");
pub const lazy_mail = @import("adapters/lazy.zig").LazyMail;
pub const lazy_outbox = @import("adapters/lazy.zig").LazyOutbox;
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
    _ = @import("ports/cache.zig");
    _ = @import("ports/bodies.zig");
    _ = @import("ports/accounts.zig");
    _ = @import("adapters/memory_mail.zig");
    _ = @import("adapters/imap_mail.zig");
    _ = @import("adapters/smtp_outbox.zig");
    _ = @import("adapters/memory_outbox.zig");
    _ = @import("app/compose.zig");
    _ = @import("app/command.zig");
    _ = @import("app/effect.zig");
    _ = @import("app/state.zig");
    _ = @import("app/update.zig");
    _ = @import("app/setup.zig");
    _ = @import("app/sync.zig");
    _ = @import("protocol/imap.zig");
    _ = @import("protocol/smtp.zig");
    _ = @import("demo.zig");
    _ = @import("cache.zig");
    _ = @import("html.zig");
    _ = @import("png.zig");
    _ = @import("ports/scope.zig");
    _ = @import("links.zig");
    _ = @import("mime.zig");
    _ = @import("sealed.zig");
    _ = @import("oauth.zig");
    _ = @import("adapters/lazy.zig");
    _ = @import("config.zig");
}
