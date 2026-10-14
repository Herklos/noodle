# Concurrent edits

Assume that multiple ai agents are editing this project. Don't get surprised.

# Commits

Committing is prohibited. Never commit, amend, push, tag or rewrite history unless
the user explicitly asks for it in that message. A documented process, a finished
task or an earlier approval is not permission. Stage changes only when asked.

# Release notes

Keep `CHANGELOG.md` current as part of every user-visible change. Add a concise entry under the appropriate heading in **Unreleased** in the same change; do not wait for release preparation to reconstruct it later.

No changelog entries for `website/` changes; they would trigger rebuilds.

Do not publish a release unless the user explicitly asks.

# Documentation

READMEs and `docs/` are for people using the apps. Code is documented only in
its own comments; follow the `no-code-docs` skill.

# Builds on this Mac

Run local builds and tests at low priority so the laptop stays usable:
prefix `swift build`, `swift test` and `xcodebuild` with `scripts/build-priority.sh`
(the repository's scripts already do). CI runs at full speed.
