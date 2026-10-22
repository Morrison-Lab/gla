#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../scripts/lib/logging.sh"
source "$BATS_TEST_DIRNAME/../../scripts/lib/gitlab-api.sh"
source "$BATS_TEST_DIRNAME/../../scripts/lib/iterate.sh"

setup() {
  export CLAUDE_TRIGGER_TOKEN="token"
  export ITERATION=1
  export MAX_ITERATIONS=3
  export CI_API_V4_URL="https://gitlab.example/api/v4"
  export CI_PROJECT_ID=42
  export MR_SOURCE_BRANCH="fix/test"
  export CI_PIPELINE_ID=10
  export PIPELINE_ATTEMPTS="$BATS_TEST_TMPDIR/pipeline-attempts"
  export PIPELINE_URLS="$BATS_TEST_TMPDIR/pipeline-urls"
  printf '0\n' > "$PIPELINE_ATTEMPTS"
  : > "$PIPELINE_URLS"
}

sleep() { :; }
post_mr_comment() { :; }

gl_api() {
  local attempts
  printf '%s\n' "$1" >> "$PIPELINE_URLS"
  attempts=$(cat "$PIPELINE_ATTEMPTS")
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" > "$PIPELINE_ATTEMPTS"
  if [[ "$attempts" -eq 1 ]]; then
    return 1
  fi
  printf '[{"id":11,"status":"success"}]\n'
}

@test "self-iteration retries after a pipeline API failure" {
  run _self_iterate

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not query the latest pipeline; retrying in 30 seconds."* ]]
  [[ "$output" == *"CI passed! No further iteration needed."* ]]
}

@test "self-iteration URL-encodes reserved branch characters" {
  MR_SOURCE_BRANCH='fix/test&part#x=y'

  run _self_iterate

  [ "$status" -eq 0 ]
  run grep -F 'ref=fix%2Ftest%26part%23x%3Dy&per_page=1' "$PIPELINE_URLS"
  [ "$status" -eq 0 ]
}

@test "self-iteration retries after a malformed pipeline response" {
  gl_api() {
    local attempts
    attempts=$(cat "$PIPELINE_ATTEMPTS")
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$PIPELINE_ATTEMPTS"
    if [[ "$attempts" -eq 1 ]]; then
      printf '[true]\n'
    else
      printf '[{"id":11,"status":"success"}]\n'
    fi
  }

  run _self_iterate

  [ "$status" -eq 0 ]
  [[ "$output" == *"Latest pipeline response was malformed; retrying in 30 seconds."* ]]
  [[ "$output" == *"CI passed! No further iteration needed."* ]]
}
