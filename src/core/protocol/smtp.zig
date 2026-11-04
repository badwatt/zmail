//! SMTP wire layer: replies, commands, and the client loop.

const std = @import("std");

pub const response = @import("smtp/response.zig");
pub const command = @import("smtp/command.zig");
pub const client = @import("smtp/client.zig");

test {
    _ = @import("smtp/response.zig");
    _ = @import("smtp/command.zig");
    _ = @import("smtp/client.zig");
}
