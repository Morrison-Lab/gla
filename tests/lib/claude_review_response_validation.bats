#!/usr/bin/env bats
# =============================================================================
# Regression tests for HACtions#51: a content-free LLM response must not be
# treated as a clean review.
# =============================================================================
# The function below mirrors the response-validation logic added to
# scripts/claude-review.sh's "POSTING REVIEW COMMENT" step exactly. Keep the
# two in sync if either changes.
#
# Run with: bats tests/lib/claude_review_response_validation.bats

# is_usable_response RESPONSE
# Returns 0 if RESPONSE contains usable review content (the FINDINGS_JSON
# marker, or at least one markdown heading, and is not bare JSON); returns 1
# (unusable) otherwise.
is_usable_response() {
  local RESPONSE="$1"
  local RESPONSE_IS_JSON=false RESPONSE_HAS_MARKER=false RESPONSE_HAS_HEADING=false

  if echo "$RESPONSE" | jq -e 'type == "array" or type == "object"' >/dev/null 2>&1; then
    RESPONSE_IS_JSON=true
  fi
  echo "$RESPONSE" | grep -qE '^-*[[:space:]]*FINDINGS_JSON[[:space:]]*-*$' && RESPONSE_HAS_MARKER=true
  echo "$RESPONSE" | grep -qE '^#' && RESPONSE_HAS_HEADING=true

  if [[ "$RESPONSE_IS_JSON" == "true" ]] || { [[ "$RESPONSE_HAS_MARKER" == "false" ]] && [[ "$RESPONSE_HAS_HEADING" == "false" ]]; }; then
    return 1
  fi
  return 0
}

@test "a normal review with a markdown heading and FINDINGS_JSON marker is usable" {
  run is_usable_response "$(printf '## MR Review\n\nLooks good.\n---FINDINGS_JSON---\n[]')"
  [ "$status" -eq 0 ]
}

@test "a review with only a markdown heading (no marker) is usable" {
  run is_usable_response "$(printf '## MR Review\n\nLooks good, no findings.')"
  [ "$status" -eq 0 ]
}

@test "a review with only the FINDINGS_JSON marker (no heading) is usable" {
  run is_usable_response "$(printf 'Looks good.\n---FINDINGS_JSON---\n[]')"
  [ "$status" -eq 0 ]
}

@test "a bare JSON array of reasoning blocks (the opus-5 case) is unusable" {
  # Regression: HACtions#51 observed a 27,720-byte raw JSON array of
  # {"type": "reasoning", "signature": "..."} blocks with no text at all.
  run is_usable_response '[{"type":"reasoning","signature":"deadbeef"}]'
  [ "$status" -eq 1 ]
}

@test "a JSON array whose string value contains a heading is unusable" {
  run is_usable_response '[{"type":"reasoning","content":"# MR Review"}]'
  [ "$status" -eq 1 ]
}

@test "plain prose with no heading and no marker is unusable" {
  run is_usable_response "just some text with no structure at all"
  [ "$status" -eq 1 ]
}

@test "an empty response is unusable" {
  run is_usable_response ""
  [ "$status" -eq 1 ]
}

@test "a bare JSON scalar with no prose is still unusable" {
  # The array/object predicate does not fire here, but the response has no
  # heading and no marker, so the prose fallback rejects it anyway. Asserting
  # this pins the reject down to the prose fallback rather than the JSON check.
  run is_usable_response '5'
  [ "$status" -eq 1 ]
}

@test "a JSON string whose content looks like a heading is unusable" {
  # The former `jq -e 'type'` expression exits successfully for this valid
  # JSON scalar. The tightened predicate does not, but the surrounding quote
  # means no line starts with '#', so the prose fallback rejects it instead.
  run is_usable_response '"# MR Review"'
  [ "$status" -eq 1 ]
}

@test "prose containing a scalar keeps its heading and stays usable" {
  # A number inside prose never made the whole response valid JSON, so this
  # was never at risk from either predicate. Pinned so a future loosening of
  # the JSON check cannot start rejecting ordinary reviews unnoticed.
  run is_usable_response "$(printf '## MR Review\n\n5 findings summarized below.')"
  [ "$status" -eq 0 ]
}
