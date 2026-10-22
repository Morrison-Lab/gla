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
  ISSUE_NOTES=""

  if [[ "$NOTEABLE_TYPE" == "MergeRequest" ]]; then
    # MR changes: fetch full JSON, extract file list BEFORE truncation, then format diff
    log "Fetching MR diff..."
    local MR_CHANGES_JSON
    MR_CHANGES_JSON=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/changes")
    # Extract file list from JSON (not from truncated text) — used by scope guard
    MR_DIFF_FILES=$(echo "$MR_CHANGES_JSON" | jq -r '.changes[].new_path' \
      | grep -vxF '/dev/null' | sort -u)
    # Format diff text for LLM context (truncated to 40KB).
    # Note: head -c is byte-based and may split multibyte UTF-8 characters at the
    # boundary. This is acceptable since the output is consumed by jq --rawfile
    # which tolerates partial sequences, and the LLM handles minor encoding noise.
    MR_DIFF=$(echo "$MR_CHANGES_JSON" \
      | jq -r '.changes[] | "--- \(.old_path)\n+++ \(.new_path)\n\(.diff)"' \
      | head -c 40000)
    local file_count="${MR_DIFF_FILES:+$(echo "$MR_DIFF_FILES" | wc -l | tr -d ' ')}"
    log "  MR diff: ${#MR_DIFF} bytes (${file_count:-0} files)"

    # Recent MR discussion (last 20 notes for thread context)
    log "Fetching MR discussion..."
    MR_NOTES=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/notes?sort=desc&per_page=20" \
      | jq -r '.[] | "[\(.author.username) @ \(.created_at)]: \(.body)"' \
      | tac \
      | head -c 15000)
    log "  MR notes: ${#MR_NOTES} bytes"
  else
    # Issue discussion (last 20 notes)
    log "Fetching Issue discussion..."
    ISSUE_NOTES=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}/notes?sort=desc&per_page=20" \
      | jq -r '.[] | "[\(.author.username) @ \(.created_at)]: \(.body)"' \
      | tac \
      | head -c 15000)
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
  local TREE_LIMIT=200
  local FULL_TREE
  FULL_TREE=$(find . -not -path './.git/*' -not -path './node_modules/*' \
    -not -path './ci/lib/*' -not -path './R_libs/*' \
    -not -path './.gitlab/scripts/*' \
    | sort)
  local TREE_COUNT
  TREE_COUNT=$(echo "$FULL_TREE" | wc -l | tr -d ' ')
  REPO_TREE=$(echo "$FULL_TREE" | head -n "$TREE_LIMIT")
  if [[ "$TREE_COUNT" -gt "$TREE_LIMIT" ]]; then
    REPO_TREE="${REPO_TREE}
... (tree truncated: showing ${TREE_LIMIT} of ${TREE_COUNT} entries)"
  fi
  log "  Tree entries: ${TREE_COUNT} (capped at ${TREE_LIMIT})"

  # Key file contents the model might need
  _gather_key_files
}

_gather_ci_logs() {
  log "Fetching CI job info from pipeline #${HEAD_PIPELINE_ID}..."
  FAILED_JOBS=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${HEAD_PIPELINE_ID}/jobs?scope[]=failed&per_page=10" \
    | jq -r '.[].id' 2>/dev/null || true)
  log "  Failed job IDs: ${FAILED_JOBS:-none}"

  for JOB_ID in $FAILED_JOBS; do
    JOB_NAME=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/${JOB_ID}" \
      | jq -r '.name')
    JOB_LOG=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/${JOB_ID}/trace" \
      | tail -c 8000)
    CI_LOGS="${CI_LOGS}
--- Failed job: ${JOB_NAME} (id: ${JOB_ID}) ---
${JOB_LOG}
"
    log "  Collected log for failed job: $JOB_NAME ($JOB_ID)"
  done

  # If no failed jobs, grab the full pipeline status summary
  if [[ -z "$CI_LOGS" ]]; then
    PIPELINE_JOBS=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${HEAD_PIPELINE_ID}/jobs?per_page=30" \
      | jq -r '.[] | "\(.name): \(.status)"')
    CI_LOGS="All jobs in pipeline #${HEAD_PIPELINE_ID}:
${PIPELINE_JOBS}"
    log "  No failed jobs; collected pipeline summary."
  fi
}


