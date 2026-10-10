#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build --disable-sandbox
bin_dir=$(swift build --show-bin-path)
app_dir="$PWD/ChessArena.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/ChessArena" "$app_dir/Contents/MacOS/ChessArena"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.chessarena.broadcast</string>
<key>CFBundleName</key><string>ChessArena</string>
<key>CFBundleDisplayName</key><string>ChessArena</string>
<key>CFBundleExecutable</key><string>ChessArena</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
print "Ready: $app_dir"
