#!/usr/bin/env bash
#
# Runs the AgentVMKit test suite.
#
#   bash Scripts/test.sh [extra swift test arguments...]
#
# The tests need no daemon, no VM and no network: they cover the pure logic —
# port specs, the config file, the env registry, mount and name validation —
# against temporary directories only. Nothing in ~/.config/agentvm is read or
# written, and no container is created.
#
# AgentVM — https://github.com/ItzMeJerry/AgentVM
# Copyright 2026 Jerry Lan
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=Scripts/toolchain.sh
source "$ROOT/Scripts/toolchain.sh"
swift_plugin_flags

exec swift test "${SWIFT_PLUGIN_FLAGS[@]}" "$@"
