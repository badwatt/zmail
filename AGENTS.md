# Project Rules

## Workflow

- **TDD mandatory**: every change requires a failing test first, then passing code, then refactor.
- **Commit freely**: commit anytime without asking.
- **Push requires approval**: never push. always ask first.
- **Coverage**: 100% line coverage via kcov, no exceptions inside the gate.
  The gate covers `src/core` and `src/tui`, except three files named for a stated
  reason: `src/tui/launch.zig`, `src/tui/main.zig`, and `src/tui/refresh.zig` --
  the process boundary, run by the end-to-end pty test in another process, which
  kcov cannot instrument. `src/net` is outside the include pattern: it needs a
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
- **Linux and macOS.** The terminal code is POSIX, not Linux: `builtin.os.tag`
  switches where the kernels differ (the `ioctl` request, the pty), never a
  `#ifdef`-style fork of the logic. `SIGPIPE` is ignored at startup because macOS
  has no `MSG_NOSIGNAL`. CI runs the whole suite on a real Mac; the release ships
  static `musl` Linux binaries and libSystem-linked macOS ones.
- **The dependency arrow points inward.** `core/` must not import `tui/`, and
  must not perform I/O, read the clock, or know about terminals. Adapters depend
  on the core; the core depends on nothing.
- **All behaviour lives in `core/app/update.zig`.** Front ends translate input
  into `core.command.Command` and execute `core.effect.Effect`. If a rule needs
  to exist for a future GUI too, it goes in the update function, not in the TUI.
- Dependency injection via `src/tui/system.zig` (terminal),
  `src/core/ports/mail.zig` (mail), and `src/core/ports/transport.zig`
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
  under 70 lines, no recursion.
- 100-column lines, 4-space indent, `zig fmt`.
- Sanitization happens on ingress (`src/core/domain/text.zig`), not on render.
- **Documentation, not commentary.** Where `TIGER_STYLE.md` asks for `//` comments, this
  project keeps the same content in doc comments instead: `///` and `//!` say what
  something is and why it exists, as part of the API. `//` comments are not written -- no
  narration of the next line, no restating the code, no notes to the reviewer. A block that
  needs one wants a better name or a smaller function; a decision that needs its reason
  kept keeps it in the doc comment of what decided it, or in the commit message.

## Commits

**Conventional Commits**, always: `<type>(<scope>)?: <subject>`.

```text
feat(reader): open a message that has a PDF attached
fix(imap): read a part's headers from BODY[1.MIME]
docs: say which files the coverage gate skips
ci: run the suite with two cores, as the runner does
```

- Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `style`, `ci`,
  `chore`, `build`, `revert`. A breaking change is `!` after the type.
- `<scope>` is the area, not the file: `reader`, `imap`, `compose`, `theme`,
  `splash`, `session`, `config`, `coverage`, `release`.
- Subject in the imperative, lower case, no full stop: it completes
  "if applied, this commit will …".
- The body is where the *why* goes, and it is welcome to be long: the changelog
  shows subjects, the history keeps the argument.
- The last line may name a closed issue: `Closes #12`.

The release notes are grouped by these prefixes (`.github/workflows/release.yml`), so a
subject without one is a change nobody reading the release will see in the right
place.

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
