# Wall of Games (first version)

Fifteen games on screen as picture tiles with their logos; the chosen game sits in the middle, larger, and plays its
preview. Up / Down move through the games, Left / Right switch the filters. Stop on a game and its controls card
comes up over the bottom row. The filter box, breadcrumbs and BACK / FILTERS hints are the default theme's.

- `gamelist.layout.xml` is the game-list layout. It names its pictures and sounds relative to a per-list layout
  folder: `<frontend>\layouts\ArcadeMaster\collections\<List>\layout\layout.xml`.
- It needs the small tiles: `python tools\New-GameTiles.py --retrofe <frontend>` (381 tiles in 12 s on RACE1, about
  12 KB each).
- To try it on one list (as on RACE1's Racing list, 2026-11-27): copy the file to
  `<frontend>\layouts\ArcadeMaster\collections\Racing\layout\layout.xml` and start the frontend, or send the cabinet
  link's `reload`. To go back, delete that file.
- How the wall moves: the list is one line of games wrapped into three rows. Each row has a hidden place off screen at
  both ends, so a game leaving one row slides out of sight before it comes in on the next. Both lists (tiles and
  logos) carry `menuIndex="0"`: without it the second one becomes a deeper menu level and is not drawn.

## Switching it on and off

- **Tools > Cabinet Settings > MENUS > GAME LIST VIEW** steps through DEFAULT, WALL and PITWALL. WALL: every game list of the cabinet (Racing, Flight, Arcade, the all-games list ...) shows the wall. DEFAULT: the default view. The main menu, Tools and Settings keep the theme's own look.
- By hand: `tools\Set-GameListView.ps1 -RetroFE <frontend> -View wall` or `-View default`; without `-View` it says which view each list has.
- With the frontend open the page changes at once; the tiles are made the first time (about 12 s for 380 games).
- A cabinet with a second screen keeps what that screen showed: the theme's extra-screen layouts are copied beside the wall.
- A list that already has a layout of its own (not ours) is left alone.

Not done yet: its own main menu, a check on the pedestal's 4K screen and second screen, a cursor that moves freely around the grid (today the chosen game stays in the middle and the wall moves past it).

## Measured (RACE1, GTX 1650, 1080p, 89 racing games, 2026-11-27)

- Opening the Racing list four times each, with `perfLog` on: the wall took 34 - 107 ms, the default view 35 - 63 ms. In both, nearly all of it is reading the game list; building the page is 5 - 9 ms and the first frame under 10 ms. The tiles and the preview fill in after the list is on screen.
- Not measured: a 16,000-game list (pedestal), and how long the tiles take to fill in while scrolling fast.
