#!/usr/bin/env bash
# =============================================================================
# Gather context (diff, notes, CI logs, file tree) for the LLM prompt
# =============================================================================
# Requires: _gather_key_files (sourced from key-files.sh)

gather_context() {
  log_step "GATHERING CONTEXT"

  MR_DIFF=""
  MR_DIFF_FILES=""
  MR_NOTES=""
  TRIGGERING_REVIEW=""
  ISSUE_NOTES=""

  if [[ "$NOTEABLE_TYPE" == "MergeRequest" ]]; then
    # MR changes: fetch full JSON, extract file list BEFORE truncation, then format diff
    log "Fetching MR diff..."
    local MR_CHANGES_JSON
    if ! MR_CHANGES_JSON=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/changes?access_raw_diffs=true"); then
      log_error "Could not fetch changes for MR !${CLAUDE_MR_IID}."
      return 1
    fi
    if ! echo "$MR_CHANGES_JSON" | jq -e '
      (.changes | type == "array") and
      all(.changes[];
        type == "object" and
        (.old_path | type == "string" and length > 0) and
        (.new_path | type == "string" and length > 0) and
        (.diff | type == "string")
      )
    ' >/dev/null 2>&1; then
      log_error "Changes response for MR !${CLAUDE_MR_IID} was malformed."
      return 1
    fi
    if echo "$MR_CHANGES_JSON" | jq -e '.overflow == true' >/dev/null 2>&1; then
      log_error "Changes response for MR !${CLAUDE_MR_IID} was truncated by GitLab."
      return 1
    fi
    # Extract file list from JSON (not from truncated text) — used by scope guard
    if ! MR_DIFF_FILES=$(echo "$MR_CHANGES_JSON" \
      | jq -r '.changes[].new_path | strings | select(. != "/dev/null")' \
      | sort -u); then
      log_error "Could not parse changed file paths for MR !${CLAUDE_MR_IID}."
      return 1
    fi
    if [[ -z "$MR_DIFF_FILES" ]]; then
      log_error "MR !${CLAUDE_MR_IID} has no changed files to review."
      return 1
    fi
    # Format diff text for LLM context (truncated to 40KB).
    local MR_DIFF_FULL
    if ! MR_DIFF_FULL=$(echo "$MR_CHANGES_JSON" \
      | jq -r '.changes[] | "--- \(.old_path)\n+++ \(.new_path)\n\(.diff)"'); then
      log_error "Could not format changes for MR !${CLAUDE_MR_IID}."
      return 1
    fi
    # The guard absorbs only the expected SIGPIPE from truncation; jq has
    # already completed successfully above.
    MR_DIFF=$(printf '%s' "$MR_DIFF_FULL" | head -c 40000 || true)
    local file_count="${MR_DIFF_FILES:+$(echo "$MR_DIFF_FILES" | wc -l | tr -d ' ')}"
    log "  MR diff: ${#MR_DIFF} bytes (${file_count:-0} files)"

    # Recent MR discussion (last 20 notes for thread context)
    log "Fetching MR discussion..."
    local mr_notes_json
    if ! mr_notes_json=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/notes?sort=desc&per_page=20"); then
      log_error "Recent MR discussion was unavailable."
      MR_NOTES=""
    # A synthetic auto-fix trusts its separately fetched, hash-bound review.
    # Do not put unrelated MR notes in the privileged model prompt.
    elif [[ -n "${TRIGGERING_REVIEW_NOTE_ID:-}" ]]; then
      MR_NOTES=""
    else
      local mr_notes_full
      if ! echo "$mr_notes_json" | jq -e '
        type == "array" and all(.[];
          type == "object" and
          (.author.username | type == "string") and
          (.created_at | type == "string") and
          (.body | type == "string")
        )
      ' >/dev/null 2>&1; then
        log_error "Recent MR discussion was malformed."
        MR_NOTES=""
      elif ! mr_notes_full=$(echo "$mr_notes_json" \
        | jq -r 'reverse[] | "[\(.author.username) @ \(.created_at)]: \(.body)"'); then
        log_error "Recent MR discussion was malformed."
        MR_NOTES=""
      else
        MR_NOTES=$(printf '%s' "$mr_notes_full" | head -c 15000 || true)
      fi
    fi
    log "  MR notes: ${#MR_NOTES} bytes"
    _gather_triggering_review || return 1
  else
    # Issue discussion (last 20 notes)
    log "Fetching Issue discussion..."
    local issue_notes_json
    if ! issue_notes_json=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}/notes?sort=desc&per_page=20"); then
      log_error "Recent Issue discussion was unavailable."
      ISSUE_NOTES=""
    else
      local issue_notes_full
      if ! echo "$issue_notes_json" | jq -e '
        type == "array" and all(.[];
          type == "object" and
          (.author.username | type == "string") and
          (.created_at | type == "string") and
          (.body | type == "string")
        )
      ' >/dev/null 2>&1; then
        log_error "Recent Issue discussion was malformed."
        ISSUE_NOTES=""
      elif ! issue_notes_full=$(echo "$issue_notes_json" \
        | jq -r 'reverse[] | "[\(.author.username) @ \(.created_at)]: \(.body)"'); then
        log_error "Recent Issue discussion was malformed."
        ISSUE_NOTES=""
      else
        ISSUE_NOTES=$(printf '%s' "$issue_notes_full" | head -c 15000 || true)
      fi
    fi
    log "  Issue notes: ${#ISSUE_NOTES} bytes"
  fi

  # Failed CI job logs from the MR's head pipeline (MR only)
  CI_LOGS=""
  if [[ -n "${HEAD_PIPELINE_ID:-}" ]]; then
    _gather_ci_logs
  else
    log "  No head pipeline found — skipping CI log collection."
  fi

  # Repository file tree (from the checked-out branch)
  log "Building repo file tree..."
  REPO_TREE=$(find . -not -path './.git/*' -not -path './node_modules/*' \
    -not -path './ci/lib/*' -not -path './R_libs/*' \
    -not -path './.gitlab/scripts/*' \
    | sort | awk 'NR<=200')
  log "  Tree entries: $(echo "$REPO_TREE" | wc -l)"

  # Key file contents the model might need
  _gather_key_files
}

