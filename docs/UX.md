# The interface

Design rules, in priority order:

1. **Nothing to learn before the first minute.** `zmail` opens a real, populated
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
   GitHub               [zmail] TUI skeleton merged (#42)                   2h
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
| `Ctrl+R` | refresh from the server |
| `?` | help: every key, grouped by where it works (`j`/`k` scrolls it, `/` filters it, anything else closes it) |
| `c` | compose a new message |
| `r` | reply to the selected message |
| `a` | cycle account scope: all → account 1 → … → all |
| `X` | delete the selected message for good (Trash only) |
| `E`, `E` | empty Trash (asks once) |
| `Ctrl+N` / `Ctrl+P` | down / up, for terminals without arrow keys |
| `Space` | a page in the list and the reader |
| `H` | in the reader: HTML view, or the plain text one. The HTML is read by zmail itself: no browser, no external program |
| `o` | in the reader: the whole mail in a browser |
| `Ctrl+Q` `Ctrl+C` | quit. The top level never closes on `Esc`, `q`, or `h` |

Search is live: typing filters as you go, `Enter` keeps the filter, `Esc`
cancels it. `↑`/`↓` still move the cursor while typing. Inside the help overlay,
`/` starts the same kind of filter over the key map itself; `Enter` keeps it and
`Esc` clears it.

`Esc` is never a quit key. The only ways out are `q` from the list (never from a
text field) and `Ctrl+Q` / `Ctrl+C` from anywhere.

## Opening

With a cache, zmail opens instantly: the first frame is the last known mail,
read from disk, and **no socket is opened**. `Ctrl+R` is what talks to the
server — it pulls the current mailbox for every account, in the background,
while the footer's position turns into a spinner.

The first seconds after start are spent warming the connection in the
background. Opening a message then shows its envelope at once and fills the
body in when the fetch lands; a message you have opened before comes from the
sealed body cache and never touches a socket.

Without a cache (first run, or a new account) the network is unavoidable, so
the first frame is a splash instead of an empty list:

```
                             █████ █   █  ███  ▀ █
                                ██ ██ ██ █   █   █
                               ██  █ █ █ █████ █ █
                              ██   █   █ █   █ █ █
                             █████ █   █  ███  █ █

                             connecting to work
                             alice@example.com

 cached mail opens instantly                                       Ctrl+Q quits
```

The wordmark is drawn, not typed: a terminal cannot set type, and five rows of
one-cell strokes is the closest it gets. Its light moves — a ramp from slate to
lit that crosses the letters once every three seconds — and nothing else on the
screen moves at all. That is the whole animation budget, and it buys the one
thing a cold start needs: a still frame that says "alive" without a spinner,
because the first connection blocks the loop a spinner would have needed, so a
spinner here would freeze mid-turn and read as a hang.

`ZMAIL_NO_MOTION` draws the still frame instead, which is a lit wordmark and not
a blank one; `NO_COLOR` keeps the wave, carried by weight (dim, normal, bold)
because the shape and the weight were always doing the work.

A connection that fails no longer refuses to start: cached mail stays readable
and the failure becomes a status line.

## First run

`zmail` with no config opens the setup assistant, one field per screen:

```
 zmail setup                                                     step 2/8
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
 Tab next field  ·  Ctrl+S send  ·  Ctrl+E edit  ·  Esc cancel
```

| Key | Action |
|-----|--------|
| any character | type into the active field |
| `Enter` | newline in the body; next field in the headers |
| `Tab` / `Shift+Tab` | next / previous field |
| `Backspace` | delete the last character of the active field |
| `Ctrl+U` | clear the active field |
| `Ctrl+E` | write the body in `$EDITOR` and take it back |
| `Ctrl+S` | send, after a five-second countdown (validates the recipient first) |
| `Esc` during the countdown | stop the send and keep the draft |
| `Esc` | cancel the draft |

## Accounts

With more than one account the list is unified by default. Each row starts with
its account label, in that account's own hue, so a glance is enough:

```
 ●home   Alice Rivera       Re: design tokens review                   1m
  work   GitHub            [zmail] TUI skeleton merged (#42)          2h
```

`a` cycles the scope: all accounts → account one → account two → all. On wide
terminals the header names the current scope. The composer shows the sending
account on a `From` line, chosen from the scope (or from the message being
replied to).

Press `A` for the accounts overlay:

```
            ╭─ Accounts ───────────────────────────╮
            │*All accounts                         │
            │ home  me@home.example                │
            │ work  me@work.example                │
            │ Enter select · d remove · n add · Esc│
            ╰──────────────────────────────────────╯
```

`Enter` picks the scope (all accounts, or just one), `d` removes the selected
account (it rewrites the config, deletes its credential, and drops its mail from
the view), and `n` runs the assistant and appends a new one — the new account
connects on the next start. The same can be done outside the TUI with
`zmail --add-account`.

Accounts live in the same file as `[account <label>]` sections, so they can also
be written by hand; the label must be unique.

A reply prefills the recipient and `Re: <subject>` and starts in the body. When
the original is open, it is quoted below the draft as well: an attribution line,
then every line prefixed with `> `. Replying from the list quotes nothing — the
body was never fetched. The draft survives a failed send. Non-ASCII text is sent
as UTF-8, and a non-ASCII subject leaves as an RFC 2047 encoded word.

`Ctrl+S` does not send at once: the message waits five seconds, the status line
says `Sending · Esc stops it`, and `Esc` (or any typing) takes it back, draft
intact. That is long enough to catch the wrong Alice and short enough not to be
in the way.

`Ctrl+E` is the way out of the one-line-at-the-end editor: it writes the body to
a temporary file, runs `$ZMAIL_EDITOR`, `$VISUAL`, `$EDITOR`, or `vi` (as an argv
list, never through a shell) with the terminal handed over, and reads the file
back. What comes back is sanitized and bounded exactly like mail, because a file
on disk is not a keystroke. A message that fails to start the editor says so and
keeps the draft.

Empty fields show a dim hint (`someone@example.com`, `(no subject)`, `Write your
message.`), and the cursor sits in the first free cell. In demo mode, sending
appends the message to Sent and the status line says so: `Message sent · 2 opens
Sent`.

## Mouse

Mouse reporting is enabled at startup (`1000` + any-motion `1003` + SGR `1006`),
because hovering is part of how a link is opened.

- Click a mailbox tab to switch.
- Click a row to select it; click it again to open it. Two clicks, no
  double-click timer: the first click is the confirmation, which is what avoids
  the “did I open the wrong message?” feeling.
- Wheel scrolls the list and the reader.
- Releases and non-left buttons are ignored.
- **Ctrl + click** opens a link; a plain click never opens anything, so a click
  meant for the text cannot launch a browser. Holding Ctrl and moving over a link
  underlines it and shows its address in a box at the bottom of the body. Links
  are drawn in the accent colour, without an underline. The status line says
  "Opening … in the browser" before the browser starts, so the click has an answer.

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

## Reading

`j`/`k` scroll, `Space` pages, `q` goes back. Text is what the reader shows by
default, always. A message that has an HTML part can be read that way with `H`:
paragraphs, lists, quotes and headings keep their shape, and every link is
written out after its text, underlined. Nothing is fetched or executed to draw
it: no browser, no images, no scripts — the HTML is read, not run.

Dragging over the body selects text and copies it: the selection is highlighted
while you drag, and on release the text goes to the clipboard and the primary
selection through OSC 52, so no `xclip` or `wl-copy` is needed. A click without a
drag does nothing, so a click meant for the text never launches a browser.

Links are opened with Ctrl+click, in either view. In the HTML view the words of a
link carry its address, so Ctrl+clicking "read more" goes where "read more" goes,
and Ctrl+hovering it shows the address it points at. Nothing is written after the
words: a paragraph with three links reads like a paragraph, not like a log. A Ctrl+click on a URL hands it to
the browser (`xdg-open`, `gio open`, `sensible-browser`, `open`, or `wslview`,
whichever exists); a Ctrl+click on the words around it does nothing.

The accounts overlay (`A`) lists "All accounts" first and then your accounts by
name, whatever order the config file uses. The choice is remembered in
`~/.config/zmail/scope`, so the next start opens on the same account — or on all
of them, if that is what you picked last.
