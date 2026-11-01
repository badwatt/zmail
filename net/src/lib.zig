//! Network adapters: the only place that opens sockets or speaks TLS.
//!
//! Everything here sits behind `core`'s `Transport` port. The logic above it
//! (framing, commands, responses, the client) is tested with a scripted peer;
//! this file is verified against a real TLS peer (see docs/ARCHITECTURE.md).

const std = @import("std");

pub const tls = @import("tls.zig");
pub const cache_file = @import("cache_file.zig");

test {
    _ = @import("tls.zig");
}
