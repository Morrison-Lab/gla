#!/usr/bin/env bash
# =============================================================================
# Self-iteration: wait for CI pipeline, re-trigger on failure
# =============================================================================
#
# Signal handoff: the parent holds wip:ci-bot while polling the child pipeline.
# The child's parse_payload filters out wip:ci-bot (get_non_self_wip_signals) so it
# doesn't self-block, then re-sets it (idempotent label add). In the normal
# success/failure paths the signal is held continuously through child completion.
#
# CAVEAT: this is NOT a hard guarantee. On the timeout (MAX_WAIT) or
# canceled/skipped branches, _self_iterate returns and the parent's EXIT trap
# clears the label while the child may still be running — an unguarded window.
# This is bounded by resource_group: claude-agent on respond (no parallel writes)
# and MAX_ITERATIONS. See docs/adr-wip-lock.md.

_self_iterate() {
  if [[ -z "${CLAUDE_TRIGGER_TOKEN:-}" ]]; then
    log "Self-iteration disabled (CLAUDE_TRIGGER_TOKEN not set)."
    return
  fi

  if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    log "Reached max iterations ($MAX_ITERATIONS). Stopping."
    post_mr_comment "⚠️ Reached maximum iteration limit (${MAX_ITERATIONS}). CI may still have issues — please review manually or post another \`@claude\` comment."
    return
  fi

  log_step "SELF-ITERATION (waiting for CI)"
  log "Iteration $ITERATION/$MAX_ITERATIONS — will wait for CI and re-trigger if it fails."

  # Wait for the new pipeline to appear and finish (poll every 30s, max 10 min)
  sleep 15
  WAIT_SECONDS=0
  MAX_WAIT=600

  local encoded_source_branch
  encoded_source_branch=$(urlencode_query_value "$MR_SOURCE_BRANCH")

  while [[ $WAIT_SECONDS -lt $MAX_WAIT ]]; do
    local latest_pipelines_json
    if ! latest_pipelines_json=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines?ref=${encoded_source_branch}&per_page=1&sort=desc"); then
      log_error "Could not query the latest pipeline; retrying in 30 seconds."
      sleep 30
      WAIT_SECONDS=$((WAIT_SECONDS + 30))
      continue
    fi
    if ! LATEST_PIPELINE=$(echo "$latest_pipelines_json" \
      | jq -e -r '.[0] | objects | select((.id | type) == "number" and (.status | type) == "string")'); then
      log_error "Latest pipeline response was malformed; retrying in 30 seconds."
      sleep 30
      WAIT_SECONDS=$((WAIT_SECONDS + 30))
      continue
    fi
    NEW_PIPELINE_ID=$(echo "$LATEST_PIPELINE" | jq -r '.id')
    PIPELINE_STATUS=$(echo "$LATEST_PIPELINE" | jq -r '.status')

    # Skip if it's the same pipeline that triggered us
    if [[ "$NEW_PIPELINE_ID" == "${CI_PIPELINE_ID:-}" ]]; then
      log "  Still seeing our own pipeline (#$NEW_PIPELINE_ID) — waiting..."
      sleep 30
      WAIT_SECONDS=$((WAIT_SECONDS + 30))
      continue
    fi

    log "  Pipeline #$NEW_PIPELINE_ID status: $PIPELINE_STATUS (waited ${WAIT_SECONDS}s)"

    case "$PIPELINE_STATUS" in
      success)
        log "✅ CI passed! No further iteration needed."
        post_mr_comment "✅ CI passed after iteration ${ITERATION}. All green! 🎉"
        break
        ;;
      failed)
        log "❌ CI failed — triggering iteration $((ITERATION + 1))..."
        post_mr_comment "🔄 CI failed after iteration ${ITERATION}. Auto-triggering iteration $((ITERATION + 1))/${MAX_ITERATIONS}..."
        _trigger_next_iteration
        break
        ;;
      canceled|skipped)
        log "Pipeline was $PIPELINE_STATUS — not iterating."
        break
        ;;
      *)
        sleep 30
        WAIT_SECONDS=$((WAIT_SECONDS + 30))
        ;;
    esac
  done

  if [[ $WAIT_SECONDS -ge $MAX_WAIT ]]; then
    log "Timed out waiting for pipeline after ${MAX_WAIT}s. Stopping iteration."
    post_mr_comment "⏱️ Timed out waiting for CI pipeline to complete (${MAX_WAIT}s). You can manually trigger another \`@claude\` comment to continue."
  fi
}

_trigger_next_iteration() {
  NEXT_ITERATION=$((ITERATION + 1))
  RETRIGGER_COMMENT="@claude CI is still failing after your last fix (iteration ${ITERATION}). Please look at the new CI errors and fix them. This is auto-iteration ${NEXT_ITERATION}/${MAX_ITERATIONS}."

  RETRIGGER_PAYLOAD=$(jq -n \
    --arg note "$RETRIGGER_COMMENT" \
    --arg noteable_type "MergeRequest" \
    --arg username "$COMMENT_AUTHOR" \
    --arg mr_iid "$CLAUDE_MR_IID" \
    '{
      object_attributes: {
        note: $note,
        noteable_type: $noteable_type,
        id: 0
      },
      user: { username: $username },
      merge_request: { iid: ($mr_iid | tonumber) }
    }')

  # Forward CLAUDE_REVIEW_TRIGGER_COUNT so the review→respond cap persists
  # across self-iteration hops (otherwise it resets to 0 on the child pipeline).
  TRIGGER_RESPONSE=$(curl -s --request POST \
    --form "token=${CLAUDE_TRIGGER_TOKEN}" \
    --form "ref=${CI_DEFAULT_BRANCH:-main}" \
    --form "variables[TRIGGER_PAYLOAD_JSON]=$RETRIGGER_PAYLOAD" \
    --form "variables[CLAUDE_ITERATION]=$NEXT_ITERATION" \
    --form "variables[CLAUDE_REVIEW_TRIGGER_COUNT]=${CLAUDE_REVIEW_TRIGGER_COUNT:-0}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/trigger/pipeline")
  TRIGGERED_ID=$(echo "$TRIGGER_RESPONSE" | jq -r '.id // empty')
  if [[ -n "$TRIGGERED_ID" ]]; then
    log "Re-triggered pipeline #$TRIGGERED_ID for iteration $NEXT_ITERATION."
  else
    log_error "Failed to re-trigger pipeline!"
    log_error "Response: $TRIGGER_RESPONSE"
    post_mr_comment "⚠️ Failed to auto-trigger iteration $NEXT_ITERATION. Please post another \`@claude\` comment manually."
  fi
}
