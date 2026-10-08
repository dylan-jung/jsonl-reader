# JSONL Reader

A fast, offline, native macOS viewer for `.jsonl` / `.ndjson` / `.json` files — built for data scientists who need to eyeball multi-GB datasets without waiting.

- The file is memory-mapped and indexed in the background; the list fills in as indexing goes. The index keeps one offset per 64 KB of file, so even a 500 GB file needs ~120 MB of RAM.
- One record per row on the left (an NSTableView, so billions of rows scroll like twenty), the selected record's tree in the middle, pretty-printed JSON in the detail pane.
- Broken lines are flagged ⚠ and counted, never silently skipped.
- Search (`⌘F`, Enter) scans the mapped bytes on all cores; a new search cancels the running one. Go-to-record, copy.
- `.json` files: a top-level array shows one row per element; an object is one record, or one row per member when the file is over 256 MB. Records are found by walking bytes, never by parsing the whole file. Records over 256 MB are shown as raw text, not parsed.
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
Sources/JSONLReader/     the app (SwiftUI shell, NSTableView record list, NSOutlineView tree, detail pane)
Sources/JSONLQuickLook/  Quick Look preview extension
Resources/               app icon (make-icon.swift regenerates AppIcon.icns), entitlements
install.sh               build → .app + .appex → sign → install → register defaults
```

## Not yet

jq filter, table view, `.gz`, editing. See `PRD.md`.
