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
```

`Ctrl+Q` (or `Ctrl+C`) quits. `?` shows every key.

```sh
zig build test       # unit + integration + a real pseudo-terminal session
zig build coverage   # kcov, fails below 100% line coverage
zig build fmt        # zig fmt
```

Requires Zig 0.17.0. The coverage step pulls `kcov` from `nix-shell` (a
development tool, not a dependency).

## What it is today

- A complete TUI over a local cache: mailbox tabs, unread counts, message list,
  reader, live search, help overlay, status line, mouse support.
- Vim keys **and** arrows/Home/PageUp **and** the mouse. Nothing is
  keyboard-only or mouse-only.
- The demo account is seeded relative to the clock, so it looks alive on first
  run. It is entirely offline.
- `core/` holds the domain and the application state machine and performs no
  I/O at all. `tui/` is one adapter on top of it. A GUI can be a second adapter.

The real IMAP/SMTP adapter is the next milestone (`docs/ROADMAP.md`). The port
it will implement is already the one the demo implements.

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
