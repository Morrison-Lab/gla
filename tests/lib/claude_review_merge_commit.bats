#!/usr/bin/env bats
# =============================================================================
# Regression tests for gla#74: claude-review.sh must not skip MR heads
# that are merge commits by default, while supporting opt-in GLA_SKIP_MERGE_COMMITS.
# =============================================================================

setup() {
  REVIEW_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
}

@test "claude-review.sh URL-encodes the branch in its MR lookup" {
  run grep -F 'ENCODED_BRANCH=$(urlencode_query_value "$BRANCH")' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'source_branch=${ENCODED_BRANCH}&state=opened' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "claude-review.sh guards merge-commit skip behind GLA_SKIP_MERGE_COMMITS" {
  run grep -F 'if [[ "${GLA_SKIP_MERGE_COMMITS:-false}" == "true"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "merge-commit MR head calculates MR diff and executes review with feature changes by default" {
  local test_tmp="$BATS_TEST_TMPDIR/merge_commit_e2e"
  mkdir -p "$test_tmp"
  local origin_dir="$test_tmp/origin.git"
  local repo_dir="$test_tmp/repo"
  local curl_log="$test_tmp/curl_requests.log"

  git init --bare --initial-branch=main "$origin_dir"
  git clone "$origin_dir" "$repo_dir"
  cd "$repo_dir"

  git config user.email "test@example.com"
  git config user.name "Test User"
  git checkout -B main

  echo "base content" > file.txt
  git add file.txt
  git commit -m "initial commit on main"
  git push -u origin main

  git checkout -b feature
  echo "feature unique content" >> file.txt
  git commit -am "feature commit"
  git push -u origin feature

  git checkout main
  echo "main update" > other.txt
  git add other.txt
  git commit -m "main update commit"
  git push origin main

  git checkout feature
  git merge --no-edit main
  git push origin feature

  local review_sha
  review_sha=$(git rev-parse HEAD)
  local main_sha
  main_sha=$(git rev-parse main)

  local bin_dir="$test_tmp/bin"
  mkdir -p "$bin_dir"

  cat << 'CURL_STUB' > "$bin_dir/curl"
#!/usr/bin/env bash
url=""
data_file=""
is_post=false
prev=""
for arg in "$@"; do
  if [[ "$arg" == http* ]]; then
    url="$arg"
  fi
  if [[ "$arg" == @* ]]; then
    data_file="${arg#@}"
  fi
  if [[ "$prev" == "--request" && "$arg" == "POST" ]]; then
    is_post=true
  fi
  prev="$arg"
done

if [[ -n "$data_file" && -f "$data_file" ]]; then
  echo "=== REQUEST TO $url ===" >> "$CURL_LOG_FILE"
  cat "$data_file" >> "$CURL_LOG_FILE"
  echo "" >> "$CURL_LOG_FILE"
fi

if [[ "$url" == */merge_requests*source_branch=feature* ]]; then
  printf '[{"iid":10,"title":"feature mr","target_branch":"main","author":{"username":"author"},"labels":[],"description":"feature mr"}]\n200\n'
elif [[ "$url" == */merge_requests/10/versions* ]]; then
  printf '[{"base_commit_sha":"%s","head_commit_sha":"%s","start_commit_sha":"%s"}]\n200\n' "$MOCK_MAIN_SHA" "$MOCK_REVIEW_SHA" "$MOCK_MAIN_SHA"
elif [[ "$url" == */merge_requests/10/discussions* ]]; then
  if [[ "$is_post" == "true" ]]; then
    printf '{"id":100,"notes":[{"id":200,"body":"mock"}]}\n201\n'
  else
    printf '[]\n200\n'
  fi
elif [[ "${MOCK_AGENT_ROUNDS:-false}" == "true" && ( "$url" == */invocations* || "$url" == */chat/completions* || "$url" == */serving-endpoints/* ) ]]; then
  calls=0
  [[ -f "$MOCK_AGENT_STATE" ]] && calls=$(cat "$MOCK_AGENT_STATE")
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$MOCK_AGENT_STATE"
  if [[ "$calls" -eq 1 ]]; then
    printf '%s\n' '{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"list_repository_files","arguments":"{}"}}]}}]}' '200'
  else
    printf '%s\n' '{"choices":[{"message":{"content":"## MR Review\n\nLooks good.\n---FINDINGS_JSON---\n[]"}}]}' '200'
  fi
elif [[ "$url" == */invocations* || "$url" == */chat/completions* || "$url" == */serving-endpoints/* ]]; then
  printf '{"choices":[{"message":{"content":"## MR Review\\n\\nLooks good.\\n---FINDINGS_JSON---\\n[]"}}]}\n200\n'
elif [[ "$url" == */user ]]; then
  printf '{"id":1,"username":"claude-bot"}\n200\n'
else
  printf '{}\n200\n'
fi
CURL_STUB
  chmod +x "$bin_dir/curl"

  export PATH="$bin_dir:$PATH"
  export CURL_LOG_FILE="$curl_log"
  export MOCK_MAIN_SHA="$main_sha"
  export MOCK_REVIEW_SHA="$review_sha"
  export CI_COMMIT_BRANCH="feature"
  export CI_DEFAULT_BRANCH="main"
  export CI_COMMIT_SHA="$review_sha"
  export CI_COMMIT_SHORT_SHA="${review_sha:0:8}"
  export CI_COMMIT_MESSAGE="Merge branch 'main' into feature"
  export CI_PROJECT_ID="1"
  export CI_API_V4_URL="https://gitlab.example/api/v4"
  export GITLAB_TOKEN="mock-token"
  export ANTHROPIC_BASE_URL="https://llm.example/api"
  export ANTHROPIC_AUTH_TOKEN="mock-llm-token"
  export GLA_REVIEW_AGENT="true"
  export MOCK_AGENT_ROUNDS="true"
  export MOCK_AGENT_STATE="$test_tmp/agent-calls"
  export CI_PIPELINE_SOURCE="push"
  export CI_PIPELINE_URL="https://gitlab.example/pipelines/1"
  unset GLA_SKIP_MERGE_COMMITS

  run "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found MR !10"* ]]
  [[ "$output" == *"Full MR diff range:"* ]]
  [[ "$output" == *"Posted review comment to MR !10"* ]]
  [[ "$output" == *"Auto-review completed successfully."* ]]

  run grep -F "feature unique content" "$curl_log"
  [ "$status" -eq 0 ]
  run grep -F 'tool_choice' "$curl_log"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_AGENT_STATE")" -eq 2 ]
  run grep -F 'role' "$curl_log"
  [ "$status" -eq 0 ]
}

