# Phase 1 — Persistence

**Goal**: clipboard history survives quit/relaunch.

## Design

- `~/Library/Application Support/ClipDeck/history.json` — metadata only:
  id, date, kind, pinned, appName, **`sourceAppBundleID`** (icon resolved
  lazily via `NSWorkspace.icon(forFile:)` on the app path, never persisted
  as image data), preview, image filename.
- Images → `images/<uuid>.tiff` next to the JSON (downscaled JPEG thumb
  ≤ 320 px for preview; full TIFF stored for repaste — full data is only
  read into memory when the item is pasted).
- Write: debounced — flush 500 ms after last poll change, and on terminate
  (see phase-03: timer invalidation lives there, flush here).
- Load: sync at `Store.start()` before first poll; cap file size by
  `capacity` on save.

## Tasks

1. `Clip`: add `Codable` envelope — `kind` → `{type: "text"|"image"|"file",
   payload: string | [paths] | imageFilename}`; add `sourceAppBundleID:
   String?` and make `appIcon` computed via cached
   `NSWorkspace.icon(forFile:)` on the resolved app URL
   (`NSWorkspace.urlForApplication(withBundleIdentifier:)`).
2. `Store.load()` at init — decode; image `NSImage` is NOT decoded here:
   `Clip.thumb` lazily loads `images/<uuid>-thumb.jpg` on first access and
   caches; `Clip.image` reads the full TIFF only inside `paste`.
3. `Store.flush()` — JSON encode + write atomically (temp file + rename).
4. Call `flush()` debounced in `poll()` after insert, and in
   `applicationWillTerminate`.
5. Images: save downscaled JPEG thumb + original TIFF side-by-side.

## Verify

- `echo x | pbcopy` → quit → relaunch → item still in palette.
- Kill -9 → relaunch → last items present (flush-on-change, not on exit).
