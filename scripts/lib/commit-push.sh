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
  if [[ -z $(git status --porcelain) ]]; then
    log "WARNING: $FILES_CHANGED file(s) were written but git sees no changes."
    git status
    return
  fi

  log "Staging changes..."
  # Exclude .gitlab/scripts/: claude-respond.sh's own runtime scripts get
  # fetched into the working tree by templates/claude.yml's before_script when
  # the consumer repo doesn't track them locally. Without this exclusion they
  # get swept into every LLM-authored commit as unrelated stray files.
  # See HACtions#48.
  git add -A -- . ':!.gitlab/scripts'
  git status --short
  # Project convention: "Acted-By: ci-bot" trailer identifies bot-authored commits.
  # Used by claude-review.sh to detect self-authored commits and auto-trigger fixes.
  # Not a standard Git trailer (like Co-authored-by:) — it's a project-specific
  # convention parsed via grep in the review script.
  #
  # "Review-Trigger-Count" persists the review→respond loop counter across the
  # push boundary (CI variables don't survive a git push). claude-review.sh reads
  # it back from the tip commit to advance the cap. See docs/adr-wip-lock.md.
  #
  # When CLAUDE_REVIEW_TRIGGER_COUNT is unset (e.g. a human re-invokes @claude
  # mid-MR), seed it from the current tip commit's trailer so we don't reset the
  # budget to 0 and re-open an unbounded loop. Validate to an integer afterwards.
  if [[ -z "${CLAUDE_REVIEW_TRIGGER_COUNT:-}" ]]; then
    CLAUDE_REVIEW_TRIGGER_COUNT=$(git log -1 --format='%B' HEAD 2>/dev/null \
      | sed -n 's/^Review-Trigger-Count:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1)
  fi
  REVIEW_TRIGGER_COUNT="${CLAUDE_REVIEW_TRIGGER_COUNT:-0}"
  [[ "$REVIEW_TRIGGER_COUNT" =~ ^[0-9]+$ ]] || REVIEW_TRIGGER_COUNT=0
  git commit -m "fix: apply changes requested via @claude (iteration ${ITERATION})

Triggered by comment on MR !${CLAUDE_MR_IID}

Acted-By: ci-bot
Review-Trigger-Count: ${REVIEW_TRIGGER_COUNT}"
  log "Committed. Pushing to origin/$MR_SOURCE_BRANCH..."

  if git push origin "HEAD:refs/heads/${MR_SOURCE_BRANCH}" 2>&1 | tee /tmp/push_output.txt; then
    log "✅ Push succeeded."
    ensure_claude_owned_label "$CLAUDE_MR_IID"
    post_mr_comment "✅ Changes have been committed and pushed to branch \`${MR_SOURCE_BRANCH}\` (iteration ${ITERATION})."

    # Resolve auto-review threads on files we just touched.
    # NOTE: resolve_addressed_threads runs immediately after the push, before
    # the new review pipeline has a chance to re-raise any findings. This is
    # an intentional race: threads on touched files are resolved optimistically,
    # and resolve_verified_threads (in the review job) will re-open them if the
    # reviewer re-raises the same finding. The two paths are complementary, not
    # conflicting, but the ordering means a re-raised finding may briefly appear
    # resolved until the new review summary posts.
    #
    # Use diff-tree as the primary method: it works for all commit types
    # (initial, merge, normal) without special-casing HEAD~1 existence.
    local pushed_files
    pushed_files=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)
    # Use log (not log_error) — an empty diff-tree result is not an error;
    # it can happen legitimately on an empty-tree initial commit.
    [[ -z "$pushed_files" ]] && log "  Warning: could not determine pushed files — skipping thread resolution"
    if [[ -n "$pushed_files" ]]; then
      log "Resolving review threads addressed by this push..."
      resolve_addressed_threads "$CLAUDE_MR_IID" "$pushed_files" || true
    fi
  else
    PUSH_ERROR=$(cat /tmp/push_output.txt)
    [[ -n "${GITLAB_TOKEN:-}" ]] && PUSH_ERROR=$(echo "$PUSH_ERROR" | sed "s/${GITLAB_TOKEN}/***REDACTED***/g")
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

  # Wip-lock release is handled by the EXIT trap (single release point).
  # No explicit release here — avoids a redundant API call on every run.

  if [[ -n "${EDIT_FAILURES:-}" ]]; then
    react_to_comment "warning"
  elif [[ "${HTTP_CODE:-}" != "200" ]]; then
    react_to_comment "x"
  else
    react_to_comment "white_check_mark"
  fi
}
