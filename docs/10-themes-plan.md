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

## 3. BigBox themes: two routes

BigBox themes are WPF / XAML, which RetroFE can't run.

| Route | What it is | Cost |
|---|---|---|
| **A. BigBox as an alternative frontend mode** | Tools → "Frontend: RetroFE / BigBox". `Start-ArcadeMaster` launches `BigBox.exe` with the chosen theme (`LaunchBox\Data\BigBoxSettings.xml → Theme`), using the LaunchBox install already on D: and its platform data. Our wheel mapping, Dolphin switching, system settings and intro still apply. | small; themes run natively |
| **B. Port a BigBox theme's look into RetroFE** | Pull the theme's backgrounds, fonts and colour palette (Themes\<name>\Images, Fonts, XAML colour resources) into an ArcadeMaster skin. The layout structure (wheel / list / grid) is rebuilt per theme family, because XAML views don't translate one-to-one. | medium per theme family |

Recommendation: do 1 and 2 first, since that's direct reuse; then route A for BigBox, which is quick. Port individual favourites with route B where the look is worth it.
