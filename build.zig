//! Build configuration for zmail.
//!
//! Two source trees, one product:
//!   - `core/`  domain + application (ports & adapters inward). No I/O, no terminal.
//!   - `tui/`   terminal adapter. Depends on `core`, never the other way around.
//!
//! `build.zig.zon` is the single source of truth for the app name and version.
//! It is imported here and exposed to the source trees as the `app_meta` module.
//!
//! Steps: `build`, `run`, `test`, `coverage`, `fmt`, `fmt:check`.

const std = @import("std");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");

/// Single source of truth, compiled from `build.zig.zon`.
pub const app_name = @tagName(zon.name);
pub const app_version = std.SemanticVersion.parse(zon.version) catch
    @panic("build.zig.zon: version is not valid semver");

/// The toolchain the manifest asks for. Builds refuse to start on an older
/// compiler with a message that names the manifest, instead of failing somewhere
/// deep in the standard library.
const minimum_zig = std.SemanticVersion.parse(zon.minimum_zig_version) catch
    @panic("build.zig.zon: minimum_zig_version is not valid semver");

comptime {
    if (builtin.zig_version.order(minimum_zig) == .lt) {
        @compileError("this build needs Zig " ++ zon.minimum_zig_version ++
            " or newer (see build.zig.zon); this is " ++ builtin.zig_version_string);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const install_test_bins = b.option(bool, "test-bin", "Install test binaries for coverage analysis") orelse false;

    const core = coreModule(b, target, optimize);
    const net = netModule(b, target, optimize, core);
    const exe = addExe(b, target, optimize, core, net);
    addTest(b, target, optimize, core, exe, install_test_bins);
    addCoverage(b, target, optimize, core);
    addFmt(b);
    addDocsCheck(b);
}

/// `build.zig.zon` as a Zig module, so the source trees read the app metadata
/// instead of duplicating the name or version anywhere.
fn metaModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("build.zig.zon") });
}

/// The domain module: pure Zig, no libc, no syscalls.
fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/core/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("app_meta", metaModule(b));
    return mod;
}

/// Network adapters (socket + TLS). Kept out of the test root: this is the one
/// tree that needs a real peer to be exercised, and it is verified by the
/// opt-in live test instead of by unit tests.
fn netModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/net/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("core", core);
    return mod;
}

/// The TUI module. Links libc for termios; only the OS adapter uses it.
fn tuiModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/tui/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("core", core);
    mod.addImport("net", netModule(b, target, optimize, core));
    return mod;
}

fn addExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, net: *std.Build.Module) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/tui/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("core", core);
    mod.addImport("net", net);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = mod,
        .version = app_version,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run zmail").dependOn(&run_cmd.step);
    return exe;
}

