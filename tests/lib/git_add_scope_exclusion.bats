#!/usr/bin/env bats
# =============================================================================
# Regression tests for HACtions#48: `git add -A` must exclude .gitlab/scripts/
# =============================================================================
# .gitlab/scripts/ is HACtions' own runtime library. templates/claude.yml's
# before_script fetches it into the working tree of consumer repos that don't
# track those files locally. A bare `git add -A` in commit-push.sh,
# git-push-issue.sh, and the scope guard in apply-changes.sh swept it into
# every LLM-authored commit as unrelated stray files (17 of them, observed on
# a consumer repo MR). The fix replaces `git add -A` with
# `git add -A -- . ':!.gitlab/scripts'` at all three call sites.
#
# Run with: bats tests/lib/git_add_scope_exclusion.bats

setup() {
  LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../scripts/lib" && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  cd "$TEST_TMPDIR" || exit 1
  git init -q -b main .
  git config user.email "test@example.com"
  git config user.name "Test"
}

teardown() {
  cd / || true
  rm -rf "$TEST_TMPDIR"
}

# --- Core behavioral test: the pathspec itself ------------------------------

@test "git add -A with the exclusion pathspec stages real changes but not vendored scripts" {
  mkdir -p .gitlab/scripts/lib
  echo "vendored" > .gitlab/scripts/lib/commit-push.sh
  echo "real change" > README.md

  git add -A -- . ':!.gitlab/scripts'

  staged="$(git diff --cached --name-only)"
  [[ "$staged" == *"README.md"* ]]
  [[ "$staged" != *".gitlab/scripts"* ]]
}

@test "git add -A without the exclusion pathspec (pre-fix behavior) stages vendored scripts too" {
  # Demonstrates the bug this fix prevents: a bare `git add -A` sweeps up
  # .gitlab/scripts/ alongside real changes.
  mkdir -p .gitlab/scripts/lib
  echo "vendored" > .gitlab/scripts/lib/commit-push.sh
  echo "real change" > README.md

  git add -A

  staged="$(git diff --cached --name-only)"
  [[ "$staged" == *".gitlab/scripts/lib/commit-push.sh"* ]]
}

@test "the exclusion pathspec still stages files nested under other dot-directories" {
  # Guards against an overly broad exclusion pattern that accidentally
  # excludes more than .gitlab/scripts/.
  mkdir -p .gitlab/other-dir .gitlab/scripts
  echo "keep me" > .gitlab/other-dir/keep.txt
  echo "vendored" > .gitlab/scripts/vendored.sh

  git add -A -- . ':!.gitlab/scripts'

  staged="$(git diff --cached --name-only)"
  [[ "$staged" == *".gitlab/other-dir/keep.txt"* ]]
  [[ "$staged" != *".gitlab/scripts/vendored.sh"* ]]
}

# --- Static regression guards: each fixed call site keeps the exclusion ----

@test "apply-changes.sh scope guard excludes .gitlab/scripts from git add -A" {
  run grep -n "git add -A -- \. ':!.gitlab/scripts'" "$LIB_DIR/apply-changes.sh"
  [ "$status" -eq 0 ]
}

@test "commit-push.sh staging excludes .gitlab/scripts from git add -A" {
  run grep -n "git add -A -- \. ':!.gitlab/scripts'" "$LIB_DIR/commit-push.sh"
  [ "$status" -eq 0 ]
}

@test "git-push-issue.sh staging excludes .gitlab/scripts from git add -A" {
  run grep -n "git add -A -- \. ':!.gitlab/scripts'" "$LIB_DIR/git-push-issue.sh"
  [ "$status" -eq 0 ]
}

@test "no bare git add -A call sites remain in scripts/lib" {
  # A bare `git add -A` (no exclusion pathspec) would re-introduce the bug.
  # Every staging call in scripts/lib must carry the exclusion.
  run grep -rn "git add -A$" "$LIB_DIR"
  [ "$status" -ne 0 ]
}

# --- Integration test: the actual scope-guard function ----------------------

@test "_check_scope_guard does not flag vendored .gitlab/scripts as out-of-scope" {
  # shellcheck source=/dev/null
  source "$LIB_DIR/apply-changes.sh"
  log() { :; }  # silence logging helper (normally provided by logging.sh)

  mkdir -p .gitlab/scripts/lib
  echo "vendored" > .gitlab/scripts/lib/commit-push.sh
  echo "baseline" > README.md
  git add README.md
  git commit -q -m "baseline"
  echo "real change" >> README.md

  MR_DIFF_FILES="README.md"
  EDIT_FAILURES=""
  FILES_CHANGED=1

  _check_scope_guard

  [[ "$EDIT_FAILURES" != *".gitlab/scripts"* ]]
  [[ "$EDIT_FAILURES" != *"Scope warning"* ]]
}

@test "_check_scope_guard still flags genuinely out-of-scope files" {
  # shellcheck source=/dev/null
  source "$LIB_DIR/apply-changes.sh"
  log() { :; }

  echo "baseline" > README.md
  git add README.md
  git commit -q -m "baseline"
  echo "unexpected edit" > unrelated-file.txt

  MR_DIFF_FILES="README.md"
  EDIT_FAILURES=""
  FILES_CHANGED=1

  _check_scope_guard

  [[ "$EDIT_FAILURES" == *"unrelated-file.txt"* ]]
  [[ "$EDIT_FAILURES" == *"Scope warning"* ]]
}
