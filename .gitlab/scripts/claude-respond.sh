#!/usr/bin/env bash
# =============================================================================
# Claude Agent — responds to @claude mentions in MR or Issue comments
# =============================================================================
# Called by the claude-respond CI job. Expects:
#   - $TRIGGER_PAYLOAD (file-type variable from webhook trigger)
#   - $GITLAB_TOKEN (project access token with api scope + write_repository)
#   - $ANTHROPIC_API_KEY or $ANTHROPIC_AUTH_TOKEN (Databricks PAT)
#   - $ANTHROPIC_BASE_URL (Databricks serving-endpoints base)
#   - Standard GitLab CI variables: CI_API_V4_URL, CI_PROJECT_ID,
#     CI_SERVER_HOST, CI_PROJECT_PATH
#
# Optional (for self-iteration):
#   - $CLAUDE_TRIGGER_TOKEN (pipeline trigger token, to re-trigger self)
#   - $CLAUDE_MAX_ITERATIONS (default: 3)
#
# Dependencies (installed in before_script): curl, git, jq, perl
# =============================================================================

set -euo pipefail

# Resolve the directory containing this script (for sourcing lib/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library modules. Order is not load-bearing — all functions are defined
# and top-level variables (including TOOLS_JSON) are set once sourcing completes.
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
source "${SCRIPT_DIR}/lib/payload.sh"
source "${SCRIPT_DIR}/lib/checkout.sh"
source "${SCRIPT_DIR}/lib/key-files.sh"
source "${SCRIPT_DIR}/lib/gather.sh"
source "${SCRIPT_DIR}/lib/prompt.sh"
source "${SCRIPT_DIR}/lib/tools-schema.sh"
source "${SCRIPT_DIR}/lib/llm.sh"
source "${SCRIPT_DIR}/lib/edit-file.sh"
source "${SCRIPT_DIR}/lib/apply-changes.sh"
source "${SCRIPT_DIR}/lib/post-comment.sh"
source "${SCRIPT_DIR}/lib/git-push-issue.sh"
source "${SCRIPT_DIR}/lib/iterate.sh"
source "${SCRIPT_DIR}/lib/commit-push.sh"

# Track whether we've acknowledged the comment (for completion reactions)
ACKNOWLEDGED=false

# Unified EXIT trap: close CI sections AND add ❌ reaction on unexpected failure
cleanup_handler() {
  local exit_code=$?
  close_sections
  if [[ $exit_code -ne 0 && "$ACKNOWLEDGED" == "true" ]]; then
    react_to_comment "x" 2>/dev/null || true
  fi
}
trap cleanup_handler EXIT

# --- Main flow ---
parse_payload
checkout_context
gather_context
build_prompt
call_llm
apply_changes
post_response_comment
commit_and_push
finalize
