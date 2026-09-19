# JSONL Reader

A fast, offline, native macOS viewer for `.jsonl` / `.ndjson` / `.json` files — built for data scientists who need to eyeball multi-GB datasets without waiting.

- Opens a 1 GB file in ~1 s. The file is memory-mapped; only newline offsets live in RAM.
- One record per row on the left, pretty-printed (or raw) JSON on the right.
- Broken lines are flagged ⚠ and counted, never silently skipped.
- Search (`⌘F`, Enter), go-to-line, copy (`⇧⌘C`), Pretty/Raw toggle.
- `.json` files: a top-level array shows one row per element; anything else is a single record.
- Quick Look: press Space on a `.jsonl` / `.ndjson` / `.json` file in Finder to see the record count, the keys with their types, and record [0] pretty-printed.
- Zero dependencies. Swift + SwiftUI. macOS 14+.

## Install

```sh
git clone https://github.com/<you>/jsonl-reader && cd jsonl-reader
./install.sh
```

This builds a release binary, wraps it as `/Applications/JSONLReader.app` with the Quick Look extension inside, ad-hoc signs it, and asks macOS to make it the default app for `.jsonl`, `.ndjson` and `.json`. Approve the dialog if one appears. If Quick Look does not pick it up, enable it under System Settings › General › Login Items & Extensions › Quick Look.

## Develop

```sh
swift build && .build/debug/JSONLReader           # run
.build/debug/JSONLReader --check                  # self-test
swift build -c release && .build/release/JSONLReader --bench big.jsonl   # index/search timing
```

## Layout

```
Sources/JSONLCore/       mmap'd file + line index, JSON node tree, one-line record preview
Sources/JSONLReader/     the app (SwiftUI shell, NSOutlineView tree, detail pane)
Sources/JSONLQuickLook/  Quick Look preview extension
Resources/               app icon (make-icon.swift regenerates AppIcon.icns), entitlements
install.sh               build → .app + .appex → sign → install → register defaults
```

## Not yet

Tree view, jq filter, table view, `.gz`, editing. See `PRD.md`.
