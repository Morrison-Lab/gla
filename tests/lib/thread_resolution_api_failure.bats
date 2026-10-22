#!/usr/bin/env bats

@test "addressed thread resolution fails open when discussions are unavailable" {
  run bash -euo pipefail -c '
    source "$1/scripts/lib/logging.sh"
    source "$1/scripts/lib/gitlab-api.sh"
    CI_API_V4_URL="https://gitlab.example/api/v4"
    CI_PROJECT_ID=42
    gl_api() { return 1; }
    resolve_addressed_threads 7 "src/a.R"
    echo continued
  ' _ "$BATS_TEST_DIRNAME/../.."

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping remaining thread resolution"* ]]
  [[ "$output" == *"continued"* ]]
}

@test "verified thread resolution fails open when discussions are unavailable" {
  run bash -euo pipefail -c '
    source "$1/scripts/lib/logging.sh"
    source "$1/scripts/lib/gitlab-api.sh"
    CI_API_V4_URL="https://gitlab.example/api/v4"
    CI_PROJECT_ID=42
    gl_api() { return 1; }
    resolve_verified_threads 7 "[]" "src/a.R" primary true
    echo continued
  ' _ "$BATS_TEST_DIRNAME/../.."

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping remaining verified thread resolution"* ]]
  [[ "$output" == *"continued"* ]]
}

@test "addressed thread resolution fails open for malformed discussion elements" {
  run bash -euo pipefail -c '
    source "$1/scripts/lib/logging.sh"
    source "$1/scripts/lib/gitlab-api.sh"
    CI_API_V4_URL="https://gitlab.example/api/v4"
    CI_PROJECT_ID=42
    gl_api() { printf "[true]\\n"; }
    resolve_addressed_threads 7 "src/a.R"
    echo continued
  ' _ "$BATS_TEST_DIRNAME/../.."

  [ "$status" -eq 0 ]
  [[ "$output" == *"was malformed; skipping remaining thread resolution"* ]]
  [[ "$output" == *"continued"* ]]
}

@test "verified thread resolution fails open for malformed discussion elements" {
  run bash -euo pipefail -c '
    source "$1/scripts/lib/logging.sh"
    source "$1/scripts/lib/gitlab-api.sh"
    CI_API_V4_URL="https://gitlab.example/api/v4"
    CI_PROJECT_ID=42
    gl_api() { printf "[true]\\n"; }
    resolve_verified_threads 7 "[]" "src/a.R" primary true
    echo continued
  ' _ "$BATS_TEST_DIRNAME/../.."

  [ "$status" -eq 0 ]
  [[ "$output" == *"was malformed; skipping remaining verified thread resolution"* ]]
  [[ "$output" == *"continued"* ]]
}

@test "addressed thread resolution fails open for malformed note fields" {
  run bash -euo pipefail -c '
    source "$1/scripts/lib/logging.sh"
    source "$1/scripts/lib/gitlab-api.sh"
    CI_API_V4_URL="https://gitlab.example/api/v4"
    CI_PROJECT_ID=42
    gl_api() { printf "%s\n" "[{\"id\":\"discussion\",\"notes\":[{\"body\":true}]}]"; }
    resolve_addressed_threads 7 "src/a.R"
    echo continued
  ' _ "$BATS_TEST_DIRNAME/../.."

  [ "$status" -eq 0 ]
  [[ "$output" == *"contained malformed note fields; skipping remaining thread resolution"* ]]
  [[ "$output" == *"continued"* ]]
}

@test "verified thread resolution fails open for malformed note fields" {
  run bash -euo pipefail -c '
    source "$1/scripts/lib/logging.sh"
    source "$1/scripts/lib/gitlab-api.sh"
    CI_API_V4_URL="https://gitlab.example/api/v4"
    CI_PROJECT_ID=42
    gl_api() { printf "%s\n" "[{\"id\":\"discussion\",\"notes\":[{\"body\":true}]}]"; }
    resolve_verified_threads 7 "[]" "src/a.R" primary true
    echo continued
  ' _ "$BATS_TEST_DIRNAME/../.."

  [ "$status" -eq 0 ]
  [[ "$output" == *"contained malformed note fields; skipping remaining verified thread resolution"* ]]
  [[ "$output" == *"continued"* ]]
}
