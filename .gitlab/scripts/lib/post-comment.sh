#!/usr/bin/env bash
# =============================================================================
# Format and post the LLM response as a GitLab comment
# =============================================================================

post_response_comment() {
  log_step "POSTING MR COMMENT"

  # Clean up the response text
  CLEAN_RESPONSE="$RESPONSE"
  # Strip fenced code blocks longer than 20 lines
  CLEAN_RESPONSE=$(echo "$CLEAN_RESPONSE" | perl -0777 -pe '
    s/```[^\n]*\n((?:.*\n){20,}?)```/[_code block omitted — see MR diff_]\n/g
  ')
  # Trim leading/trailing whitespace
  CLEAN_RESPONSE=$(echo "$CLEAN_RESPONSE" | sed '/^$/N;/^\n$/d')

  # If any tool calls failed to apply, append a note
  if [[ -n "${EDIT_FAILURES:-}" ]]; then
    CLEAN_RESPONSE="${CLEAN_RESPONSE}

⚠️ **Some edits could not be applied automatically:**
$(printf '%b' "$EDIT_FAILURES")
Please re-check the affected files (the current contents may differ from what I expected)."
  fi

  ITERATION="${CLAUDE_ITERATION:-1}"
  MAX_ITERATIONS="${CLAUDE_MAX_ITERATIONS:-3}"

  if [[ $FILES_CHANGED -gt 0 ]]; then
    COMMENT_PREFIX="🤖 **Claude Response** (iteration ${ITERATION}/${MAX_ITERATIONS} — pushing changes)"
  else
    COMMENT_PREFIX="🤖 **Claude Response**"
  fi

  # Guard: truncate if response exceeds GitLab's ~1MB note limit
  FULL_COMMENT="${COMMENT_PREFIX}

$CLEAN_RESPONSE"
  MAX_COMMENT_BYTES=900000
  COMMENT_SIZE=${#FULL_COMMENT}
  if [[ $COMMENT_SIZE -gt $MAX_COMMENT_BYTES ]]; then
    log "WARNING: Comment size (${COMMENT_SIZE} bytes) exceeds limit — truncating."
    FULL_COMMENT="${FULL_COMMENT:0:$MAX_COMMENT_BYTES}

---
⚠️ **Response truncated** (${COMMENT_SIZE} bytes exceeded the ${MAX_COMMENT_BYTES}-byte limit). See the [full output in the CI job log](${CI_JOB_URL})."
  fi

  post_comment "$FULL_COMMENT"
  if [[ "$NOTEABLE_TYPE" == "MergeRequest" ]]; then
    log "Posted comment to MR !${CLAUDE_MR_IID}"
  else
    log "Posted comment to Issue #${CLAUDE_ISSUE_IID}"
  fi
}
