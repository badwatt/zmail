# The interface

Design rules, in priority order:

1. **Nothing to learn before the first minute.** `amail` opens a real, populated
   inbox with no account and no setup. The hint bar always shows the keys that
   apply right now.
2. **One screen, one job.** List, reader, help. No panes fighting for space, no
   modes hidden behind a colon.
3. **Vim when you want it, arrows when you don't.** Every vim binding has an
   obvious non-vim twin.
4. **Quiet until it matters.** Default terminal background, one accent color,
   bold for unread, dim for metadata. Emphasis comes from weight and spacing,
   not from a rainbow.

## Layout

```
row 0            header: app name + mailbox tabs + unread counts
row 1            rule
rows 2..h-3      list rows (or the reader body)
row h-3          rule
row h-2          breathing room
row h-1          footer: contextual hints (left) + position (right)
```

The reader uses the full screen: subject on row 0, metadata on row 1, a rule on
row 2, body from row 3, its own rule and footer at the bottom.

Below 40 columns or 10 rows the client says so instead of drawing garbage. Below
76 columns the tabs collapse to the active mailbox plus its unread count; `Tab`
still switches.

### List rows

```
 ● Alice Rivera         Re: design tokens review                            1m
   GitHub               [amail] TUI skeleton merged (#42)                   2h
 ● Ana Torres           Invoice for October                                 1d ★
```

The unread count belongs to its own tab: it sits one space after the title
(`Inbox 3`), left-aligned in a reserved three-cell area, so it can never be
mistaken for the next mailbox's badge. The active tab is underlined.

- `●` unread (accent), nothing when read.
- Sender: normal when unread, dim when read. Truncated with an ellipsis.
- Subject: bold when unread, normal when read.
- Relative date, right-aligned: `now`, `14m`, `5h`, `3d`, then `10/22`.
- `★` flagged (amber), rightmost column.
- Selected row: a subtle background across the whole width, not reverse video
  (which screams). In `NO_COLOR` mode it becomes reverse video, because there is
  no background to tint.

### Footer

Hints are two-tone: the key in the accent color, the action dim. They are
contextual, not a static manual:

- list: `j/k move · Enter open · c compose · r reply · / search · ? help`
- reader: `j/k scroll · Space page · q back · u unread · d archive`
- search: `type filter · Enter apply · Esc cancel`
- help: `any key close help`

The right side shows `2/7` in the list or `75%` in the reader. A status message
(“Archived”, “Marked unread”, or an alert in red) temporarily replaces the hints
and disappears on the next action.

## Keys

| Key | Action |
|-----|--------|
| `j` `↓` | move down / scroll down |
| `k` `↑` | move up / scroll up |
| `g` `Home` | first row |
| `G` `End` | last row |
| `Ctrl+D` / `Ctrl+U` | half page down / up |
| `Ctrl+F` / `Ctrl+B`, `PageDown` / `PageUp` | page down / up |
| `Enter` `l` `o` `→` | open the selected message |
| `q` | quit from the list, back from the reader, type `q` in a field |
| `h` `Esc` `←` | back one layer; never quits |
| `u` | toggle read / unread |
| `s` `*` | star / unstar |
| `d` | archive |
| `#` `Delete` | move to trash |
| `/` | search (live filter over sender and subject) |
| `Tab` `]` | next mailbox |
| `Shift+Tab` `[` | previous mailbox |
| `1`–`6` | jump to Inbox, Sent, Drafts, Archive, Trash, Junk |
| `R` | refresh from the server |
| `?` | help (`/` filters the key list) |
| `c` | compose a new message |
| `r` | reply to the selected message |
| `a` | cycle account scope: all → account 1 → … → all |
| `Ctrl+Q` `Ctrl+C` | quit. The top level never closes on `Esc`, `q`, or `h` |

Search is live: typing filters as you go, `Enter` keeps the filter, `Esc`
cancels it. `↑`/`↓` still move the cursor while typing. Inside the help overlay,
`/` starts the same kind of filter over the key map itself; `Enter` keeps it and
`Esc` clears it.

`Esc` is never a quit key. The only ways out are `q` from the list (never from a
text field) and `Ctrl+Q` / `Ctrl+C` from anywhere.

## First run

`amail` with no config opens the setup assistant, one field per screen:

```
 amail setup                                                     step 2/8
────────────────────────────────────────────────────────────────────────
 IMAP server
 imap.example.com▏
 Where mail is read from; TLS is required

 Enter next  ·  Esc back  ·  Ctrl+U clear  ·  Ctrl+Q quit
```

It asks for the address, the IMAP server and port (prefilled `imap.<domain>`
and `993`), the SMTP server and port (`smtp.<domain>` / `465`, leave the host
empty to skip sending), the username (prefilled from the address), and the
password (masked, never echoed). The last screen shows the config that will be
written, the path, and where the password goes. `Enter` saves, `Esc` goes back,
`Ctrl+Q` cancels without writing anything.

## Writing mail

`c` (or `r`) opens a full-screen composer:

```
 To       alice@example.com▏
 Subject  Re: design tokens
────────────────────────────────────────────────────────
 Looks good to me.
 See you Monday.
────────────────────────────────────────────────────────
 Tab next field  ·  Ctrl+S send  ·  Ctrl+U clear field  ·  Esc cancel
```

| Key | Action |
|-----|--------|
| any character | type into the active field |
| `Enter` | newline in the body; next field in the headers |
| `Tab` / `Shift+Tab` | next / previous field |
| `Backspace` | delete the last character of the active field |
| `Ctrl+U` | clear the active field |
| `Ctrl+S` | send (validates the recipient first) |
| `Esc` | cancel the draft |

With more than one account the list is unified by default: each row starts with
its account initial (`P`, `W`), and the header shows the current scope on wide
terminals. `a` narrows it to one account; the same key returns to all. The
composer shows the sending account on a `From` line, chosen from the account
scope (or from the message being replied to).

A reply prefills the recipient and `Re: <subject>` and starts in the body. The
draft survives a failed send. Non-ASCII text is sent as UTF-8; a subject with
non-ASCII characters will need MIME encoding in a later version.

Empty fields show a dim hint (`someone@example.com`, `(no subject)`, `Write your
message.`), and the cursor sits in the first free cell. In demo mode, sending
appends the message to Sent and the status line says so: `Message sent · 2 opens
Sent`.

## Mouse

Mouse reporting is enabled at startup (`1000` + SGR `1006`).

- Click a mailbox tab to switch.
- Click a row to select it; click it again to open it. Two clicks, no
  double-click timer: the first click is the confirmation, which is what avoids
  the “did I open the wrong message?” feeling.
- Wheel scrolls the list and the reader.
- Releases and non-left buttons are ignored.

## States

| State | What the user sees |
|-------|--------------------|
| Empty mailbox | “Nothing in Junk” + “Press ? for keys”, centered |
| Empty search | `No matches for "invoice"` |
| Body still loading | dim “Loading...” in the body area |
| Message vanished | “Message unavailable” in the alert color |
| Server error | the status line turns into an alert; the cache is kept |
| Terminal too small | “Terminal too small” + the required size |
| Help | a centered card over the current view, any key closes it |

## Color

Default background; one accent (xterm 74, muted blue); amber for stars; a dim
gray for metadata; the terminal's own foreground for body text. `NO_COLOR` (or
`TERM=dumb`) switches to attributes only — bold, dim, reverse — and the layout
is unchanged.

## Non-goals for now

No colon command line, no tabs-within-tabs, no threading view, no HTML
rendering. Each of those adds a mode or a pane, and the next milestone is live
mail, not more surface area.
