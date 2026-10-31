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
pub const secret = @import("domain/secret.zig");
pub const account = @import("domain/account.zig");
pub const store = @import("domain/store.zig");
pub const time = @import("domain/time.zig");

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
    _ = @import("domain/secret.zig");
    _ = @import("domain/account.zig");
    _ = @import("domain/store.zig");
    _ = @import("domain/time.zig");
}
