#!/usr/bin/env bash
#
# Shared toolchain detection, sourced by the other scripts in here.
# Written for bash 3.2, the bash macOS ships.
#
# SwiftUI's property wrappers (@State, @Binding, @Observable…) are macros now,
# and the plugin that expands them ships inside Xcode, not with the Command
# Line Tools. When the selected toolchain is a CLT one, the plugin is still
# there inside Xcode.app — it just isn't on the search path, so we add it.
# No `xcode-select`, no `sudo`.
#
# AgentVM — https://github.com/ItzMeJerry/AgentVM
# Copyright 2026 Jerry Lan
# SPDX-License-Identifier: Apache-2.0

# Sets SWIFT_PLUGIN_FLAGS to the -plugin-path flags `swift` needs, or to
# nothing when the selected toolchain already knows where its plugins are.
# Returns non-zero, with an explanation, when no plugin can be found at all.
#
#   swift_plugin_flags || exit 1
#   swift build "${SWIFT_PLUGIN_FLAGS[@]}"
# Where the running `swift` keeps its swift-testing macro plugin, or nothing.
_swift_toolchain_testing_plugins() {
    local binary directory
    binary="$(xcrun --find swift 2>/dev/null || command -v swift || true)"
    [ -n "$binary" ] || return 0
    directory="$(cd "$(dirname "$binary")/.." 2>/dev/null && pwd)/lib/swift/host/plugins/testing"
    [ -e "$directory/libTestingMacros.dylib" ] && printf '%s' "$directory"
    return 0
}

swift_plugin_flags() {
    SWIFT_PLUGIN_FLAGS=()

    local selected plugins
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$selected" ] && [ -e "$selected/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
        return 0
    fi

    for plugins in \
        "$selected/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
        /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
    do
        if [ -e "$plugins/libSwiftUIMacros.dylib" ]; then
            SWIFT_PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$plugins")
            # Naming a plugin path replaces the default search rather than
            # adding to it, so the toolchain's own swift-testing macros would
            # go missing and `swift test` would stop compiling. Put them back.
            local testing
            testing="$(_swift_toolchain_testing_plugins)"
            if [ -n "$testing" ]; then
                SWIFT_PLUGIN_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$testing")
            fi
            return 0
        fi
    done

    cat >&2 <<'MESSAGE'
error: no SwiftUI macro plugin (libSwiftUIMacros.dylib) found.

    SwiftUI's property wrappers are macros, and the plugin that expands them
    ships inside Xcode — the Command Line Tools alone are not enough.

    Install Xcode from the App Store, open it once to let it finish setting
    up, then try again. Scripts/doctor.sh reports what it finds.
MESSAGE
    return 1
}
