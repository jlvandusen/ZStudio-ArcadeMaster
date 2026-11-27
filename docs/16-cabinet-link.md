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
| 2. Link helper: finds similar cabinets, passes selections on, decides who follows | `tools\AmLink.ps1` | **done**, on for RACE1 and RACE2 |
| 3. "Joining in 5 4 3 2 1" card on the following cabinet, any menu button cancels | `tools\AmLink.ps1` | **done** |
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

## Part 2-3: the helper (`tools\AmLink.ps1`)
**Where it is on:** `catalog\cabinet-link.json` lists the cabinets (`DESKTOP-RACE1`, `DESKTOP-RACE2`), the idle time
(30 s) and the countdown (5 s). At the next start of the frontend Start-ArcadeMaster adds `linkEvents = yes` to that
cabinet's settings.conf once and starts the helper (hidden; it ends with the launcher). **Cabinet Settings > CABINET
LINK** switches it off or on for one cabinet; a cabinet that has its own `linkEvents` line keeps its choice.

**Attract on the game list (2026-11-26):** when nobody is at the cabinet and nobody is browsing on a twin, a cabinet
that has sat on the main menu for 60 s (`-AttractEnterSec`, 0 = off; never in the first 60 s after start) is taken
into its own game list: racing / simulation -> Racing, flight -> Flight, lightgun -> Lightgun, stand-up / pedestal ->
Arcade, when the main menu has that entry. Attract mode then rolls the games and their videos (patch 0029) instead of
Racing / Tools / Exit.

**How cabinets hear each other:** each helper writes `<share>\<HOST>.json` on `\\ds-mce\downloads\ArcadeMaster\link`
(what is selected, how long since somebody used it, the last game started) on every change and once a second, and
reads the others 4 times a second. No firewall rule and no admin prompt; AmPanel is not involved (it only talks on its
own PC, through a named pipe). "Is that cabinet there?" is judged by its counter changing, not by clocks.

**What it does**
- Follows only a cabinet of the same type (`cabinet-mode.json`: racing with racing), only while this one has had no menu
  action for 30 s, and only a cabinet where somebody pressed something in the last 15 s.
- Same menu: `goto` the leader's game (name + collection, so Daytona single and linked stay apart). On the main menu:
  goes to the leader's menu and opens it. In another menu: sends `back` (RetroFE answers that from patch 0018 on;
  until then the cabinet stays where it is).
- The leader starts a game (`launch user`): a card on top of RetroFE, "RACE2 is starting / <title> / JOINING IN 5 - any
  button to stay". A menu action here cancels ("STAYING HERE"). No action: the same game is selected and opened here.
  A game this cabinet does not have: "not on this cabinet".
- Everything this cabinet does because of the link is published as `remote`; only `user` actions are followed, so two
  cabinets cannot chase each other.
- Log: `manifestmlink.log`.

**Tested on RACE1 (2026-11-26) against a script acting as a second racing rig (a `DESKTOP-FAKE.json` peer file)**
- From the main menu it followed into Tools and Racing and onto each selected game (Daytona 3 single / linked by
  collection, Daytona USA, Sega Rally 2).
- Leader "starts" Menu Buttons: countdown card, then RACE1 started it itself (`launch remote`).
- Leader "starts" Daytona USA, a real key pressed on RACE1 during the countdown: "countdown cancelled here", no game,
  no emulator process.
- Through the real start-up path (the Startup shortcut): link switched on from the list, helper started, followed with
  the 30 s rule.
**Not tested yet:** two real cabinets. RACE2 gets it at its next frontend start after pulling main.

**First real try, RACE1 + RACE2 (2026-11-26 08:40) and what it showed**
- RACE2 followed RACE1 onto Batman, but did not start it. RACE1's presses on the main menu's EXIT entry had started "joining EXIT" on RACE2; RACE2 could not go back to the main menu (no `back` yet), stayed busy for 15 s, and the Batman start fell into that time.
- Fixed: only games are joined - never an entry of the first menu (EXIT) or of Tools / SETTINGS / Controller, and a cabinet is not followed into those; a newer start replaces one still counting or joining; `open` is sent once.
- The helper restarts itself when a newer AmLink.ps1 arrives (checked every 30 s), and `tools\Restart-CabinetHelpers.ps1` restarts the helpers under a running launcher.

**Known gaps**
- The follower cannot leave a menu (`back`) until RetroFE patch 0018.
- After a joined game starts, it runs until somebody exits it at that cabinet (the in-game menu, A3, is the place to
  end it when the leader's game ends).
- Starting "the same entry" is not yet linked play: the two-cabinet versions still need their network settings (part 5).

## Part 4: the wheel turning by itself
The G29's motor can turn the rim: RetroFE's frontend force feedback (`Control/Haptics`) already runs a centring
spring, and its constant-force "clicks" stepped the rim round (which is why they are off by default). Moving the
spring's centre makes the wheel go to an angle and hold it. Limits: gentle force, a small angle (it cannot know
whether a hand is on the rim), only on an idle cabinet, and released the moment somebody touches a control.

## 2026-11-27: following by name, attract sync, stand-up cabinets

- **Following stopped after one game.** A cabinet names the game and the list it took it from. RACE1 keeps some
  TeknoParrot games in a list RACE2 does not have, so RACE2 went to the first game and then stood still. The helper now
  tries twice with the list name, then by the game's name alone. After six tries the game is not on that cabinet and
  it waits for the next one.
- **Attract mode shows the link.** With nobody at any cabinet each one rolls its own games. Every two minutes, for 14
  seconds, linked cabinets show the same game and a card at the top of the screen says so: "CABINET LINK - RACE1 +
  RACE2 - pick a game here and the other cabinet follows - start it and it joins". The window comes from the clock, so
  the cabinets are in it together; the cabinet whose name sorts first shows its game and the others go to it.
  `-ShowLinkEverySec 0` switches it off.
- **Stand-up cabinets link too.** The 4-player pedestal and the 2-player stand-up count as one kind ("arcade"), like a
  racing rig and a driving-sim rig count as "racing". `catalog/cabinet-link.json` now has all four cabinets.
- **Tested on RACE1** against a stand-in second cabinet (a `DESKTOP-FAKE.json` file on the share): it followed a game
  named from a list RACE1 does not have, and in the attract window it went to the stand-in's game and showed the card.
  **Not tested yet:** two real cabinets with the new helper, and the pedestal with the 2-player cabinet.