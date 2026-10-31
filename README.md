# amail

A calm terminal mail client, written in Zig.

```
 amail  Inbox    3 Sent       Drafts     Archive    Trash      Junk
────────────────────────────────────────────────────────────────────────────
 ● Alice Rivera         Re: design tokens review                            1m
 ● Bob Chen             Zig 0.17 release notes                             14m ★
   GitHub               [amail] TUI skeleton merged (#42)                   2h
   NixOS Weekly         NixOS Weekly #312                                   5h
 ● Ana Torres           Invoice for October                                 1d ★
   Linear               Your week in review                                 3d
   Hacker News           The best of last week                           10/22
────────────────────────────────────────────────────────────────────────────
 j/k move  ·  Enter open  ·  / search  ·  d archive  ·  ? help              2/7
```

Two things matter here: it has to be **simple** and it has to be **beautiful**. Every
decision below serves one of those, in that order.

## Run it

```sh
zig build run        # opens the demo inbox: no account, no network, no config
amail --live         # connects to the account in the config file
```

`q` quits from the list, `Ctrl+Q`/`Ctrl+C` quit from anywhere, and `?` shows
every key (`/` inside the help filters it).

### Live mode

`~/.config/amail/config` (or `--config PATH`):

```ini
address     = alice@example.com
label       = work
username    = alice
imap_host   = imap.example.com
imap_port   = 993
imap_security = tls

# Optional. Without SMTP, reading works and compose reports that it cannot send.
smtp_host   = smtp.example.com
smtp_port   = 465
smtp_security = tls
```

The password is **never** in the file; it is read from `AMAIL_PASSWORD`:

```sh
AMAIL_PASSWORD='...' amail --live
```

Only implicit TLS is supported today (IMAP 993, SMTP 465). Certificate
verification is mandatory and uses the system CA bundle. Sending authenticates
with AUTH PLAIN inside that TLS connection. STARTTLS and a real secret store
(OS keyring, encrypted file, self-hosted sync) are next.

Writing mail: `c` composes, `r` replies, `Tab` moves between fields, `Ctrl+S`
sends, `Esc` cancels. The first version edits at the end of the active field
(`Ctrl+U` clears it), sends to one recipient, and does not quote the original.

```sh
zig build test       # unit + integration + a real pseudo-terminal session
zig build coverage   # kcov, fails below 100% line coverage
zig build fmt        # zig fmt
```

Requires Zig 0.17.0. The coverage step pulls `kcov` from `nix-shell` (a
development tool, not a dependency).

## What it is today

- A complete TUI over a local cache: mailbox tabs, unread counts, message list,
  reader, compose/reply, live search, help overlay, status line, mouse support.
- Vim keys **and** arrows/Home/PageUp **and** the mouse. Nothing is
  keyboard-only or mouse-only.
- The demo account is seeded relative to the clock, so it looks alive on first
  run. It is entirely offline.
- `core/` holds the domain and the application state machine and performs no
  I/O at all. `tui/` is one adapter on top of it. A GUI can be a second adapter.

Live IMAP works: TLS transport with mandatory certificate verification, the
protocol layer (framing with literals, commands, responses with ENVELOPE),
the client loop, the `Mail` adapter, config parsing, and `--live`. The protocol
and adapter are tested against a scripted server; the TLS transport is verified
against a real IMAP server (a refused login is the expected end-to-end result
for a bogus password). STARTTLS and a real secret store are next.

## Why this shape

- **Hexagonal, with one direction of dependency.** `core/` never imports
  `tui/`. The TUI translates bytes into `core.command.Command` and executes the
  `core.effect.Effect` values that come back. All behaviour lives in
  `core/app/update.zig`, so a future GUI cannot drift from the TUI.
- **Bounded everything.** Subjects, addresses, bodies, and the cache have
  fixed capacities. Mail from strangers is truncated at a UTF-8 boundary, never
  trusted to size an allocation.
- **Safe by default.** Control characters are neutralized on ingress, so a
  subject cannot emit a terminal escape. Plaintext transport is rejected unless
  explicitly allowed. Secrets zero on drop and print as `<redacted>`.
- **Tiger style.** snake_case functions, explicit integer widths, assertions for
  programmer errors, one screen per function, and 100% line coverage gated in
  CI (`docs/TIGER_STYLE.md`).

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers, ports, effects, and
  the coverage boundary.
- [`docs/UX.md`](docs/UX.md) — the interface, key map, and mouse behaviour.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model and the privacy rules
  the code enforces.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — IMAP/SMTP, compose, self-hosted
  credential storage, GUI.
- [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) — the style guide we follow.

## Status

Early, honest, and tested: the vertical slice works end to end offline. Live
accounts, composing, and a self-hosted credential backend are designed for but
not built yet.
