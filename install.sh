#!/bin/sh
# Build release, wrap in .app, ad-hoc sign, install to /Applications, set as default .jsonl/.ndjson viewer.
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error:|Build complete" || true
APP=/Applications/JSONLReader.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/JSONLReader "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.dylanjung.JSONLReader</string>
  <key>CFBundleName</key><string>JSONL Reader</string>
  <key>CFBundleExecutable</key><string>JSONLReader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>JSON Lines</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>dev.dylanjung.jsonl</string><string>public.ndjson</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>JSON</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.json</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key><array>
    <dict>
      <key>UTTypeIdentifier</key><string>dev.dylanjung.jsonl</string>
      <key>UTTypeDescription</key><string>JSON Lines</string>
      <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
      <key>UTTypeTagSpecification</key><dict>
        <key>public.filename-extension</key><array><string>jsonl</string><string>ndjson</string></array>
      </dict>
    </dict>
  </array>
</dict></plist>
PLIST
# Quick Look preview extension
EXT="$APP/Contents/PlugIns/JSONLQuickLook.appex"
mkdir -p "$EXT/Contents/MacOS"
cp .build/release/JSONLQuickLook "$EXT/Contents/MacOS/"
cat > "$EXT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.dylanjung.JSONLReader.QuickLook</string>
  <key>CFBundleName</key><string>JSONL Quick Look</string>
  <key>CFBundleExecutable</key><string>JSONLQuickLook</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.preview</string>
    <key>NSExtensionPrincipalClass</key><string>PreviewViewController</string>
    <key>NSExtensionAttributes</key><dict>
      <key>QLSupportedContentTypes</key><array>
        <string>dev.dylanjung.jsonl</string><string>public.ndjson</string><string>public.json</string>
      </array>
      <key>QLSupportsSearchableItems</key><false/>
    </dict>
  </dict>
</dict></plist>
PLIST
codesign --force --sign - --entitlements Resources/QuickLook.entitlements "$EXT"
codesign --force --sign - "$APP"
pluginkit -a "$EXT" 2>/dev/null || true
pluginkit -e use -i dev.dylanjung.JSONLReader.QuickLook 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# Set default handler (jsonl, ndjson, json). NSWorkspace API needs a run loop, so a tiny Swift script.
cat > /tmp/setdefault.swift <<'SWIFT'
import AppKit
import UniformTypeIdentifiers
let app = URL(fileURLWithPath: "/Applications/JSONLReader.app")
var left = 0
for ext in ["jsonl", "ndjson", "json"] {
    guard let t = UTType(filenameExtension: ext) else { print("\(ext): no UTType"); continue }
    left += 1
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) { err in
        print("\(ext) (\(t.identifier)): \(err.map { "\($0)" } ?? "default set")")
        left -= 1
    }
}
while left > 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
SWIFT
swift /tmp/setdefault.swift
echo "Installed: $APP"
