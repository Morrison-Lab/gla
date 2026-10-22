#!/usr/bin/env bash
set -euo pipefail

mode="${1:?mode required}"
review_script="${2:?review script required}"
tmpdir="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/review-boundary-${mode}"
rm -rf "$tmpdir"
mkdir -p "$tmpdir/bin"

git init -q -b main "$tmpdir/repo"
git -C "$tmpdir/repo" config user.email test@example.com
git -C "$tmpdir/repo" config user.name "Test User"
printf 'base\n' > "$tmpdir/repo/file.txt"
git -C "$tmpdir/repo" add file.txt
git -C "$tmpdir/repo" commit -qm base
git -C "$tmpdir/repo" checkout -qb feature
printf 'change\n' >> "$tmpdir/repo/file.txt"
git -C "$tmpdir/repo" commit -qam change
review_sha=$(git -C "$tmpdir/repo" rev-parse HEAD)
main_sha=$(git -C "$tmpdir/repo" rev-parse main)

cat > "$tmpdir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=""
data_file=""
for arg in "$@"; do
  [[ "$arg" == http* ]] && url="$arg"
  [[ "$arg" == @* ]] && data_file="${arg#@}"
done
if [[ "$url" == */merge_requests*source_branch=feature* ]]; then
  printf '[{"iid":10,"title":"fixture","target_branch":"main","author":{"username":"author"},"labels":[],"description":"fixture"}]\n200\n'
elif [[ "$url" == */merge_requests/10/versions* ]]; then
  printf '[{"base_commit_sha":"%s","head_commit_sha":"%s","start_commit_sha":"%s"}]\n200\n' "$MOCK_MAIN_SHA" "$MOCK_REVIEW_SHA" "$MOCK_MAIN_SHA"
elif [[ "$url" == */merge_requests/10/discussions* ]]; then
  if [[ " $* " == *" --request POST "* ]]; then
    printf '{"id":100,"notes":[{"id":200,"body":"mock"}]}\n201\n'
  else
    printf '[]\n200\n'
  fi
elif [[ "$url" == */invocations* || "$url" == */chat/completions* || "$url" == */serving-endpoints/* ]]; then
  calls=0
  [[ -f "$MOCK_STATE" ]] && calls=$(cat "$MOCK_STATE")
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$MOCK_STATE"
  [[ -n "$data_file" && -f "$data_file" ]] && cat "$data_file" >> "$MOCK_REQUESTS"
  printf 'CURL_ARGS %s\n' "$*" >> "$MOCK_REQUESTS"
  if [[ "$MOCK_MODE" == "http400" && "$calls" -eq 1 ]]; then
    printf '{"message":"tools unsupported"}\n400\n'
  elif [[ "$MOCK_MODE" == "call-exhaustion" && "$calls" -eq 1 ]]; then
    printf '%s\n' '{"choices":[{"message":{"content":"","tool_calls":[{"id":"a","type":"function","function":{"name":"list_repository_files","arguments":"{}"}},{"id":"b","type":"function","function":{"name":"list_repository_files","arguments":"{}"}}]}}]}' '200'
  elif [[ "$MOCK_MODE" == "round-exhaustion" && "$calls" -le 2 ]]; then
    printf '%s\n' '{"choices":[{"message":{"content":"","tool_calls":[{"id":"a","type":"function","function":{"name":"list_repository_files","arguments":"{}"}}]}}]}' '200'
  elif [[ "$MOCK_MODE" == "oversized" ]]; then
    printf '{"choices":[{"message":{"content":"%*s"}}]}\n200\n' 300 ''
  else
    printf '%s\n' '{"choices":[{"message":{"content":"## MR Review\n\nLooks good.\n---FINDINGS_JSON---\n[]"}}]}' '200'
  fi
elif [[ "$url" == */user ]]; then
  printf '{"id":1,"username":"claude-bot"}\n200\n'
else
  printf '{}\n200\n'
fi
CURL
chmod +x "$tmpdir/bin/curl"

export PATH="$tmpdir/bin:$PATH"
export MOCK_MODE="$mode"
export MOCK_STATE="$tmpdir/state"
export MOCK_REQUESTS="$tmpdir/requests"
export MOCK_MAIN_SHA="$main_sha"
export MOCK_REVIEW_SHA="$review_sha"
export CI_COMMIT_BRANCH=feature CI_DEFAULT_BRANCH=main CI_COMMIT_SHA="$review_sha"
export CI_COMMIT_SHORT_SHA="${review_sha:0:8}" CI_COMMIT_MESSAGE=change
export CI_PROJECT_ID=1 CI_API_V4_URL=https://gitlab.example/api/v4 GITLAB_TOKEN=mock-token
export ANTHROPIC_BASE_URL=https://llm.example/api ANTHROPIC_AUTH_TOKEN=mock-token
export GLA_REVIEW_AGENT=true CI_PIPELINE_SOURCE=push CI_PIPELINE_URL=https://gitlab.example/pipelines/1
export MOCK_AGENT_STATE="$MOCK_STATE"
case "$mode" in
  call-exhaustion) export GLA_MAX_REVIEW_TOOL_CALLS=1 ;;
  round-exhaustion) export GLA_MAX_REVIEW_TOOL_ROUNDS=1 ;;
  deadline) export GLA_REVIEW_DEADLINE_SECONDS=0 ;;
  oversized) export GLA_MAX_REVIEW_RESPONSE_CHARS=100 ;;
  http400) : ;;
esac

set +e
(cd "$tmpdir/repo" && "$review_script")
status=$?
set -e
printf '%s\n' "$status" > "$tmpdir/status"
printf '%s\n' "$tmpdir"
