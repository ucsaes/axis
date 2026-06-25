#!/bin/bash
# Personal install script for axis.
#
# Builds the axis CLI (SPM) and the Axis.app bundle (Xcode), then installs both
# and codesigns them. This deliberately SKIPS docs/shell-completion (build-release.sh),
# so asciidoctor/fish/bash5 are NOT required.
#
# Usage: git clone https://github.com/ucsaes/axis.git && cd axis && ./install.sh
#
# Codesigning:
#   - If a keychain identity named "aerospace-codesign-certificate" exists, it's used
#     (re-builds keep Accessibility permission -> no re-approval needed).
#   - Otherwise falls back to ad-hoc signing ("-"). Works, but macOS re-asks for
#     Accessibility permission after every rebuild.

set -euo pipefail
cd "$(dirname "$0")"

CERT="aerospace-codesign-certificate"
APP_DEST="/Applications/Axis.app"

# --- Preflight ----------------------------------------------------------------
if ! xcrun --find xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: xcodebuild not available." >&2
    echo "Install Xcode (App Store) and point the toolchain at it:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  sudo xcodebuild -license accept" >&2
    exit 1
fi

if command -v brew >/dev/null 2>&1; then
    BIN_DIR="$(brew --prefix)/bin"
else
    BIN_DIR="/usr/local/bin"
    echo "warning: brew not found, installing CLI to $BIN_DIR" >&2
fi

# Pick signing identity.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT"; then
    SIGN_ID="$CERT"
    echo "==> Using codesign identity: $CERT"
else
    SIGN_ID="-"
    echo "==> '$CERT' not found in keychain -> ad-hoc signing (Accessibility will re-prompt on rebuilds)"
fi

# --- Build --------------------------------------------------------------------
echo "==> Building axis CLI (swift build -c release)"
swift build -c release --product axis

echo "==> Building Axis.app (xcodebuild Release)"
xcodebuild \
    -project Axis.xcodeproj \
    -scheme Axis \
    -configuration Release \
    -derivedDataPath .xcode-build \
    CODE_SIGN_IDENTITY="-" \
    build

# --- Install ------------------------------------------------------------------
echo "==> Installing $APP_DEST"
rm -rf "$APP_DEST"
cp -R ".xcode-build/Build/Products/Release/Axis.app" "$APP_DEST"

echo "==> Installing CLI to $BIN_DIR/axis"
cp ".build/release/axis" "$BIN_DIR/axis"

# --- Sign ---------------------------------------------------------------------
echo "==> Codesigning (identity: $SIGN_ID)"
codesign -s "$SIGN_ID" -f "$APP_DEST"
codesign -s "$SIGN_ID" -f "$BIN_DIR/axis"

echo
echo "Done."
echo "  app: $APP_DEST"
echo "  cli: $BIN_DIR/axis"
echo "Launch Axis.app once and grant Accessibility permission in System Settings."
