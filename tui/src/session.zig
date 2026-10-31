//! Temporary: replaced by the real session in the next step.

const std = @import("std");

pub fn launch(init: std.process.Init) !u8 {
    _ = init;
    return 0;
}
