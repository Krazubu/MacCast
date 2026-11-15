#!/usr/bin/env bash
# Build and install "Cast Mirror.app" into /Applications, then open it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="/Applications/Cast Mirror.app"

"$root/scripts/build-app.sh"

osascript -e 'tell application id "com.github.castmirror.app" to quit' 2>/dev/null || true
pkill -f "Cast Mirror.app/Contents/MacOS/" 2>/dev/null || true

rm -rf "$dest"
cp -R "$root/build/Cast Mirror.app" "$dest"
open "$dest"
echo "installed $dest"
