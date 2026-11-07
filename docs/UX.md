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
columns 0..21    the folder sidebar
column 22        the rule that separates it from the content
columns 24..     the content

row 0            the first row of the list -- there is no bar over it
rows 0..h-3      list rows (or the reader body)
row h-3          rule
row h-2          breathing room
row h-1          footer: contextual hints (left) + position (right)
```

The list owns the top of the screen: with folders on the left, a bar showing the
same folders would be the same list twice, so there is no bar. The reader takes
the whole width as well -- the sidebar is for choosing a folder, and reading is
not choosing -- with the subject on row 0, metadata on row 1, a rule on row 2,
body from row 3, its own rule and footer at the bottom.

Below 84 columns there is no room for both, so the sidebar is not drawn and a
one-line header comes back (`zmail  Inbox 3`): without it nothing would say which
folder is on screen. Below 40 columns or 10 rows the client says so instead of
drawing garbage.

### The sidebar

```
 ALL ACCOUNTS       3
 personal           3
 work
 ────────────────────
   Inbox             3
   Sent
   Drafts            1
   Clients
   Invoices          1
```

The top rows are the scope: every account at once, or one of them. The rule says
"the folders below belong to the scope above". Choosing a scope asks that account
what folders it has (`LIST`), and the numbers come from `STATUS`: the six the app
knows are counted from the store, the rest from what the server last said. A
folder whose name carries a namespace (`[Gmail]/All Mail`) is shown without it,
one row each, with `…` when even that does not fit; a name that only holds other
folders (`[Gmail]`) is not a folder and is not listed.

`J` and `K` walk the folders in the order the sidebar shows them, and a click on
a row does the same.

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

The card behind `?` shows the ones that matter for the screen you are on; this is all of
them.

| Anywhere | |
|---|---|
| `?` | the key card (`j`/`k` scrolls it, `/` filters it, anything else closes) |
| `Ctrl+C` | quit. Nothing else does: not `Esc`, `q`, `h`, or `Ctrl+Q` |
| `Ctrl+R` | refresh from the server |
| `/` | search the list |
| `J` / `K` | next / previous folder, in the order the sidebar shows them |
| `1`–`9` | the folder in that position in the sidebar |
| `a` / `A` | next account scope / the accounts overlay |
| `j` `k` `g` `G`, `↑` `↓` `Home` `End` | move: down, up, first, last |
| `Ctrl+D` `Ctrl+U` / `Ctrl+F` `Ctrl+B`, `PageDown` `PageUp` | half a page / a page |
| `Ctrl+N` `Ctrl+P` | down / up, for terminals without arrow keys |
| `Space` | a page |

| The list | |
|---|---|
| `Enter` `l` `o` `→` | open the selected message |
| `c` / `r` | compose / reply |
| `u` / `s` `*` | read or unread / star or unstar |
| `d` / `#` `Delete` | archive / move to Trash |
| `m` | move to another folder: `j`/`k` choose, `Enter` moves, `Esc` cancels |
| `X` / `E` | delete for good (Trash only) / empty Trash |
| click, wheel | select a row (again to open it), scroll |

