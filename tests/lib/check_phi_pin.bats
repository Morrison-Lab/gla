#!/usr/bin/env bats
# =============================================================================
# Regression tests for templates/check-phi.yml's supply-chain pins.
# =============================================================================
# check-phi.yml fetches a script from GitHub and EXECUTES it. Two properties
# make that safe, and both are easy to break silently when bumping the pin:
#
#   1. GLA_GHA_REF must be a full 40-hex commit SHA. A branch name (e.g. "main")
#      still fetches successfully and still passes CI, so nothing reports that
#      the pipeline has started executing unreviewed upstream code.
#   2. GLA_PHI_SHA256 must be a full 64-hex digest. An empty or malformed value
#      makes the template skip verification with only a log warning.
#
# These are offline checks: they assert the shape of what is pinned, not that
# the digest still matches upstream (that would need network access, and is
# what the job's own checksum step does at runtime).
#
# Run with: bats tests/lib/check_phi_pin.bats

TEMPLATE="templates/check-phi.yml"

# value_of KEY -- print the scalar assigned to KEY in the variables block.
# Quotes are optional: an unquoted `GLA_GHA_REF: main` is valid YAML, and a
# quote-only matcher would return nothing for it -- so the pin assertions would
# pass on an empty string rather than failing on a branch name.
value_of() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*[\"']\{0,1\}\([^\"'[:space:]]*\)[\"']\{0,1\}[[:space:]]*$/\1/p" \
    "$TEMPLATE" | head -n 1
}

@test "template file exists" {
  [ -f "$TEMPLATE" ]
}

@test "GLA_GHA_REF is a full 40-hex commit SHA, not a branch name" {
  run value_of GLA_GHA_REF
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Rejects "main", "v1", a short SHA, and any uppercase/typo'd digest.
  [[ "$output" =~ ^[0-9a-f]{40}$ ]]
}

@test "GLA_PHI_SHA256 is a full 64-hex digest" {
  run value_of GLA_PHI_SHA256
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "the fetch URL is built from the pinned ref, not a floating one" {
  # Guards against someone hardcoding /main/ into the URL while leaving
  # GLA_GHA_REF in place, which would make the pin cosmetic.
  run grep -c 'raw.githubusercontent.com/${GLA_GHA_REPO}/${GLA_GHA_REF}/' "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "the checksum is verified before the scanner is executed" {
  # Ordering is load-bearing: verifying after execution verifies nothing.
  verify_line=$(grep -n 'checksum mismatch' "$TEMPLATE" | cut -d: -f1)
  exec_line=$(grep -n 'python3 -u "\$PHI_TMP/check-phi.py"' "$TEMPLATE" | cut -d: -f1)
  [ -n "$verify_line" ]
  [ -n "$exec_line" ]
  [ "$verify_line" -lt "$exec_line" ]
}

@test "both the hidden job and its concrete job are defined" {
  grep -qx '\.gla-check-phi:' "$TEMPLATE"
  grep -qx 'check-phi:' "$TEMPLATE"
  grep -q 'extends: \.gla-check-phi' "$TEMPLATE"
}

@test "a failed fetch aborts rather than warning" {
  # A PHI scan that silently does not run leaves the pipeline green and
  # reports nothing, which reads as a clean result.
  grep -q 'Failed to fetch check-phi.py' "$TEMPLATE"
  grep -A6 'Failed to fetch check-phi.py' "$TEMPLATE" | grep -q 'exit 1'
}

@test "tag pipelines are admitted by the rules AND handled by scope resolution" {
  # These are two separate places, and fixing only the first is the mistake this
  # test exists to catch: adding the `$CI_COMMIT_TAG` rule makes the job RUN on a
  # tag, while scope resolution still compares CI_COMMIT_BRANCH (empty on tags)
  # against CI_DEFAULT_BRANCH, falls through to the else arm, and tries to diff
  # against a branch that the tag has no relationship to. The template documents
  # a whole-tree scan for tags, so the two would silently disagree.
  grep -q 'if: \$CI_COMMIT_TAG' "$TEMPLATE"
  grep -q 'if \[ -n "\${CI_COMMIT_TAG:-}" \]' "$TEMPLATE"
  # The tag arm must come first: the branch-equality test would otherwise
  # already have taken the else path.
  tag_line=$(grep -n 'if \[ -n "\${CI_COMMIT_TAG:-}" \]' "$TEMPLATE" | cut -d: -f1)
  branch_line=$(grep -n 'CI_COMMIT_BRANCH:-}" = "\${CI_DEFAULT_BRANCH' "$TEMPLATE" | cut -d: -f1)
  [ "$tag_line" -lt "$branch_line" ]
}

@test "no value crosses script blocks through a sourced shell file" {
  # Values were once written as KEY=VALUE into .gla-phi-env and sourced, so an
  # allowlist path containing a space was parsed as shell rather than used as a
  # path. Content files read with `cat` cannot do that.
  ! grep -qE '^\s+\.\s+\./\.gla-phi' "$TEMPLATE"
  grep -q 'cat "\$PHI_TMP/base-ref"' "$TEMPLATE"
  grep -q 'cat "\$PHI_TMP/allowlist"' "$TEMPLATE"
}

@test "no scratch file is written into the consumer's checkout" {
  # A fixed filename in the working tree would overwrite a consumer file tracked
  # at that path -- letting its real content evade a whole-tree scan -- and then
  # delete it on a reused shell-executor workspace.
  ! grep -qE '> \.gla-|-o \.gla-|rm -f \.gla-' "$TEMPLATE"
  grep -q 'PHI_TMP="\${TMPDIR:-/tmp}/gla-phi-\${CI_JOB_ID:-\$\$}"' "$TEMPLATE"
}

@test "consumer-tunable variables are top-level, not job-level" {
  # Job-level variables take precedence over a consumer's global block, so
  # defining these on the job would silently override the very thing the README
  # tells consumers to set. GIT_DEPTH is not consumer-tunable and stays on the job.
  top_level=$(sed -n '/^variables:/,/^$/p' "$TEMPLATE")
  for key in GLA_PHI_IMAGE GLA_GHA_REPO GLA_GHA_REF GLA_PHI_SHA256 \
             GLA_PHI_DETECTORS GLA_PHI_PATHS_IGNORE GLA_PHI_ALLOWLIST_FILE GLA_PHI_FAIL; do
    echo "$top_level" | grep -q "^  ${key}:" || {
      echo "expected ${key} in the top-level variables block" >&2
      return 1
    }
  done
  # And none of them may reappear under the job.
  job_block=$(sed -n '/^\.gla-check-phi:/,/^  before_script:/p' "$TEMPLATE")
  ! echo "$job_block" | grep -qE '^\s+GLA_(PHI|GHA)_'
}

@test "the job pins a real checkout, not just full history" {
  # GIT_DEPTH alone forces history, not a working tree. A consumer-level
  # GIT_STRATEGY: none or GIT_CHECKOUT: "false" would otherwise leave the
  # scanner walking an absent tree and reporting nothing -- a green PHI scan
  # that examined zero files.
  job_block=$(sed -n '/^\.gla-check-phi:/,/^  rules:/p' "$TEMPLATE")
  echo "$job_block" | grep -q 'GIT_STRATEGY: clone'
  echo "$job_block" | grep -q 'GIT_CHECKOUT: "true"'
  echo "$job_block" | grep -q 'GIT_DEPTH: 0'
}
