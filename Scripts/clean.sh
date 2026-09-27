#!/usr/bin/env bash
#
# Removes build output.
#
#   bash Scripts/clean.sh          drops compiled output, keeps the resolved sources
#   bash Scripts/clean.sh --all    drops .build entirely, including the checkouts
#
# The checkouts are the cloned sources of apple/container and its dependency
# graph — about 650 MB, and the slow part of a first build. Keeping them turns
# a 15–30 minute clean build into a few minutes.
#
# AgentVM — https://github.com/ItzMeJerry/AgentVM
# Copyright 2026 Jerry Lan
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"

if [ ! -d "$BUILD" ]; then
    echo "nothing to clean: $BUILD does not exist"
    exit 0
fi

before="$(du -sh "$BUILD" 2>/dev/null | cut -f1)"

if [ "${1:-}" = "--all" ]; then
    rm -rf "$BUILD"
    echo "removed $BUILD ($before)"
    echo "the next build re-resolves and re-clones the package graph: budget 15–30 minutes."
else
    rm -rf "$BUILD/out" "$BUILD/debug" "$BUILD/release" "$BUILD/AgentVM.app" "$BUILD/artifacts"
    after="$(du -sh "$BUILD" 2>/dev/null | cut -f1)"
    echo "cleaned compiled output: $before → $after"
    echo "the checkouts are kept, so the next build only recompiles."
fi
