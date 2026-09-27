#!/usr/bin/env bash
#
# Builds AgentVM.app from the SwiftPM executable.
#
#   bash Scripts/build-app.sh [debug|release]   (default: release)
#
# The result is .build/AgentVM.app — a normal, unsandboxed macOS app. It is NOT
# sandboxed on purpose: it talks to the container daemon over XPC and mounts
# directories you pick, neither of which a sandboxed app can do.
#
# Set AGENTVM_SKIP_DOCTOR=1 to skip the preflight checks.
# Written for bash 3.2, the bash macOS ships.
#
# AgentVM — https://github.com/ItzMeJerry/AgentVM
# Copyright 2026 Jerry Lan
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "usage: $(basename "$0") [debug|release]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/AgentVM.app"
VERSION="2.0.0"

cd "$ROOT"

# Say why a build is about to fail, before it spends ten minutes failing.
if [ "${AGENTVM_SKIP_DOCTOR:-0}" != "1" ]; then
    bash "$ROOT/Scripts/doctor.sh" --quiet || exit 1
fi

# shellcheck source=Scripts/toolchain.sh
source "$ROOT/Scripts/toolchain.sh"
swift_plugin_flags

swift build -c "$CONFIGURATION" --product agentvm-gui "${SWIFT_PLUGIN_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIGURATION" --product agentvm-gui "${SWIFT_PLUGIN_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/agentvm-gui"

if [ ! -x "$BINARY" ]; then
    echo "error: swift build reported success but produced no binary at $BINARY" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AgentVM"

# SwiftPM resource bundles. Bundle.module finds them next to the executable or
# in Resources; put them in Resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>AgentVM</string>
    <key>CFBundleDisplayName</key>     <string>AgentVM</string>
    <key>CFBundleExecutable</key>      <string>AgentVM</string>
    <key>CFBundleIdentifier</key>      <string>io.github.itzmejerry.agentvm</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local use, and it keeps the XPC client happy.
codesign --force --sign - "$APP" >/dev/null 2>&1 ||
    echo "warning: could not ad-hoc sign $APP (it will still run)" >&2

# A bundle that does not validate will not launch, so say so here rather than
# letting Finder fail silently.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "warning: $APP does not pass signature verification" >&2
fi
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "error: $APP/Contents/Info.plist is not readable as a plist" >&2
    exit 1
fi

echo "$APP"
