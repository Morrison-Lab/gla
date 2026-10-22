#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../scripts/lib/logging.sh"
source "$BATS_TEST_DIRNAME/../../scripts/lib/gitlab-api.sh"

setup() {
  GITLAB_TOKEN="test-token"
}

@test "query values encode reserved branch characters" {
  run urlencode_query_value 'fix/test&part#x=y'

  [ "$status" -eq 0 ]
  [ "$output" = 'fix%2Ftest%26part%23x%3Dy' ]
}

@test "gl_api returns successful response body" {
  curl() { printf '{"ok":true}\n200\n'; }
  export -f curl

  run gl_api "https://gitlab.example/api/v4/test"

  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
}

@test "gl_api disables curl globbing for array query parameters" {
  curl() {
    [[ " $* " == *" --globoff "* ]]
    [[ " $* " == *"scope[]=failed"* ]]
    printf '[]\n200\n'
  }
  export -f curl

  run gl_api "https://gitlab.example/api/v4/jobs?scope[]=failed"

  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "gl_api bounds requests by the remaining review deadline" {
  REVIEW_DEADLINE=$(( $(date +%s) + 30 ))
  curl() {
    [[ " $* " == *" --max-time "* ]]
    printf '{"ok":true}\n200\n'
  }
  export -f curl

  run gl_api "https://gitlab.example/api/v4/test"

  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
}

@test "gl_api reports HTTP errors and returns failure" {
  curl() { printf '{"message":"denied"}\n403\n'; }
  export -f curl

  run gl_api "https://gitlab.example/api/v4/test"

  [ "$status" -eq 1 ]
  [[ "$output" == *"GitLab API returned HTTP 403 for: https://gitlab.example/api/v4/test"* ]]
  [[ "$output" == *'Response body: {"message":"denied"}'* ]]
}

@test "gl_api reports transport errors and returns failure" {
  curl() { return 7; }
  export -f curl

  run gl_api "https://gitlab.example/api/v4/test"

  [ "$status" -eq 1 ]
  [[ "$output" == *"GitLab API request failed for: https://gitlab.example/api/v4/test"* ]]
}

@test "review_curl applies the remaining deadline to write requests" {
  REVIEW_DEADLINE=$(( $(date +%s) + 30 ))
  curl() {
    [[ " $* " == *" --max-time "* ]]
    printf '{}\n201\n'
  }
  export -f curl

  run review_curl -s --request POST "https://gitlab.example/api/v4/test"

  [ "$status" -eq 0 ]
  [ "$output" = $'{}\n201' ]
}

@test "review_curl refuses a write after the deadline" {
  REVIEW_DEADLINE=$(( $(date +%s) - 1 ))
  curl() { printf 'curl must not run\n' >&2; return 99; }
  export -f curl

  run review_curl -s --request PUT "https://gitlab.example/api/v4/test"

  [ "$status" -eq 124 ]
}
