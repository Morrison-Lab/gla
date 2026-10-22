#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../scripts/lib/logging.sh"
source "$BATS_TEST_DIRNAME/../../scripts/lib/gather.sh"

setup() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export NOTEABLE_TYPE="MergeRequest"
  export CI_API_V4_URL="https://gitlab.example/api/v4"
  export CI_PROJECT_ID="42"
  export CLAUDE_MR_IID="7"
  export HEAD_PIPELINE_ID=""
  export TRIGGERING_REVIEW_NOTE_ID=""
  export MOCK_CHANGES='{"changes":[{"old_path":"src/a.R","new_path":"src/a.R","diff":"+changed"}]}'
  export MOCK_NOTES='[]'
  export MOCK_FAILED_JOBS='[{"id":5}]'
  export MOCK_JOB_DATA='{"name":"failed-job"}'
  export MOCK_PIPELINE_JOBS='[{"name":"failed-job","status":"failed"}]'
}

gl_api() {
  case "$1" in
    */changes\?access_raw_diffs=true)
      [[ "${MOCK_CHANGES_FAILURE:-false}" == "true" ]] && return 1
      printf '%s\n' "$MOCK_CHANGES"
      ;;
    */notes*)
      [[ "${MOCK_NOTES_FAILURE:-false}" == "true" ]] && return 1
      printf '%s\n' "$MOCK_NOTES"
      ;;
    */jobs/5/trace)
      [[ "${MOCK_TRACE_FAILURE:-false}" == "true" ]] && return 1
      printf 'trace\n'
      ;;
    */jobs/5)
      printf '%s\n' "$MOCK_JOB_DATA"
      ;;
    *"scope[]=failed"*)
      printf '%s\n' "$MOCK_FAILED_JOBS"
      ;;
    */pipelines/*/jobs*)
      printf '%s\n' "$MOCK_PIPELINE_JOBS"
      ;;
    *)
      printf '[]\n'
      ;;
  esac
}

_gather_key_files() { :; }

@test "large MR diff does not abort under pipefail" {
  local large_diff
  large_diff=$(printf 'x%.0s' $(seq 1 80000))
  MOCK_CHANGES=$(jq -cn --arg diff "$large_diff" \
    '{changes:[{old_path:"src/a.R",new_path:"src/a.R",diff:$diff}]}')
  export MOCK_CHANGES

  run bash -c '
    set -euo pipefail
    source "$REPO_ROOT/scripts/lib/logging.sh"
    source "$REPO_ROOT/scripts/lib/gather.sh"
    gl_api() {
      if [[ "$1" == *"/changes?access_raw_diffs=true" ]]; then printf "%s\n" "$MOCK_CHANGES"; else printf "[]\n"; fi
    }
    _gather_key_files() { :; }
    gather_context
    printf "diff-bytes=%s files=%s\n" "${#MR_DIFF}" "$MR_DIFF_FILES"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"diff-bytes=40000 files=src/a.R"* ]]
}

@test "MR changes request failure is reported clearly" {
  MOCK_CHANGES_FAILURE=true

  run gather_context

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not fetch changes for MR !7."* ]]
}

@test "malformed MR changes response is reported clearly" {
  MOCK_CHANGES='{"message":"unexpected response"}'

  run gather_context

  [ "$status" -eq 1 ]
  [[ "$output" == *"Changes response for MR !7 was malformed."* ]]
}

@test "mixed valid and malformed MR change entries are rejected" {
  MOCK_CHANGES='{"changes":[null,{"old_path":"src/a.R","new_path":"src/a.R","diff":"+changed"}]}'

  run gather_context

  [ "$status" -eq 1 ]
  [[ "$output" == *"Changes response for MR !7 was malformed."* ]]
}

@test "MR with no changed files is reported clearly" {
  MOCK_CHANGES='{"changes":[]}'

  run gather_context

  [ "$status" -eq 1 ]
  [[ "$output" == *"MR !7 has no changed files to review."* ]]
}

@test "overflowing MR changes response is rejected clearly" {
  MOCK_CHANGES='{"overflow":true,"changes":[{"old_path":"src/a.R","new_path":"src/a.R","diff":"+partial"}]}'

  run gather_context

  [ "$status" -eq 1 ]
  [[ "$output" == *"Changes response for MR !7 was truncated by GitLab."* ]]
}

@test "MR discussion request failure degrades to empty context" {
  MOCK_NOTES_FAILURE=true

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" == *"Recent MR discussion was unavailable."* ]]
  [[ "$output" == *"MR notes: 0 bytes"* ]]
}

@test "malformed MR discussion entries degrade to empty context" {
  local payload
  for payload in \
    '[{}]' \
    '[{"author":{"username":"reviewer"},"created_at":"now","body":1}]' \
    '[{"author":{"username":1},"created_at":"now","body":"note"}]'; do
    MOCK_NOTES="$payload"

    run gather_context

    [ "$status" -eq 0 ]
    [[ "$output" == *"Recent MR discussion was malformed."* ]]
    [[ "$output" == *"MR notes: 0 bytes"* ]]
  done
}

@test "large MR discussion is truncated without being discarded" {
  local large_note
  large_note=$(printf 'x%.0s' $(seq 1 20000))
  MOCK_NOTES=$(jq -cn --arg body "$large_note" \
    '[{author:{username:"reviewer"},created_at:"2026-09-14T00:00:00Z",body:$body}]')

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" != *"Recent MR discussion was malformed"* ]]
  [[ "$output" == *"MR notes: 15000 bytes"* ]]
}

@test "large Issue discussion is truncated without being discarded" {
  local large_note
  large_note=$(printf 'x%.0s' $(seq 1 20000))
  MOCK_NOTES=$(jq -cn --arg body "$large_note" \
    '[{author:{username:"reviewer"},created_at:"2026-09-14T00:00:00Z",body:$body}]')
  NOTEABLE_TYPE="Issue"
  CLAUDE_ISSUE_IID=9

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" != *"Recent Issue discussion was malformed"* ]]
  [[ "$output" == *"Issue notes: 15000 bytes"* ]]
}

@test "malformed Issue discussion entries degrade to empty context" {
  MOCK_NOTES='[{"author":{"username":"reviewer"},"created_at":1,"body":"note"}]'
  NOTEABLE_TYPE="Issue"
  CLAUDE_ISSUE_IID=9

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" == *"Recent Issue discussion was malformed."* ]]
  [[ "$output" == *"Issue notes: 0 bytes"* ]]
}

@test "failed job trace request does not abort context gathering" {
  HEAD_PIPELINE_ID=9
  MOCK_TRACE_FAILURE=true

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not fetch trace for failed job 5; skipping its log."* ]]
}

@test "malformed failed-job metadata is skipped" {
  HEAD_PIPELINE_ID=9
  MOCK_JOB_DATA='{"name":42}'

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" == *"Metadata for failed job 5 was malformed; skipping its log."* ]]
  [[ "$output" != *"Collected log for failed job: 42"* ]]
}

@test "malformed pipeline-summary entries are skipped" {
  HEAD_PIPELINE_ID=9
  MOCK_FAILED_JOBS='[]'
  MOCK_PIPELINE_JOBS='[{"name":"test"}]'

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" == *"Pipeline job summary was malformed; continuing without CI logs."* ]]
  [[ "$output" != *"No failed jobs; collected pipeline summary."* ]]
}

@test "empty failed job list is accepted" {
  HEAD_PIPELINE_ID=9
  MOCK_FAILED_JOBS='[]'

  run gather_context

  [ "$status" -eq 0 ]
  [[ "$output" != *"Failed-job list was malformed"* ]]
  [[ "$output" == *"Failed job IDs: none"* ]]
  [[ "$output" == *"No failed jobs; collected pipeline summary."* ]]
}
