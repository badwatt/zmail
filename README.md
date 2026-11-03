# zmail

[![ci](https://github.com/badwatt/zmail/actions/workflows/ci.yml/badge.svg)](https://github.com/badwatt/zmail/actions/workflows/ci.yml)

A calm terminal mail client, written in Zig.

```
 zmail  Inbox    3 Sent       Drafts     Archive    Trash      Junk
────────────────────────────────────────────────────────────────────────────
 ● Alice Rivera         Re: design tokens review                            1m
 ● Bob Chen             Zig 0.17 release notes                             14m ★
   GitHub               [zmail] TUI skeleton merged (#42)                   2h
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
zig build run        # live by default: the config, or the setup assistant
zmail --demo         # the built-in demo inbox: no account, no network
```

Once the cache is warm, startup opens no socket: the first frame is the mail you
already had, and `Ctrl+R` pulls from the server in the background (a spinner
sits where the position is). `A` opens the accounts overlay (pick a scope, add, remove);
the list is unified by default, with every row labelled and coloured by account,
and `a` narrows it to one.

`q` quits from the list, `Ctrl+Q`/`Ctrl+C` quit from anywhere, and `?` shows
every key (`/` inside the help filters it).

### Live mode

The first `zmail` with no config starts a setup assistant: it asks for the
address, derives the IMAP/SMTP servers, collects the password, and writes
`~/.config/zmail/config` plus `~/.config/zmail/credentials/<label>`, both
`0600`. Later runs read both; `ZMAIL_PASSWORD` overrides the file for a
single-account config.

`~/.config/zmail/config` (or `--config PATH`) supports several accounts, shown
in one unified inbox:

```ini
[account work]
address     = alice@example.com
username    = alice
imap_host   = imap.example.com
imap_port   = 993
imap_security = tls

# Optional. Without SMTP, reading works and compose reports it cannot send.
smtp_host   = smtp.example.com
smtp_port   = 465
smtp_security = tls

[account personal]
address     = alice@home.example
username    = alice
imap_host   = imap.home.example
imap_port   = 993
imap_security = tls
```

A file with no sections is one account labelled `account`, so older configs
keep working. Press `a` to cycle the scope (all accounts → one → next → all);
the list is unified by default and each row carries its account initial.

The password is **never** in the config. It lives in
`credentials/<label>` (mode `0600`), and `ZMAIL_PASSWORD` overrides it when
there is only one account.

If a password manager already holds it, name the command instead and zmail asks
it every start:

```ini
[account work]
address          = alice@example.com
username         = alice
imap_host        = imap.example.com
imap_port        = 993
imap_security    = tls
# Runs as an argv list, never through a shell. One line of output, no caching.
password_command = pass show mail/work
```

The command runs as argv (split on spaces, no quoting, `sh` is never
involved), its first line of output is used and nothing is written to disk, so
`pass` rotating a password needs no action here. It wins over both
`ZMAIL_PASSWORD` and the sealed file, because an account that names a command
has said where its password lives.

### OAuth2 (Microsoft and Google)

Providers that no longer accept passwords need OAuth2. Mark the account in the
form (`Sign in` → `oauth`) or add two keys by hand:

```ini
oauth_client_id = <your app registration's client id>
oauth_tenant   = common      # Microsoft only: common | consumers | organizations | <tenant id>
```

Then `zmail --oauth`, or `o` on the account in the `A` overlay. The flow opens
the browser, listens on `http://127.0.0.1:8123/` and reads the code when the
provider redirects back; there is nothing to paste unless the port cannot be
bound, and no QR unless `qrencode` is installed. The token is sealed in
`~/.config/zmail/tokens/<label>` and refreshed in the background when it
expires, so a password is never asked for again.

For Microsoft the app registration must allow personal accounts (or the tenant
matching the account), be a public client, and list `http://127.0.0.1:8123/` as
a redirect URI; otherwise Azure answers `unauthorized_client`, which zmail now
prints verbatim.

Only implicit TLS is supported today (IMAP 993, SMTP 465). Certificate
verification is mandatory and uses the system CA bundle. Sending authenticates
with AUTH PLAIN inside that TLS connection. STARTTLS and a real secret store
(OS keyring, encrypted file, self-hosted sync) are next.

Writing mail: `c` composes, `r` replies, `Tab` moves between fields, `Ctrl+S`
sends after a five-second countdown that `Esc` stops, `Ctrl+E` hands the body to
`$EDITOR` and takes it back, `Esc` cancels. The first version edits at the end of the active field
(`Ctrl+U` clears it) and sends to one recipient. A reply written from the
reader quotes the original below the draft, attribution line included; a
subject with non-ASCII characters leaves as an RFC 2047 encoded word.

In the demo, sending is real end to end: the message is appended to Sent and the
status line says `Message sent · 2 opens Sent`. No account needed.

```sh
zig build test       # unit + integration + a real pseudo-terminal session
zig build coverage   # kcov, fails below 100% line coverage
zig build fmt        # zig fmt
```

Requires Zig 0.17.0. The coverage step uses `kcov` from `PATH` when it is
installed and falls back to `nix-shell` when it is not (a development tool, not a
dependency).

## What it is today

- A complete TUI over a local cache: mailbox tabs, unread counts, message list,
  reader, compose/reply, live search, help overlay, status line, mouse support.
- Vim keys **and** arrows/Home/PageUp **and** the mouse. Nothing is
  keyboard-only or mouse-only.
- The demo account is seeded relative to the clock, so it looks alive on first
  run. It is entirely offline.
- `core/` holds the domain and the application state machine and performs no
  I/O at all. `tui/` is one adapter on top of it. A GUI can be a second adapter.

Messages are rendered as text, not raw MIME: `core/src/mime.zig` decodes
encoded-word subjects and names, base64 and quoted-printable bodies, the common
charsets (UTF-8, ISO-8859-1, Windows-1252), and walks multipart trees (prefers
`text/plain`, falls back to stripped HTML). Every buffer is bounded; a message
larger than 128 KiB is truncated rather than refused.

Live IMAP works: TLS transport with mandatory certificate verification, the
protocol layer (framing with literals, commands, responses with ENVELOPE),
the client loop, the `Mail` adapter, multi-account config, and the setup
assistant. Envelopes are cached under `~/.cache/zmail`, so a restart and a
mailbox switch do not wait for the network; `Ctrl+R` refreshes on demand, and
message bodies are cached too (sealed with XChaCha20-Poly1305), so reading a
message you have already opened never touches a socket. The protocol
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

## Releasing

The version in [`build.zig.zon`](build.zig.zon) is the release: bumping it is the
only thing that can cut one.

1. Bump `.version` in `build.zig.zon` and commit it.
2. Push to `main`. The `release` workflow starts because the manifest changed,
   tags that version (a tag that already exists stops it there), builds
   `ReleaseSafe` binaries for x86_64 and aarch64 Linux, and publishes them with
   `SHA256SUMS` and a changelog grouped by commit prefix.

Pushing code without touching the manifest runs the CI and nothing else. A
release that failed halfway can be retried with **Run workflow**
(`workflow_dispatch`) without changing the version again.

## CI

`ci` runs on every push to `main` and every pull request: formatting,
`docs:check` (the manifest is the only place the name, version and toolchain
live), the whole test suite including the end-to-end PTY test, and a
`ReleaseSafe` build. Line coverage is reported as a second job.

`release` only starts when `build.zig.zon` changes; see [Releasing](#releasing).

CodeQL is not here on purpose: the repository is private without code scanning
enabled, and Zig is not one of its languages — it would only ever read the
workflows themselves.

## Status

Early, honest, and tested: the vertical slice works end to end offline. Live
accounts, composing, and a self-hosted credential backend are designed for but
not built yet.
