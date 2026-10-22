#!/usr/bin/env bats
# =============================================================================
# Regression tests for templates/check-new-line-breaks.yml supply-chain pins.
# =============================================================================

TEMPLATE="templates/check-new-line-breaks.yml"

value_of() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*[\"']\{0,1\}\([^\"'[:space:]]*\)[\"']\{0,1\}[[:space:]]*$/\1/p" \
    "$TEMPLATE" | head -n 1
}

@test "nlb template file exists" {
  [ -f "$TEMPLATE" ]
}

@test "HAC_NLB_REF is a full 40-hex commit SHA, not a branch name" {
  run value_of HAC_NLB_REF
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ ^[0-9a-f]{40}$ ]]
}

@test "HAC_NLB_SHA256 is a full 64-hex digest" {
  run value_of HAC_NLB_SHA256
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "the nlb fetch query uses TARGET_REF parameter" {
  run grep -c 'ref=\${TARGET_REF}' "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "the nlb checksum is verified before the script is executed" {
  verify_line=$(grep -n 'checksum mismatch' "$TEMPLATE" | cut -d: -f1)
  exec_line=$(grep -n 'python3 "\$SCRIPT_PATH"' "$TEMPLATE" | cut -d: -f1)
  [ -n "$verify_line" ]
  [ -n "$exec_line" ]
  [ "$verify_line" -lt "$exec_line" ]
}

@test "both the hidden job and its concrete job are defined for nlb" {
  run grep -c '^\.hac-check-new-line-breaks:' "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run grep -c '^check-new-line-breaks:' "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "HAC_NLB_SHA256 matches canonical scripts/check-new-line-breaks.py checksum" {
  run value_of HAC_NLB_SHA256
  [ "$status" -eq 0 ]
  pinned_sha="$output"
  actual_sha=$(sha256sum scripts/check-new-line-breaks.py | awk '{print $1}')
  [ "$pinned_sha" = "$actual_sha" ]
}

@test "HAC_NLB_REF in git repository contains the script matching HAC_NLB_SHA256" {
  run value_of HAC_NLB_REF
  [ "$status" -eq 0 ]
  pinned_ref="$output"

  run value_of HAC_NLB_SHA256
  [ "$status" -eq 0 ]
  pinned_sha="$output"

  if ! git cat-file -e "${pinned_ref}^{commit}" 2>/dev/null; then
    git fetch origin "${pinned_ref}" >/dev/null 2>&1 || true
  fi

  actual_sha=$(git show "${pinned_ref}:scripts/check-new-line-breaks.py" | sha256sum | awk '{print $1}')
  [ "$pinned_sha" = "$actual_sha" ]
}

@test "MR query warns on failed response code or transport error" {
  run grep 'WARNING: Failed to query merge requests' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "fetch failure warns and skips rather than scanning whole tree" {
  run grep 'could not fetch.*skipping check' "$TEMPLATE"
  [ "$status" -eq 0 ]
}
