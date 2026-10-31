//! Single test root, so one `kcov` run measures both trees.

const std = @import("std");

test {
    _ = @import("core");
    _ = @import("tui");
}
