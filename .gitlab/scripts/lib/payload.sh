#!/usr/bin/env bash
# =============================================================================
# Payload parsing, @claude detection, bot guards, MR/Issue extraction
# =============================================================================

parse_payload() {
  log_step "PAYLOAD PARSING"

  # Support both file-type variable (webhook path) and inline JSON (self-iteration).
  # Self-iteration sends TRIGGER_PAYLOAD_JSON as a regular variable; write it to
  # a temp file so the rest of the function works uniformly.
  if [[ ! -f "${TRIGGER_PAYLOAD:-/nonexistent}" && -n "${TRIGGER_PAYLOAD_JSON:-}" ]]; then
    TRIGGER_PAYLOAD=$(mktemp)
    printf '%s' "$TRIGGER_PAYLOAD_JSON" > "$TRIGGER_PAYLOAD"
    log "Using TRIGGER_PAYLOAD_JSON (self-iteration path) → temp file: $TRIGGER_PAYLOAD"
  fi

  if [[ ! -f "${TRIGGER_PAYLOAD:-/nonexistent}" ]]; then
    log_error "No TRIGGER_PAYLOAD file found at '${TRIGGER_PAYLOAD:-<unset>}'."
    log "  Hint: Was this triggered via webhook? The webhook must POST to the"
    log "  Pipeline Triggers API URL with the payload as a file-type variable."
    log "  Check Settings → Webhooks → Recent Deliveries for errors."
    exit 1
  fi

  log "TRIGGER_PAYLOAD file: $TRIGGER_PAYLOAD ($(wc -c < "$TRIGGER_PAYLOAD") bytes)"
  PAYLOAD=$(cat "$TRIGGER_PAYLOAD")

  # Verify this is a Note event on a MergeRequest or Issue
  NOTEABLE_TYPE=$(echo "$PAYLOAD" | jq -r '.object_attributes.noteable_type // ""')
  if [[ "$NOTEABLE_TYPE" != "MergeRequest" && "$NOTEABLE_TYPE" != "Issue" ]]; then
    log "Not a MergeRequest or Issue comment (got: '$NOTEABLE_TYPE') — skipping."
    exit 0
  fi

  # Extract comment body and check for @claude mention
  CLAUDE_COMMENT_BODY=$(echo "$PAYLOAD" | jq -r '.object_attributes.note // ""')
  log "Comment body (first 200 chars): $(echo "$CLAUDE_COMMENT_BODY" | head -c 200)"

  if ! echo "$CLAUDE_COMMENT_BODY" | grep -qi "@claude"; then
    log "Comment does not mention @claude — skipping."
    exit 0
  fi

  # Ignore bot/self comments to prevent infinite loops
  COMMENT_AUTHOR=$(echo "$PAYLOAD" | jq -r '.user.username // ""')

  # Guard 1: Username-based filter (catches project access tokens with "bot" in name)
  # Exception: "claude-auto-review" is a synthetic trigger from the auto-review script
  # that asks the bot to address review findings — this must NOT be filtered out.
  if echo "$COMMENT_AUTHOR" | grep -qiE "(bot|claude)" && [[ "$COMMENT_AUTHOR" != "claude-auto-review" ]]; then
    log "Ignoring comment from bot user: $COMMENT_AUTHOR"
    exit 0
  fi

  # Guard 2: Explicit bot username match (for PATs that post as a real user)
  CLAUDE_BOT_USERNAME="${CLAUDE_BOT_USERNAME:-}"
  if [[ -n "$CLAUDE_BOT_USERNAME" && "$COMMENT_AUTHOR" == "$CLAUDE_BOT_USERNAME" ]]; then
    log "Ignoring comment from configured bot user: $COMMENT_AUTHOR"
    exit 0
  fi

  # Guard 3: Content-based filter — ignore comments that look like bot output.
  # Patterns are specific enough to avoid swallowing legitimate user comments.
  # Note: literal '[' must be escaped as '\[' to avoid grep treating it as a character class.
  # IMPORTANT: The self-iteration synthetic payload (iterate.sh _trigger_next_iteration)
  # uses text "@claude CI is still failing..." which intentionally does NOT match these
  # prefixes. If you add new bot-output prefixes here, verify they don't collide with
  # the iteration re-trigger text.
  if echo "$CLAUDE_COMMENT_BODY" | grep -qE "^(🤖 \*\*Claude Response|👀 On it — \\[follow along|✅ Changes have been committed|✅ Changes pushed to |✅ I've implemented|✅ CI passed after iteration|🔄 CI failed after iteration|⚠️ Reached maximum iteration|❌ \*\*Push failed)"; then
    log "Ignoring comment that matches bot output pattern (self-trigger guard)"
    exit 0
  fi

  # Extract MR or Issue IID
  CLAUDE_MR_IID=""
  CLAUDE_ISSUE_IID=""

  if [[ "$NOTEABLE_TYPE" == "MergeRequest" ]]; then
    CLAUDE_MR_IID=$(echo "$PAYLOAD" | jq -r '.merge_request.iid // ""')
    if [[ -z "$CLAUDE_MR_IID" ]]; then
      log_error "Could not extract MR IID from payload."
      log "  Payload keys: $(echo "$PAYLOAD" | jq -r 'keys[]' | tr '\n' ' ')"
      log "  merge_request field: $(echo "$PAYLOAD" | jq '.merge_request')"
      exit 1
    fi
    log "Processing @claude request on MR !${CLAUDE_MR_IID}"
  else
    CLAUDE_ISSUE_IID=$(echo "$PAYLOAD" | jq -r '.issue.iid // .object_attributes.noteable_iid // ""')
    if [[ -z "$CLAUDE_ISSUE_IID" ]]; then
      log_error "Could not extract Issue IID from payload."
      log "  Payload keys: $(echo "$PAYLOAD" | jq -r 'keys[]' | tr '\n' ' ')"
      log "  issue field: $(echo "$PAYLOAD" | jq '.issue')"
      exit 1
    fi
    log "Processing @claude request on Issue #${CLAUDE_ISSUE_IID}"
  fi
  log "  Author: $COMMENT_AUTHOR"
  log "  Comment ID: $(echo "$PAYLOAD" | jq -r '.object_attributes.id // "unknown"')"

  # Acknowledge immediately with a 👀 reaction and a comment linking to the running job.
  # Skip for synthetic self-iteration payloads (note_id == 0) to avoid cluttering the MR.
  local _note_id
  _note_id=$(echo "$PAYLOAD" | jq -r '.object_attributes.id // ""')
  if [[ "$_note_id" != "0" ]]; then
    log "Posting acknowledgement reaction and job link..."
    react_to_comment "eyes"
    post_comment "👀 On it — [follow along in the CI job](${CI_JOB_URL})"
  else
    log "Synthetic iteration payload (note_id=0) — skipping ack comment"
  fi
  # ACKNOWLEDGED=true even for synthetic payloads — the cleanup_handler uses it to
  # decide whether to call react_to_comment, which is a no-op for note_id=0 anyway
  # (double-guarded by the sentinel check in react_to_comment itself).
  ACKNOWLEDGED=true
}
