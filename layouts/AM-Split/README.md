# Split Screen (first version)

Left: the chosen game playing, its controls card under it. Down the middle: the list as a strip, the chosen game on a
bright block. Right: the game's logo, what it is (maker, year, players, kind of game), how often and how long it has been
played on this cabinet and when last, and its story scrolling slowly. Up / Down move through the games, Left / Right
switch the filters; the filter box and BACK hint are top right, the breadcrumbs top left.

- `gamelist.layout.xml` is the game-list layout; `images\` holds its three small pictures. `tools\Set-GameListView.ps1
  -View split` puts both in place for every game list.
- **"On this cabinet"** comes from `<manifest>\playtime.json`, which `Record-GamePlay.ps1` keeps at the end of every
  game. `tools\New-GameStats.ps1` writes it as `medium_artwork\am_stats\<item>.txt` per game; Record-GamePlay runs it for
  the game that just ended, so the line is fresh. A game never played here shows nothing there.
- Switch: **Tools > Cabinet Settings > MENUS > GAME LIST VIEW** steps through DEFAULT, WALL, PITWALL, SPLIT.
- Tried on RACE1 (GTX 1650, 1080p) on the Racing list: draws, the preview plays, the card, facts and story show.

Not done yet: best time / high score (no source for it yet), a "not played here yet" line for new games, and a check on
the pedestal's 4K screen and second screen.
