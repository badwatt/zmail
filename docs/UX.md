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

- list: `j/k move · Enter open · / search · d archive · ? help`
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
| `h` `q` `Esc` `←` | back one layer, or quit from the list |
| `u` | toggle read / unread |
| `s` `*` | star / unstar |
| `d` | archive |
| `#` `Delete` | move to trash |
| `/` | search (live filter over sender and subject) |
| `Tab` `]` | next mailbox |
| `Shift+Tab` `[` | previous mailbox |
| `1`–`6` | jump to Inbox, Sent, Drafts, Archive, Trash, Junk |
| `R` | refresh from the server |
| `?` | help |
| `Ctrl+C` | quit immediately |

Search is live: typing filters as you go, `Enter` keeps the filter, `Esc`
cancels it. `↑`/`↓` still move the cursor while typing.

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
