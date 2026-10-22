#!/usr/bin/env bash

normalize_findings_json() {
  local findings_json="$1"
  local changed_files="$2"

  jq -c --arg changed_files "$changed_files" '[.[] | select(
    type == "object" and
    (.file | type == "string" and length > 0) and
    (.file as $file | ($changed_files | split("\n") | map(select(length > 0)) | index($file)) != null) and
    (.line | type == "number" and . > 0 and floor == .) and
    (.severity == "high" or .severity == "medium" or .severity == "low") and
    (.message | type == "string" and length > 0)
  )]' <<< "$findings_json"
}
# =============================================================================
# GitLab API helpers (requires GITLAB_TOKEN, CI_API_V4_URL, CI_PROJECT_ID)
# =============================================================================

urlencode_query_value() {
  jq -rn --arg value "$1" '$value | @uri'
}

# Apply the review's remaining wall-clock budget to every GitLab request. The
# deadline is intentionally evaluated at call time because these helpers are
# also used after the model request, when little time may remain.
review_curl() {
  local -a curl_args=()
  if [[ "${REVIEW_DEADLINE:-}" =~ ^[0-9]+$ ]]; then
    local remaining=$((REVIEW_DEADLINE - $(date +%s)))
    (( remaining > 0 )) || return 124
    curl_args+=(--max-time "$remaining")
  fi
  curl "${curl_args[@]}" "$@"
}

