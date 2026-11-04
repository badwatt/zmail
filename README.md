```
██████████████  ████      ████  ██████████████  ██████  ██████
██████████████  ████      ████  ██████████████  ██████  ██████
      ██████    ██████  ██████  ██████  ██████  ██████  ██████
      ██████    ██████  ██████  ██████  ██████  ██████  ██████
    ██████      ████  ██  ████  ██████████████  ██████  ██████
    ██████      ████  ██  ████  ██████████████  ██████  ██████
  ██████        ████      ████  ██████  ██████  ██████  ██████
  ██████        ████      ████  ██████  ██████  ██████  ██████
██████████████  ████      ████  ██████  ██████  ██████  ████████████
██████████████  ████      ████  ██████  ██████  ██████  ████████████
```

**Mail at the speed of a keystroke.**

[![ci](https://github.com/badwatt/zmail/actions/workflows/ci.yml/badge.svg)](https://github.com/badwatt/zmail/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![coverage](https://img.shields.io/badge/coverage-100%25-brightgreen.svg)](docs/ARCHITECTURE.md)

A calm terminal mail client, written in Zig, for people who already live in a terminal.
Nothing you ask of it waits for the network: the cache answers first and the socket
catches up.

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
 j/k move  ·  Enter open  ·  / search  ·  c compose  ·  r reply  ·  d archive  ·  ? help
```

## Highlights

- **Instant, then honest about the wait.** Mail you already had comes from disk; the
  first frame opens no socket. Bodies load on a worker, so the reader is on screen in
  the same tick you press `Enter` — with a spinner in the footer and the terminal's own
  progress bar (`OSC 9;4`) running while it lands.
- **One connection at a time, and never in your way.** A refresh does not stop the
  keys: the effects that need the socket wait in a line instead of blocking the loop.
- **Reads HTML itself.** `core/html.zig` turns a message into text with headings,
  lists and links — no browser, no Electron, no external program.
- **Pictures and details.** `i` shows the images a message carries or points at
  (fetched with `curl`, off the loop, composited over your own background); `\` opens
  every header: To, Cc, Reply-To, Date, Message-ID.
- **A colour, not a palette.** zmail asks the terminal what it paints behind the text
  and derives the rest in OKLCH, so "a shade lighter" is arithmetic and contrast can be
  computed rather than hoped for.
- **Safe by default.** Mail is attacker-controlled text: control characters are
  neutralised on ingress, every buffer is bounded, secrets zero on drop and print as
  `<redacted>`, and only implicit TLS is accepted.
- **Keyboard, arrows, and the mouse.** Nothing is keyboard-only or mouse-only.
- **One static binary.** Linux (musl, static) and macOS, x86_64 and aarch64.

> [!IMPORTANT]
> `Ctrl+C` is the only way out — it is a signal, so it works even inside a socket read.
> `Esc` and `q` go back one layer and at the top they do nothing.

## Run it

```sh
zig build run     # live: the config, or the setup assistant on first run
zmail --demo      # the built-in demo inbox: no account, no network
```

Prebuilt binaries for all four targets are in [Releases](https://github.com/badwatt/zmail/releases).

Requires **Zig 0.17.0**. The first run with no config starts an assistant that asks for
the address, derives the servers, collects the password and writes both files `0600`.

## Configure

`~/.config/zmail/config`, or `--config PATH`. Several accounts, one unified inbox:

```ini
[account work]
address       = alice@example.com
username      = alice
imap_host     = imap.example.com
imap_port     = 993
imap_security = tls

# Optional. Without SMTP, reading works and compose says it cannot send.
smtp_host     = smtp.example.com
smtp_port     = 465
smtp_security = tls
```

The password is never in the config. It lives in `~/.config/zmail/credentials/<label>`,
sealed with XChaCha20-Poly1305; `ZMAIL_PASSWORD` overrides it for a single-account
config, and a password manager can be named instead:

```ini
password_command = pass show mail/work
```

The command runs as an argv list — never through a shell — every start, and its first
line is used. `pass` rotating a password needs no action here.

> [!NOTE]
> `NO_COLOR` or `TERM=dumb` drops colour and keeps everything else. `ZMAIL_NO_MOTION`
> keeps the first screen still. Both are read once at start.

### OAuth2

Providers that no longer accept passwords need OAuth2. Mark the account in the form
(`Sign in` → `oauth`) or add the keys by hand:

```ini
oauth_client_id = <your app registration's client id>
oauth_tenant    = common      # Microsoft only: common | consumers | organizations | <tenant>
```

Then `zmail --oauth`, or `o` on the account in the `A` overlay: the browser opens, zmail
listens on `http://127.0.0.1:8123/` and reads the code when the provider redirects back.
The token is sealed in `~/.config/zmail/tokens/<label>` and refreshed in the background.

For Microsoft the app registration must be a public client that allows personal accounts
(or the tenant of the mailbox) and list `http://127.0.0.1:8123/` as a redirect URI.

> [!WARNING]
> Only implicit TLS is supported today (IMAP 993, SMTP 465), with mandatory certificate
> verification against the system CA bundle. STARTTLS is next.

### Sending from a script

```sh
zmail send --to alice@example.com --subject "Deploy finished" --body "42 tests, green"
git format-patch -1 --stdout | zmail send --to devs@example.com --subject "patch" --body - --from work
```

No terminal, no cache: it loads the config, gets the password, hands the message to SMTP
and exits. **0 means the server took it, 1 means it did not**, so a script can tell "sent"
from "quietly did nothing". `--body -` reads standard input; `--from` picks an account by
label or address.

## Keys

The card behind `?` is the whole map, per screen. The short version:

| | |
|---|---|
| `j` `k` `g` `G`, arrows | move, first, last |
| `Enter` `l` | open the message |
| `/` | search the list |
| `c` / `r` | compose / reply |
| `u` / `s` | read or unread / star |
| `d` / `#` | archive / move to Trash |
| `H` `i` `\` | HTML view, pictures, every header |
| `Tab` `1`–`6` | mailbox |
| `a` / `A` | next account / accounts overlay |
| `Ctrl+R` | refresh from the server |
| `Ctrl+C` | quit |

Full table, including the mouse: [`docs/UX.md`](docs/UX.md).

## Why this shape

- **Hexagonal, with one direction of dependency.** `core/` never imports `tui/` and
  performs no I/O. The terminal translates bytes into commands and executes the effects
  that come back; all behaviour lives in `core/app/update.zig`, so a future GUI cannot
  drift from the TUI.
- **Bounded everything.** Subjects, addresses, bodies and the cache have fixed capacities.
  A message larger than the limit is truncated at a UTF-8 boundary, never trusted to size
  an allocation.
- **Tested where it matters.** The whole suite runs on a real pseudo-terminal, the IMAP
  adapter against a scripted server, and line coverage is gated at **100%**.
- **Tiger style.** snake_case, explicit integer widths, assertions for programmer errors,
  functions under seventy lines, comments that explain why
  ([`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md)).

