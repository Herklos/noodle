#!/bin/zsh
# Runs a build command: at full speed on CI, and elsewhere at a low scheduling priority, so it still
# uses every core and normal disk speed but gives way to the apps in front, keeping a laptop usable.
#   scripts/build-priority.sh xcodebuild ...
#   scripts/build-priority.sh swift build ...
set -euo pipefail
[[ -z "${CI:-}" ]] || exec "$@"
exec nice -n 15 "$@"
