# ZStudio ArcadeMaster: session start

Several cabinets work on this repo; each runs its own Claude session:

| Machine | Cabinet |
|---|---|
| DESKTOP-RACE1 | racing / flight, G29 wheel; the coordinator |
| ARCADE-PEDESTAL | 4-player pedestal with a touch second screen |

They coordinate on the NAS board, **`Z:\ArcadeMaster\board`**. Read `BOARD.md` there.

1. Run `hostname`.
2. `powershell -ExecutionPolicy Bypass -File tools\Board.ps1 beat -Doing "joined; claiming open jobs" -Can "<what this machine has>"`
3. Run `tools\Board.ps1 list`. Jobs for your machine are listed first. Claim one (`claim -Id`), do it, then finish with `done -Id -Report`.
4. Results go into the repo (commit + push). The board only carries jobs and reports.

**Rules:**
- Audit jobs are read-only.
- Never delete game data. Variants such as Daytona standalone / multicab are kept.
- Test Windows system switches only with `AM_SYSTEM_DRYRUN=1` (see docs/08).
- Pedals are always clutch LEFT, brake MIDDLE, gas RIGHT.

Docs: `docs/09-pedestal-install.md` (new cabinet), `docs/06-input-mapping.md` (controls), `docs/08-dynamic-catalog.md` (frontend tools), `docs/10-themes-plan.md`.