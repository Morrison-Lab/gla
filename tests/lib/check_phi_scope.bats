#!/usr/bin/env bats
# =============================================================================
# Behavioral tests for templates/check-phi.yml's scan-scope resolution.
# =============================================================================
# The sibling check_phi_pin.bats matches template TEXT, which cannot see whether
# the logic actually produces the right base ref. These tests extract the real
# script block and run it against real git repositories, following the
# extraction pattern established by version_check_auth_header.bats.
#
# Run with: bats tests/lib/check_phi_scope.bats

setup() {
  TEMPLATE="$BATS_TEST_DIRNAME/../../templates/check-phi.yml"
  SCRIPT="$BATS_TEST_TMPDIR/scope.sh"
  # Block index 2 is the scope-resolution step (0 fetch, 1 checksum, 2 scope,
  # 3 allowlist, 4 run). Extracted rather than duplicated so the test cannot
  # drift from the template.
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-check-phi").fetch("script")[2]' \
    "$TEMPLATE" > "$SCRIPT"

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  git init --quiet --bare "$REMOTE"
  git init --quiet "$BATS_TEST_TMPDIR/seed"
  (
    cd "$BATS_TEST_TMPDIR/seed"
    git config user.email t@t.invalid
    git config user.name t
    git checkout --quiet -b main
    echo base > f.txt
    git add f.txt
    git commit --quiet -m base
    git checkout --quiet -b feature
    echo more >> f.txt
    git commit --quiet -am more
    git push --quiet "$REMOTE" main feature
  )
}

# run_scope -- run the extracted block in WORK, setting scope_status and
# scope_base.
#
# Deliberately NOT a value-returning helper called through $(...), and
# deliberately not a bats `run` target. A command substitution discards the exit
# status, so a script that crashed produced empty output -- which is exactly what
# the whole-tree cases assert, so they passed on a crash. Demonstrated with a
# script whose entire body is `exit 7`: it satisfied `[ -z "$(run_scope)" ]`.
#
# scope_base is set to a sentinel rather than "" when the file is missing, so
# "the script never wrote it" cannot be mistaken for "the script chose a
# whole-tree scan".
run_scope() {
  # The block derives its scratch dir as ${TMPDIR:-/tmp}/gla-phi-${CI_JOB_ID:-$$},
  # deliberately outside the checkout, so the test pins both to read it back.
  export TMPDIR="$BATS_TEST_TMPDIR" CI_JOB_ID=bats
  ( cd "$WORK" && bash "$SCRIPT" >/dev/null 2>&1 )
  scope_status=$?
  local ref_file="$BATS_TEST_TMPDIR/gla-phi-bats/base-ref"
  if [ -f "$ref_file" ]; then
    scope_base=$(cat "$ref_file")
  else
    scope_base="<file-not-written>"
  fi
}

@test "a tag pipeline resolves to a whole-tree scan" {
  git clone --quiet "$REMOTE" "$WORK"
  export CI_COMMIT_TAG=v1.0.0 CI_DEFAULT_BRANCH=main
  unset CI_COMMIT_BRANCH
  run_scope
  [ "$scope_status" -eq 0 ]
  # Empty base ref means the scanner scans the whole tracked tree.
  [ -z "$scope_base" ]
}

@test "the default branch resolves to a whole-tree scan" {
  git clone --quiet "$REMOTE" "$WORK"
  export CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main
  unset CI_COMMIT_TAG
  run_scope
  [ "$scope_status" -eq 0 ]
  [ -z "$scope_base" ]
}

@test "a feature branch resolves to a diff against the default branch" {
  git clone --quiet "$REMOTE" "$WORK"
  export CI_COMMIT_BRANCH=feature CI_DEFAULT_BRANCH=main
  unset CI_COMMIT_TAG
  run_scope
  [ "$scope_status" -eq 0 ]
  [ "$scope_base" = "origin/main" ]
}

@test "a single-branch clone still resolves the default branch" {
  # This is the case a GitLab runner actually produces, and the one a
  # `git fetch origin main` (no refspec) fails: the commit lands in FETCH_HEAD
  # only, refs/remotes/origin/main is never created, and the job silently
  # widens to a whole-tree scan instead of diffing.
  git clone --quiet --single-branch --branch feature "$REMOTE" "$WORK"
  run git -C "$WORK" rev-parse --verify --quiet origin/main
  [ "$status" -ne 0 ]   # precondition: origin/main is genuinely absent

  export CI_COMMIT_BRANCH=feature CI_DEFAULT_BRANCH=main
  unset CI_COMMIT_TAG
  run_scope
  [ "$scope_status" -eq 0 ]
  [ "$scope_base" = "origin/main" ]
}

@test "a stale remote-tracking ref does not license diff mode after a failed fetch" {
  # The existing unreachable-remote test deletes origin/main, so rev-parse fails
  # and the fallback is taken for the wrong reason. A REUSED workspace keeps a
  # stale origin/main from an earlier pipeline: rev-parse then succeeds, and
  # without gating on the fetch the job would diff against an outdated base
  # while the template documents a whole-tree scan.
  git clone --quiet "$REMOTE" "$WORK"
  git -C "$WORK" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  # Deliberately NOT deleting the ref -- that is the whole point.
  run git -C "$WORK" rev-parse --verify --quiet origin/main
  [ "$status" -eq 0 ]   # precondition: a stale origin/main is present

  export CI_COMMIT_BRANCH=feature CI_DEFAULT_BRANCH=main
  unset CI_COMMIT_TAG
  run_scope
  [ "$scope_status" -eq 0 ]
  [ -z "$scope_base" ]
}

@test "an unreachable default branch degrades to a whole-tree scan, not an error" {
  git clone --quiet "$REMOTE" "$WORK"
  git -C "$WORK" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  git -C "$WORK" update-ref -d refs/remotes/origin/main
  export CI_COMMIT_BRANCH=feature CI_DEFAULT_BRANCH=main
  unset CI_COMMIT_TAG
  run_scope
  # Widening is the safe direction: it scans more, never less -- but the script
  # must still succeed while doing it, not crash into an empty result.
  [ "$scope_status" -eq 0 ]
  [ -z "$scope_base" ]
}
