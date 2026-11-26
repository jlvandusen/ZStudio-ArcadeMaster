# 16. Cabinet link: similar cabinets browse and start games together

James, 2026-11-26: "see if a similar cab is online and attract mode sync with it. When a player is picking games on
one race cabinet, the other race cabinet moves its choices in unison and suggests starting the same game; if that
person doesn't answer in a 5 s countdown, start the game there too." None of Big Box, Batocera / RetroBat or CoinOPS
does this. Several of our games are linked-cabinet versions (Daytona "Linked Cabinets"), so "the same game on both
rigs" can be a real two-player race.

## The rule that keeps it safe
**A cabinet only follows while nobody is using it.** Any menu action on a cabinet makes it its own master again at
once; any button cancels the countdown. RetroFE itself only ever talks to 127.0.0.1, so nothing on the network can
drive a cabinet directly: the helper decides.

## Parts
| Part | Where | State |
|---|---|---|
| 1. RetroFE says what it is doing and takes two commands | fork patch 0017 (`Control/AmLink`) | **done**, off by default |
| 2. Link helper: finds similar cabinets on the LAN, passes selections on, decides who follows | `tools\AmLink` (next) | to do |
| 3. "Join? 5 4 3 2 1" countdown on the following cabinet, any button cancels | helper + tool screen | to do |
| 4. The idle rig's wheel turns with the other rig's steering (force-feedback spring centre) | fork patch, `Control/Haptics` | to do, after 2-3 |
| 5. Linked games: start the two-cabinet version on both, with the network settings each needs | catalog + launcher | to do |

## Part 1: what RetroFE does (patch 0017)
`settings.conf`: `linkEvents = yes` (default no), `linkSendPort = 47801`, `linkRecvPort = 47802`. UDP on 127.0.0.1,
one line per datagram, fields separated by tabs.

Out (to the helper):
| Line | When |
|---|---|
| `hello <menu> <ms since somebody used this cabinet>` | every second while a menu is shown (none while a game runs) |
| `select <user\|remote\|auto> <menu> <playlist> <item> <item's collection> <game\|menu>` | the selection changed |
| `launch <user\|remote> <menu> <item> <item's collection>` | a game is starting |
| `miss <item>` | a `goto` for a game this menu does not have |

In (from the helper), acted on only while the menu stands still:
| Line | Does |
|---|---|
| `goto <item> [<collection>]` | jumps to that game (the "random game" path, to a named game). The collection matters: a merged menu can hold the same name twice (Daytona single / linked) |
| `open` | what Select does: starts the game, or enters the menu |

`user` = a menu action or a real direction was pressed on this cabinet in the last 3 s; `remote` = a link command;
`auto` = anything else (start-up, attract mode). Raw button events are not used: an H-shifter left in gear is a held
button and reports itself as a press.

### Found on the way: menus skipped their first games
On RACE1 up and down both read as held for about 250 ms after a menu is entered (the pedal axes are bound to up / down,
and are read as pressed right after the input states are reset). RetroFE resolved "both" as down, so the list moved:
Racing opened on its third game. Patch 0017 makes opposite directions cancel. Racing now opens on 1 / 91.

### Tested (RACE1, a script standing in for the helper)
- `goto Tools` on the main menu, `open` (enters Tools), `goto 0a Menu Buttons`, `open` (starts it):
  `select remote ...` each time, then `launch remote Tools 0a Menu Buttons`.
- Entering by `open` leaves the selection on the first entry and the idle clock untouched (no phantom "user").
- Real keys: Enter opens Racing on American Truck Simulator (1 / 91); Down x3 and Up move one game each, all `user`.
- Test keys must be sent as extended keys (arrow keys): without that flag Windows reads them as number-pad keys.

## Part 2-3: the helper (plan)
- Announce on the LAN (UDP broadcast, cabinet network only): name, cabinet type (racing / flight / standup ...),
  what is selected, whether somebody is here.
- Follow only a cabinet of the same type, only while this one is idle (no `user` for 30 s, not in a game).
- Leader's `select user` -> follower `goto` (and `open` first when the follower is still on the main menu).
- Leader's `launch user` -> follower shows "RACE1 is starting <game> - join? 5 4 3 2 1"; no button -> `open`.
  A game the follower does not have (`miss`) is skipped, with a line on the countdown card.
- Tools switch: Cabinet Link on / off; off by default until tried at the cabinets.

## Part 4: the wheel turning by itself
The G29's motor can turn the rim: RetroFE's frontend force feedback (`Control/Haptics`) already runs a centring
spring, and its constant-force "clicks" stepped the rim round (which is why they are off by default). Moving the
spring's centre makes the wheel go to an angle and hold it. Limits: gentle force, a small angle (it cannot know
whether a hand is on the rim), only on an idle cabinet, and released the moment somebody touches a control.
