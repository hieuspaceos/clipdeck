# ClipDesk — stability, lightness, smoothness

Make ClipDesk feel like a system utility: survives restarts, opens in <120 ms,
uses <30 MB idle RSS, and animates at a solid 60 fps.

## Success criteria

- History persists across quit/relaunch (text, image thumb, file refs).
- Cold ⌘⇧V → palette visible in <120 ms; warm in <60 ms.
- Idle RSS < 30 MB; poll CPU ~0.
- Palette open/close animates without frame drop on 1080p.
- No functional regressions: search, ⌘1-9, pin, plain paste, delete, Esc.

## Phases

| # | Phase | Focus |
|---|-------|-------|
| 1 | `phase-01-persistence.md` | JSON store + image thumbs on disk |
| 2 | `phase-02-instant-palette.md` | Pre-created window, cached views |
| 3 | `phase-03-lean-runtime.md` | Poll interval, memory trims, launch polish |
| 4 | `phase-04-verify.md` | Measure: launch latency, RSS, fps, regressions |
