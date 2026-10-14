#!/bin/zsh
# PreToolUse hook: a shell command that builds or tests Swift code runs at a low scheduling priority,
# as scripts/build-priority.sh runs the scripts' own builds, so agents building at once leave the
# laptop usable. CI runs keep full speed.
[[ -z "${CI:-}" ]] || exit 0
command="$(jq -r '.tool_input.command // empty')"
[[ "$command" =~ '(^|[^[:alnum:]_-])(swift +(build|test)|xcodebuild)([^[:alnum:]_-]|$)' ]] || exit 0
[[ "$command" != "nice "* ]] || exit 0
jq -n --arg command "nice -n 15 /bin/zsh -c $(jq -rn --arg c "$command" '$c | @sh')" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: {command: $command}
  }
}'
