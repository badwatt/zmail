//! IMAP wire layer: tokens, commands, and responses.
//!
//! Pure functions over byte buffers. The transport (TLS, sockets, timeouts)
//! plugs in above this, which keeps the protocol itself 100% unit tested.

const std = @import("std");

pub const tokenizer = @import("imap/tokenizer.zig");
pub const command = @import("imap/command.zig");
pub const response = @import("imap/response.zig");
pub const bodystructure = @import("imap/bodystructure.zig");
pub const framing = @import("imap/framing.zig");
pub const client = @import("imap/client.zig");

test {
    _ = @import("imap/tokenizer.zig");
    _ = @import("imap/command.zig");
    _ = @import("imap/response.zig");
    _ = @import("imap/bodystructure.zig");
    _ = @import("imap/framing.zig");
    _ = @import("imap/client.zig");
}
