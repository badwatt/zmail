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

**Domain (`src/core/domain`).** Value types with the invariants baked in:
`Text(capacity)` (truncating, control-neutralizing), `Address`, `Mailbox`,
`Message`, `Flags`, `Store` (fixed-capacity cache, newest first), `Secret`,
`Account`/`Server`, and `time` (relative stamps and calendar dates).

**Ports (`src/core/ports`).** `mail.Mail` is a vtable with four operations:
fetch envelopes for a mailbox, fetch one body, set flags, move a message. The
port is small on purpose: it is the entire surface an IMAP adapter, an SMTP
adapter, or a test double must satisfy.

**Application (`src/core/app`).**

- `command.Command` is a user intent with no keyboard or mouse in it.
- `state.State` is the aggregate: view (`list`, `reader`, `help`), mode
  (`normal`, `search`), mailbox, filter, cursor, scroll, open message, status.
- `update.apply(state, store, command) → Effects` is the **only** place that
  decides what a command means. It performs no I/O.
- `effect.Effect` is the bounded list of work the front end must do:
  `fetch_body`, `sync_flags`, `move_message`, `refresh`.

**MIME (`src/core/mime.zig`).** The bridge between wire format and prose, pure
and allocation-free: RFC 2047 encoded words (subjects, display names), transfer
encodings (base64, quoted-printable), charsets (UTF-8, ASCII, ISO-8859-1,
Windows-1252), multipart walking that prefers `text/plain` and falls back to
stripped `text/html`, and sanitization on the way out. Buffers come from the
caller, so a hostile message can only produce truncated text.

One lifetime rule follows from the protocol code: strings unescaped from a
response point into a scratch buffer, so that buffer belongs to the
`Client` (`parse_scratch`), never to the parsing function. A stack local there
dangles the moment the function returns, and the reader saw exactly that as
garbage subjects.

**Starting up.** `Session.init` reads the cache and paints; `Session.boot`
opens only the connections the cache could not replace, after that first frame
is on screen. The connections themselves are lazy (`adapters/lazy.zig`): the
`Mail` and `Outbox` ports open on their first call, so a warm start performs no
I/O at all and a failed connection is an ordinary port error instead of a
startup failure. The process boundary (`src/tui/launch.zig`) keeps the
password, the TLS transports, and the error messages that the opener needs.

**Warming the connection.** A start from cache opens no socket, so the *first*
message open would otherwise pay DNS, TCP, TLS, LOGIN, SELECT and FETCH before
the first byte of prose. Right after the first frame the session starts a
refresh in the background: the connection is warm by the time a message is
opened, and a body asked for while the worker is busy is deferred (the reader
shows the envelope immediately and the text arrives when the fetch finishes),
never blocked and never refused.

**Refreshing.** `Ctrl+R` starts one worker thread (`src/tui/refresh.zig`): it
fetches the current mailbox for every account into a second buffer, and the UI
thread swaps the result into the store when an atomic flag says done. The store
is only ever touched by the UI thread, other mail requests are refused while the
worker runs ("Refreshing mail…"), and a failed account keeps the mail already on
screen.

**Mailbox names.** IMAP mailbox names are server-defined: "Sent" is "Sent
Items", "Sent Messages", or "[Gmail]/Sent Mail". The adapter tries our title
first and, on refusal, runs `LIST` once and resolves by SPECIAL-USE flag
(`\Sent`) or by a known alias; a mailbox the server does not have is simply
empty, not an error.

**Caching.** `cache.zig` is the versioned TSV codec; `ports/cache.zig` is the
port; the session reads it at startup and on mailbox switches and writes it
after every network refresh. `src/net/cache_file.zig` is the file adapter
(one file per account and mailbox under the cache directory).

**Adapters.** `adapters/memory_mail.zig` is the demo account and the tests'
server double. `adapters/imap_mail.zig` implements the same port over the real
protocol client; it is tested with a scripted server, not a network. The TLS
transport is the only adapter still missing, and it plugs into the `Transport`
port without touching either adapter.

**Protocol (`src/core/protocol/imap`).** Pure functions over byte buffers:

| File | Responsibility |
|------|----------------|
| `tokenizer.zig` | atoms, quoted strings with escapes, literals |
| `framing.zig` | response framing: a response may contain CRLF-bearing literals |
| `command.zig` | commands rendered into bounded buffers, with quoting |
| `response.zig` | tagged/untagged classification, counts, FETCH + ENVELOPE |
| `client.zig` | the conversation: send, pump untagged, turn tags into results |

`client.zig` talks to `ports/transport.zig` (`read`/`write`/`close`), never to a
socket, so a whole IMAP conversation is a unit test with a scripted peer.

**Network tree (`src/net`).** `tls.zig` is the only code that opens a socket.
It implements the `Transport` port over `std.Io.net` + `std.crypto.tls.Client`:
system CA bundle, hostname verification, no insecure mode. Two details matter:

- Reads poll the socket, but first drain bytes already decrypted (or a complete
  encrypted record already buffered). A greeting often arrives with the
  handshake and would otherwise be invisible while the socket stays silent.
- TLS is only entered when a whole encrypted record is buffered, because its own
  read would block without a timeout. A partial record waits for the next poll.

`src/net/` is deliberately outside the kcov include pattern (`src/core,src/tui`).
It cannot be unit tested without a real TLS peer; it is verified by an opt-in
live run (a real IMAP server, expected login refusal with a wrong password)
plus the scripted-conversation tests one layer above it.

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

- `src/tui/launch.zig` — raw mode, alternate screen, and session lifecycle.
- `src/tui/main.zig` — three lines of process wiring.

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
