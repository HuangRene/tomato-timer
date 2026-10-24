#!/bin/bash
# Builds the app, copies it to /Applications and launches it.
# The first launch from /Applications turns on "open at login".
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
pkill -x TomatoTimer || true
rm -rf /Applications/TomatoTimer.app
cp -R build/TomatoTimer.app /Applications/
open /Applications/TomatoTimer.app
echo "Installed /Applications/TomatoTimer.app"
