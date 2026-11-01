# Security and privacy

Mail is the most hostile text most people read every day. The threat model here
is not “a nation-state wants my inbox”; it is:

- a sender who can put **anything** in a subject, a display name, a body, or a
  header, including ANSI escape sequences and invalid UTF-8;
- a server that can lie about sizes, counts, and dates;
- an attacker with local access who can read process memory, logs, or config;
- a network attacker on the path to the mail server.

Rules are enforced in code, with tests, not in documentation alone.

## Implemented now

### Mail content can never reach the terminal raw

Every text ingress goes through `core/src/domain/text.zig`:

- C0 controls (`0x00`–`0x1f`), DEL, and C1 controls (`U+0080`–`U+009F`, which
  some terminals interpret as CSI) are replaced with a space;
- invalid UTF-8 bytes become `?`, one byte at a time, so no partial sequence
  reaches a cell;
- truncation happens at a UTF-8 boundary, never mid-codepoint.

Sanitization happens **on ingress**, so no later code path can accidentally
print a raw control byte by forgetting to sanitize on render. Address display
names, subjects, snippets, and bodies all pass through it.

Tests assert that `"\x1b[2J"` becomes `" [2J"` and that `U+009B` is neutralized.

### Bounded, allocated-once memory

The cache (4096 messages), the body buffer (64 KiB), subjects (160 bytes),
address parts, the query, and the status line all have fixed capacities.
Allocation happens at startup; the render loop allocates nothing. A malicious
server cannot make the client allocate unbounded memory, and eviction zeroes the
vacated slots so deleted mail does not linger in process memory.

### Secrets

`domain/secret.zig` provides a fixed-capacity secret that:

- is initialized **in place** (`init(bytes, &secret)`), so no copy of the plain
  bytes is made on the stack;
- zeroes its whole buffer on `deinit`;
- prints as `<redacted>` through `format`, so a stray `{f}` in a log line cannot
  leak it.

### Transport policy

`domain/account.zig` refuses `plain` transport unless the caller explicitly
opts in with `Policy{ .allow_plaintext = true }`. Implicit TLS (`tls`) and
`starttls` are the only defaults. This is the policy the IMAP/SMTP adapter will
enforce; it is unit-tested today.

### No shell, no hidden I/O

External commands, when they exist, run as argv lists, never through a shell.
The domain has no syscalls at all. The only file in the TUI that touches the OS
is `os.zig`, and it only reads stdin, writes stdout, queries the window size, and
sets termios.

### No telemetry, no network by default

The demo account is entirely local. The client makes no network request in this
milestone. There is no analytics, no update check, and no crash reporting.

### Live connections

- **TLS with mandatory verification.** `net/src/tls.zig` has no insecure mode:
  the system CA bundle validates the chain and the hostname is checked against
  the certificate. Plaintext is refused by config validation unless the user
  writes `allow_plaintext = true` for a local server.
- **The config never contains a password.** The parser refuses a `password`
  key by name, with an actionable error. The setup assistant writes the
  password to a separate `0600` file next to the config (`credential`), and
  `AMAIL_PASSWORD` overrides it. A plaintext file with owner-only permissions is
  a deliberate, temporary tradeoff: it is what makes first-run setup usable
  without a secret service. The OS keyring and an `age`-encrypted file are the
  next adapters behind the same `SecretStore` port; until then, the file is
  guarded by `0600` and never printed, logged, or included in the config.
- **Per-account credentials.** One `0600` file per account label under
  `credentials/`; the config still refuses a `password` key.
- **Everything on disk is sealed.** One key, `~/.cache/amail/key` (32 random
  bytes from the IO's CSPRNG, mode `0600`, created on first use), encrypts the
  envelope cache, the message bodies, and the password file with
  XChaCha20-Poly1305. No sender, subject, snippet, body, or password is written
  in the clear.
- **The key is the trust boundary.** It sits next to the data with mode `0600`:
  that protects against a stray backup, a synced cache directory, and other
  users, not against code running as you. An OS keyring (libsecret, the kernel
  keyring) is the next step.
- **Migration.** An older install's plaintext `credential` and `.tsv` files are
  read once and immediately replaced with sealed copies.
- **Bodies are sealed at rest.** `~/.cache/amail/<label>/bodies/<mailbox>/<uid>.bin`
  is `nonce || XChaCha20-Poly1305 ciphertext || tag`, keyed with
  `~/.cache/amail/key` (32 random bytes, `0600`, created on first use; the key
  uses the IO's CSPRNG). No body text is ever written in the clear, so a stray
  backup or a synced cache directory does not leak prose. A tampered or
  truncated file fails authentication and is treated as a cache miss.
- **SMTP AUTH PLAIN only inside TLS.** The credentials are base64-encoded in the
  command (as SMTP requires) and only sent after the TLS handshake. Plaintext
  SMTP follows the same `allow_plaintext` rule as IMAP. The encoded payload is
  never logged.
- **Bounded protocol.** Commands have a fixed maximum size and are refused
  rather than truncated; responses have a fixed frame budget; timeouts bound
  every wait.

## Planned (with the IMAP/SMTP work)

These are designed for but not built yet; they are not claimed as done.

- **TLS verification is mandatory.** Certificate validation on by default, with
  an explicit, loud opt-out for a self-signed local server. No “accept anything”
  fallback.
- **Credentials leave the environment.** The `SecretStore` port will have three
  adapters: OS keyring, an `age`/`sops`-encrypted file with `0600` permissions,
  and the self-hosted backend below. `AMAIL_PASSWORD` is the temporary bridge;
  it is never logged, echoed, or written to the config.
- **OAuth2/XOAUTH2 for providers that require it**, with tokens stored like
  passwords, refreshed in memory, and never written to logs.
- **HTML mail is rendered as text.** No HTML engine in the client. Links are
  shown as `text <url>`; opening one requires an explicit action.
- **Remote content is never fetched.** No tracking pixels, no remote images, no
  auto-loading of anything.
- **Attachment handling is display-only**: name, type, size. Nothing is executed
  or opened automatically.
- **Header rendering shows the truth**: the envelope sender and the
  `From:` header are shown separately, so a spoofed display name is visible.
  Authentication results (SPF/DKIM/DMARC) will be summarized in the reader.
- **Logging policy**: no message bodies, no subjects, no addresses, no
  credentials. If a debug log is ever added it will be opt-in and off by
  default.

## Self-hosted credential storage

The goal: users should be able to keep their account credentials on their own
server, not in a third party's database and not in plain files on their laptop.

The shape that follows from the current design:

- A `SecretStore` port in `core/` (load, save, delete), exactly like the mail
  port. The application never knows where the secret came from.
- A small sync service (separate binary, separate repository) that stores
  **client-side encrypted** blobs: the server never sees a password or a key.
  The client encrypts with a key derived from a passphrase (Argon2id) or with a
  device key held in the OS keyring.
- Transport is TLS with certificate pinning for the self-hosted endpoint, and
  the server is stateless apart from encrypted blobs.
- Offline-first: the local adapter (keyring or encrypted file) is always the
  source for the active session; the backend is for syncing across devices.

That keeps the hexagon intact: the backend is an adapter behind a port, not a
new dependency of the core.

## Reporting

This is a personal project in early development. Until there is a release, treat
the demo as a demo and do not point it at an account you cannot afford to lose.
