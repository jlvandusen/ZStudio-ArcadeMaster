# 23. Storage layout: one ArcadeMaster tree, links to what others own

James, 2026-11-27: "This format ... with the links to the folders for each emulator and rom is good", "when it does a
discovery of a new system first run it can then find all the stuff and do the same thing to each thus not effecting
another frontend etc.. or give the user option to move it all if wanted", "document them so we can combine them all
when time comes".

## The tree

Every ArcadeMaster launcher, list and config names paths in its own tree, never another frontend's:

| Path | What |
|---|---|
| `<root>\emulators\<emulator>` | each emulator a direct launcher uses (RetroArch, Cemu, PCSX2, TeknoParrot ...) |
| `<root>\library\roms\<system>` | each system's games (Move-ToLibrary filled most of it; the rest are links) |
| `<root>\bios`, `<root>\saves` | BIOS files and saves |
| `<root>\decorations` | bezel art (RetroBat's decoration sets) |
| `<root>\frontend\<build>` | the frontend (our RetroFE fork) and its own TeknoParrot install |
| `<root>\manifest` | generated data: discovery.json, search index, lights, `storage-map.json` |

`<root>` is `R:\ArcadeMaster` on ARCADE-PEDESTAL.

## Links first, moves when asked

Files another frontend owns (RetroBat on the pedestal) stay where they are. ArcadeMaster gets a **folder link**
(an NTFS junction: no admin rights, no extra space) at its own path. The other frontend keeps working unchanged.
ArcadeMaster's files point at the link, so a later move changes nothing for ArcadeMaster.

- `tools/Move-OffRetroBat.py` (dry run by default; `--apply`):
  - finds every RetroBat path that ArcadeMaster's launchers, lists, TeknoParrot profiles and manifest configs name;
  - links each folder into the tree;
  - rewrites ArcadeMaster's own files to the tree paths, with a backup of each.
- A folder that already exists in the tree with other content (`library\roms\teknoparrot`) gets one link per missing
  entry. Nothing that is already there is replaced.
- `--mode move` moves the real folders in their place: a rename on the same drive, which is instant. It also rewrites
  the configs inside the moved emulators. After that, RetroBat can be deleted.
- `--undo` removes the links, moves folders back and restores every backed-up file (`<root>\_off-retrobat\undo.json`).
- `--map` writes the record of every link:
  - `<root>\STORAGE.md` for people;
  - `<manifest>\storage-map.json` for tools.

## Combining later

Each cabinet's `storage-map.json` lists every link and its real folder. To bring a cabinet's files together:
- **On the same drive:** `--mode move`.
- **On another drive:** copy each real folder, then replace its link with the copy.

The paths ArcadeMaster uses never change, so nothing else needs editing.

## Next (docs/BACKLOG 1a)

- **First run:** discovery, then link everything found, whatever frontend owns it. The wizard offers "keep links" or
  "move everything in".
- **Import:** point at a folder (an emulator, a system's games, one game). It is linked or moved in, and its list,
  launcher, art, lights and search entry are made.
