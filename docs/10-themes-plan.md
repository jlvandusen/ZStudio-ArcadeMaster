# Themes: plan

The goal is to switch the whole look of a cabinet. Themes can come from the existing CoinOPS / Core builds, and BigBox themes should be supported too. `tools/Survey-Frontends.ps1` already lists what each machine has; run it on the pedestal first, because that's where most of the themes are.

## 1. CoinOPS / Core themes: direct import

A CoinOPS theme is a RetroFE layout, and our fork is CoinOPS-compatible, so these import almost unchanged.

`tools/Import-RetroFETheme.ps1 -Source <coinops root> -Layout <name>` will:
- **Copy the layout.** `layouts/<name>` → `layouts/CO-<name>`, with fonts, images, sounds, videos and per-collection layouts. It's a copy, not a link, and the source is never touched.
- **Check compatibility.** Compare the art types the layout reads (`artwork_front`, `artwork_3d`, `bezel`, `story`, `video`, …; the survey already extracts them) against what our collections have, and report the gaps per collection, e.g. "Racing: layout wants `artwork_3d`, 0 of 103 games have it".
- **Fill gaps where safe.** Use our `fanart` / `logo` as a fallback type, or generate missing art. It never deletes art.
- **Fix the known traps.** `layout - N.xml` gets `monitor="N"`; it was missing in ours, which made the second screen draw over the main one. A font path relative to the layout root is resolved too.
- **Make a preview.** Launch RetroFE on the theme for a moment and screenshot it into `themes/<name>/preview.png`.

`themes.json` then lists the installed themes, each with source, preview and a compatibility score.

## 2. Theme picker (Tools → Themes)

- The same visual picker as Cabinet Type: preview cards, with the wheel / stick / tap to choose and a button to apply.
- Cabinet default (`layout =`), plus optional per-collection overrides, e.g. Racing in one theme and Flight in another.
- "Random theme each boot" option, handled by `Start-ArcadeMaster`.
- ArcadeMaster stays the fallback. **Done (2026-11-22):** at boot, a theme that is missing its `layout.xml` is reset by the health check. In a crash loop, the watchdog first restores the last-known-good settings. If RetroFE still crashes, it sets `layout = ArcadeMaster` (keeping `settings.conf.before-theme-fallback`) and tries again before giving up. Tested with a fake frontend that always crashes.

## Styles: many looks, no speed cost (2026-11-23)

The ArcadeMaster layout has picture slots: the centre wheel or yoke, two dials and their needle, the flight horizon and HUD sight, and the select flash. A **style** is a different set of pictures for those slots, at the same sizes. The layout, its layers and animations don't change, so every style loads and draws exactly as fast as the original.

| Racing | Flight |
|---|---|
| Neon Night (original) | Classic Cockpit (original) |
| Rally Stage: cream dials, orange needles, gravel spray | Fighter HUD: green head-up display, side stick |
| GT Carbon: carbon-fibre dials, red needles | Warbird: brass and olive 1940s instruments, bomber wheel |
| Pit Wall: LED shift-light dials, teal | Glass Cockpit: airliner flight display, magenta guidance |
| Tokyo Drift: violet neon, tyre smoke | Starfighter: violet space horizon, star streaks |
| Vintage Chrome: ivory dials, brass needles | Night Ops: night-vision green |
| Le Mans Night: night-lit green dials, rain | |
| Dragstrip: white dials, shift light, flames | |