@test "merge-commit MR head skips auto-review when GLA_SKIP_MERGE_COMMITS=true" {
  local test_tmp="$BATS_TEST_TMPDIR/merge_commit_skip"
  mkdir -p "$test_tmp"
  local repo_dir="$test_tmp/repo"

  git init -b main "$repo_dir"
  cd "$repo_dir"

  git config user.email "test@example.com"
  git config user.name "Test User"

  echo "base content" > file.txt
  git add file.txt
  git commit -m "initial commit on main"

  git checkout -b feature
  echo "feature unique content" >> file.txt
  git commit -am "feature commit"

  git checkout main
  echo "main update" > other.txt
  git add other.txt
  git commit -m "main update commit"

  git checkout feature
  git merge --no-edit main

  local review_sha
  review_sha=$(git rev-parse HEAD)

  export CI_COMMIT_BRANCH="feature"
  export CI_DEFAULT_BRANCH="main"
  export CI_COMMIT_SHA="$review_sha"
  export CI_COMMIT_SHORT_SHA="${review_sha:0:8}"
  export CI_COMMIT_MESSAGE="Merge branch 'main' into feature"
  export CI_PROJECT_ID="1"
  export CI_API_V4_URL="https://gitlab.example/api/v4"
  export GITLAB_TOKEN="mock-token"
  export CI_PIPELINE_SOURCE="push"
  export GLA_SKIP_MERGE_COMMITS="true"

  run "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GLA_SKIP_MERGE_COMMITS is enabled and merge commit detected"* ]]
  [[ "$output" == *"skipping auto-review."* ]]
}
