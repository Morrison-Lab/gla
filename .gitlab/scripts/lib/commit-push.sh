#!/usr/bin/env bash
# =============================================================================
# Commit changes, push to remote — dispatcher + MR push logic
# =============================================================================
# Requires: _commit_push_issue (git-push-issue.sh), _self_iterate (iterate.sh)

commit_and_push() {
  log_step "COMMIT & PUSH"

  ITERATION="${CLAUDE_ITERATION:-1}"
  MAX_ITERATIONS="${CLAUDE_MAX_ITERATIONS:-3}"

  if [[ "$NOTEABLE_TYPE" == "Issue" && $FILES_CHANGED -gt 0 ]]; then
    _commit_push_issue
  elif [[ "$NOTEABLE_TYPE" == "Issue" ]]; then
    log "Issue comment with no file changes — nothing to commit."
  elif [[ $FILES_CHANGED -gt 0 ]]; then
    _commit_push_mr
  else
    log "No files changed — nothing to commit."
  fi
}

_commit_push_mr() {
  # Note: _check_scope_guard (apply-changes.sh) runs `git add -A` before this
  # function, so the index already reflects all tool-call writes. git status
  # --porcelain reports both staged and unstaged changes, so this check is valid
  # regardless of whether the scope guard ran.
  if [[ -z $(git status --porcelain) ]]; then
    log "WARNING: $FILES_CHANGED file(s) were written but git sees no changes (edits may have produced identical content)."
    git status
    post_mr_comment "🤖 Claude processed ${FILES_CHANGED} tool call(s) but the resulting files are identical to the current branch state — no net changes to commit."
    return
  fi

  log "Staging changes..."
  git add -A
  git status --short
  git commit -m "fix: apply changes requested via @claude (iteration ${ITERATION})

Triggered by comment on MR !${CLAUDE_MR_IID}"
  log "Committed. Pushing to origin/$MR_SOURCE_BRANCH..."

  if git push origin "HEAD:refs/heads/${MR_SOURCE_BRANCH}" 2>&1 | tee /tmp/push_output.txt; then
    log "✅ Push succeeded."
    ensure_claude_owned_label "$CLAUDE_MR_IID"
    post_mr_comment "✅ Changes have been committed and pushed to branch \`${MR_SOURCE_BRANCH}\` (iteration ${ITERATION})."
  else
    PUSH_ERROR=$(cat /tmp/push_output.txt)
    [[ -n "${GITLAB_TOKEN:-}" ]] && PUSH_ERROR=$(echo "$PUSH_ERROR" | sed "s#${GITLAB_TOKEN}#***REDACTED***#g")
    log_error "Push FAILED!"
    log_error "$PUSH_ERROR"
    post_mr_comment "❌ **Push failed** (iteration ${ITERATION}):
\`\`\`
$PUSH_ERROR
\`\`\`
Possible causes:
- The project access token may lack \`write_repository\` scope
- The branch may be protected (token role needs Developer or higher)
- The token may have expired

Check **Settings → Access Tokens** and **Settings → Repository → Protected Branches**."
    exit 1
  fi

  # Self-iteration (defined in iterate.sh)
  _self_iterate
}

finalize() {
  log_step "DONE"

  if [[ -n "${EDIT_FAILURES:-}" ]]; then
    react_to_comment "warning" || true
  elif [[ "${LLM_HTTP_CODE:-}" != "200" ]]; then
    react_to_comment "x" || true
  else
    react_to_comment "white_check_mark" || true
  fi
}
