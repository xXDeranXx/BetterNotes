#!/bin/zsh
# Runs the tests the way the project's test rhythm wants (see SPEC.md, "Rules learned"):
#   scripts/test.sh fast <Suite> [<Suite> ...]   only these unit test suites (while building)
#   scripts/test.sh unit                         all unit tests, about 20 s (before each commit)
#   scripts/test.sh ui                           build, then the 2 UI tests, about 3 min (before an iPad handover)
# Prints only the summary lines. Always serial: parallel testing boots throwaway "Clone" simulators.
set -e
cd "$(dirname "$0")/../BetterNotes"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SIM="${SIM:-EACE8B60-A993-4FF0-98FF-2C86FA2F620D}"
DEST="platform=iOS Simulator,id=$SIM"
run() {
  xcodebuild "$@" -project BetterNotes.xcodeproj -scheme BetterNotes -destination "$DEST" -parallel-testing-enabled NO 2>&1 \
    | grep -E "✘|error: -|error:|Test run with|Test Case .*(passed|failed)|\*\* (TEST|BUILD)" | grep -v simctl || true
}
case "$1" in
  fast)
    shift
    [[ $# -gt 0 ]] || { echo "usage: scripts/test.sh fast <Suite> ..."; exit 1; }
    args=(); for suite in "$@"; do args+=("-only-testing:BetterNotesTests/$suite"); done
    run test "${args[@]}" ;;
  unit) run test -only-testing:BetterNotesTests ;;
  ui)
    run build
    run test -only-testing:BetterNotesUITests ;;
  *) echo "usage: scripts/test.sh fast <Suite>... | unit | ui"; exit 1 ;;
esac
