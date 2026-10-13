#!/bin/zsh
# PreToolUse hook: a shell command that builds or tests Swift code runs at background priority,
# as scripts/build-priority.sh runs the scripts' own builds, so agents building at once leave the
# laptop usable. CI runs keep full speed.
[[ -z "${CI:-}" ]] || exit 0
command="$(jq -r '.tool_input.command // empty')"
[[ "$command" =~ '(^|[^[:alnum:]_-])(swift +(build|test)|xcodebuild)([^[:alnum:]_-]|$)' ]] || exit 0
[[ "$command" != "taskpolicy "* ]] || exit 0
jq -n --arg command "taskpolicy -b /bin/zsh -c $(jq -rn --arg c "$command" '$c | @sh')" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: {command: $command},
    additionalContext: "This build runs at background priority on the efficiency cores, so it is slower than usual."
  }
}'
