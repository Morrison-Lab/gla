#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/review-tools.sh"
}

@test "review tools expose only read-oriented operations" {
  run bash -c 'source "$1"; printf "%s" "$REVIEW_TOOLS_JSON" | jq -e "all(.[]; .function.name | test(\"^(list_repository_files|read_repository_file|read_merge_request_history|fetch_allowlisted_documentation)$\"))"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "repository listing reports its 1000-file truncation limit" {
  run grep -F 'truncated:$truncated,limit:1000' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "repository file tools return bounded JSON and reject traversal" {
  run bash -c 'source "$1"; execute_review_tool read_repository_file "{\"path\":\"README.md\",\"max_chars\":100}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .path <<< "$output")" = "README.md" ]
  [ "$(jq -r .truncated <<< "$output")" = "true" ]

  run bash -c 'source "$1"; execute_review_tool read_repository_file "{\"path\":\"../README.md\"}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .error <<< "$output")" = "invalid or unsafe file request" ]

  run bash -c 'touch .review-tools-untracked-test; source "$1"; execute_review_tool read_repository_file "{\"path\":\".review-tools-untracked-test\"}"; status=$?; rm -f .review-tools-untracked-test; exit "$status"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .error <<< "$output")" = "file is not a tracked regular file" ]

  run bash -c 'source "$1"; execute_review_tool list_repository_files "5"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .error <<< "$output")" = "tool arguments must be a JSON object" ]
}

@test "documentation tool enforces its URL allowlist" {
  run bash -c 'source "$1"; execute_review_tool fetch_allowlisted_documentation "{\"url\":\"https://example.com\"}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .error <<< "$output")" = "URL is not on the review documentation allowlist" ]
}

@test "repository file tool rejects pathspec metacharacters literally" {
  run bash -c 'touch "literal*"; source "$1"; execute_review_tool read_repository_file "{\"path\":\"literal*\"}"; status=$?; rm -f -- literal\*; exit "$status"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .error <<< "$output")" = "file is not a tracked regular file" ]
}

@test "repository file tool bounds large file reads before jq" {
  run bash -c 'tmp=$(mktemp -d); trap "rm -rf \"$tmp\"" EXIT; cd "$tmp"; git init -q; git config user.email test@example.com; git config user.name test; head -c 100000 /dev/zero | tr "\\0" x > large.txt; git add large.txt; source "$1"; execute_review_tool read_repository_file "{\"path\":\"large.txt\",\"max_chars\":10}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .truncated <<< "$output")" = "true" ]
  [ "$(jq -r '.content | length' <<< "$output")" -eq 10 ]
}

@test "repository file tool reads tracked leading-dash filenames literally" {
  run bash -c 'tmp=$(mktemp -d); trap "rm -rf "$tmp"" EXIT; cd "$tmp"; git init -q; git config user.email test@example.com; git config user.name test; printf "contents" > --help; git add -- --help; source "$1"; execute_review_tool read_repository_file "{\"path\":\"--help\",\"max_chars\":20}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .content <<< "$output")" = "contents" ]
}

@test "documentation tool rejects model-controlled URL paths and queries" {
  run bash -c 'source "$1"; curl() { printf "unexpected fetch\n"; return 0; }; execute_review_tool fetch_allowlisted_documentation "{\"url\":\"https://docs.gitlab.com/{a,b}[1]?leak=repository-content\"}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .error <<< "$output")" = "URL is not on the review documentation allowlist" ]
  [[ "$output" != *"unexpected fetch"* ]]
}

@test "merge request history tool reports truncation within its bound" {
  run bash -c 'source "$1"; REVIEW_NOTES=$(printf "%0500d" 0); PRIOR_REVIEW_CONTEXT=history; MAX_REVIEW_HISTORY_CHARS=120; execute_review_tool read_merge_request_history "{}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .truncated <<< "$output")" = "true" ]
  [ "$(jq -r .max_chars <<< "$output")" -eq 120 ]
  [ "$(jq -r '.history | length' <<< "$output")" -le 120 ]
}

@test "repository file tool counts multibyte characters consistently" {
  run bash -c 'tmp=$(mktemp -d); trap "rm -rf \"$tmp\"" EXIT; cd "$tmp"; git init -q; git config user.email test@example.com; git config user.name test; printf "é%.0s" $(seq 1 100) > unicode.txt; git add unicode.txt; source "$1"; execute_review_tool read_repository_file "{\"path\":\"unicode.txt\",\"max_chars\":10}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .truncated <<< "$output")" = "true" ]
  [ "$(jq -r '.content | length' <<< "$output")" -eq 10 ]
}

@test "merge request history tool honors a zero budget" {
  run bash -c 'source "$1"; REVIEW_NOTES=notes; PRIOR_REVIEW_CONTEXT=history; MAX_REVIEW_HISTORY_CHARS=0; execute_review_tool read_merge_request_history "{}"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r .truncated <<< "$output")" = "false" ]
  [ "$(jq -r .max_chars <<< "$output")" -eq 0 ]
  [ "$(jq -r .discussion <<< "$output")" = "" ]
  [ "$(jq -r .prior_review_context <<< "$output")" = "" ]
}
