#!/usr/bin/env bats

setup() {
  REVIEW_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TEST_REPO" "$BIN_DIR"

  git init -q -b feature "$TEST_REPO"
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "Test User"
  echo test > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit -q -m "test commit"

  cat > "$BIN_DIR/curl" <<'CURL_STUB'
#!/usr/bin/env bash
printf '%s\n200\n' "$MOCK_MR_RESPONSE"
CURL_STUB
  chmod +x "$BIN_DIR/curl"

  export PATH="$BIN_DIR:$PATH"
  export CI_COMMIT_BRANCH="feature"
  export CI_DEFAULT_BRANCH="main"
  export CI_COMMIT_SHA
  CI_COMMIT_SHA=$(git -C "$TEST_REPO" rev-parse HEAD)
  export CI_COMMIT_SHORT_SHA="${CI_COMMIT_SHA:0:8}"
  export CI_COMMIT_MESSAGE="test commit"
  export CI_PROJECT_ID=1
  export CI_API_V4_URL="https://gitlab.example/api/v4"
  export GITLAB_TOKEN="mock-token"
  export CI_PIPELINE_SOURCE="push"
}

@test "claude-review accepts an empty open-MR lookup array" {
  export MOCK_MR_RESPONSE='[]'
  cd "$TEST_REPO"

  run "$REVIEW_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No open MR found for branch 'feature' — skipping review."* ]]
}

@test "claude-review rejects malformed open-MR lookup responses" {
  local payload
  cd "$TEST_REPO"

  for payload in \
    'not json' \
    '{}' \
    '[{}]' \
    '[{"iid":"1","title":"Change","target_branch":"main","author":{"username":"author"},"labels":[],"description":null}]' \
    '[{"iid":1,"title":"Change","target_branch":"main","author":{"username":"author"},"labels":[1],"description":null}]'; do
    export MOCK_MR_RESPONSE="$payload"

    run "$REVIEW_SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Open-MR lookup for branch 'feature' returned malformed data."* ]]
    [[ "$output" != *"No open MR found"* ]]
  done
}
