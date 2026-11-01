# Roadmap

Ordered by what a user needs next, not by what is fun to build. Every milestone
keeps the same rules: the core stays I/O-free, every behaviour is a test, and
the coverage gate stays at 100%.

## M1 — the vertical slice (done)

- Domain, ports, application state machine, and the TUI, in separate trees.
- Demo account, list/reader/help, live search, vim + arrows + mouse.
- 100% line coverage, including the POSIX adapter driven against a real pty and
  an end-to-end session on the real binary.

## M2 — live mail (IMAP)

The port exists; this milestone fills it in.

- **Protocol codec, pure and tested (done: M2.1).** `core/src/protocol/imap/`:
  a tokenizer (atoms, quoted strings, literals), commands rendered into bounded
  buffers with quoting and tag validation, and response parsing for tagged
  status, `EXISTS`/`RECENT`/`EXPUNGE`, capabilities, and `FETCH` attributes
  (`UID`, `FLAGS`, `RFC822.SIZE`, `INTERNALDATE`). 100% line coverage, no
  sockets involved. `ENVELOPE` parsing lands with the adapter.
- **Framing and client (done: M2.2).** `framing.zig` understands literals, so a
  body with CRLF is one response; `client.zig` sends a command, pumps untagged
  responses, and turns the tagged one into a result or an error. Timeouts are
  bounded (100 × 100 ms), and the command buffer is capped.
- **The adapter (done: M2.2).** `adapters/imap_mail.zig` implements
  `ports/mail.Mail` on top of the client, selecting a mailbox once and mapping
  every protocol error onto `Unavailable` / `NotFound` / `Rejected`.
- **TLS transport (done: M2.3).** `net/src/tls.zig` implements the `Transport`
  port over a socket and `std.crypto.tls.Client`, with the system CA bundle and
  hostname verification. Reads poll first and drain buffered records so a
  greeting that arrives with the handshake is not lost.
- **Account setup (done: M2.3, first run in M3.2).** A strict `key = value`
  config parsed in `core/config.zig` (unknown keys and passwords are refused),
  `--live` and `--config` in the CLI. If the config is missing, a setup
  assistant asks for the account fields, validates them with the same parser,
  and writes the config plus a `0600` credential file next to it.
- **STARTTLS (next).** Upgrade a plaintext connection on 143/587 with the same
  verification. Today only implicit TLS is accepted.
- **SecretStore (next).** OS keyring, then an encrypted file, then the
  self-hosted sync backend. This replaces the plaintext `0600` credential file
  that setup writes today; `AMAIL_PASSWORD` stays as an override.
- **IDLE** for new mail, and flag sync back to the server after a local change.
- **TLS adapter.** `std.crypto.tls.Client` with certificate verification
  mandatory. STARTTLS upgrade. A bounded, line-oriented transport with
  timeouts.
- **IDLE** for new mail (or polling every N seconds first; IDLE second).
- The adapter maps server errors onto the port's `Unavailable` / `NotFound` /
  `Rejected` so the application code does not change.

## M3 — writing mail (done: M3.1, next: M3.2)

- **SMTP over TLS (done).** `core/src/protocol/smtp/`: reply parsing, commands,
  AUTH PLAIN, a streaming client with CRLF normalization and dot-stuffing, and
  `adapters/smtp_outbox.zig` behind the `Outbox` port. The demo has a memory
  outbox that appends to Sent.
- **Compose and reply (done).** Full-screen composer with three fields, UTF-8
  body, validation, `Ctrl+S` to send, a draft that survives a failed send, and
  `r` prefilling recipient and subject. Demo mode sends into Sent.
- **Multi-account and cache (done).** `[account <label>]` sections, one
  credential file per account, a unified list with an `a` scope switch, and a
  TSV envelope cache under `~/.cache/amail`. Switching to a loaded mailbox no
  longer refetches it, and startup reads the cache before the network.
- **Real mail bodies (done).** `core/src/mime.zig` decodes encoded-word
  subjects and names, base64 and quoted-printable, the common charsets, and
  multipart trees (plain first, HTML stripped as a fallback). Bodies are
  fetched with `BODY.PEEK[]` from the message's own mailbox, so reading Sent
  works and a cached start still opens messages.
- **Lazy connections (next).** The launcher still logs in before the UI opens,
  so a dead server delays startup. Sources should connect on demand and show
  cached mail immediately.
- **Big messages (next).** A response is bounded at 128 KiB, so a message with
  a large attachment is truncated or refused. Streaming a literal straight into
  the body buffer would remove the bound without an allocation.
- **M3.2 next.** Quote the original in replies; `Cc`/`Bcc` and multiple
  recipients; RFC 2047 encoding for non-ASCII subjects; drafts persisted in the
  Drafts mailbox; reply-all and forward; threading by `Message-ID`.
- **Later.** STARTTLS for 587, `8BITMIME`/`SIZE` negotiation, a local queue that
  survives a dropped network.

## M4 — self-hosted credentials

- `SecretStore` port plus three adapters: OS keyring, `age`-encrypted file, and
  a sync service.
- Sync service: separate repository and binary. Client-side encryption only
  (Argon2id-derived key or device key in the keyring); the server stores opaque
  blobs. TLS with certificate pinning.
- Multi-account: the `Account`/`Server` types already exist; the state machine
  gains an account switcher and per-account caches.

## M5 — a GUI

- The same `core/` behind a second adapter. The renderer is already a pure
  function from state to a cell buffer; the GUI replaces the buffer with its own
  widget or canvas tree.
- Input is already semantic (`Command`), so the GUI only has to map its events.
- No behaviour is duplicated: if the GUI needs a new rule, it goes in
  `core/app/update.zig` and the TUI gets it too.

## Later, if they earn their place

- HTML mail → text conversion (never rendering; extraction only).
- PGP/inline signature display, not composition.
- Sieve/filters.
- A command palette for people who like `:` more than `?`.
- Wide-glyph (CJK, emoji) width tables for the cell buffer.

## Explicit non-goals

- A built-in browser, HTML engine, or JavaScript runtime.
- Auto-loading remote content.
- Cloud accounts, telemetry, or “sign in with” anything.
- Storing plaintext credentials anywhere, ever.
