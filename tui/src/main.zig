//! Process entry point. Wiring only: everything testable lives in `lib.zig`.

const std = @import("std");
const tui = @import("lib.zig");

pub fn main(init: std.process.Init) !u8 {
    return tui.run.main(init);
}
