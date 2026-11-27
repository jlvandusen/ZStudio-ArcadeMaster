# 22. The touch surface (docs/21 phase 6)

James, 2026-11-27: "the 2nd screen touch controls was awesome, need to think more along those lines". The second
screen (the pedestal's touch panel, a marquee screen, any touch display) becomes a control surface. It works for every
cabinet that has one, and it is designed in the theme next to the main screen.

## Step 1: touch buttons (done, ZStudio-retrofe PR 9)

Any layout component becomes a button with `touchAction="<action>"`.

```xml
<image src="images/btn_random.png" touchAction="random" x="1536" y="720" width="384" height="360" layer="8">
  <onTouch><set duration=".15"><animate type="alpha" from=".4" to="1"/></set></onTouch>
</image>
```

- **Action:** any `controls.conf` action name: `select`, `back`, `up`, `down`, `left`, `right`, `random`,
  `nextPlaylist`, `prevPlaylist`, `favPlaylist`, `addPlaylist`, `letterUp`, `letterDown`, `pageUp`, `pageDown`,
  `toggleGameInfo`, `settings`, `menu`, and so on. It works even when `controls.conf` binds no key to it.
- **Hit-testing:** the component's drawn rectangle on its own screen (`monitor`), at its current animated position.
  The topmost visible one wins (alpha 0.05 or more).
- **No double firing:** the tap that hit a button is not also a `touch…Tap` gesture or a region tap. Old
  `controls.conf` region bindings can stay as a fallback for builds without touch buttons.
- **Feedback:** `onTouch` plays on the button that was hit.
- **Invisible buttons:** use `images/touch_hit.png`, a transparent picture drawn at full alpha, over painted art.
  The ArcadeMaster layouts do this over the existing touch bar.
- **Log:** `[Touch] button 'down' on screen 1`.
- **Testing without a finger:** use Windows touch injection (`InitializeTouchInjection` + `InjectTouchInput`, pointer
  type touch, flags DOWN|INRANGE|INCONTACT then UP). The pedestal's panel is a digitizer mapped to its display, so a
  mouse click is not a finger there.

## Next steps

2. **Touch the list itself.** A tap on a game in a menu selects that game, and a tap on the selected game starts it.
   Flicks scroll the list with momentum.
3. **Companion panels.** One touch layout holds several panels: details, controls card, video, search, filters,
   favourites and settings. A tab row switches between them (`touchAction="panel:controls"`, with
   `onPanelEnter` / `onPanelExit` events), and the panels follow the selected game. AmPanel's search and chooser
   windows move in here.
4. **Search on the touch screen.** The keyboard from AmPanel's SearchScreen becomes a panel that types into the
   frontend's own search. It covers all systems, and the result opens the game.
5. **In a game.** The second screen keeps drawing during a game (RetroFE's keepRendering thread for the secondary
   screens) and shows that game's buttons: coin, start, service, pause, save and load state, quit. They work through
   the emulator's own keys (per-emulator key table, as AmPanel's exit guard uses). The touch window must not take
   the focus from the game: WS_EX_NOACTIVATE only while a game runs.
6. **Attract mode.** The marquee, high scores (hi2txt, which RACE1 has on its list) and a "now playing / try this"
   card.
7. **One theme, both screens.** RACE1's theme engine (phase 4) owns layers, timelines and data binding. Touch
   buttons, panels and the in-game set are all ordinary components, so a theme lays out both screens together.

## Cabinet types

- **The pedestal:** 4K main screen and a 1920x1080 touch panel. The touch panel is RetroFE screen 1.
- **A racing cabinet with a dash or marquee screen:** the same layouts work, with the in-game set showing the wheel
  buttons instead.
- **A cabinet without a second screen:** gets the same panels as an overlay on the main screen, opened by a button.

Which of these applies comes from the cabinet profile (docs/21 phase 3).
