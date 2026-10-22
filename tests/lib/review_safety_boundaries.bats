#!/usr/bin/env bats

setup() {
  REVIEW_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
  FIXTURE="$BATS_TEST_DIRNAME/../fixtures/review-boundary-fixture.sh"
  chmod +x "$FIXTURE"
}

run_fixture() {
  run "$FIXTURE" "$1" "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  FIXTURE_DIR="$(tail -n1 <<< "$output")"
  FIXTURE_STATUS="$(cat "$FIXTURE_DIR/status")"
  REQUESTS="$(cat "$FIXTURE_DIR/requests" 2>/dev/null || true)"
}

@test "agent falls back to prompt-only mode after HTTP 400" {
  run_fixture http400
  [ "$FIXTURE_STATUS" -eq 0 ]
  [ "$(grep -c 'tool_choice' <<< "$REQUESTS")" -eq 1 ]
}

@test "agent finalizes after tool-call budget exhaustion" {
  run_fixture call-exhaustion
  [ "$FIXTURE_STATUS" -eq 0 ]
  [[ "$REQUESTS" == *"per-response tool-call budget exhausted"* ]]
}

@test "agent finalizes after tool-round budget exhaustion" {
  run_fixture round-exhaustion
  [ "$FIXTURE_STATUS" -eq 0 ]
  [[ "$REQUESTS" == *"read-only exploration budget is exhausted"* ]]
}

@test "agent refuses to start after the deadline" {
  run_fixture deadline
  [ "$FIXTURE_STATUS" -ne 0 ]
  [ ! -s "$FIXTURE_DIR/state" ]
}

@test "agent bounds an oversized model response" {
  run_fixture oversized
  [ "$FIXTURE_STATUS" -ne 0 ]
  [[ "$REQUESTS" == *"--max-filesize 100"* ]]
}
