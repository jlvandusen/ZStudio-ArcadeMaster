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

Not done yet: a place in Tools > Themes (today's look stays the default), a main menu of its own, a check on the
pedestal's 4K screen and second screen, and a measured menu-ready time against the default.
