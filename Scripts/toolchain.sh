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

# Puts Xcode's Metal compiler on PATH. SwiftTerm ships a Metal shader, and
# SwiftPM compiles it by running `metal` by name — which a Command Line Tools
# toolchain doesn't have. The compiler is an optional Xcode component
# (`xcodebuild -downloadComponent MetalToolchain`); once installed, Xcode's
# xcrun finds it even while the CLT stays selected. Sets METAL_COMPILER to its
# path, or returns non-zero with an explanation.
metal_on_path() {
    local compiler xcode
    compiler="$(command -v metal || xcrun --find metal 2>/dev/null || true)"
    if [ -z "$compiler" ]; then
        for xcode in /Applications/Xcode*.app/Contents/Developer; do
            [ -d "$xcode" ] || continue
            compiler="$(DEVELOPER_DIR="$xcode" xcrun --find metal 2>/dev/null || true)"
            [ -n "$compiler" ] && break
        done
    fi
    if [ -n "$compiler" ] && [ -x "$compiler" ]; then
        METAL_COMPILER="$compiler"
        case ":$PATH:" in
            *":$(dirname "$compiler"):"*) ;;
            *) export PATH="$(dirname "$compiler"):$PATH" ;;
        esac
        return 0
    fi

    cat >&2 <<'MESSAGE'
error: no Metal compiler (metal) found.

    The terminal library, SwiftTerm, ships a Metal shader, and compiling it
    needs Xcode's Metal toolchain — an optional component. Install it once:

        sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept
        /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -downloadComponent MetalToolchain

    (The full path matters: a plain `xcodebuild` refuses to run while the
    Command Line Tools are the selected toolchain.)

    Scripts/doctor.sh reports what it finds.
MESSAGE
    return 1
}
