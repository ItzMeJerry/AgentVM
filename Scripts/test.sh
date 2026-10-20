#!/usr/bin/env bash
#
# Runs the unit tests, AgentVMKit's and AgentVMLayout's.
#
#   bash Scripts/test.sh [extra swift test arguments...]
#
# They need no daemon, no VM and no network: they check the logic that stands
# on its own, against files of their own. Nothing in ~/.config/agentvm is read
# or written, and no container is created. The integration tests, which do
# talk to the daemon, run only when asked for:
#
#   AGENTVM_INTEGRATION=1 bash Scripts/test.sh --filter Integration
#
# CONTRIBUTING.md lists what each suite covers.
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
metal_on_path || exit 1

exec swift test "${SWIFT_PLUGIN_FLAGS[@]}" "$@"
