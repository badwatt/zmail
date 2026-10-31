//! amail core: domain and application, the hexagon's inside.
//!
//! Nothing in this module tree performs I/O, reads the clock, or knows what a
//! terminal is. Adapters (TUI today, GUI tomorrow, IMAP/SMTP later) depend on
//! this module; it never depends on them.

const std = @import("std");

pub const limits = @import("limits.zig");
pub const meta = @import("meta.zig");
pub const text = @import("domain/text.zig");

test {
    _ = @import("meta.zig");
    _ = @import("domain/text.zig");
}
