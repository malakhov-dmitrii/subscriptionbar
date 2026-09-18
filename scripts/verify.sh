#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/subscriptionbar-clang-cache"
swift test --disable-sandbox --scratch-path "${TMPDIR:-/tmp}/subscriptionbar-test-build"
node browser-extension/build-firefox.mjs
node --test browser-extension/*.test.mjs
node --check browser-extension/background.js
node --check browser-extension/popup.js
node --check browser-extension/firefox/background.js
node --check browser-extension/firefox/popup.js
bash -n scripts/package-app.sh scripts/install-browser-host.command
