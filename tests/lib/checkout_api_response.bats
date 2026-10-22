#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../scripts/lib/logging.sh"
source "$BATS_TEST_DIRNAME/../../scripts/lib/checkout.sh"

setup() {
  export CI_API_V4_URL="https://gitlab.example/api/v4"
  export CI_PROJECT_ID=42
  export CLAUDE_MR_IID=7
  export CLAUDE_ISSUE_IID=9
}

gl_api() {
  printf '%s\n' "$MOCK_RESPONSE"
}

git() {
  printf 'unexpected git call\n'
  return 1
}

@test "MR checkout rejects incomplete, invalid, and wrongly typed API responses" {
  local payload
  for payload in \
    '{}' \
    'not json' \
    '{"source_branch":1,"target_branch":"main","title":"Change","description":null}' \
    '{"source_branch":"feature","target_branch":1,"title":"Change","description":null}' \
    '{"source_branch":"feature","target_branch":"main","title":1,"description":null}' \
    '{"source_branch":"feature","target_branch":"main","title":"Change","description":1}' \
    '{"source_branch":"feature","target_branch":"main","title":"Change","description":null,"sha":1}' \
    '{"source_branch":"feature","target_branch":"main","title":"Change","description":null,"head_pipeline":{"id":"1"}}'; do
    MOCK_RESPONSE="$payload"

    run _checkout_mr_branch

    [ "$status" -eq 1 ]
    [[ "$output" == *"Response for MR !7 was malformed; cannot check out its source branch."* ]]
    [[ "$output" != *"unexpected git call"* ]]
  done
}

@test "Issue checkout rejects incomplete, invalid, and wrongly typed API responses" {
  local payload
  for payload in \
    '{}' \
    'not json' \
    '{"title":1,"description":"Details"}' \
    '{"title":"Issue","description":1}'; do
    MOCK_RESPONSE="$payload"

    run _checkout_issue_branch

    [ "$status" -eq 1 ]
    [[ "$output" == *"Response for Issue #9 was malformed; cannot create its work branch."* ]]
    [[ "$output" != *"unexpected git call"* ]]
  done
}
