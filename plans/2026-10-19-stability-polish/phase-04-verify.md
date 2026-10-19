# Phase 4 — Verify & measure

## Bench (in-app)

`ClipDeck --bench` prints to stderr:
- `show` duration ms (CFAbsoluteTime around palette `show()`)
- resident MB at print time

```sh
./Build/ClipDesk.app/Contents/MacOS/ClipDeck --bench &
sleep 3
osascript -e 'tell application "System Events" to keystroke "v" using {command down, shift down}'
# → "palette show: NNms" in stderr; relaunch for cold number.
```

- [ ] Cold open < 120 ms, warm < 60 ms (`--bench` stderr)
- [ ] RSS < 30 MB after 60 s idle (`ps -o rss= -p <pid>`)
- [ ] RSS stays < 60 MB with 50 items incl. screenshots (phase-3 rule)
- [ ] Quit → relaunch → history intact (phase 1)
- [ ] ⌘⇧V → type filter → ⏎ paste lands in previous app
- [ ] Esc / click-outside / second ⌘⇧V all dismiss
- [ ] Pin survives restart; Clear keeps pinned
- [ ] Settings: launch-at-login registers (check Login Items)
- [ ] Kill -9 → relaunch → items present (flush-on-change works)

## Regression watch

- Borderless→titled panel change may affect `ignoresMouseEvents`/
  drag region — verify titlebar area doesn't swallow row clicks.
