#!/usr/bin/env bash
# Build "build/Cast Mirror.app" (menu bar app, also usable from the command line).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="0.1.0"
app="build/Cast Mirror.app"
contents="$app/Contents"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" \
  -import-objc-header Sources/CGVirtualDisplay.h \
  -o "$contents/MacOS/CastMirror" Sources/*.swift

cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>fr</string>
	</array>
	<key>CFBundleIdentifier</key>
	<string>com.github.castmirror.app</string>
	<key>CFBundleName</key>
	<string>Cast Mirror</string>
	<key>CFBundleDisplayName</key>
	<string>Cast Mirror</string>
	<key>CFBundleExecutable</key>
	<string>CastMirror</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Cast Mirror looks for Cast devices on the local network and sends them the picture of your screen.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_googlecast._tcp</string>
	</array>
</dict>
</plist>
EOF

# Translations (English is the text in the code, French in fr.lproj).
cp -R Resources/*.lproj "$contents/Resources/"

codesign --force --sign - --identifier com.github.castmirror.app "$app"
codesign --verify --strict "$app"
echo "built $app"