- **Making them:** `tools\New-ThemeSkins.ps1` draws them (System.Drawing with Segoe UI, original art) into `images\skins\` and registers them in `themes.json` (`themes` and `skins`). All 12 styles together take 3.2 MB.
- **Left out:** soft effects are drawn at half size. `am_drift` has no element in any layout, so no style makes a picture for it.
- **Picking:** Tools → Themes lists the styles for the cabinet's mode first, then **Surprise me** (a different style every start), then the whole layouts (imported themes). The choice is stored per family in `manifest\skins.json`.
- **Real wheel:** every racing style keeps the cabinet's real wheel in the centre (`New-RealWheelArt`, from Logitech G HUB's picture). The centre wheel on the main menu and on the game list turns with the real wheel (`liveSteer`, patch 0007).

## Arcade layouts: five new arrangements (2026-11-24)

Styles change the pictures; these change the **arrangement**. Each is a complete RetroFE layout in `layouts\AM-<Name>\` that shows the same per-game media as ArcadeMaster: `am_video`, `am_backdrop`, `am_controls`, `am_hint`, `am_story`, logo, marquee, the playlist banner and the list position (`collectionIndexSize`). The placement ideas come from the CoinOPS and CORE layouts on R:. Their pictures, logos and names are not used: every picture is drawn by one script, `tools\New-ArcadeThemes.py` (Pillow).

| Layout | Idea | Borrowed from |
|---|---|---|
| **AM-Wall** (Tile Wall) | A staggered two-column wall of logo tiles on the left. The chosen game opens big on the right: video, title bar, controls card, hint, and the story after 6 s. | CoinOPS Wall / Night Wall |
| **AM-Marquee** (Cabinet) | The screen is a cabinet: a lit marquee lightbox on top (`type="marquee"`), the video in a CRT bezel with scanline glass, the controls card on the control-panel deck. Logos are on the left side panel; title and story are on the right one. | CoinOPS Marquee / Marquee + Bezel |
| **AM-Wheel** (Spin Wheel) | Logos on a curved, tilted wheel at the right, over a neon arc. The video is big on the left, and the story runs as a ticker along the bottom. | CoinOPS Wheel Ani, CORE TYPE R |
| **AM-Poster** (Box Art) | A box-art (`cover`) carousel with tilted neighbours along the bottom, over the game's full-bleed backdrop. The video is top right and the controls card top left. | CoinOPS Poster / Bottom Spin |
| **AM-Neon** (Neon Lite) | A centred neon **text** list under one huge logo. It has no list pictures to load and the fewest layers, so it's the theme for weak PCs. | CoinOPS Vertical / Fast |

- **Keys:** every game-list menu is `orientation="vertical"`, so UP / DOWN move through the games and LEFT / RIGHT stay on the playlists. This holds even where the items are laid out sideways (Poster, Wall): there, UP / DOWN mean previous / next. The main-menu row stays horizontal like ArcadeMaster's, so the wheel steers it.
- **Speed:**
  - Every generated picture is made at the size the layout draws it.
  - Each theme has two full-screen layers: one opaque, pre-scaled JPEG background and the game's `am_backdrop`. The backdrop is darkened by its alpha, not by a scrim layer, and has no resize animation.
  - The tile wall is baked into one picture; only the logos move between the fixed tiles.
  - The video has one fixed size (`width` + `maxHeight`, so 4:3 and 16:9 both fit), and only its alpha animates.
  - Each theme's own art is 0.1 to 0.9 MB.
- **Each folder also has:**
  - `layout - 1.xml`, the second screen (`monitor="1"`): the marquee in the theme's frame, the logo under it and ArcadeMaster's touch bar.
  - The main menu, `collections\Main\layout\layout.xml` and its `layout - 1.xml`.
  - ArcadeMaster's Tools screen, boot intro, sounds, font and collection logos.
  - `theme.json`, with the label, idea and keys.
- **Install** with `python tools\New-ArcadeThemes.py --install <RetroFE root> --manifest <manifest dir>`. This:
  - copies each folder to `<RetroFE>\layouts\AM-<Name>`. It refuses E: and never replaces a folder it did not make.
  - adds the cabinet's own playlist banners and intro card.
  - draws a preview mock-up from sample media into `<manifest>\themes\AM-<Name>.png`.
  - registers each theme in `<manifest>\themes.json` and scores its artwork coverage with `Import-RetroFETheme.ps1` (in place, `-NoPreview`), so Tools → Themes lists it.
  - It does not touch `settings.conf`.
- **Tested** on the LEGENDS-am copy (2026-11-24): RetroFE started on each theme with `firstCollection = Arcades` and loaded every layout file with no errors in `log.txt`. `settings.conf` was restored byte for byte afterwards. One quirk on that machine: the 4K primary is display 0 at 200 %, and parts of the second-screen layout show on the primary. Stock ArcadeMaster does the same, so the new layouts don't cause it.

## 3. BigBox themes: two routes

BigBox themes are WPF / XAML, which RetroFE can't run.

| Route | What it is | Cost |
|---|---|---|
| **A. BigBox as an alternative frontend mode** | Tools → "Frontend: RetroFE / BigBox". `Start-ArcadeMaster` launches `BigBox.exe` with the chosen theme (`LaunchBox\Data\BigBoxSettings.xml → Theme`), using the LaunchBox install already on D: and its platform data. Our wheel mapping, Dolphin switching, system settings and intro still apply. | small; themes run natively |
| **B. Port a BigBox theme's look into RetroFE** | Pull the theme's backgrounds, fonts and colour palette (Themes\<name>\Images, Fonts, XAML colour resources) into an ArcadeMaster skin. The layout structure (wheel / list / grid) is rebuilt per theme family, because XAML views don't translate one-to-one. | medium per theme family |

Recommendation: do 1 and 2 first, since that's direct reuse; then route A for BigBox, which is quick. Port individual favourites with route B where the look is worth it.
