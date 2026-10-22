#!/usr/bin/env bash
# =============================================================================
# Commit & push for Issue-triggered changes, open/link MR
# =============================================================================

_commit_push_issue() {
  log "Issue comment with file changes — committing to $NEW_BRANCH..."

  if [[ -z $(git status --porcelain) ]]; then
    log "WARNING: Files were written but git sees no changes on branch."
    return
  fi

  # Exclude .gitlab/scripts/: see commit-push.sh for why. HACtions#48.
  git add -A -- . ':!.gitlab/scripts'
  git status --short
  git commit -m "feat: implement changes for issue #${CLAUDE_ISSUE_IID}

Requested via @claude comment on issue #${CLAUDE_ISSUE_IID}: ${ISSUE_TITLE}

Acted-By: ci-bot"
  log "Committed changes to $NEW_BRANCH"

  if git push origin "HEAD:refs/heads/${NEW_BRANCH}" 2>&1 | tee /tmp/push_output.txt; then
    log "✅ Push succeeded."
    _open_or_link_mr
  else
    PUSH_ERROR=$(cat /tmp/push_output.txt)
    [[ -n "${GITLAB_TOKEN:-}" ]] && PUSH_ERROR=$(echo "$PUSH_ERROR" | sed "s/${GITLAB_TOKEN}/***REDACTED***/g")
    log_error "Push FAILED: $PUSH_ERROR"
    post_issue_comment "❌ Failed to push branch \`${NEW_BRANCH}\`:\n\`\`\`\n${PUSH_ERROR}\n\`\`\`"
  fi
}

_open_or_link_mr() {
  EXISTING_MR=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests?source_branch=${NEW_BRANCH}&state=opened" \
    | jq -r '.[0] // empty')
  EXISTING_MR_IID=$(echo "$EXISTING_MR" | jq -r '.iid // empty')
  EXISTING_MR_URL=$(echo "$EXISTING_MR" | jq -r '.web_url // empty')

  if [[ -n "$EXISTING_MR_IID" ]]; then
    log "MR !${EXISTING_MR_IID} already open for branch $NEW_BRANCH — skipping creation."
    post_issue_comment "✅ Changes pushed to existing MR !${EXISTING_MR_IID}: ${EXISTING_MR_URL}"
  else
    # Build a substantive MR description from the bot's response
    local mr_description
    mr_description="## Summary

${RESPONSE:-_No summary provided._}

---

Implements changes requested in issue #${CLAUDE_ISSUE_IID}.

Closes #${CLAUDE_ISSUE_IID}"

    MR_PAYLOAD=$(jq -n \
      --arg title "feat: ${ISSUE_TITLE}" \
      --arg desc "$mr_description" \
      --arg source "$NEW_BRANCH" \
      --arg target "$DEFAULT_BRANCH" \
      '{title: $title, description: $desc, source_branch: $source, target_branch: $target}')
    MR_RESPONSE=$(curl -s --request POST \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      --header "Content-Type: application/json" \
      --data "$MR_PAYLOAD" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests")
    NEW_MR_IID=$(echo "$MR_RESPONSE" | jq -r '.iid // empty')
    NEW_MR_URL=$(echo "$MR_RESPONSE" | jq -r '.web_url // empty')

    if [[ -n "$NEW_MR_IID" ]]; then
      log "✅ Opened MR !${NEW_MR_IID}: $NEW_MR_URL"
      ensure_claude_owned_label "$NEW_MR_IID"
      post_issue_comment "✅ I've implemented the requested changes and opened MR !${NEW_MR_IID}: ${NEW_MR_URL}"
    else
      log_error "Failed to open MR. Response: $(echo "$MR_RESPONSE" | head -c 500)"
      post_issue_comment "✅ Changes pushed to branch \`${NEW_BRANCH}\`, but MR creation failed. Please open one manually."
    fi
  fi
}
