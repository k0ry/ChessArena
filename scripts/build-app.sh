#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build --disable-sandbox
./scripts/build-icon.sh
bin_dir=$(swift build --show-bin-path)
app_dir="$PWD/ChessArena.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$bin_dir/ChessArena" "$app_dir/Contents/MacOS/ChessArena.next"
mv "$app_dir/Contents/MacOS/ChessArena.next" "$app_dir/Contents/MacOS/ChessArena"
cp Assets/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cp scripts/qwen-server.py "$app_dir/Contents/Resources/qwen-server.py"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.chessarena.broadcast</string>
<key>CFBundleName</key><string>ChessArena</string>
<key>CFBundleDisplayName</key><string>ChessArena</string>
<key>CFBundleExecutable</key><string>ChessArena</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
touch "$app_dir"
print "Ready: $app_dir"
