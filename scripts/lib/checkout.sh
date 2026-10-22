#!/usr/bin/env bash
# =============================================================================
# Checkout the working branch (MR source or new issue branch)
# =============================================================================

checkout_context() {
  log_step "CONTEXT CHECKOUT"

  # Initialize variables used later
  MR_SOURCE_BRANCH=""
  MR_TITLE=""
  MR_DESCRIPTION=""
  TARGET_BRANCH=""
  HEAD_PIPELINE_ID=""
  ISSUE_TITLE=""
  ISSUE_DESCRIPTION=""

  if [[ "$NOTEABLE_TYPE" == "MergeRequest" ]]; then
    _checkout_mr_branch
  else
    _checkout_issue_branch
  fi
}

_checkout_mr_branch() {
  if ! MR_DATA=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}"); then
    log_error "Could not fetch MR !${CLAUDE_MR_IID}; cannot check out its source branch."
    return 1
  fi
  if ! echo "$MR_DATA" | jq -e '
    type == "object" and
    (.source_branch | type == "string" and length > 0) and
    (.target_branch | type == "string" and length > 0) and
    (.title | type == "string" and length > 0) and
    (.description == null or (.description | type == "string")) and
    (.sha == null or (.sha | type == "string")) and
    (.head_pipeline == null or (
      (.head_pipeline | type == "object") and
      (.head_pipeline.id == null or (.head_pipeline.id | type == "number"))
    ))
  ' >/dev/null 2>&1; then
    log_error "Response for MR !${CLAUDE_MR_IID} was malformed; cannot check out its source branch."
    return 1
  fi
  MR_SOURCE_BRANCH=$(echo "$MR_DATA" | jq -r '.source_branch')
  MR_TITLE=$(echo "$MR_DATA" | jq -r '.title')
  MR_DESCRIPTION=$(echo "$MR_DATA" | jq -r '.description // ""')
  TARGET_BRANCH=$(echo "$MR_DATA" | jq -r '.target_branch')
  MR_HEAD_SHA=$(echo "$MR_DATA" | jq -r '.sha // empty')
  HEAD_PIPELINE_ID=$(echo "$MR_DATA" | jq -r '.head_pipeline.id // empty')

  log "Source branch: $MR_SOURCE_BRANCH"
  log "Target branch: $TARGET_BRANCH"
  log "Head pipeline: ${HEAD_PIPELINE_ID:-none}"

  # Configure git for pushing
  PUSH_URL="https://oauth2:${GITLAB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
  git remote set-url origin "$PUSH_URL"
  git config user.email "claude-bot@gitlab.ci"
  git config user.name "Claude Bot"

  git fetch origin "$MR_SOURCE_BRANCH"
  git checkout -B "$MR_SOURCE_BRANCH" "origin/$MR_SOURCE_BRANCH"
  CHECKED_OUT_SHA=$(git rev-parse HEAD)
  validate_triggering_review_head "${TRIGGERING_REVIEW_SHA:-}" "$CHECKED_OUT_SHA"
  log "Checked out $MR_SOURCE_BRANCH at $(git rev-parse --short HEAD)"
}

validate_triggering_review_head() {
  local reviewed_sha="$1"
  local current_sha="$2"

  [[ -n "$reviewed_sha" ]] || return 0
  if [[ ! "$reviewed_sha" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "Triggering review SHA is malformed; refusing auto-fix."
    return 1
  fi
  if [[ "$reviewed_sha" != "$current_sha" ]]; then
    log_error "Triggering review SHA does not match the current MR head; refusing stale auto-fix."
    return 1
  fi
}

_checkout_issue_branch() {
  if ! ISSUE_DATA=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}"); then
    log_error "Could not fetch Issue #${CLAUDE_ISSUE_IID}; cannot create its work branch."
    return 1
  fi
  if ! echo "$ISSUE_DATA" | jq -e '
    type == "object" and
    (.title | type == "string" and length > 0) and
    (.description == null or (.description | type == "string"))
  ' >/dev/null 2>&1; then
    log_error "Response for Issue #${CLAUDE_ISSUE_IID} was malformed; cannot create its work branch."
    return 1
  fi
  ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')
  ISSUE_DESCRIPTION=$(echo "$ISSUE_DATA" | jq -r '.description // ""')
  log "Issue title: $ISSUE_TITLE"

  # Configure git for pushing
  PUSH_URL="https://oauth2:${GITLAB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
  git remote set-url origin "$PUSH_URL"
  git config user.email "claude-bot@gitlab.ci"
  git config user.name "Claude Bot"

  # Derive branch name from issue IID + title slug
  ISSUE_SLUG=$(echo "${ISSUE_TITLE}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)
  if [[ -z "$ISSUE_SLUG" ]]; then
    ISSUE_SLUG="work"
  fi
  NEW_BRANCH="claude/issue-${CLAUDE_ISSUE_IID}-${ISSUE_SLUG}"
  DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

  # Validate branch name (prevent command injection)
  if ! echo "$NEW_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$'; then
    log_error "Generated branch name contains invalid characters: $NEW_BRANCH"
    exit 1
  fi

  # Checkout the issue branch
  git fetch origin "$DEFAULT_BRANCH"
  if git fetch origin "$NEW_BRANCH" 2>/dev/null; then
    git checkout -B "$NEW_BRANCH" "origin/$NEW_BRANCH"
    log "Checked out existing issue branch $NEW_BRANCH from remote"

    # Keep the branch up to date with the default branch
    if git merge-base --is-ancestor "origin/$DEFAULT_BRANCH" HEAD; then
      log "Branch is already up to date with $DEFAULT_BRANCH"
    else
      log "Merging $DEFAULT_BRANCH into $NEW_BRANCH to stay current..."
      if git merge "origin/$DEFAULT_BRANCH" --no-edit -m "Merge $DEFAULT_BRANCH into $NEW_BRANCH"; then
        log "Merge succeeded"
      else
        log_error "Merge conflict merging $DEFAULT_BRANCH into $NEW_BRANCH"
        log "Aborting merge and continuing with stale branch (model will work on current state)"
        git merge --abort
      fi
    fi
  else
    git checkout -B "$NEW_BRANCH" "origin/$DEFAULT_BRANCH"
    log "Created new issue branch $NEW_BRANCH from $DEFAULT_BRANCH"
  fi
  log "On branch $NEW_BRANCH at $(git rev-parse --short HEAD)"
}
