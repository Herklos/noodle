#!/usr/bin/env python3
"""Choose the test suites a run of "Validate and release versions" needs.

A push to main that only lands a pull request whose last run passed CI runs none: that pull request
already ran them. A release pull request, changing only VERSION and CHANGELOG.md files, runs none either:
the release run on main tests everything before publishing. Releases, other pull requests, manual runs
and every other push run all of them. The result is the JSON list `suites`: "checks" for the checks job
and NAME for each test-NAME job.
"""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent

EVERYTHING = ["checks", "noodle", "shared", "noodle-macos27", "computer", "applet", "applet-rendering", "bridge",
              "browser", "hub", "mobile"]


def git(*args, root=ROOT):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def resolves(revision, root=ROOT):
    try:
        return subprocess.run(["git", "rev-parse", "--verify", "--quiet", revision + "^{commit}"], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def tested_merge(repository, sha, before, root=ROOT):
    """Whether this push only lands one pull request, merged or squashed, whose last CI run passed."""
    try:
        # Exactly one new commit on main, so nothing else rides along with the pull request.
        if not resolves(before, root) or not resolves("HEAD^1", root) or git("rev-parse", "HEAD^1", root=root) != git(
                "rev-parse", before + "^{commit}", root=root) or git("rev-parse", "HEAD", root=root) != sha:
            return False
        pulls = [pull for pull in gh(f"repos/{repository}/commits/{sha}/pulls")
                 if pull.get("merged_at") and pull.get("merge_commit_sha") == sha
                 and pull["base"]["ref"] == "main"]
        if len(pulls) != 1:
            return False
        head = pulls[0]["head"]["sha"]
        runs = gh(f"repos/{repository}/commits/{head}/check-runs?check_name=CI%20passed&filter=latest")["check_runs"]
        runs = [run for run in runs if run.get("app", {}).get("slug") == "github-actions"]
        latest = max(runs, key=lambda run: run.get("started_at") or "", default=None)
        return bool(latest) and latest.get("status") == "completed" and latest.get("conclusion") == "success"
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, TypeError):
        return False


def release_only(paths):
    """Whether a change only sets versions and their release notes, as a release pull request does."""
    return bool(paths) and all(path.rsplit("/", 1)[-1] in ("VERSION", "CHANGELOG.md") for path in paths)


def scope(environment, root=ROOT):
    event = environment.get("GITHUB_EVENT_NAME", "")
    # A release pull request: the versions job has checked its notes, and the release run on main
    # tests everything before anything is published.
    if event == "pull_request" and resolves("HEAD^2", root) and release_only(
            git("diff", "--name-only", "--no-renames", "HEAD^1", "HEAD", root=root).splitlines()):
        return [], "a release pull request: the release run on main tests every suite before publishing"
    if environment.get("RELEASE") == "true":
        return list(EVERYTHING), "a release is being validated: every suite runs"
    if event == "push" and tested_merge(environment.get("GITHUB_REPOSITORY", ""), environment.get("GITHUB_SHA", ""),
                                        environment.get("BEFORE", ""), root):
        return [], "this merges a pull request that passed CI: no suite runs again"
    return list(EVERYTHING), "every suite runs"


def main():
    suites, reason = scope(os.environ)
    output = f"suites={json.dumps(suites)}\n"
    print(output + reason)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write(f"Test suites: {', '.join(suites) or 'none'} ({reason}).\n")


if __name__ == "__main__":
    main()