# GET helper: returns body, logs URL on failure
gl_api() {
  local url="$1"
  local response http_code body
  local -a curl_args=(--globoff -sS -w "\n%{http_code}" --header "PRIVATE-TOKEN: $GITLAB_TOKEN")
  if [[ "${REVIEW_DEADLINE:-}" =~ ^[0-9]+$ ]]; then
    local api_remaining=$((REVIEW_DEADLINE - $(date +%s)))
    if [[ "$api_remaining" -le 0 ]]; then
      log_error "GitLab API request skipped because the review deadline was exceeded: $url"
      return 1
    fi
    curl_args+=(--max-time "$api_remaining")
  fi
  if [[ "${GL_API_MAX_BYTES:-}" =~ ^[1-9][0-9]*$ ]]; then
    curl_args+=(--max-filesize "$GL_API_MAX_BYTES")
  fi
  if ! response=$(review_curl "${curl_args[@]}" "$url"); then
    log_error "GitLab API request failed for: $url"
    return 1
  fi
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" != "200" ]]; then
    log_error "GitLab API returned HTTP $http_code for: $url"
    local safe_body
    safe_body=$(echo "$body" | head -c 500)
    [[ -n "${GITLAB_TOKEN:-}" ]] && safe_body=$(echo "$safe_body" | sed "s/${GITLAB_TOKEN}/***REDACTED***/g")
    log_error "Response body: $safe_body"
    return 1
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
  review_curl -s --request POST \
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
  review_curl -s --request POST \
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

# -----------------------------------------------------------------------
# WIP-label advisory signal — see docs/adr-wip-lock.md for design rationale.
# Real serialization: `resource_group: claude-agent` on the CI job.
# -----------------------------------------------------------------------

# Canonical label name — used in all check/acquire/release paths.
# Guarded against double-sourcing: if this file is sourced multiple times in the
# same shell (e.g. by both claude-respond.sh and a future module), the readonly
# would abort under set -e on the second source.
[[ -n "${WIP_BOT_LABEL:-}" ]] || readonly WIP_BOT_LABEL="wip:ci-bot"

# Fetch all labels from an MR, one per line. On API/parse failure echoes the
# sentinel "__API_ERROR__" so callers can fail-closed. Shared by the wip-lock
# helpers to avoid duplicating the curl+http_code+sed boilerplate (TODO #7).
_fetch_mr_labels() {
  local mr_iid="$1"
  local response http_code body labels

  response=$(review_curl -s -w "\n%{http_code}" --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}")
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    local safe_body
    safe_body=$(echo "$body" | head -c 200)
    [[ -n "${GITLAB_TOKEN:-}" ]] && safe_body=$(echo "$safe_body" | sed "s/${GITLAB_TOKEN}/***REDACTED***/g")
    log_error "Failed to fetch MR !${mr_iid} labels (HTTP $http_code): $safe_body"
    echo "__API_ERROR__"
    return 0
  fi

  labels=$(echo "$body" | jq -r '.labels // [] | .[]' 2>/dev/null || echo "__API_ERROR__")
  if [[ "$labels" == "__API_ERROR__" ]]; then
    log_error "Failed to parse labels JSON for MR !${mr_iid}"
    echo "__API_ERROR__"
    return 0
  fi
  echo "$labels"
}

# Fetch non-self wip: labels from an MR. Returns one label per line (empty if none).
# On API failure, returns the string "__API_ERROR__" so callers can fail-closed.
get_non_self_wip_signals() {
  local mr_iid="$1"
  local labels
  labels=$(_fetch_mr_labels "$mr_iid")
  if [[ "$labels" == "__API_ERROR__" ]]; then
    echo "__API_ERROR__"
    return 0
  fi
  # Case-insensitive wip: match, exact-case exclusion of our own label.
  # A differently-cased "WIP:ci-bot" is treated as non-self (human intent).
  echo "$labels" | grep -i "^wip:" | grep -v "^${WIP_BOT_LABEL}$" || true
}

# Check if the bot's own wip signal is currently set on an MR.
# Returns 0 (true) if wip:ci-bot is present, 1 (false) otherwise.
# On API failure returns 1 (fail-open: caller should use separate fail-closed checks).
has_bot_wip_signal() {
  local mr_iid="$1"
  local labels
  labels=$(_fetch_mr_labels "$mr_iid")
  [[ "$labels" == "__API_ERROR__" ]] && return 1
  echo "$labels" | grep -qi "^${WIP_BOT_LABEL}$"
}

# Set the wip:ci-bot signal label. Returns 0 on success, 1 on failure.
# PUT returns 200 whether label was newly added or already present (idempotent).
set_wip_signal() {
  local mr_iid="$1"
  local response http_code

  response=$(review_curl -s -w "\n%{http_code}" --request PUT \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"add_labels\": \"${WIP_BOT_LABEL}\"}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}")
  http_code=$(echo "$response" | tail -n1)

  if [[ "$http_code" != "200" ]]; then
    local safe_body
    safe_body=$(echo "$response" | sed '$d' | head -c 200)
    [[ -n "${GITLAB_TOKEN:-}" ]] && safe_body=$(echo "$safe_body" | sed "s/${GITLAB_TOKEN}/***REDACTED***/g")
    log_error "Failed to set wip signal on MR !${mr_iid} (HTTP $http_code): $safe_body"
    return 1
  fi

  log "Set ${WIP_BOT_LABEL} signal on MR !${mr_iid}"
  return 0
}

# Clear the wip:ci-bot signal label from an MR (idempotent, best-effort).
# Returns 0 on success, 1 on failure (so callers can gate cleanup on it).
#
# ACCEPTED RISK: If a human manually adds exactly "wip:ci-bot" (not "wip:human"
# or another label), the bot's EXIT trap will remove it. This is unlikely in
# practice (humans use wip:human or wip:<name>), and the label is advisory —
# real serialization is via resource_group. See docs/adr-wip-lock.md.
clear_wip_signal() {
  local mr_iid="$1"
  local response http_code
  response=$(review_curl -s -w "\n%{http_code}" --request PUT \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"remove_labels\": \"${WIP_BOT_LABEL}\"}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}")
  http_code=$(echo "$response" | tail -n1)
  if [[ "$http_code" == "200" ]]; then
    log "Cleared ${WIP_BOT_LABEL} signal on MR !${mr_iid}"
    return 0
  else
    local safe_body
    safe_body=$(echo "$response" | sed '$d' | head -c 200)
    [[ -n "${GITLAB_TOKEN:-}" ]] && safe_body=$(echo "$safe_body" | sed "s/${GITLAB_TOKEN}/***REDACTED***/g")
    log_error "Failed to clear ${WIP_BOT_LABEL} signal on MR !${mr_iid} (HTTP $http_code): $safe_body"
    return 1
  fi
}

# Ensure the "claude-owned" label is on an MR (idempotent)
ensure_claude_owned_label() {
  local mr_iid="$1"
  review_curl -s --request PUT \
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
  if [[ "${NOTEABLE_TYPE}" == "MergeRequest" ]]; then
    review_curl -s --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --header "Content-Type: application/json" \
      --data "{\"name\": \"${emoji}\"}" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}/notes/${note_id}/award_emoji" > /dev/null
  else
    review_curl -s --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --header "Content-Type: application/json" \
      --data "{\"name\": \"${emoji}\"}" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}/notes/${note_id}/award_emoji" > /dev/null
  fi
}