| The reader | |
|---|---|
| `q` `h` `Esc` `←` | back to the list; never quits |
| `j` `k` `Space`, `↑` `↓` `PageDown` | scroll |
| `r` / `c` | reply / compose |
| `u` `s` `d` `#` | the list's actions, on the message you are reading |
| `o` | the whole mail in a browser, pictures and all |
| `H` | HTML view, or the plain text one. The HTML is read by zmail itself: no browser, no external program |
| `i` | the pictures the message carries: the ones in it, and the ones it points at (fetched by `curl`, off the loop) |
| `\` | every header: the account it arrived at, from, to, cc, reply-to, date, message-id |
| `←` (click) | back one layer, exactly where `Esc` goes |
| `Ctrl+click` / `drag` | open the link under the pointer / select and copy |

| Writing | |
|---|---|
| `Tab` / `Shift+Tab` | next / previous field |
| `Enter` | next field, or a line break in the body |
| `Ctrl+S` | send in five seconds; `Enter` again sends now |
| `Ctrl+E` / `Ctrl+U` | write the body in `$EDITOR` / clear the field |
| `Esc` | cancel, close |

| The accounts overlay | |
|---|---|
| `n` `e` `r` `d` | add, edit, rename, remove |
| `o` | sign in with the provider |
| `Enter` / `Esc` | use this account / close |

Search is live: typing filters as you go, `Enter` keeps the filter, `Esc`
cancels it. `↑`/`↓` still move the cursor while typing. Inside the help overlay,
`/` starts the same kind of filter over the key map itself; `Enter` keeps it and
`Esc` clears it.

`Esc` is never a quit key, and neither is `q`: it goes back one layer and at the
top it does nothing. **`Ctrl+C` is the only way out**, from anywhere.

The `←` in the top-left corner is that same step, for a mouse: a chip the width of
three cells, a couple of columns clear of the title it shares a row with. It is drawn
wherever there is a layer to return to — the reader, which owns the whole width, and
the overlays that hide the sidebar — and the pointer turns into a hand over it, the
same shape a link gets. The list is the bottom of the stack, so it draws nothing
there, and a click on the corner does nothing either.

**Quitting while something is loading.** The loop spends part of its life
waiting: for a refresh, for a body, for the first connection of a cold start.
Wherever it is waiting rather than working it reads keys, so a quit during a
wait is honoured at the first opportunity, nothing further is started, and the
spinner is not waited out. A key pressed *while a socket is being read* can only
be acted on when that call returns -- which is why `Ctrl+C` is a signal and not
a byte: zmail keeps `ISIG` on, and the handler puts the terminal back the way it
found it (alternate screen off, cursor visible, cooked mode) and leaves with
status 130. That path works even inside a TLS read, in the middle of the splash,
before the first frame.

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
the first frame is the splash instead of an empty list:

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

                                                             version: 0.5.1

                                                          alice@example.com

 connecting to work                                               Ctrl+C quits
```

The wordmark is drawn, not typed: a terminal cannot set type, and blocks are
the closest it gets. It is one shape stored once, five cells high and
thirty-five wide, and the size on screen is that shape with every cell drawn
twice, three times, or four -- whichever still leaves three columns of air at
each side. The picture above is the twice size, which is what an eighty-column
terminal gets; a narrow one gets the small mark rather than a cropped one.

It breathes: the whole word dims and comes back over four seconds, between its
full brightness and forty-five per cent, so the letters stay readable while the
light moves through them. The two corner sentences are the only other thing that
moves -- a band of light crossing them left to right. That is the whole
animation budget, and it buys the one thing a cold start needs: a frame that is
already alive when the connection is still being made.

The version comes from the manifest, and the address is the account's own. Both
are right-aligned together under the mark's right edge.

`ZMAIL_NO_MOTION` draws the still frame, which is a lit wordmark and not a blank
one.

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

 Enter next  ·  Esc back  ·  Ctrl+U clear  ·  Ctrl+C quit
```

It asks for the address, the IMAP server and port (prefilled `imap.<domain>`
and `993`), the SMTP server and port (`smtp.<domain>` / `465`, leave the host
empty to skip sending), the username (prefilled from the address), and the
password (masked, never echoed). The last screen shows the config that will be
written, the path, and where the password goes. `Enter` saves, `Esc` goes back,
`Ctrl+C` cancels without writing anything.

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

There is no palette to configure. Once, at startup, zmail asks the terminal what
colour it paints behind the text (`OSC 11`) and derives everything from it in
OKLCH: the lightness of that ground decides the direction, one hue family is
laid out in steps of lightness — accent, metadata, selection, rule — and hue
carries meaning rather than decoration (a muted periwinkle for the accent,
red-orange for alerts, amber for stars, four account hues a quarter turn apart).

Contrast is therefore a property of the construction, not of taste: the accent
clears 4.5:1 against the ground it was built for, the metadata 3:1, and the
selection stays near the ground so the terminal's own text still reads on it. A
terminal that does not answer keeps the built-in palette; nothing is guessed.

Body text is left at the terminal's own foreground, because it is already tuned
to that background and no generated colour can improve on it.

`NO_COLOR` (or `TERM=dumb`) switches to attributes only — bold, dim, reverse —
and the layout is unchanged.

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

Every place — each account, and "All accounts", which is a place of its own — keeps
the folder it was reading while the app is open: going from `work` on Sent to
`home` on Drafts and back to `work` puts you on Sent again. Nothing about it is
written down, though: a restart opens on the first folder, so the morning starts in
the same place every time.
