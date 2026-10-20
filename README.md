# clipspot

A free, lightweight clipboard manager for macOS — the Paste-app-style
workflow without the subscription. Menubar agent (no Dock icon), Swift +
AppKit/SwiftUI, zero third-party dependencies.

## Install

**Homebrew (recommended)**

```sh
brew tap hieuspaceos/suite && brew trust hieuspaceos/suite
brew install --cask clipspot
```

**Manual** — grab the DMG from
[Releases](https://github.com/hieuspaceos/clipspot/releases/latest), drag into
/Applications and open (Developer ID signed + notarized).

## Features

- **⌘⇧V shelf** — a borderless panel slides up along the bottom of the
  screen with card previews of everything you copied.
- **Cards** — source-app icon + name, timestamp, content preview
  (text, image thumbnail, file names). First 9 items get `⌘1…⌘9`.
- **Search** — the top field filters live as you type.
- **Keyboard-first** — arrows move selection, ⏎ pastes into the
  previously-front app (synthetic ⌘V), ⌫ deletes, ⎋ dismisses.
- **Pin** — right-click a card → Pin; pinned items sort first and survive
  "Clear history".
- **Context menu** — Paste as plain text, Pin/Unpin, Delete.
- **Dedupe** — re-copying an item moves it to the top.
- **Menubar menu** — Show clipspot (⌘⇧V), Clear history, Quit (⌘Q).

## Build & run

```sh
make        # builds Build/clipspot.app (ad-hoc signed)
make run    # build + open
make clean
```

Requires Xcode toolchain, arm64, macOS 14+.

## Permissions

- The synthetic paste-back (`paste`) posts a ⌘V `CGEvent` — macOS will
  ask for **Accessibility** the first time you paste from the shelf.
- Reading the clipboard requires no permission.

## Notes / limitations

- History is in-memory only (no persistence across restarts) — a
  deliberate v1 scope cut.
- Items are capped at 200 (`Store.capacity`); oldest unpinned evicted.
- No iCloud sync, no pinboard collections, no rules UI — see
  `rea/notes/paste.md` for the full Paste feature inventory this
  approximates.
- `paste as plain text` currently pastes the item as-is; RTF flattening
  is a TODO.
## Security & trust

- **Open source** — every byte of the release binary is produced from the
  commit you can read, by GitHub Actions (see the workflow run linked in
  each release). No opaque build steps.
- **Checksums** — every release ships `ClipSpot.dmg.sha256`. Verify:
  ```sh
  shasum -a 256 ClipSpot.dmg
  ```
- **No telemetry, no account, no network calls** — the app works fully
  offline; nothing leaves your Mac.
- **Permissions** — ClipSpot asks for none required — reads the pasteboard, which is a public API
  and nothing else.
- **Signed & notarized** — release builds are signed with a Developer ID
  certificate and notarized by Apple; macOS opens them with no Gatekeeper
  warning.
- **Prefer building yourself?** `git clone`, `make`, `make run` —
  no external dependencies, readable in one sitting.
