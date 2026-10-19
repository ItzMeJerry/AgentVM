#!/usr/bin/env bash
#
# Checks that this machine can build and run AgentVM, and says what to do about
# anything it can't.
#
#   bash Scripts/doctor.sh            full report
#   bash Scripts/doctor.sh --quiet    print only problems; silent when all is well
#
# Exit status: 0 when everything needed to build is present, 1 otherwise.
# Written for bash 3.2, the bash macOS ships.
#
# AgentVM — https://github.com/ItzMeJerry/AgentVM
# Copyright 2026 Jerry Lan
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

FAILURES=0
WARNINGS=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; DIM=''; OFF=''
fi

# ok NAME DETAIL — a requirement that is satisfied.
ok() {
    [ "$QUIET" -eq 1 ] && return 0
    printf '  %s✓%s %-22s %s%s%s\n' "$GREEN" "$OFF" "$1" "$DIM" "${2:-}" "$OFF"
}

# warn NAME DETAIL [FIX...] — not needed to build, but you will want it.
warn() {
    WARNINGS=$((WARNINGS + 1))
    printf '  %s!%s %-22s %s\n' "$YELLOW" "$OFF" "$1" "${2:-}"
    shift 2 2>/dev/null || shift $#
    for line in "$@"; do printf '      %s%s%s\n' "$DIM" "$line" "$OFF"; done
}

# fail NAME DETAIL [FIX...] — the build cannot proceed.
fail() {
    FAILURES=$((FAILURES + 1))
    printf '  %s✗%s %-22s %s\n' "$RED" "$OFF" "$1" "${2:-}"
    shift 2 2>/dev/null || shift $#
    for line in "$@"; do printf '      %s%s%s\n' "$DIM" "$line" "$OFF"; done
}

heading() {
    [ "$QUIET" -eq 1 ] && return 0
    printf '\n%s\n' "$1"
}

# ---------------------------------------------------------------- the machine

heading "Machine"

MACOS="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="${MACOS%%.*}"
if [ "$MACOS_MAJOR" -ge 26 ] 2>/dev/null; then
    ok "macOS" "$MACOS"
else
    fail "macOS" "$MACOS — AgentVM needs macOS 26 or later" \
        "A host-only network (the killswitch) cannot be built on macOS 15 or earlier."
fi

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
    ok "Architecture" "$ARCH"
else
    fail "Architecture" "$ARCH — apple/container needs Apple Silicon"
fi

# A clean build writes roughly 4 GB into .build.
AVAILABLE_KB="$(df -k "$ROOT" | awk 'NR==2 {print $4}')"
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
if [ "$AVAILABLE_GB" -ge 8 ]; then
    ok "Free disk space" "${AVAILABLE_GB} GB"
elif [ "$AVAILABLE_GB" -ge 5 ]; then
    warn "Free disk space" "${AVAILABLE_GB} GB — enough, but not much to spare" \
        "A clean build writes about 4 GB into .build/."
else
    fail "Free disk space" "${AVAILABLE_GB} GB — a clean build needs about 4 GB" \
        "Free some space, or run bash Scripts/clean.sh to drop an old build."
fi

# -------------------------------------------------------------- the toolchain

heading "Toolchain"

if command -v swift >/dev/null 2>&1; then
    SWIFT_VERSION="$(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)"
    SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
    SWIFT_MINOR="$(printf '%s' "${SWIFT_VERSION#*.}" | cut -d. -f1)"
    if [ "${SWIFT_MAJOR:-0}" -gt 6 ] 2>/dev/null ||
        { [ "${SWIFT_MAJOR:-0}" -eq 6 ] && [ "${SWIFT_MINOR:-0}" -ge 2 ]; } 2>/dev/null; then
        ok "Swift" "$SWIFT_VERSION"
    else
        fail "Swift" "${SWIFT_VERSION:-unknown} — Package.swift needs swift-tools 6.2" \
            "Install a newer Xcode, or the matching Command Line Tools."
    fi
else
    fail "Swift" "not found" \
        "xcode-select --install, or install Xcode from the App Store."
fi

SELECTED="$(xcode-select -p 2>/dev/null || true)"
if [ -n "$SELECTED" ]; then
    ok "Selected toolchain" "$SELECTED"
else
    fail "Selected toolchain" "xcode-select reports nothing" \
        "xcode-select --install"
fi

# SwiftUI's property wrappers are macros; their plugin ships inside Xcode only.
# Scripts/build-app.sh points the compiler at it, so the CLT alone is fine as
# long as Xcode is installed somewhere.
# shellcheck source=Scripts/toolchain.sh
source "$ROOT/Scripts/toolchain.sh"
if swift_plugin_flags 2>/dev/null; then
    if [ "${#SWIFT_PLUGIN_FLAGS[@]}" -eq 0 ]; then
        ok "SwiftUI macro plugin" "in the selected toolchain"
    else
        ok "SwiftUI macro plugin" "${SWIFT_PLUGIN_FLAGS[3]}"
    fi
else
    fail "SwiftUI macro plugin" "libSwiftUIMacros.dylib not found" \
        "SwiftUI's @State and friends are macros, and the plugin that expands" \
        "them ships inside Xcode — the Command Line Tools are not enough." \
        "Install Xcode from the App Store and open it once."
fi

# SwiftTerm, the terminal library, ships a Metal shader that the build compiles.
if metal_on_path 2>/dev/null; then
    ok "Metal compiler" "$METAL_COMPILER"
else
    fail "Metal compiler" "not installed — the terminal library ships a Metal shader" \
        "sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept" \
        "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -downloadComponent MetalToolchain"
fi

# ------------------------------------------------------------- runtime pieces

heading "To run it (not needed to build)"

if command -v container >/dev/null 2>&1; then
    CONTAINER_VERSION="$(container --version 2>/dev/null | head -1)"
    ok "container" "${CONTAINER_VERSION:-installed}"
    case "$CONTAINER_VERSION" in
        *1.3*) ;;
        "") ;;
        *) warn "container version" "$CONTAINER_VERSION" \
            "Package.swift pins the client libraries to container 1.3.0. The XPC" \
            "routes are versioned with the release, so a different daemon may" \
            "refuse to talk to this build. Change the pin to match, or install 1.3.0." ;;
    esac
else
    warn "container" "not installed" \
        "brew install apple/tap/container" \
        "The app builds without it, but has no daemon to talk to."
fi

APP_ROOT="$HOME/Library/Application Support/com.apple.container"
if [ -d "$APP_ROOT/apiserver" ]; then
    ok "container app root" "$APP_ROOT"
else
    warn "container app root" "not set up yet" \
        "container system start"
fi

# ---------------------------------------------------------------------- verdict

if [ "$QUIET" -eq 1 ]; then
    [ "$FAILURES" -eq 0 ] && exit 0
    printf '\n%sScripts/doctor.sh found %d problem(s) that stop the build.%s\n' "$RED" "$FAILURES" "$OFF" >&2
    exit 1
fi

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
    printf '%s%d problem(s) stop the build.%s\n' "$RED" "$FAILURES" "$OFF"
    exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
    printf '%sReady to build. %d thing(s) to look at before running it.%s\n' "$YELLOW" "$WARNINGS" "$OFF"
else
    printf '%sReady to build.%s\n' "$GREEN" "$OFF"
fi
printf '%s  bash Scripts/build-app.sh    builds .build/AgentVM.app%s\n' "$DIM" "$OFF"
printf '%s  bash Scripts/test.sh         runs the AgentVMKit tests%s\n' "$DIM" "$OFF"
exit 0
