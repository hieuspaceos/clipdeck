---
title: "ClipSpot perf optimization"
status: todo
goal: "Footprint ≤ 120 MB at 2 h uptime (from 354 MB), palette open < 150 ms"
---

# ClipSpot — Performance Optimization

Measured: 213 MB at launch → **354 MB after 2 h** (peak 459 MB).
`vmmap -summary`: ~300 MB dirty in Malloc zones; CG Image only ~11 MB.

## Root cause (confirmed by code audit)

`poll()` stores `.image(Data)` — the **full uncompressed TIFF** (~5-15 MB
per screenshot) — directly in `items`, capacity 200. `.imageRef` is only
produced on app restart via `history.json` decode, so persistence-on-flush
never frees memory this session. This is the dominant ~300 MB.

## Actions (ranked)

1. [ ] **Store `.imageRef` at capture time** — write PNG to `imagesDir`
       immediately in `poll()`, keep only the filename in `items`.
       `imageData` already lazy-loads from disk; make the in-memory kind
       always `.imageRef` for images. (`main.swift:269`)
2. [ ] **Bound `ThumbCache`** — it's a plain `[UUID: NSImage]` dict with
       no limit; caches full NSImage when source ≤320 px. Convert to
       `NSCache` with `countLimit` 50 / `totalCostLimit` ~100 MB; keep the
       `drop(id:)` calls in delete paths. Note: cache misses decode the
       FULL image then downscale — consider storing a small JPEG sidecar
       at capture time so thumbs never touch the full file.
       (`main.swift:162-178`)
3. [ ] **Cache app icons** — `clip.appIcon` calls
       `NSWorkspace.shared.icon(forFile:)` on every `RowView`/`PreviewPane`
       body evaluation, uncached. Cache per `bundleID`.
4. [ ] **Fix `sameContent` disk reads on dedupe** — `.imageRef` vs
       `.image` does `Data(contentsOf:)` full-file reads, and `poll()`
       runs `firstIndex(where: sameContent)` over all items per clip →
       multiple full file reads on main thread. Compare by a content hash
       stored at capture, or skip compare unless kinds+byte sizes match.
       (`main.swift:86-95, 275`)
5. [ ] **Fix inverted `setPaletteOpen` guard** —
       `guard open != !idle else { reschedule(idle: !open); return }`
       reschedules when state is already consistent and does nothing when
       it differs — opening the palette while idle never switches the
       timer to 0.25 s. Small bug, real UX cost. (`main.swift:200-213`)

## Stale items — already done

- ~~Disk persistence~~ — exists (`Clip.Kind.imageRef`, `imagesDir`,
  `history.json`). The gap is runtime kind, not persistence.
- ~~Pasteboard polling~~ — already compliant: 1.0 s idle / 0.25 s open,
  tolerance 0.3, reads only `changeCount` per tick.
- ~~NSTableView reuse~~ — UI is `LazyVStack` capped at 80 rows; no AppKit
  cell work needed.

## Verify

```sh
PID=$(pgrep -x ClipSpot | head -1)
leaks -nostacks $PID
# copy 50 screenshots → footprint should stay flat (thumbs only)
```
