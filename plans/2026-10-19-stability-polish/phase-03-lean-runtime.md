# Phase 3 — Lean runtime

**Goal**: idle RSS < 30 MB, near-zero CPU.

## Tasks

1. **Poll interval** — 0.5 s → adaptive: 0.25 s while palette open, 1.0 s
   idle. Timer `tolerance = 0.3` for power.
   - **Terminate cleanup**: `applicationWillTerminate` →
     `timer.invalidate()` + `Store.flush()` — both, not flush alone.
2. **Text preview** — store full string but cap `preview` render at
   ~2000 chars (large clips already truncated for display).
3. **Image memory** — resident set is the biggest RSS risk: 200 clips
   with screenshots could be 1 GB+. Rule: only `preview` text + `thumb`
   (≤320 px JPEG, ~50 KB) live in memory; full image `Data` is read from
   `images/<uuid>.tiff` lazily in `paste()` and released after writing to
   the pasteboard.
4. **Dedupe strings** — compare `preview` hash instead of storing
   duplicate content.
5. **Icon cache** — `NSWorkspace.frontmostApplication.icon` hits disk;
   cache by bundle id.
6. **Launch polish** — add `LSUIElement`, ensure no Dock flash; confirm
   `Info.plist` min version matches Makefile target (14.0).

## Verify

- `ps` RSS after 60 s idle < 30 MB.
- `powermetrics`/`top` — CPU ~0% idle.
