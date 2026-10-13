#!/bin/zsh
# Runs a build command: at full speed on CI, and elsewhere at background priority, which keeps it on
# the efficiency cores, with fewer compile jobs at once, so a laptop stays usable while it builds.
#   scripts/build-priority.sh xcodebuild ...
#   scripts/build-priority.sh swift build ...
set -euo pipefail
[[ -z "${CI:-}" ]] || exec "$@"
case "$1 ${2:-}" in
    "xcodebuild "*) set -- "$1" -jobs 4 "${@:2}" ;;
    "swift build" | "swift test") set -- "$1" "$2" --jobs 4 "${@:3}" ;;
esac
exec taskpolicy -b "$@"
