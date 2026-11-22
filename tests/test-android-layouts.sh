#!/usr/bin/env bash
set -eu
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.."
node --test tests/android-layouts.test.mjs
