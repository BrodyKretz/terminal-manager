#!/usr/bin/env bash
# Builds "build/Terminal Manager.app": the release binary and the hook helper next to it, Info.plist with the
# version from Version.swift, the web UI, then a signature (ad-hoc unless TM_SIGN_IDENTITY names a codesign
# identity). No Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*static let string = "\([^"]*\)".*/\1/p' Sources/TerminalManager/Version.swift)"
[ -n "$VERSION" ] || { echo "build.sh: no version in Sources/TerminalManager/Version.swift" >&2; exit 1; }
[ -f web/index.html ] || { echo "build.sh: web/index.html is missing" >&2; exit 1; }

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Terminal Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/terminal-manager" "$APP/Contents/MacOS/terminal-manager"
cp "$BIN_DIR/terminal-manager-hook" "$APP/Contents/MacOS/terminal-manager-hook"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
rsync -a --exclude test --exclude .DS_Store web/ "$APP/Contents/Resources/web/"

# Nested code is signed before the bundle that holds it.
IDENTITY="${TM_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/MacOS/terminal-manager-hook"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "built: $(pwd)/$APP (version $VERSION, signed: ${TM_SIGN_IDENTITY:-ad-hoc})"
