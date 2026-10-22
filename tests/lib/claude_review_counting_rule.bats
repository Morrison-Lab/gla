#!/usr/bin/env bats
# =============================================================================
# The reviewer must not assert character counts it cannot compute.
# =============================================================================
# Measured on MR !47: claude-companion reported five times, escalating to high,
# that a 64-character SHA-256 digest was 63 characters. It quoted the digest in
# full, correctly, nine times out of nine -- so nothing upstream corrupted the
# string. It reproduced 64 characters and asserted 63.
#
# It cannot do otherwise. claude-review.sh sends a single completion with no
# `tools` key (the respond path's edit_file/create_file are not offered to the
# reviewer), so there is no way to run wc -c. The count is intuition over
# tokens.
#
# A false finding of this kind does not decay: PRIOR_REVIEW_CONTEXT feeds the
# reviewer its own previous review, and because a correct value never changes,
# the finding reads as unaddressed every round and gets re-raised.
#
# Run with: bats tests/lib/claude_review_counting_rule.bats

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"

@test "the review script is syntactically valid" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the prompt forbids asserting character counts from inspection" {
  grep -q "NEVER assert the character count" "$SCRIPT"
}

@test "the review prompt distinguishes false-finding rebuttals" {
  grep -q 'REBUTTED:' "$SCRIPT"
  grep -q 'explicit false-finding' "$SCRIPT"
  grep -q 'independently' "$SCRIPT"
  grep -q 'verified concrete evidence' "$SCRIPT"
  ! grep -q 'only with new evidence' "$SCRIPT"
}

@test "the rule names a program rather than only prohibiting the guess" {
  # Prohibition alone leaves the reviewer with no way to raise a real
  # malformed-literal problem, so the rule has to redirect to a check.
  block=$(sed -n '/NEVER assert the character count/,/intuited/p' "$SCRIPT")
  echo "$block" | grep -q "sha256sum"
  # A length instruction must not hand back an off-by-one: echo appends a
  # newline, so 'echo VALUE | wc -c' reports 65 for a 64-character digest and
  # manufactures the exact error this rule exists to prevent.
  echo "$block" | grep -q "printf rather than echo"
  ! echo "$block" | grep -qE "^\s*'echo .*wc -c'"
}

@test "the rule covers the literal kinds that actually appear in this repo" {
  block=$(sed -n '/NEVER assert the character count/,/intuited/p' "$SCRIPT")
  for kind in checksum digest SHA base64 UUID; do
    echo "$block" | grep -qi "$kind" || {
      echo "rule does not mention: $kind" >&2
      return 1
    }
  done
}

@test "the rule sits in the Instructions section, not in a comment" {
  # A rule outside the prompt string reaches the model in no way at all.
  instr_start=$(grep -n '^## Instructions' "$SCRIPT" | head -1 | cut -d: -f1)
  rule_line=$(grep -n 'NEVER assert the character count' "$SCRIPT" | head -1 | cut -d: -f1)
  prompt_end=$(grep -n 'it will still appear in the summary' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$instr_start" ]
  [ -n "$rule_line" ]
  [ -n "$prompt_end" ]
  [ "$rule_line" -gt "$instr_start" ]
  [ "$rule_line" -lt "$prompt_end" ]
}

@test "the added text cannot be mangled by shell interpolation" {
  # The prompt is a double-quoted shell string, so an unescaped $ or backtick
  # would interpolate or run a command before the model ever saw it.
  block=$(sed -n '/NEVER assert the character count/,/intuited/p' "$SCRIPT")
  ! echo "$block" | grep -qE '[$`]'
}