## Develop

```sh
zig build test       # unit, integration, and a real pseudo-terminal session
zig build coverage   # kcov, fails below 100% line coverage
zig build fmt        # zig fmt
zig build docs:check # the manifest is the only place the name and version live
```

The coverage step uses `kcov` from `PATH` when it is installed, and falls back to
`nix-shell` when it is not — a development tool, not a dependency.

## Documentation

| | |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | layers, ports, effects, and the coverage boundary |
| [`docs/UX.md`](docs/UX.md) | the interface, every key, and the mouse |
| [`docs/SECURITY.md`](docs/SECURITY.md) | threat model and the privacy rules the code enforces |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | what is next: STARTTLS, a real secret store, a GUI adapter |

## Releasing

The version in [`build.zig.zon`](build.zig.zon) *is* the release: bump `.version`, push to
`main`, and the workflow tags it, cross-compiles the four targets and publishes them with
`SHA256SUMS` and notes grouped by commit prefix. A tag that already exists stops it there,
and a failed run can be retried with **Run workflow** without touching the version.

## Status

Early, honest and tested: the vertical slice works end to end. Live IMAP and SMTP are
there; replies quote the original below the draft, and the demo can send a message without
an account.

Known limits, stated rather than discovered: the composer edits at the end of the active
field, sending goes to one recipient, and STARTTLS, a self-hosted credential backend and a
GUI adapter are designed for and not built yet.