/// Three test binaries: core, TUI, and build helpers.
///
/// Each module root is its own test root so `zig test` sees the submodules'
/// `test` blocks (a module imported by another module brings types, not tests).
fn addTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, exe: *std.Build.Step.Compile, install_test_bins: bool) void {
    const test_step = b.step("test", "Run unit and integration tests");

    addUnitTest(b, test_step, core, "zmail-core-test", install_test_bins);

    const tui = tuiModule(b, target, optimize, core);
    addUnitTest(b, test_step, tui, "zmail-tui-test", install_test_bins);

    const helpers = b.createModule(.{
        .root_source_file = b.path("build/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addUnitTest(b, test_step, helpers, b.fmt("{s}-build-test", .{app_name}), install_test_bins);

    addE2eTest(b, target, optimize, core, exe, test_step);
}

fn addUnitTest(b: *std.Build, test_step: *std.Build.Step, mod: *std.Build.Module, name: []const u8, install_test_bins: bool) void {
    const compile = b.addTest(.{
        .name = name,
        .root_module = mod,
        .use_llvm = true,
    });
    const run_tests = b.addRunArtifact(compile);
    if (install_test_bins) {
        const install = b.addInstallArtifact(compile, .{});
        b.getInstallStep().dependOn(&install.step);
    }
    test_step.dependOn(&run_tests.step);
}

/// End-to-end tests spawn the real binary: argv handling, exit codes, and a
/// full TUI session driven through a pseudo-terminal.
fn addE2eTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, exe: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOptionPath("zmail_exe", exe.getEmittedBin());
    mod.addImport("build_options", options.createModule());
    mod.addImport("core", core);

    const compile = b.addTest(.{
        .name = b.fmt("{s}-e2e", .{app_name}),
        .root_module = mod,
        .use_llvm = true,
    });
    const run_tests = b.addRunArtifact(compile);
    run_tests.step.dependOn(&exe.step);
    test_step.dependOn(&run_tests.step);
}

/// Runs both test binaries under kcov, merges the reports, and fails unless
/// every measured line is covered.
///
/// The process boundary is excluded by name, not by accident: `src/tui/launch.zig`
/// and `src/tui/refresh.zig` (the only thread)
/// (raw mode, alternate screen, session lifecycle) and `src/tui/main.zig` (three
/// lines of wiring) are executed by the end-to-end PTY test, not by unit tests.
///
/// kcov is provided by nix-shell because kcov is a development tool, not a
/// project dependency (zero dependencies, apart from the Zig toolchain).
fn addCoverage(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module) void {
    const core_tests = b.addTest(.{
        .name = b.fmt("{s}-core-coverage", .{app_name}),
        .root_module = coreModule(b, target, optimize),
        .use_llvm = true,
    });
    const tui_tests = b.addTest(.{
        .name = b.fmt("{s}-tui-coverage", .{app_name}),
        .root_module = tuiModule(b, target, optimize, core),
        .use_llvm = true,
    });

    const report_mod = b.createModule(.{
        .root_source_file = b.path("build/coverage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const report = b.addExecutable(.{ .name = b.fmt("{s}-coverage-report", .{app_name}), .root_module = report_mod });

    const kcov = b.addSystemCommand(&.{ "sh", "-c" });
    kcov.addArg(
        \\set -e
        \\rm -rf .coverage coverage
        \\mkdir -p .coverage
        \\export CORE_BIN="$1" TUI_BIN="$2" REPORT_BIN="$3"
        \\export PATTERN="src/core,src/tui"
        \\export SKIP="src/tui/launch.zig,src/tui/main.zig,src/tui/refresh.zig"
        \\steps='
        \\# A kcov from nix carries its own glibc in LD_LIBRARY_PATH, while the binary
        \\# under test was linked against the system one: the mixture does not load.
        \\# kcov runs from its own RUNPATH, so the variable can go for the child.
        \\kcov() { env -u LD_LIBRARY_PATH kcov "$@"; }
        \\kcov --include-pattern="$PATTERN" --exclude-pattern="$SKIP" .coverage/core "$CORE_BIN" &&
        \\kcov --include-pattern="$PATTERN" --exclude-pattern="$SKIP" .coverage/tui "$TUI_BIN" &&
        \\kcov --merge coverage .coverage/core .coverage/tui
        \\'
        \\# kcov is a development tool, not a dependency: a distro package when it is
        \\# installed (CI), nix-shell otherwise.
        \\if command -v kcov >/dev/null 2>&1; then
        \\  sh -c "$steps"
        \\else
        \\  nix-shell --quiet -p kcov --run "$steps"
        \\fi
        \\exec "$REPORT_BIN" coverage
    );
    kcov.addArg(b.fmt("{s}-coverage", .{app_name}));
    kcov.addArtifactArg2(core_tests, .{});
    kcov.addArtifactArg2(tui_tests, .{});
    kcov.addArtifactArg2(report, .{});
    b.step("coverage", "Run tests under kcov, fail below 100% line coverage").dependOn(&kcov.step);
}

/// Fails when the docs quote a Zig version, a version, or a product name that the
/// manifest no longer says, and when a literal "zmail appears in the Zig trees:
/// the name lives in `build.zig.zon`, and nothing else may spell it out.
fn addDocsCheck(b: *std.Build) void {
    const check = b.addSystemCommand(&.{ "sh", "-c" });
    check.addArg(b.fmt(
        \\set -e
        \\grep -q "Zig {s}" README.md AGENTS.md
        \\if grep -rn --include=*.zig -e '"zmail' src build tests | grep -v 'zmail-cache'; then
        \\  echo "the product name is a literal; read it from build.zig.zon" >&2
        \\  exit 1
        \\fi
    , .{zon.minimum_zig_version}));
    b.step("docs:check", "Fail if the docs quote a stale name, version or toolchain")
        .dependOn(&check.step);
}

fn addFmt(b: *std.Build) void {
    const paths: []const std.Build.LazyPath = &.{
        b.path("build.zig"),
        b.path("build"),
        b.path("src"),
        b.path("tests"),
    };
    const fmt = b.addFmt(.{ .paths = paths });
    b.step("fmt", "Format source files").dependOn(&fmt.step);

    const check = b.addFmt(.{ .paths = paths, .check = true });
    b.step("fmt:check", "Fail if source files are not formatted").dependOn(&check.step);
}