# -----------------------------------------------------------------------
# Resolve auto-review threads whose findings were addressed by a commit.
# -----------------------------------------------------------------------
# Only resolves threads that:
#   1. Are primary or legacy auto-review threads
#   2. Are still unresolved
#   3. Reference a file that was touched in the given commit (changed_files list)
#
# Usage: resolve_addressed_threads <mr_iid> <changed_files>
#   changed_files: newline-separated list of file paths modified in the push
#
# Design: review findings should only be resolved when actually addressed —
# not blanket-resolved on each new review run. This function is called after
# the respond agent pushes a fix, so only findings on files it touched get
# resolved. Findings on untouched files remain open for human attention.
#
# Resolution is FILE-GRANULAR for primary and legacy findings. Companion
# findings stay open until the companion reviewer verifies them in
# resolve_verified_threads(), which prevents the response agent from clearing
# an independent companion finding.
resolve_addressed_threads() {
  local mr_iid="$1"
  local changed_files="$2"
  local discussions page=1 resolved_count=0

  if [[ -z "$changed_files" ]]; then
    log "  No changed files — skipping thread resolution."
    return 0
  fi

  # Thread resolution is best-effort: stop safely if any discussion page is
  # unavailable or malformed rather than aborting the caller.
  while true; do
    if ! discussions=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/discussions?per_page=100&page=${page}"); then
      log_error "Could not fetch MR !${mr_iid} discussions page ${page}; skipping remaining thread resolution."
      break
    fi
    if ! echo "$discussions" | jq -e '
      type == "array" and
      all(.[]; type == "object" and (.id | type == "string" or type == "number") and
        (.notes | type == "array") and all(.notes[]; type == "object"))
    ' >/dev/null 2>&1; then
      log_error "MR !${mr_iid} discussions page ${page} was malformed; skipping remaining thread resolution."
      break
    fi

    if [[ "$(echo "$discussions" | jq 'length')" -eq 0 ]]; then
      break
    fi

    # Find colon-bearing primary-reviewer tags, colon-free transitional model
    # tags, and bare legacy tags. Other colon-bearing tags are reviewer-scoped
    # and must remain independent even when their reviewer ID starts databricks-.
    # Find unresolved auto-review inline threads (DiffNote with position).
    # For each, check if the file referenced in the position was touched.
    local thread_info
    if ! thread_info=$(echo "$discussions" | jq -r '
      .[] | select(
        .notes[0].body != null and
        (.notes[0].body | test("^🔍 (\\[primary:[^]]+\\] |\\[databricks-[^]:]+\\] )?[🔴🟡🔵⚪]")) and
        (.notes[0].type == "DiffNote") and
        (.notes[0].resolvable == true) and
        (.notes[0].resolved == false) and
        (.notes[0].position.new_path != null)
      ) | "\(.id)\t\(.notes[0].position.new_path)"'); then
      log_error "MR !${mr_iid} discussions page ${page} contained malformed note fields; skipping remaining thread resolution."
      break
    fi

    # Log if jq produced no threads despite a non-empty page — could indicate
    # a jq selector mismatch or unexpected API response shape.
    local page_count
    page_count=$(echo "$discussions" | jq 'if type=="array" then length else 0 end')
    if [[ -z "$(echo "$thread_info" | tr -d '[:space:]')" && "$page_count" -gt 0 ]]; then
      log "  No matching threads on page $page ($page_count discussion(s)) — possible selector mismatch or all threads already resolved."
    fi

    local tid fpath
    while IFS=$'\t' read -r tid fpath; do
      [[ -z "$tid" ]] && continue
      # Only resolve if the file was touched in this commit
      if echo "$changed_files" | grep -qxF "$fpath"; then
        local resolve_response resolve_code
        resolve_response=$(review_curl -s -w "\n%{http_code}" --request PUT \
          --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
          "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/discussions/${tid}?resolved=true")
        resolve_code=$(echo "$resolve_response" | tail -n1)
        if [[ "$resolve_code" == "200" ]]; then
          log "  Resolved addressed thread: $tid (file: $fpath)"
          resolved_count=$((resolved_count + 1))
        else
          log_error "  Failed to resolve thread $tid (HTTP $resolve_code)"
        fi
      fi
    done <<< "$thread_info"

    page=$((page + 1))
    if [[ $page -gt 10 ]]; then
      log "  Warning: hit 10-page cap while resolving addressed threads"
      break
    fi
  done

  log "Resolved $resolved_count addressed review thread(s)."
}

# -----------------------------------------------------------------------
# Resolve prior auto-review threads verified as addressed by a new review.
# -----------------------------------------------------------------------
# Called by the REVIEW agent after posting new findings. Logic:
#   - For each unresolved prior auto-review inline thread (DiffNote):
#     * If the file it references was changed in the MR, AND
#     * The new review's FINDINGS_JSON does NOT contain a finding on the
#       same file+line (i.e., the reviewer looked and didn't re-raise it),
#     * Then the prior finding is considered verified-addressed → resolve it.
#   - Threads on files NOT in the current diff are left alone (the reviewer
#     may not have re-examined them).
#
# Usage: resolve_verified_threads <mr_iid> <findings_json> <changed_files> <reviewer_id> <include_legacy>
#   findings_json:  the JSON array of new findings from this review run
#   changed_files:  newline-separated list of files the reviewer examined in
#                   THIS review run — typically the files in the latest push
#                   (git diff-tree --no-commit-id --name-only -r HEAD), NOT
#                   the full MR diff. Only threads on these files are eligible
#                   for resolution; threads on files the reviewer didn't
#                   re-examine in this cycle are left open.
resolve_verified_threads() {
  local mr_iid="$1"
  local new_findings_json="$2"
  local changed_files="${3:-}"
  local reviewer_id="${4:-}"
  local include_legacy="${5:-false}"
  local discussions page=1 resolved_count=0

  if [[ -z "$reviewer_id" ]]; then
    log "  Warning: reviewer identity is empty — skipping verified thread resolution."
    return 0
  fi

  # Build a lookup of new findings as "file:line" for fast matching.
  # If findings_json is empty/null, all prior threads on changed files resolve.
  local new_finding_keys
  # Normalize .line to an integer via tonumber|floor so float (42.0) or
  # quoted-string ("42") LLM output still matches the thread's integer line.
  new_finding_keys=$(echo "$new_findings_json" | jq -r '
    if type == "array" then .[] | "\(.file):\(.line | tonumber | floor)" else empty end
  ' 2>/dev/null || true)

  # Distinguish a valid empty-findings array (clean review) from a malformed or
  # missing LLM response. Both result in empty new_finding_keys, but the
  # behaviors should differ:
  #   - Valid "[]"  → clean review; resolve all prior threads on changed files.
  #   - Malformed   → parse failure; skip resolution to avoid silently clearing
  #                   the thread backlog on a transient LLM error.
  if [[ -z "$new_finding_keys" ]]; then
    if echo "$new_findings_json" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1; then
      log "  No new findings (clean review) — all prior threads on changed files will be resolved."
    else
      log "  Warning: new_findings_json is empty or malformed — skipping thread resolution to avoid clearing threads on a parse failure."
      return 0
    fi
  fi

  # Thread resolution is best-effort: stop safely if any discussion page is
  # unavailable or malformed rather than aborting the review job.
  while true; do
    if ! discussions=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/discussions?per_page=100&page=${page}"); then
      log_error "Could not fetch MR !${mr_iid} discussions page ${page}; skipping remaining verified thread resolution."
      break
    fi
    if ! echo "$discussions" | jq -e '
      type == "array" and
      all(.[]; type == "object" and (.id | type == "string" or type == "number") and
        (.notes | type == "array") and all(.notes[]; type == "object"))
    ' >/dev/null 2>&1; then
      log_error "MR !${mr_iid} discussions page ${page} was malformed; skipping remaining verified thread resolution."
      break
    fi

    if [[ "$(echo "$discussions" | jq 'length')" -eq 0 ]]; then
      break
    fi

    # Find reviewer-owned tags plus colon-free transitional model tags and bare
    # legacy tags when requested. Other colon-bearing tags belong to another
    # reviewer identity and must not be adopted through the legacy path.
    # Find unresolved auto-review inline threads with position info.
    # Exclude the summary thread (which starts with "🔍 **Auto-review").
    local thread_info
    if ! thread_info=$(echo "$discussions" | jq -r \
      --arg prefix "🔍 [${reviewer_id}:" \
      --argjson include_legacy "$include_legacy" '
      .[] | select(
        .notes[0].body != null and
        ((.notes[0].body | startswith($prefix)) or
         ($include_legacy and
          (.notes[0].body | test("^🔍 (\\[databricks-[^]:]+\\] )?[🔴🟡🔵⚪]")))) and
        (.notes[0].type == "DiffNote") and
        (.notes[0].resolvable == true) and
        (.notes[0].resolved == false) and
        (.notes[0].position.new_path != null) and
        (.notes[0].position.new_line != null)
      ) | "\(.id)\t\(.notes[0].position.new_path)\t\(.notes[0].position.new_line)"'); then
      log_error "MR !${mr_iid} discussions page ${page} contained malformed note fields; skipping remaining verified thread resolution."
      break
    fi

    local tid fpath fline
    while IFS=$'\t' read -r tid fpath fline; do
      [[ -z "$tid" ]] && continue

      # Only consider threads on files in the current diff (reviewer saw them)
      if ! echo "$changed_files" | grep -qxF "$fpath"; then
        continue
      fi

      # If the new review re-raised a finding on the same file:line, skip
      local key="${fpath}:${fline}"
      if echo "$new_finding_keys" | grep -qxF "$key"; then
        continue
      fi

      # The reviewer saw this file, didn't re-raise the finding → resolved
      local resolve_response resolve_code
      resolve_response=$(review_curl -s -w "\n%{http_code}" --request PUT \
        --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/discussions/${tid}?resolved=true")
      resolve_code=$(echo "$resolve_response" | tail -n1)
      if [[ "$resolve_code" == "200" ]]; then
        log "  Resolved verified-addressed thread: $tid (${fpath}:${fline})"
        resolved_count=$((resolved_count + 1))
      else
        log_error "  Failed to resolve thread $tid (HTTP $resolve_code)"
      fi
    done <<< "$thread_info"

    page=$((page + 1))
    if [[ $page -gt 10 ]]; then
      log "  Warning: hit 10-page cap while resolving verified threads"
      break
    fi
  done

  log "Resolved $resolved_count verified-addressed review thread(s)."
}
