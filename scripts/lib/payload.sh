#!/usr/bin/env bash
# =============================================================================
# Payload parsing, @claude detection, bot guards, MR/Issue extraction
# =============================================================================

parse_payload() {
  log_step "PAYLOAD PARSING"

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
  COMMENT_AUTHOR=$(echo "$PAYLOAD" | jq -r '.user.username // ""')
  TRIGGERING_REVIEW_NOTE_ID=$(echo "$PAYLOAD" | jq -r '.object_attributes.review_note_id // empty')
  TRIGGERING_REVIEW_SHA=$(echo "$PAYLOAD" | jq -r '.object_attributes.review_sha // empty')
  TRIGGERING_REVIEW_BODY_HASH=$(echo "$PAYLOAD" | jq -r '.object_attributes.review_body_hash // empty')
  validate_triggering_review_anchor \
    "$TRIGGERING_REVIEW_NOTE_ID" "$TRIGGERING_REVIEW_SHA" "$TRIGGERING_REVIEW_BODY_HASH"
  log "Comment body (first 200 chars): $(echo "$CLAUDE_COMMENT_BODY" | head -c 200)"

  # Require @claude at line-start (after optional markdown prefixes: blockquote
  # markers, list bullets). Rejects mid-sentence mentions. See README for full
  # examples. Known limitations: N) syntax not matched; fenced blocks can trigger.
  # ERE syntax, compatible with alpine/busybox grep.
  if ! echo "$CLAUDE_COMMENT_BODY" | grep -qiE '^[[:space:]]*(>[[:space:]]*)*(([*+-]|[0-9]+\.)[[:space:]]+)?@claude'; then
    log "Comment does not contain an @claude invocation — skipping."
    log "  (Hint: @claude must appear at the start of a line, optionally after"
    log "   markdown prefixes like >, -, *, or 1. to trigger a response.)"
    exit 0
  fi

  # Ignore bot/self comments to prevent infinite loops

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

  # -----------------------------------------------------------------------
  # CONCURRENCY GUARD + SIGNAL ACQUISITION
  # Advisory wip signal: check → set. See docs/adr-wip-lock.md for design.
  # -----------------------------------------------------------------------
  if [[ -n "$CLAUDE_MR_IID" ]]; then
    NON_SELF_WIP=$(get_non_self_wip_signals "$CLAUDE_MR_IID")
    if [[ "$NON_SELF_WIP" == "__API_ERROR__" ]]; then
      log_error "Cannot verify wip signal state — failing closed to avoid conflicts."
      exit 1
    fi
    if [[ -n "$NON_SELF_WIP" ]]; then
      log "MR !${CLAUDE_MR_IID} is locked by another actor: $NON_SELF_WIP"
      log "Skipping to avoid conflicts. Remove the wip: label to unlock."
      exit 0
    fi
    # Set signal immediately — fail-open (see docs/adr-wip-lock.md).
    if set_wip_signal "$CLAUDE_MR_IID"; then
      : # already logged inside set_wip_signal
    else
      log_error "Failed to set wip signal — proceeding without signal."
    fi
  fi

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

  # -----------------------------------------------------------------------
  # MODEL SELECTION from comment directives
  # Supports: @claude --model <name>  or  @claude --model=<name>
  # Aliases: opus, sonnet, haiku → full Databricks model names.
  # If present, exports CLAUDE_MODEL so lib/llm.sh picks it up.
  # -----------------------------------------------------------------------
  parse_model_directive
}

validate_triggering_review_anchor() {
  local note_id="$1"
  local reviewed_sha="$2"
  local body_hash="$3"

  if [[ -z "$note_id" && -z "$reviewed_sha" && -z "$body_hash" ]]; then
    if [[ "$COMMENT_AUTHOR" == "claude-auto-review" ]]; then
      log_error "Synthetic auto-fix requests require a complete review anchor."
      return 1
    fi
    return 0
  fi
  if [[ "$NOTEABLE_TYPE" != "MergeRequest" ]]; then
    log_error "Triggering review anchors are valid only for merge-request payloads."
    return 1
  fi
  if [[ ! "$note_id" =~ ^[1-9][0-9]*$ ||
        ! "$reviewed_sha" =~ ^[0-9a-f]{40}$ ||
        ! "$body_hash" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "Triggering review anchor is incomplete or malformed; refusing auto-fix."
    return 1
  fi
}

# Parse --model directive from CLAUDE_COMMENT_BODY and export CLAUDE_MODEL.
# Called at the end of parse_payload. Safe to call multiple times (idempotent).
parse_model_directive() {
  local model_arg=""

  # Match: --model <value> or --model=<value> (case-insensitive flag, value preserved)
  # Looks anywhere in the comment body — not just the @claude line — so users
  # can put it on a continuation line if they prefer.
  model_arg=$(echo "$CLAUDE_COMMENT_BODY" | { grep -oiE '\-\-model[= ]+[a-zA-Z0-9_.-]+'  || true; } | head -n1 | sed -E 's/--model[= ]+//i')

  if [[ -z "$model_arg" ]]; then
    return 0
  fi

  # Map short aliases to full Databricks endpoint names
  case "${model_arg,,}" in
    opus|opus-4|claude-opus)
      CLAUDE_MODEL="databricks-claude-opus-4-8"
      ;;
    sonnet|sonnet-4|claude-sonnet)
      CLAUDE_MODEL="databricks-claude-sonnet-4-6"
      ;;
    haiku|haiku-3.5|claude-haiku)
      CLAUDE_MODEL="databricks-claude-haiku-3-5"
      ;;
    *)
      # Assume it's a full model name (e.g., databricks-claude-opus-4-8)
      CLAUDE_MODEL="$model_arg"
      ;;
  esac

  export CLAUDE_MODEL
  log "Model override from comment: $CLAUDE_MODEL (parsed from '--model $model_arg')"
}
