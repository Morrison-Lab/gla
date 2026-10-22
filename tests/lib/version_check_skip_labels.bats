#!/usr/bin/env bats
# =============================================================================
# Regression tests for templates/version-check.yml's GLA_VERSION_SKIP_LABELS
# comma-split / trim / empty-guard logic (MR !38 review finding #4).
# =============================================================================
# The loop below mirrors the shell logic in the "Check for skip labels on
# associated MR" script block of templates/version-check.yml exactly. Keep
# the two in sync if either changes.
#
# Run with: bats tests/lib/version_check_skip_labels.bats

# skip_check LABELS GLA_VERSION_SKIP_LABELS
# Prints "skip:<label>" and returns 0 if a configured skip label matches one
# of the newline-separated LABELS; otherwise prints nothing and returns 1.
skip_check() {
  local LABELS="$1"
  local GLA_VERSION_SKIP_LABELS="$2"
  local SKIP_LABELS skip_label
  IFS=',' read -ra SKIP_LABELS <<< "$GLA_VERSION_SKIP_LABELS"
  for skip_label in "${SKIP_LABELS[@]}"; do
    skip_label=$(echo "$skip_label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$skip_label" ] && continue
    if echo "$LABELS" | grep -qxF "$skip_label"; then
      echo "skip:${skip_label}"
      return 0
    fi
  done
  return 1
}

@test "matches a configured skip label present on the MR" {
  run skip_check "$(printf 'bug\nno-version-bump')" "no-version-bump,no version increment"
  [ "$status" -eq 0 ]
  [ "$output" = "skip:no-version-bump" ]
}

@test "does not match when no configured skip label is present" {
  run skip_check "$(printf 'bug\nenhancement')" "no-version-bump,no version increment"
  [ "$status" -eq 1 ]
}

@test "trims whitespace around configured labels before matching" {
  run skip_check "$(printf 'no version increment')" "no-version-bump, no version increment "
  [ "$status" -eq 0 ]
  [ "$output" = "skip:no version increment" ]
}

@test "a trailing comma yields an empty element that is skipped, not treated as a wildcard match" {
  # Regression: without the `[ -z "$skip_label" ] && continue` guard,
  # grep -qxF "" matches any non-empty line and skips the check for every MR.
  run skip_check "$(printf 'bug\nenhancement')" "no-version-bump,"
  [ "$status" -eq 1 ]
}

@test "an empty LABELS value never matches, even with a trailing-comma skip list" {
  run skip_check "" "no-version-bump,"
  [ "$status" -eq 1 ]
}
