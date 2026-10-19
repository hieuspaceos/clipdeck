# Phase 2 — Instant palette

**Goal**: ⌘⇧V → visible UI under 120 ms cold, <60 ms warm.

Current cost: `Palette.show()` recreates `NSHostingView` + full SwiftUI
tree every open (~30-80 ms on first, still wasteful after). Fix by
caching.

## Tasks

1. **Prewarm window** — `Palette.shared` already inits at launch; also
   render one frame offscreen (`orderOut` after `displayIfNeeded`) so
   SwiftUI/Metal pipelines are hot.
2. **Stop rebuilding the view** — `refresh()` currently assigns a new
   `NSHostingView` (full SwiftUI tree recreate). Replace with reactive
   updates:
   - Move `selected` to `Store` as `@Published var selected = 0`.
   - `PaletteView`/`RowView`/`PreviewPane` read `store.selected` — rows
     re-render via diff, no view replacement. Delete `refresh()`/
     `refreshSoon()` and their call sites.
   - `show()` sets `store.selected = 0` before `orderFront`.
3. **Selection scroll** — `onChange(of: store.selected)` on the ScrollView
   + `ScrollViewReader.scrollTo` stays.
4. **Images** — rows and `PreviewPane` render `clip.thumb` (≤320 px,
   cached per-clip, decoded once) — never `clip.image` at render time.
5. **Fade-in** stays 0.18 s ease-out; prewarm makes it invisible.

## Verify

- Instrument: `CFAbsoluteTime` around `show()` → log ms. Target
  numbers above.
- Scroll 50+ rows: no stutter (release build).
