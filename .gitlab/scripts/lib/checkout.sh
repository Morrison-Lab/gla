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
  MR_DATA=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CLAUDE_MR_IID}")
  MR_SOURCE_BRANCH=$(echo "$MR_DATA" | jq -r '.source_branch')
  MR_TITLE=$(echo "$MR_DATA" | jq -r '.title')
  MR_DESCRIPTION=$(echo "$MR_DATA" | jq -r '.description // ""')
  TARGET_BRANCH=$(echo "$MR_DATA" | jq -r '.target_branch')
  HEAD_PIPELINE_ID=$(echo "$MR_DATA" | jq -r '.head_pipeline.id // empty')

  # Validate branch name (defense-in-depth, symmetric with _checkout_issue_branch)
  if [[ ! "$MR_SOURCE_BRANCH" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
    log_error "Invalid MR source branch name: '$MR_SOURCE_BRANCH'"
    exit 1
  fi

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
  log "Checked out $MR_SOURCE_BRANCH at $(git rev-parse --short HEAD)"
}

_checkout_issue_branch() {
  ISSUE_DATA=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/issues/${CLAUDE_ISSUE_IID}")
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