_gather_triggering_review() {
  [[ -n "${TRIGGERING_REVIEW_NOTE_ID:-}" ]] || return 0

  if [[ ! "$TRIGGERING_REVIEW_NOTE_ID" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid triggering review note ID; refusing unanchored auto-fix."
    return 1
  fi
  if [[ ! "$TRIGGERING_REVIEW_BODY_HASH" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "Invalid triggering review hash; refusing unanchored auto-fix."
    return 1
  fi

  local review_note triggering_review actual_hash sentinel
  if ! review_note=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/notes/${TRIGGERING_REVIEW_NOTE_ID}"); then
    log_error "Triggering review note ${TRIGGERING_REVIEW_NOTE_ID} could not be fetched."
    return 1
  fi
  if ! echo "$review_note" | jq -e '.body | strings | select(length > 0)' >/dev/null 2>&1; then
    log_error "Triggering review note ${TRIGGERING_REVIEW_NOTE_ID} was unavailable."
    return 1
  fi
  local trusted_bot_username
  trusted_bot_username="${CLAUDE_BOT_USERNAME:-}"
  if [[ -z "$trusted_bot_username" ]]; then
    local current_user_json
    if ! current_user_json=$(gl_api "${CI_API_V4_URL}/user") ||
       ! trusted_bot_username=$(echo "$current_user_json" | jq -e -r '.username | strings | select(length > 0)'); then
      log_error "Could not determine the trusted bot identity."
      return 1
    fi
  fi
  if [[ -z "$trusted_bot_username" ]] ||
     ! echo "$review_note" | jq -e --arg bot "$trusted_bot_username" \
       --arg sha "${TRIGGERING_REVIEW_SHA:0:8}" '
         .author.username == $bot and
         (.body | startswith("🔍 **Auto-review by primary (")) and
         (.body | contains("latest: " + $sha + ")"))
       ' >/dev/null; then
    log_error "Triggering review note is not the anchored primary review."
    return 1
  fi
  actual_hash=$(echo "$review_note" | jq -j '.body' | git hash-object --stdin)
  if [[ "$actual_hash" != "$TRIGGERING_REVIEW_BODY_HASH" ]]; then
    log_error "Triggering review note ${TRIGGERING_REVIEW_NOTE_ID} no longer matches its immutable hash."
    return 1
  fi
  # Appending a non-newline sentinel prevents command substitution from removing
  # body newlines; removing only that final byte preserves all original bytes.
  sentinel=$'\x1f'
  triggering_review=$(echo "$review_note" | jq -j '.body'; printf '%s' "$sentinel")
  triggering_review="${triggering_review%$sentinel}"
  TRIGGERING_REVIEW="$triggering_review"
  log "  Triggering review note: ${TRIGGERING_REVIEW_NOTE_ID} (${TRIGGERING_REVIEW_SHA:-unknown SHA})"
}

_gather_ci_logs() {
  log "Fetching CI job info from pipeline #${HEAD_PIPELINE_ID}..."
  local failed_jobs_json
  if ! failed_jobs_json=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${HEAD_PIPELINE_ID}/jobs?scope[]=failed&per_page=10"); then
    log_error "Failed-job list was unavailable; continuing without individual job logs."
    FAILED_JOBS=""
  elif ! echo "$failed_jobs_json" | jq -e '
    type == "array" and all(.[]; type == "object" and (.id | type == "number"))
  ' >/dev/null 2>&1; then
    log_error "Failed-job list was malformed; continuing without individual job logs."
    FAILED_JOBS=""
  else
    FAILED_JOBS=$(echo "$failed_jobs_json" | jq -r '.[].id')
  fi
  log "  Failed job IDs: ${FAILED_JOBS:-none}"

  local job_data job_trace
  for JOB_ID in $FAILED_JOBS; do
    if ! job_data=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/${JOB_ID}"); then
      log_error "Could not fetch metadata for failed job ${JOB_ID}; skipping its log."
      continue
    fi
    if ! echo "$job_data" | jq -e '
      type == "object" and (.name | type == "string" and length > 0)
    ' >/dev/null 2>&1; then
      log_error "Metadata for failed job ${JOB_ID} was malformed; skipping its log."
      continue
    fi
    JOB_NAME=$(echo "$job_data" | jq -r '.name')
    if ! job_trace=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/${JOB_ID}/trace"); then
      log_error "Could not fetch trace for failed job ${JOB_ID}; skipping its log."
      continue
    fi
    JOB_LOG=$(printf '%s' "$job_trace" | tail -c 8000)
    CI_LOGS="${CI_LOGS}
--- Failed job: ${JOB_NAME} (id: ${JOB_ID}) ---
${JOB_LOG}
"
    log "  Collected log for failed job: $JOB_NAME ($JOB_ID)"
  done

  # If no failed jobs, grab the full pipeline status summary
  if [[ -z "$CI_LOGS" ]]; then
    local pipeline_jobs_json
    if ! pipeline_jobs_json=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${HEAD_PIPELINE_ID}/jobs?per_page=30"); then
      log_error "Pipeline job summary was unavailable; continuing without CI logs."
    elif ! echo "$pipeline_jobs_json" | jq -e '
      type == "array" and all(.[];
        type == "object" and
        (.name | type == "string" and length > 0) and
        (.status | type == "string" and length > 0)
      )
    ' >/dev/null 2>&1; then
      log_error "Pipeline job summary was malformed; continuing without CI logs."
    elif ! PIPELINE_JOBS=$(echo "$pipeline_jobs_json" | jq -r '.[] | "\(.name): \(.status)"'); then
      log_error "Pipeline job summary was malformed; continuing without CI logs."
    else
      CI_LOGS="All jobs in pipeline #${HEAD_PIPELINE_ID}:
${PIPELINE_JOBS}"
      log "  No failed jobs; collected pipeline summary."
    fi
  fi
}


