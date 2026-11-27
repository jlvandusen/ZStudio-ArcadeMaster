# Pit Wall (first version)

The chosen game's preview fills the whole screen. The list is a timing tower down the left, like a race broadcast, with
the chosen game on a bright bar: three games above it, five below. Lower right is the game's logo; stop on a game and its
controls card comes up. Title, maker and year run along the bottom. Up / Down move through the games, Left / Right
switch the filters; the filter box sits at the top of the tower and the breadcrumbs top right.

- `gamelist.layout.xml` is the game-list layout; `images\` holds its three small pictures (the tower panel, the bright
  bar, the fade under the video). `tools\Set-GameListView.ps1 -View pitwall` puts both in place for every game list.
- Switch: **Tools > Cabinet Settings > MENUS > GAME LIST VIEW** steps through DEFAULT, WALL, PITWALL.
- Tried on RACE1 (GTX 1650, 1080p) on the Racing list: draws, scrolls, the video plays full screen, the card comes up.

Not done yet: a 4:3 preview leaves plain bars at the sides (the game's backdrop should show there), numbers down the
tower like a real timing screen, and a check on the pedestal's 4K screen and second screen.
