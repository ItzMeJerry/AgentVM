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
metal_on_path || exit 1

swift build -c "$CONFIGURATION" --product agentvm-gui "${SWIFT_PLUGIN_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIGURATION" --product agentvm-gui "${SWIFT_PLUGIN_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/agentvm-gui"

if [ ! -x "$BINARY" ]; then
    echo "error: swift build reported success but produced no binary at $BINARY" >&2
    exit 1
fi

# SwiftTerm's Metal renderer loads the app's default Metal library before its
# own, so AgentVM's copy of its shaders goes there: the one change in it is how
# dark text is blended (see the file). Being a copy, it has to match the
# SwiftTerm it was copied from, which this checks first. Both happen before
# the app already built is touched, so a failure leaves that one working.
SHADERS="$ROOT/Sources/AgentVMApp/Shaders/TerminalShaders.metal"
UPSTREAM_SHADERS="$ROOT/.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal"
UPSTREAM_SHADERS_SHA256="5f9f1d64f238821d11e4eda5f33c933d85d4e7f124a2c3bd8a930f8726b2fc12" # SwiftTerm 1.20.0
if [ ! -f "$UPSTREAM_SHADERS" ] ||
    [ "$(shasum -a 256 "$UPSTREAM_SHADERS" | cut -d ' ' -f 1)" != "$UPSTREAM_SHADERS_SHA256" ]; then
    cat >&2 <<MESSAGE
error: SwiftTerm's Metal shaders are not the ones AgentVM's copy was made from.

    $UPSTREAM_SHADERS
    differs from SwiftTerm 1.20.0's. After a SwiftTerm upgrade, copy it over
    Sources/AgentVMApp/Shaders/TerminalShaders.metal, make the change marked
    "AgentVM:" in terminal_text_fragment_gray again, and put the new file's
    SHA-256 in this script.
MESSAGE
    exit 1
fi
SHADER_BUILD="$(mktemp -d)"
trap 'rm -rf "$SHADER_BUILD"' EXIT
xcrun -sdk macosx metal -c "$SHADERS" -o "$SHADER_BUILD/TerminalShaders.air"
xcrun -sdk macosx metallib "$SHADER_BUILD/TerminalShaders.air" -o "$SHADER_BUILD/default.metallib"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AgentVM"
cp "$SHADER_BUILD/default.metallib" "$APP/Contents/Resources/default.metallib"

# Symbols are more than half of a release binary — 38 of its 68 MB — and
# nothing reads them at run time. SwiftPM keeps them in
# .build/release/agentvm-gui.dSYM, which still symbolicates a crash report:
# stripping leaves the binary's UUID as it was. A debug build keeps them.
if [ "$CONFIGURATION" = "release" ]; then
    codesign --remove-signature "$APP/Contents/MacOS/AgentVM"
    xcrun strip "$APP/Contents/MacOS/AgentVM"
fi

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
