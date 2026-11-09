//! Network adapters: the only place that opens sockets or speaks TLS.
//!
//! Everything here sits behind `core`'s `Transport` port. The logic above it
//! (framing, commands, responses, the client) is tested with a scripted peer;
//! this file is verified against a real TLS peer (see docs/ARCHITECTURE.md).

const std = @import("std");

pub const tls = @import("tls.zig");
pub const plain = @import("plain.zig");
pub const smtp_openssl = @import("smtp_openssl.zig");
pub const cache_file = @import("cache_file.zig");
pub const bodies = @import("bodies.zig");
pub const keyfile = @import("keyfile.zig");
pub const https = @import("https.zig");
pub const oauth_flow = @import("oauth_flow.zig");

test {
    _ = @import("tls.zig");
}
