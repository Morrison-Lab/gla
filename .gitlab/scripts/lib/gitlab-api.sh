#!/usr/bin/env bash
# =============================================================================
# GitLab API helpers (requires GITLAB_TOKEN, CI_API_V4_URL, CI_PROJECT_ID)
# =============================================================================

# GET helper: returns body, logs URL on failure
gl_api() {
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$1")
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" != "200" ]]; then
    log_error "GitLab API returned HTTP $http_code for: $1"
    local safe_body
    safe_body=$(echo "$body" | head -c 500)
    [[ -n "${GITLAB_TOKEN:-}" ]] && safe_body=$(echo "$safe_body" | sed "s#${GITLAB_TOKEN}#***REDACTED***#g")
    log_error "Response body: $safe_body"
  fi
  echo "$body"
}

# Post a comment on an MR
post_mr_comment() {
  local body_text="$1"
  local tmpfile json_file
  tmpfile=$(mktemp) || { log_error "mktemp failed"; return 1; }
  json_file=$(mktemp) || { rm -f "$tmpfile"; log_error "mktemp failed"; return 1; }
  printf '%s' "$body_text" > "$tmpfile"
  if ! jq -n --rawfile body "$tmpfile" '{body: $body}' > "$json_file"; then
    log_error "Failed to build comment JSON payload"
    rm -f "$tmpfile" "$json_file"
    return 1
  fi
  curl -s --request POST \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data @"$json_file" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/notes" > /dev/null
  rm -f "$tmpfile" "$json_file"
}

# Post a comment on an Issue
post_issue_comment() {
  local body_text="$1"
  local tmpfile json_file
  tmpfile=$(mktemp) || { log_error "mktemp failed"; return 1; }
  json_file=$(mktemp) || { rm -f "$tmpfile"; log_error "mktemp failed"; return 1; }
  printf '%s' "$body_text" > "$tmpfile"
  if ! jq -n --rawfile body "$tmpfile" '{body: $body}' > "$json_file"; then
    log_error "Failed to build comment JSON payload"
    rm -f "$tmpfile" "$json_file"
    return 1
  fi
  curl -s --request POST \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data @"$json_file" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}/notes" > /dev/null
  rm -f "$tmpfile" "$json_file"
}

# Post a comment to whichever noteable type is active
post_comment() {
  if [[ "${NOTEABLE_TYPE}" == "MergeRequest" ]]; then
    post_mr_comment "$1"
  else
    post_issue_comment "$1"
  fi
}

# Ensure the "claude-owned" label is on an MR (idempotent)
ensure_claude_owned_label() {
  local mr_iid="$1"
  curl -s --request PUT \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data '{"add_labels": "claude-owned"}' \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}" > /dev/null
  log "Applied 'claude-owned' label to MR !${mr_iid}"
}

# Add an emoji reaction to the triggering comment.
# note_id == "0" is the sentinel for synthetic self-iteration payloads
# (see iterate.sh _trigger_next_iteration) — no real note exists to react to.
react_to_comment() {
  local emoji="$1"
  local note_id
  note_id=$(echo "$PAYLOAD" | jq -r '.object_attributes.id // ""')
  [[ -z "$note_id" || "$note_id" == "0" ]] && return
  local json_data http_resp
  json_data=$(jq -n --arg name "$emoji" '{name: $name}')
  if [[ "${NOTEABLE_TYPE}" == "MergeRequest" ]]; then
    http_resp=$(curl -s -o /dev/null -w "%{http_code}" --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --header "Content-Type: application/json" \
      --data "$json_data" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/notes/${note_id}/award_emoji")
  else
    http_resp=$(curl -s -o /dev/null -w "%{http_code}" --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --header "Content-Type: application/json" \
      --data "$json_data" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}/notes/${note_id}/award_emoji")
  fi
  if [[ "$http_resp" != "201" && "$http_resp" != "200" ]]; then
    log "  ⚠ react_to_comment '$emoji' returned HTTP $http_resp (non-fatal)"
  fi
  return 0
}
