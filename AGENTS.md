# Project Rules

## Workflow

- **TDD mandatory**: every change requires a failing test first, then passing code, then refactor.
- **Commit freely**: commit anytime without asking.
- **Push requires approval**: never push. always ask first.
- **Coverage**: 100% line coverage via kcov, no exceptions inside the gate.
  The gate covers `core/src` and `tui/src`, except three files named for a stated
  reason: `tui/src/launch.zig`, `tui/src/main.zig`, and `tui/src/refresh.zig` --
  the process boundary, run by the end-to-end pty test in another process, which
  kcov cannot instrument. `net/src` is outside the include pattern: it needs a
  real TLS peer, and is verified with an opt-in live run. See
  `docs/ARCHITECTURE.md`.

## Verification Steps

1. Write failing test.
2. Make test pass with minimal code.
3. Refactor.
4. Run `zig build test` → all pass (core, TUI, build helpers, e2e on a real pty).
5. Run `zig build coverage` → 100.00%.
6. Commit.

## Technical Constraints

- Zig 0.17.0+.
- **The dependency arrow points inward.** `core/` must not import `tui/`, and
  must not perform I/O, read the clock, or know about terminals. Adapters depend
  on the core; the core depends on nothing.
- **All behaviour lives in `core/app/update.zig`.** Front ends translate input
  into `core.command.Command` and execute `core.effect.Effect`. If a rule needs
  to exist for a future GUI too, it goes in the update function, not in the TUI.
- Dependency injection via `tui/src/system.zig` (terminal),
  `core/src/ports/mail.zig` (mail), and `core/src/ports/transport.zig`
  (network). Tests use `system.Fake`, `adapters/memory_mail.zig`, and
  `ports/transport.zig`'s `Scripted` peer; never the real terminal or network.
- External commands run as argv lists, never through a shell.
- No hardcoded stdout/stdin: the session writes through the `System` port;
  `cli`/`run` take writers. Output is never written from library code.
- `use_llvm = true` on the test binaries for kcov.
- Bounded everything: no allocation after startup, no unbounded copies, no
  unbounded loops. Mail content is attacker-controlled; treat it as such.
- `build.zig.zon` is the single source of truth for the app name and version.
  Never hardcode either anywhere else.

## Style

- Follow `docs/TIGER_STYLE.md`: snake_case functions, explicit integer widths,
  assertions for programmer errors (including the negative space), functions
  under 70 lines, no recursion, comments that explain *why*.
- 100-column lines, 4-space indent, `zig fmt`.
- Sanitization happens on ingress (`core/src/domain/text.zig`), not on render.

## Releasing

- `build.zig.zon` is the release: `.version` is the tag, `.name` is the binary and
  `.minimum_zig_version` is the compiler. Nothing else may spell any of them.
- Bump `.version` and push; `release.yml` only starts when the manifest changes,
  and refuses to tag a version that already has a tag.
- `zig build docs:check` keeps README/AGENTS honest about the toolchain and fails
  if a Zig file writes the product name as a literal.

## Questions?

Ask before uncertain decisions. Prefer stating assumptions in the commit
message over silently picking one.
