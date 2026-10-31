# Architecture

```
                 ┌─────────────────────────────────────────────┐
   bytes ──────▶ │ tui/                                        │
                 │  input → keymap → core.command.Command       │
                 │  session ──▶ core.app.update ──▶ effects    │
                 │     ▲                              │        │
                 │     └──── render ← state, store ◀──┘        │
                 └───────────────┬─────────────────────────────┘
                                 │ depends on
                 ┌───────────────▼─────────────────────────────┐
                 │ core/                                       │
                 │  domain/   address, mailbox, message, ...   │
                 │  ports/    mail (vtables)                   │
                 │  adapters/ memory_mail (demo + test double) │
                 │  app/      command, state, update, effects  │
                 └─────────────────────────────────────────────┘
```

The arrow only ever points inward: `core/` has no import of `tui/`, no libc, no
clock, no terminal, and no filesystem. That is what makes the domain testable in
microseconds and what will let a GUI reuse it unchanged.

## The hexagon

**Domain (`core/src/domain`).** Value types with the invariants baked in:
`Text(capacity)` (truncating, control-neutralizing), `Address`, `Mailbox`,
`Message`, `Flags`, `Store` (fixed-capacity cache, newest first), `Secret`,
`Account`/`Server`, and `time` (relative stamps and calendar dates).

**Ports (`core/src/ports`).** `mail.Mail` is a vtable with four operations:
fetch envelopes for a mailbox, fetch one body, set flags, move a message. The
port is small on purpose: it is the entire surface an IMAP adapter, an SMTP
adapter, or a test double must satisfy.

**Application (`core/src/app`).**

- `command.Command` is a user intent with no keyboard or mouse in it.
- `state.State` is the aggregate: view (`list`, `reader`, `help`), mode
  (`normal`, `search`), mailbox, filter, cursor, scroll, open message, status.
- `update.apply(state, store, command) → Effects` is the **only** place that
  decides what a command means. It performs no I/O.
- `effect.Effect` is the bounded list of work the front end must do:
  `fetch_body`, `sync_flags`, `move_message`, `refresh`.

**Adapters.** `adapters/memory_mail.zig` is the demo account and the tests'
server double. `adapters/imap_mail.zig` implements the same port over the real
protocol client; it is tested with a scripted server, not a network. The TLS
transport is the only adapter still missing, and it plugs into the `Transport`
port without touching either adapter.

**Protocol (`core/src/protocol/imap`).** Pure functions over byte buffers:

| File | Responsibility |
|------|----------------|
| `tokenizer.zig` | atoms, quoted strings with escapes, literals |
| `framing.zig` | response framing: a response may contain CRLF-bearing literals |
| `command.zig` | commands rendered into bounded buffers, with quoting |
| `response.zig` | tagged/untagged classification, counts, FETCH + ENVELOPE |
| `client.zig` | the conversation: send, pump untagged, turn tags into results |

`client.zig` talks to `ports/transport.zig` (`read`/`write`/`close`), never to a
socket, so a whole IMAP conversation is a unit test with a scripted peer.

## The TUI

| File | Responsibility |
|------|----------------|
| `cli.zig` | argv → intent; `--help`, `--version`, usage errors |
| `run.zig` | process entry; the decision table is pure and tested |
| `launch.zig` | raw mode, alternate screen, mouse reporting, session lifecycle |
| `session.zig` | the loop: read → decode → update → execute effects → render |
| `input.zig` | bytes → keys (CSI/SS3, SGR mouse, UTF-8, split sequences) |
| `keymap.zig` | keys + context → `core.command.Command` |
| `layout.zig` | geometry and hit boxes for one terminal size |
| `render.zig` | state → cells (no I/O, no globals, `now` injected) |
| `screen.zig` | cell buffer, rounded boxes, ANSI encoding |
| `wrap.zig` | greedy word wrap into fixed line ranges |
| `theme.zig` | dark palette and a `NO_COLOR` monochrome palette |
| `system.zig` | the port: read/write/size/raw mode, plus a scripted fake |
| `os.zig` | the POSIX adapter: fds, termios, ioctl, `getenv`, `clock_gettime` |

Rendering is a pure function `Inputs → Screen`. The session then encodes the
screen row by row into a bounded buffer and writes it. No allocations happen
after startup.

## Why effects instead of callbacks

A keystroke may need I/O (fetch a body, sync a flag). If `update` called the
mail port directly, every test would need a mock and every front end would need
to know the port. Instead `update` returns a bounded list of effects and the
session executes them. The consequences:

- all behaviour is a unit test with no I/O;
- a GUI can execute the same effects with the same ports;
- a command can never ask for unbounded background work;
- partial failure has one obvious home (the session maps port errors to
  `state.set_alert`).

## Viewport feedback

The renderer knows geometry; the state machine needs it for paging and scroll
clamping. The session sends `Command.set_viewport` with `list_rows`,
`reader_rows`, and the measured `body_rows` before each frame. The command does
not clear the status line, so a resize never erases "Archived".

## Coverage boundary

`zig build coverage` runs the core and TUI test binaries under kcov, merges the
reports, and fails unless every measured line is covered. Two files are
excluded **by name**, and only these two:

- `tui/src/launch.zig` — raw mode, alternate screen, and session lifecycle.
- `tui/src/main.zig` — three lines of process wiring.

Both are executed by the end-to-end test that spawns the real binary on a
pseudo-terminal, asserts the first frame contains the app name and the Inbox
tabs, sends `q`, and requires a clean exit. Everything else, including the
POSIX adapter (`os.zig`, driven against a real pty) and the CLI (`run.zig`), is
under the 100% gate.

## Testing strategy

- **Domain**: exhaustive valid/invalid tables, boundary capacities, truncation
  at UTF-8 boundaries, and the negative space (control bytes, oversized parts).
- **Application**: one or more tests per command, including the empty list,
  cursor bounds, filter edge cases, and every port error variant.
- **TUI**: rows of the cell buffer, not ANSI goldens, so tests read like
  assertions about what a user sees.
- **Process**: the real binary under a pty, plus `--version`/`--help`/usage.

## Adding a GUI later

The GUI implements the same three things the TUI does: a `System`-equivalent
front end that turns its events into `Command`, an effect executor for the same
`Deps`, and a renderer from `State` + `Store` to its own pixel/widget tree. The
`core/` module is already a standalone unit; moving it to its own package is a
move, not a rewrite.
