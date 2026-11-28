# Cockpit (game list view)

You sit in the car. The chosen game's own art is the view ahead, its preview plays in the windscreen, the games pass
as a row of logos under it, and the dash along the bottom carries the default theme's speedo, rev counter and the
cabinet's real wheel. They move with the wheel and pedals, as on the main menu. Stop on a game for three seconds and
its controls card comes up over the middle of the dash, between the two gauges.

Turn it on: Cabinet Settings > MENUS > GAME LIST VIEW > COCKPIT, or

    tools\Set-GameListView.ps1 -RetroFE <frontend> -View cockpit

`gamelist.layout.xml` is copied to every game list as that list's own layout. The gauge block is a copy of the one in
`layouts\ArcadeMaster\layout.xml` moved into place, so it follows the cabinet's gauge skin. `images\cockpit_dash.png`
is the dash band (made once, kept in the repo).