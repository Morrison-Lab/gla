#!/usr/bin/env bash
# =============================================================================
# Automatic MR review — reviews new commits pushed to MR branches
# =============================================================================
# Called by the claude-review CI job on branch pipelines when an MR is open.
# (The template uses: $CI_COMMIT_BRANCH && $CI_OPEN_MERGE_REQUESTS)
# Expects:
#   - $GITLAB_TOKEN (project access token with api scope)
#   - $ANTHROPIC_API_KEY or $ANTHROPIC_AUTH_TOKEN (Databricks PAT)
#   - $ANTHROPIC_BASE_URL (Databricks serving-endpoints base)
#   - Standard GitLab CI variables: CI_API_V4_URL, CI_PROJECT_ID,
#     CI_COMMIT_SHA, CI_COMMIT_SHORT_SHA, CI_COMMIT_MESSAGE, CI_PIPELINE_URL,
#     CI_COMMIT_BRANCH, CI_DEFAULT_BRANCH
#   - MR metadata is looked up via API using CI_COMMIT_BRANCH (branch pipelines
#     don't have CI_MERGE_REQUEST_* variables)
#
# Dependencies (installed in before_script): curl, git, jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_START_EPOCH=$(date +%s)
if [[ -n "${CI_JOB_STARTED_AT:-}" ]]; then
  CI_JOB_EPOCH=$(date -d "$CI_JOB_STARTED_AT" +%s 2>/dev/null || true)
  [[ "$CI_JOB_EPOCH" =~ ^[0-9]+$ ]] && REVIEW_START_EPOCH="$CI_JOB_EPOCH"
fi

# ---------------------------------------------------------------
# Logging helpers (with GitLab CI collapsible sections)
# ---------------------------------------------------------------
source "${SCRIPT_DIR}/lib/logging.sh"
cleanup() {
  close_sections
  rm -f "${REQUEST_FILE:-}" "${PROMPT_FILE:-}" "${DIFF_FILE:-}" "${INITIAL_REQUEST_FILE:-}"
  if [[ -n "${REQUEST_FILE:-}" ]]; then
    rm -f "${REQUEST_FILE}".*
  fi
  return 0
}
trap cleanup EXIT

# Source shared GitLab API helpers. MUST come after logging.sh (which defines
# log/log_error that gitlab-api.sh uses).
# COUPLING: path must match templates/claude.yml .hac-claude-review before_script.
# See issue #12 (wip-signal.sh extraction) for planned decoupling.
source "${SCRIPT_DIR}/lib/gitlab-api.sh"
source "${SCRIPT_DIR}/lib/select-author-response.sh"
source "${SCRIPT_DIR}/lib/select-review-note.sh"
source "${SCRIPT_DIR}/lib/validate-nonnegative-integer.sh"
source "${SCRIPT_DIR}/lib/format-review-comment.sh"
source "${SCRIPT_DIR}/lib/review-tools.sh"
source "${SCRIPT_DIR}/lib/context-priority.sh"

# REVIEW_MODEL is the provider-neutral setting. CLAUDE_MODEL remains as a
# compatibility fallback for existing consumers of the claude.yml template.
MODEL="${REVIEW_MODEL:-${CLAUDE_MODEL:-databricks-gpt-5-6-sol}}"
REVIEWER_ID="${HAC_REVIEWER_ID:-primary}"
AGENT_MODE="${HAC_REVIEW_AGENT:-true}"
validate_boolean "HAC_REVIEW_AGENT" "$AGENT_MODE" || exit 1
REVIEW_DEADLINE_SECONDS=${HAC_REVIEW_DEADLINE_SECONDS:-480}
validate_nonnegative_integer "HAC_REVIEW_DEADLINE_SECONDS" "$REVIEW_DEADLINE_SECONDS" || exit 1
REVIEW_DEADLINE=$(( REVIEW_START_EPOCH + REVIEW_DEADLINE_SECONDS ))

# Helper: post an inline diff comment on a specific file/line in the MR.
# Uses the GitLab Discussions API with a position object to attach the comment
# to the diff view. Requires base_sha, head_sha, start_sha from MR versions.
# Falls back silently on failure (inline comments are best-effort).
post_inline_comment() {
  local mr_iid="$1" body_text="$2" file_path="$3" new_line="$4"
  local base_sha="$5" head_sha="$6" start_sha="$7"
  local tmpfile json_file response http_code

  # Self-enforcing guard: new_line must be a positive integer
  [[ "$new_line" =~ ^[1-9][0-9]*$ ]] || { log_error "post_inline_comment: invalid new_line '$new_line'"; return 1; }

  # Note: tmpfile/json_file are not registered with the global trap cleanup.
  # On signal interruption mid-curl they'd leak, but CI runners are ephemeral
  # so this is acceptable. All normal return paths (success + error) rm them.
  tmpfile=$(mktemp) || { log_error "mktemp failed"; return 1; }
  json_file=$(mktemp) || { rm -f "$tmpfile"; log_error "mktemp failed"; return 1; }
  printf '%s' "$body_text" > "$tmpfile"
  # Build the JSON payload with position for inline diff note.
  # new_line only (not old_line) → comment on an added/modified line.
  # Limitation: findings on context/unchanged lines (which require old_line in
  # GitLab's API) will be rejected (HTTP 400/422) and counted as INLINE_FAILURES.
  # This is the documented graceful-degradation path, not a bug.
  # NOTE: old_path is set equal to new_path — assumes no rename. Renamed files
  # are already filtered out upstream (CHANGED_FILES guard uses git diff names).
  if ! jq -n --rawfile body "$tmpfile" \
    --arg new_path "$file_path" \
    --arg old_path "$file_path" \
    --arg base_sha "$base_sha" \
    --arg head_sha "$head_sha" \
    --arg start_sha "$start_sha" \
    --argjson new_line "$new_line" \
    '{
      body: $body,
      position: {
        position_type: "text",
        base_sha: $base_sha,
        head_sha: $head_sha,
        start_sha: $start_sha,
        new_path: $new_path,
        old_path: $old_path,
        new_line: $new_line
      }
    }' > "$json_file"; then
    log_error "Failed to build inline comment JSON payload"
    rm -f "$tmpfile" "$json_file"
    return 1
  fi
  response=$(review_curl -s -w "\n%{http_code}" --request POST \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data @"$json_file" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/discussions")
  http_code=$(echo "$response" | tail -n1)
  rm -f "$tmpfile" "$json_file"
  if [[ "$http_code" != "201" ]]; then
    # Log but don't fail — inline comments are best-effort.
    # Distinguish expected rejections (4xx: line not in diff, invalid position)
    # from transient infrastructure errors (5xx/000: API outage, network blip).
    if [[ "$http_code" =~ ^4 ]]; then
      log_error "post_inline_comment: HTTP $http_code for ${file_path}:${new_line} — position rejected (non-fatal)"
    else
      log_error "post_inline_comment: HTTP $http_code for ${file_path}:${new_line} — transient API error (non-fatal)"
    fi
    return 1
  fi
}

# Helper: post a comment on an MR as a resolvable discussion thread.
# Old review threads are auto-resolved so the MR stays tidy.
# Distinct from the sourced post_mr_comment (which posts to /notes with a global
# $CLAUDE_MR_IID). This version posts to /discussions and takes mr_iid explicitly.
post_review_discussion() {
  local mr_iid="$1" body_text="$2" capture_anchor="${3:-false}"
  local tmpfile json_file response http_code
  tmpfile=$(mktemp) || { log_error "mktemp failed"; return 1; }
  json_file=$(mktemp) || { rm -f "$tmpfile"; log_error "mktemp failed"; return 1; }
  # Use --rawfile to safely handle large bodies with special characters
  printf '%s' "$body_text" > "$tmpfile"
  if ! jq -n --rawfile body "$tmpfile" '{body: $body}' > "$json_file"; then
    log_error "Failed to build comment JSON payload"
    rm -f "$tmpfile" "$json_file"
    return 1
  fi
  response=$(review_curl -s -w "\n%{http_code}" --request POST \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data @"$json_file" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/discussions")
  http_code=$(echo "$response" | tail -n1)
  rm -f "$tmpfile" "$json_file"
  if [[ "$http_code" != "201" ]]; then
    log_error "post_review_discussion: GitLab returned HTTP $http_code (expected 201)"
    return 1
  fi
  if [[ "$capture_anchor" == "true" ]]; then
    POSTED_REVIEW_NOTE_ID=$(echo "$response" | sed '$d' | jq -r '.notes[0].id // empty')
    if [[ ! "$POSTED_REVIEW_NOTE_ID" =~ ^[1-9][0-9]*$ ]]; then
      log_error "post_review_discussion: response did not contain a positive numeric note ID"
      POSTED_REVIEW_NOTE_ID=""
      return 1
    fi
    POSTED_REVIEW_BODY_HASH=$(echo "$response" | sed '$d' \
      | jq -j '.notes[0].body' | git hash-object --stdin)
  fi
}

# NOTE: resolve_old_review_threads was removed. Review threads are now resolved
# selectively by resolve_addressed_threads() (lib/gitlab-api.sh) only when the
# respond agent pushes a fix touching the relevant file. See commit message.

# ---------------------------------------------------------------
log_step "FINDING ASSOCIATED MR"
# ---------------------------------------------------------------

# Branch name — always available in branch pipelines.
BRANCH="${CI_COMMIT_BRANCH:-}"
log "Branch: $BRANCH"
log "Commit: ${CI_COMMIT_SHORT_SHA} — ${CI_COMMIT_MESSAGE%%$'\n'*}"

# Skip reviews on the default branch (only review MR branches)
DEFAULT_BRANCH="${CI_DEFAULT_BRANCH:-main}"
if [[ "$BRANCH" == "$DEFAULT_BRANCH" ]]; then
  log "Source branch matches default branch ($DEFAULT_BRANCH) — skipping review."
  exit 0
fi

# The commit to review — in branch pipelines this is the real source-branch tip.
REVIEW_SHA="$CI_COMMIT_SHA"

# Skip if the most recent commit was made by the Claude bot (avoid reviewing our
# own commits). Note: only checks the tip commit — if a multi-commit push has a
# mix of bot and human commits, the review still runs (acceptable trade-off).
# Set CLAUDE_SELF_REVIEW=true to disable this guard (e.g., for repos where Claude
# is the primary author and you still want reviews on its output).
COMMIT_AUTHOR=$(git log -1 --format='%ae' "$REVIEW_SHA" 2>/dev/null || echo "")
if [[ "${CLAUDE_SELF_REVIEW:-false}" != "true" ]] && echo "$COMMIT_AUTHOR" | grep -qi "claude-bot"; then
  log "Commit authored by Claude bot — skipping self-review."
  exit 0
fi

# Optional opt-in guard: skip merge commits if explicitly configured (default: false).
# By default, merge-commit MR heads (e.g. after syncing main) are reviewed against
# the target branch using the full MR diff (HACtions#74). Set HAC_SKIP_MERGE_COMMITS=true
# to restore the skip behavior for push-triggered reviews.
if [[ "${HAC_SKIP_MERGE_COMMITS:-false}" == "true" && "${CI_PIPELINE_SOURCE:-}" == "push" ]]; then
  PARENT_FIELD_COUNT=$(git rev-list --parents -n 1 "$REVIEW_SHA" 2>/dev/null | wc -w)
  if [[ "$PARENT_FIELD_COUNT" -gt 2 ]]; then
    log "HAC_SKIP_MERGE_COMMITS is enabled and merge commit detected ($((PARENT_FIELD_COUNT - 1)) parents) — skipping auto-review."
    exit 0
  fi
fi


# Look up the open MR for this branch via API.
# (Branch pipelines don't have CI_MERGE_REQUEST_* variables.)
ENCODED_BRANCH=$(urlencode_query_value "$BRANCH")
if ! MR_DATA=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests?source_branch=${ENCODED_BRANCH}&state=opened&per_page=1"); then
  log_error "Could not query the open MR for branch '$BRANCH'."
  exit 1
fi
if ! echo "$MR_DATA" | jq -e '
  type == "array" and
  (length == 0 or (
    (.[0] | type == "object") and
    (.[0].iid | type == "number") and
    (.[0].title | type == "string" and length > 0) and
    (.[0].target_branch | type == "string" and length > 0) and
    (.[0].author.username | type == "string" and length > 0) and
    (.[0].labels | type == "array" and all(.[]; type == "string")) and
    (.[0].description == null or (.[0].description | type == "string"))
  ))
' >/dev/null 2>&1; then
  log_error "Open-MR lookup for branch '$BRANCH' returned malformed data."
  exit 1
fi
MR_IID=$(echo "$MR_DATA" | jq -r '.[0].iid // empty')
MR_TITLE=$(echo "$MR_DATA" | jq -r '.[0].title // empty')
TARGET_BRANCH=$(echo "$MR_DATA" | jq -r '.[0].target_branch // empty')
MR_AUTHOR=$(echo "$MR_DATA" | jq -r '.[0].author.username // empty')
MR_LABELS=$(echo "$MR_DATA" | jq -r '.[0].labels // [] | join(",")')
MR_DESCRIPTION=$(echo "$MR_DATA" | jq -r '.[0].description // empty')

if [[ -z "$MR_IID" ]]; then
  log "No open MR found for branch '$BRANCH' — skipping review."
  exit 0
fi

# Truncate MR description to avoid prompt bloat (contains "Known Deferred Items"
# and "Notes for Automated Reviewers" sections that inform the reviewer about
# previously addressed concerns).
MAX_MR_DESCRIPTION_CHARS=${HAC_MAX_MR_DESCRIPTION_CHARS:-2000}
MR_DESCRIPTION="${MR_DESCRIPTION:0:$MAX_MR_DESCRIPTION_CHARS}"

# Check if the MR has the "claude-owned" label (signals Claude should auto-respond to reviews)
IS_CLAUDE_OWNED=false
if echo ",$MR_LABELS," | grep -qi ",claude-owned,"; then
  IS_CLAUDE_OWNED=true
fi

log "Found MR !${MR_IID}: ${MR_TITLE}"
log "Target branch: ${TARGET_BRANCH}"
# Note: IS_CLAUDE_OWNED is retained for informational logging only. The
# auto-trigger decision now relies on actual bot authorship (author email or
# Acted-By trailer), NOT this label — see the AUTO-TRIGGER block below.
[[ "$IS_CLAUDE_OWNED" == "true" ]] && log "MR has 'claude-owned' label (informational only — does not drive auto-trigger)"

# ---------------------------------------------------------------
log_step "GATHERING COMMIT DIFF"
# ---------------------------------------------------------------

# Get the FULL MR diff (merge-base with target branch → current HEAD).
# This ensures the review covers all changes in the MR, not just the latest push.
FETCH_REMAINING=$((REVIEW_DEADLINE - $(date +%s)))
if [[ "$FETCH_REMAINING" -gt 0 ]]; then
  timeout --signal=TERM "${FETCH_REMAINING}s" \
    git -c http.lowSpeedLimit=1 -c http.lowSpeedTime="$FETCH_REMAINING" \
      fetch origin "$TARGET_BRANCH" 2>/dev/null || true
else
  log "Review deadline exceeded before fetching the target branch; using available refs."
fi

MERGE_BASE=$(git merge-base "origin/$TARGET_BRANCH" "$REVIEW_SHA" 2>/dev/null || echo "")
USE_DIFF_ROOT=false
if [[ -z "$MERGE_BASE" ]]; then
  # Fallback: try parent commit. If this is a root commit (no parent),
  # use git diff --root to diff against the empty tree.
  # NOTE: rev-parse succeeding does NOT guarantee the parent tree is locally
  # present (e.g., in a shallow/grafted clone). That deeper edge case may still
  # yield an empty diff via the normal path — tracked as part of #29's scope note.
  if git rev-parse "${REVIEW_SHA}~1" >/dev/null 2>&1; then
    log "Cannot determine merge base — falling back to HEAD~1"
    MERGE_BASE="${REVIEW_SHA}~1"
  else
    log "Root commit detected (no parent) — using diff --root"
    USE_DIFF_ROOT=true
  fi
fi

# Helper: return the git-log-style range for this MR.
# Centralizes the USE_DIFF_ROOT conditional so callers don't repeat it.
# For root commits, returns just $REVIEW_SHA (git log <sha> lists that single commit).
# For normal commits, returns $MERGE_BASE..$REVIEW_SHA.
mr_log_range() {
  if [[ "$USE_DIFF_ROOT" == "true" ]]; then
    printf '%s' "$REVIEW_SHA"
  else
    printf '%s' "${MERGE_BASE}..${REVIEW_SHA}"
  fi
}

# Write complete UTF-8 lines whose byte total does not exceed the requested cap.
# LC_ALL=C makes awk's length byte-based while preserving the original UTF-8
# bytes; stopping before a partial line avoids splitting a multibyte sequence.
truncate_utf8_lines() {
  local input_file="$1"
  local output_file="$2"
  local byte_cap="$3"
  LC_ALL=C awk -v max="$byte_cap" '
    {
      line = $0 ORS
      if (used + length(line) > max) exit
      printf "%s", line
      used += length(line)
    }
  ' "$input_file" > "$output_file"
}

# Configurable diff size cap (bytes). Override via CI variable HAC_MAX_DIFF_BYTES.
# 250 KB keeps typical multi-file MRs complete while retaining a hard prompt cap.
MAX_DIFF_BYTES=${HAC_MAX_DIFF_BYTES:-250000}
validate_nonnegative_integer "HAC_MAX_DIFF_BYTES" "$MAX_DIFF_BYTES" || {
  log_error "HAC_MAX_DIFF_BYTES must be a non-negative decimal integer"
  exit 1
}

# Capture the diff untruncated first so the full size is known. Truncating with a
# bare `head -c` loses that number, and without it the prompt can't disclose that
# the model is seeing a partial changeset — which lets a clean verdict be returned
# over code the reviewer never received.
#
# The diff goes to a temp file rather than a variable because `$()` strips trailing
# newlines, and git diffs always end in one. Measuring the captured string would
# under-report the total by at least a byte — a wrong number in the very
# disclosure this code exists to make trustworthy.
# Cleanup is handled by the global `cleanup` EXIT trap, which lists DIFF_FILE.
# Installing a second `trap ... EXIT` here would REPLACE that trap, silently
# dropping the REQUEST_FILE/PROMPT_FILE cleanup and the close_sections call.
DIFF_FILE=$(mktemp) || { log_error "mktemp failed"; exit 1; }

if [[ "$USE_DIFF_ROOT" == "true" ]]; then
  log "Full MR diff range: (empty tree)..${REVIEW_SHA:0:8} (root commit)"
  git diff-tree -p -r --no-commit-id --root "$REVIEW_SHA" > "$DIFF_FILE" 2>/dev/null || true
else
  log "Full MR diff range: ${MERGE_BASE:0:8}..${REVIEW_SHA:0:8} (merge-base with $TARGET_BRANCH)"
  git diff "$MERGE_BASE" "$REVIEW_SHA" > "$DIFF_FILE" 2>/dev/null || true
fi

DIFF_FULL_SIZE=$(wc -c < "$DIFF_FILE" | tr -d ' ')
DIFF_TRUNCATED=false

if [[ $DIFF_FULL_SIZE -gt $MAX_DIFF_BYTES ]]; then
  DIFF_TRUNCATED=true
  TRUNCATED_DIFF_FILE=$(mktemp) || { log_error "mktemp failed"; exit 1; }
  truncate_utf8_lines "$DIFF_FILE" "$TRUNCATED_DIFF_FILE" "$MAX_DIFF_BYTES"
  # The sentinel keeps command substitution from stripping retained trailing
  # newlines, so the disclosed byte count matches the prompt representation.
  COMMIT_DIFF=$(cat "$TRUNCATED_DIFF_FILE"; printf '\001')
  COMMIT_DIFF="${COMMIT_DIFF%$'\001'}"
  DIFF_INCLUDED_BYTES=$(wc -c < "$TRUNCATED_DIFF_FILE" | tr -d ' ')
  DIFF_OMITTED_BYTES=$((DIFF_FULL_SIZE - DIFF_INCLUDED_BYTES))
  rm -f "$TRUNCATED_DIFF_FILE"
  COMMIT_DIFF="${COMMIT_DIFF}

... [DIFF TRUNCATED — ${DIFF_OMITTED_BYTES} of ${DIFF_FULL_SIZE} bytes omitted to fit the ${MAX_DIFF_BYTES}-byte cap.
This diff is INCOMPLETE. Changes beyond this point were not provided to you.]"
  log "WARNING: Diff truncated at ${MAX_DIFF_BYTES} bytes (${DIFF_OMITTED_BYTES} of ${DIFF_FULL_SIZE} bytes omitted)."
else
  DIFF_INCLUDED_BYTES=$DIFF_FULL_SIZE
  COMMIT_DIFF=$(cat "$DIFF_FILE")
fi
# Early cleanup so a large diff isn't held on disk for the rest of the run. The
# cleanup EXIT trap covers an abnormal exit between the mktemp above and this
# line -- a set -e abort during capture, or a signal. No normal-path exit sits in
# that window, so on a successful run this rm is what actually removes the file.
rm -f "$DIFF_FILE"

if [[ "$DIFF_TRUNCATED" == "true" ]]; then
  DIFF_DISCLOSURE="**INCOMPLETE — this diff was truncated to fit a size cap. You are seeing
${DIFF_INCLUDED_BYTES} of ${DIFF_FULL_SIZE} bytes. Do not treat absence of a problem in the
omitted region as evidence there is none, and say in your summary that the diff was
truncated so a human knows the review is partial.**"
else
  DIFF_DISCLOSURE="Complete: the entire diff is included below."
fi

DIFF_SIZE=${#COMMIT_DIFF}
log "Full MR diff: $DIFF_FULL_SIZE bytes (${DIFF_SIZE} bytes in prompt)"

if [[ $DIFF_FULL_SIZE -eq 0 ]]; then
  log "Empty diff — nothing to review."
  exit 0
fi

# Get the list of changed files (full MR)
# NOTE: Can't fully collapse this conditional — root commits need diff-tree --root
# (git diff --name-only doesn't support --root). The else branch uses mr_log_range().
if [[ "$USE_DIFF_ROOT" == "true" ]]; then
  CHANGED_FILES=$(git diff-tree --no-commit-id --name-only -r --root "$REVIEW_SHA" 2>/dev/null || echo "")
else
  CHANGED_FILES=$(git diff --name-only $(mr_log_range) 2>/dev/null || echo "")
fi
if [[ -z "$CHANGED_FILES" ]]; then
  NUM_FILES=0
else
  NUM_FILES=$(printf '%s\n' "$CHANGED_FILES" | wc -l | tr -d ' ')
fi
log "Changed files: $NUM_FILES"

# Get all commit messages in the MR
# NOTE: In the root-commit path, `git log <sha>` is unbounded but safe because
# USE_DIFF_ROOT is only true for genuinely parentless commits (single entry).
COMMIT_MESSAGES=$(git log --format='%h %s' $(mr_log_range) 2>/dev/null || echo "$CI_COMMIT_MESSAGE")

# Cap the commit list so every prompt component is bounded. NUM_COMMITS is computed
# here (pre-truncation) because a later reporting step needs the true count.
#
# `printf '%s\n'` is required, not incidental: `$()` above stripped the trailing
# newline, so a bare `wc -l` would under-count by one. The diff uses a temp file
# for the same reason -- here the value is line-counted rather than byte-counted,
# so re-adding the one newline is exact.
MAX_COMMIT_LINES=${HAC_MAX_COMMIT_LINES:-100}
NUM_COMMITS=$(printf '%s\n' "$COMMIT_MESSAGES" | wc -l | tr -d ' ')
if [[ $NUM_COMMITS -gt $MAX_COMMIT_LINES ]]; then
  # `|| true` guards the same SIGPIPE-under-pipefail case as the diff cap above.
  COMMIT_MESSAGES="$(printf '%s\n' "$COMMIT_MESSAGES" | head -n "$MAX_COMMIT_LINES" || true)
... [truncated — showing $MAX_COMMIT_LINES of $NUM_COMMITS commits]"
  log "WARNING: Commit list truncated to ${MAX_COMMIT_LINES} of ${NUM_COMMITS} commits."
fi

log "Commits in MR:"
echo "$COMMIT_MESSAGES" | head -10

# ---------------------------------------------------------------
log_step "BUILDING REVIEW CONTEXT"
# ---------------------------------------------------------------

# Include contents of changed files for full context.
#
# The total is what actually bounds the prompt. Sizing: a 200k-token context
# window less the 8192-token output reservation leaves ~191k tokens of input, so
# at ~4 bytes/token even 250000 bytes here plus every other component stays
# comfortably inside it. The old 80000 was ~4x more conservative than the model
# required, which is what pushed this very script out of its own review context.
KEY_FILES=""
KEY_FILES_BYTES=0
MAX_KEY_FILES_BYTES=${HAC_MAX_KEY_FILES_BYTES:-250000}
validate_nonnegative_integer "HAC_MAX_KEY_FILES_BYTES" "$MAX_KEY_FILES_BYTES" || {
  log_error "HAC_MAX_KEY_FILES_BYTES must be a non-negative decimal integer"
  exit 1
}

# Derived from the total, not fixed: the per-file cap exists so one large file
# can't consume the whole budget and starve the other changed files. That is a
# claim about its SHARE of the budget, so a percentage is the honest expression
# of it -- a hard-coded byte count silently becomes a different policy whenever
# the total moves. Integer arithmetic, so this truncates; that is fine here.
SINGLE_FILE_PCT=${HAC_MAX_SINGLE_FILE_PCT:-60}
validate_nonnegative_integer "HAC_MAX_SINGLE_FILE_PCT" "$SINGLE_FILE_PCT" 100 || {
  log_error "HAC_MAX_SINGLE_FILE_PCT must be a decimal integer from 0 to 100"
  exit 1
}
MAX_SINGLE_FILE_BYTES=${HAC_MAX_SINGLE_FILE_BYTES:-$((MAX_KEY_FILES_BYTES * SINGLE_FILE_PCT / 100))}
validate_nonnegative_integer "HAC_MAX_SINGLE_FILE_BYTES" "$MAX_SINGLE_FILE_BYTES" || {
  log_error "HAC_MAX_SINGLE_FILE_BYTES must be a non-negative decimal integer"
  exit 1
}
PRIORITY_RESERVE_PCT=${HAC_CONTEXT_PRIORITY_RESERVE_PCT:-50}
validate_nonnegative_integer "HAC_CONTEXT_PRIORITY_RESERVE_PCT" "$PRIORITY_RESERVE_PCT" 100 || {
  log_error "HAC_CONTEXT_PRIORITY_RESERVE_PCT must be a decimal integer from 0 to 100"
  exit 1
}
# Give every eligible changed file a fair first share before using the remaining
# budget in file order. A first-come allocation can otherwise omit the final
# files completely, leaving a reviewer unable to approve the MR as a whole.
CONTEXT_FILES=()
CONTEXT_FILE_SIZES=()
CONTEXT_HEADER_SIZES=()
PARTIAL_FILES=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -L "$f" ]] && continue
  [[ ! -f "$f" ]] && continue
  case "$f" in
    *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.pdf|*.rds|*.RData|*.rda|*.o|*.so|*.dll)
      PARTIAL_FILES="${PARTIAL_FILES} ${f}"
      continue
      ;;
  esac
  # Only inspect the prefix that could be added to context. This avoids scanning
  # a whole binary artifact before the existing per-file cap takes effect.
  BINARY_SCAN_BYTES=$MAX_SINGLE_FILE_BYTES
  [[ $BINARY_SCAN_BYTES -gt $MAX_KEY_FILES_BYTES ]] && BINARY_SCAN_BYTES=$MAX_KEY_FILES_BYTES
  if head -c "$BINARY_SCAN_BYTES" -- "$f" | od -An -v -t x1 | grep '00' >/dev/null; then
    PARTIAL_FILES="${PARTIAL_FILES} ${f}"
    continue
  fi
  FILE_SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
  CONTEXT_FILES+=("$f")
  CONTEXT_FILE_SIZES+=("$FILE_SIZE")
  CONTEXT_HEADER_SIZES+=("$(printf '\n=== %s ===\n' "$f" | wc -c | tr -d ' ')")
done <<< "$(printf '%s\n' "$CHANGED_FILES" | context_files_for_review "$PRIORITY_RESERVE_PCT")"

CONTEXT_FILE_COUNT=${#CONTEXT_FILES[@]}
if [[ $CONTEXT_FILE_COUNT -gt 0 ]]; then
  FIRST_PASS_HEADER_BYTES=0
  for HEADER_BYTES in "${CONTEXT_HEADER_SIZES[@]}"; do
    FIRST_PASS_HEADER_BYTES=$((FIRST_PASS_HEADER_BYTES + HEADER_BYTES))
  done
  CONTENT_BUDGET=$((MAX_KEY_FILES_BYTES - FIRST_PASS_HEADER_BYTES))
  [[ $CONTENT_BUDGET -lt 0 ]] && CONTENT_BUDGET=0
  FAIR_SHARE_BYTES=$(context_first_pass_share "$CONTENT_BUDGET" "$CONTEXT_FILE_COUNT" "$PRIORITY_RESERVE_PCT")
  [[ $FAIR_SHARE_BYTES -gt $MAX_SINGLE_FILE_BYTES ]] && FAIR_SHARE_BYTES=$MAX_SINGLE_FILE_BYTES

  for ((i = 0; i < CONTEXT_FILE_COUNT; i++)); do
    f="${CONTEXT_FILES[$i]}"
    FILE_SIZE="${CONTEXT_FILE_SIZES[$i]}"
    ENTRY_HEADER="
=== ${f} ===
"
    HEADER_BYTES=$(printf '%s' "$ENTRY_HEADER" | wc -c | tr -d ' ')
    AVAILABLE_BYTES=$((MAX_KEY_FILES_BYTES - KEY_FILES_BYTES - HEADER_BYTES))
    [[ $AVAILABLE_BYTES -le 0 ]] && continue
    EXCERPT_BYTES=$FILE_SIZE
    [[ $EXCERPT_BYTES -gt $FAIR_SHARE_BYTES ]] && EXCERPT_BYTES=$FAIR_SHARE_BYTES
    [[ $EXCERPT_BYTES -gt $AVAILABLE_BYTES ]] && EXCERPT_BYTES=$AVAILABLE_BYTES
    # Command substitution strips trailing newlines. Append an ASCII sentinel,
    # then remove it after capture so the excerpt retains every requested byte.
    EXCERPT=$(head -c "$EXCERPT_BYTES" -- "$f"; printf '\001')
    EXCERPT="${EXCERPT%$'\001'}"
    KEY_FILES="${KEY_FILES}${ENTRY_HEADER}${EXCERPT}"
    KEY_FILES_BYTES=$((KEY_FILES_BYTES + HEADER_BYTES + EXCERPT_BYTES))
    CONTEXT_FILE_SIZES[$i]=$((FILE_SIZE - EXCERPT_BYTES))
  done

  for ((i = 0; i < CONTEXT_FILE_COUNT; i++)); do
    [[ $KEY_FILES_BYTES -ge $MAX_KEY_FILES_BYTES ]] && break
    f="${CONTEXT_FILES[$i]}"
    REMAINING_FILE_BYTES="${CONTEXT_FILE_SIZES[$i]}"
    [[ $REMAINING_FILE_BYTES -eq 0 ]] && continue
    FILE_SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
    INCLUDED_BYTES=$((FILE_SIZE - REMAINING_FILE_BYTES))
    FILE_ROOM=$((MAX_SINGLE_FILE_BYTES - INCLUDED_BYTES))
    EXTRA_BYTES=$REMAINING_FILE_BYTES
    ENTRY_HEADER="
  === ${f} (continued) ===
  "
    HEADER_BYTES=$(printf '%s' "$ENTRY_HEADER" | wc -c | tr -d ' ')
    REMAINING_BUDGET=$((MAX_KEY_FILES_BYTES - KEY_FILES_BYTES - HEADER_BYTES))
    [[ $EXTRA_BYTES -gt $FILE_ROOM ]] && EXTRA_BYTES=$FILE_ROOM
    [[ $EXTRA_BYTES -gt $REMAINING_BUDGET ]] && EXTRA_BYTES=$REMAINING_BUDGET
    [[ $EXTRA_BYTES -le 0 ]] && continue
    EXCERPT=$(tail -c +$((INCLUDED_BYTES + 1)) -- "$f" | head -c "$EXTRA_BYTES" || true; printf '\001')
    EXCERPT="${EXCERPT%$'\001'}"
    KEY_FILES="${KEY_FILES}${ENTRY_HEADER}${EXCERPT}"
    KEY_FILES_BYTES=$((KEY_FILES_BYTES + HEADER_BYTES + EXTRA_BYTES))
    CONTEXT_FILE_SIZES[$i]=$((REMAINING_FILE_BYTES - EXTRA_BYTES))
  done

  for ((i = 0; i < CONTEXT_FILE_COUNT; i++)); do
    if [[ "${CONTEXT_FILE_SIZES[$i]}" -gt 0 ]]; then
      PARTIAL_FILES="${PARTIAL_FILES} ${CONTEXT_FILES[$i]}"
    fi
  done
fi

# Disclose partial files in the prompt, not only in the CI log. A reviewer told
# nothing treats the provided excerpts as the whole change.
SKIPPED_FILES_NOTE=""
if [[ -n "$PARTIAL_FILES" ]]; then
  SKIPPED_FILES_NOTE="
**INCOMPLETE — full contents were NOT provided for every changed file.**
Review the paths below from the diff alone, and say so in your summary."
  SKIPPED_FILES_NOTE="${SKIPPED_FILES_NOTE}
- Partially included within the ${MAX_KEY_FILES_BYTES}-byte total context budget:${PARTIAL_FILES}"
  log "WARNING: Partial file context within ${MAX_KEY_FILES_BYTES}-byte budget:${PARTIAL_FILES}"
fi

log "Key files context: ${KEY_FILES_BYTES} bytes"

# ---------------------------------------------------------------
log_step "FETCHING MR DIFF VERSIONS"
# ---------------------------------------------------------------

# Fetch the latest MR diff version to get base_sha, head_sha, start_sha.
# These are required for posting inline diff comments via the Discussions API.
MR_VERSIONS=$(gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${MR_IID}/versions" 2>/dev/null || echo "[]")
INLINE_BASE_SHA=""
INLINE_HEAD_SHA=""
INLINE_START_SHA=""

if [[ "$MR_VERSIONS" != "[]" ]] && [[ -n "$MR_VERSIONS" ]]; then
  # Latest version is first in the array
  INLINE_HEAD_SHA=$(echo "$MR_VERSIONS" | jq -r '.[0].head_commit_sha // empty')
  INLINE_BASE_SHA=$(echo "$MR_VERSIONS" | jq -r '.[0].base_commit_sha // empty')
  INLINE_START_SHA=$(echo "$MR_VERSIONS" | jq -r '.[0].start_commit_sha // empty')
  if [[ ! "$INLINE_HEAD_SHA" =~ ^[0-9a-f]{40}$ ||
        ! "$INLINE_BASE_SHA" =~ ^[0-9a-f]{40}$ ||
        ! "$INLINE_START_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    log "Warning: malformed MR version SHAs — inline comments disabled"
    INLINE_HEAD_SHA=""
  elif [[ "$INLINE_HEAD_SHA" != "$REVIEW_SHA" ]]; then
    log "Warning: MR diff version head does not match reviewed commit — inline comments disabled"
    INLINE_HEAD_SHA=""
  else
    log "MR diff version SHAs: base=${INLINE_BASE_SHA:0:8} head=${INLINE_HEAD_SHA:0:8} start=${INLINE_START_SHA:0:8}"
    log "Inline diff comments: enabled"
  fi
else
  log "Warning: could not fetch MR versions — inline comments disabled"
fi

# ---------------------------------------------------------------
log_step "FETCHING PRIOR REVIEW CONTEXT"
# ---------------------------------------------------------------

# Fetch the most recent auto-review by this model and the author's response (if
# any) so the reviewer doesn't re-raise findings that have already been addressed.
# This dramatically reduces asymptotic noise in multi-round review loops.
PRIOR_REVIEW_CONTEXT=""
REVIEW_NOTES="[]"
REVIEW_PREFIX="🔍 **Auto-review by ${REVIEWER_ID} (${MODEL}) "
MAX_REVIEW_HISTORY_CHARS=${HAC_MAX_REVIEW_HISTORY_CHARS:-12000}
MAX_REVIEW_NOTES_CHARS=${HAC_MAX_REVIEW_NOTES_CHARS:-500000}
MAX_PRIOR_REVIEW_CHARS=${HAC_MAX_PRIOR_REVIEW_CHARS:-3000}
MAX_AUTHOR_RESPONSE_CHARS=${HAC_MAX_AUTHOR_RESPONSE_CHARS:-2000}
validate_nonnegative_integer "HAC_MAX_REVIEW_HISTORY_CHARS" "$MAX_REVIEW_HISTORY_CHARS" || {
  log_error "HAC_MAX_REVIEW_HISTORY_CHARS must be a non-negative integer"
  exit 1
}
validate_nonnegative_integer "HAC_MAX_REVIEW_NOTES_CHARS" "$MAX_REVIEW_NOTES_CHARS" || {
  log_error "HAC_MAX_REVIEW_NOTES_CHARS must be a non-negative decimal integer"
  exit 1
}
validate_nonnegative_integer "HAC_MAX_PRIOR_REVIEW_CHARS" "$MAX_PRIOR_REVIEW_CHARS" || {
  log_error "HAC_MAX_PRIOR_REVIEW_CHARS must be a non-negative decimal integer"
  exit 1
}
validate_nonnegative_integer "HAC_MAX_AUTHOR_RESPONSE_CHARS" "$MAX_AUTHOR_RESPONSE_CHARS" || {
  log_error "HAC_MAX_AUTHOR_RESPONSE_CHARS must be a non-negative decimal integer"
  exit 1
}
TRUSTED_BOT_USERNAME="${CLAUDE_BOT_USERNAME:-}"
if [[ -z "$TRUSTED_BOT_USERNAME" ]]; then
  TRUSTED_BOT_USERNAME=$(gl_api "${CI_API_V4_URL}/user" 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)
fi

# Walk backward through at most 1,000 recent notes. Keep the complete fetched
# history because an author may rebut an older review round after which later
# reviews were posted; retaining only the latest round loses that rebuttal.
# Any failed page invalidates the partial result so missing context is never
# mistaken for a complete note history.
fetch_prior_review_notes "$MR_IID" "$REVIEW_PREFIX" "$TRUSTED_BOT_USERNAME" || true

if [[ "$REVIEW_NOTES" != "[]" ]] && [[ -n "$REVIEW_NOTES" ]]; then
  # Keep older review rounds as well as the latest one. A rebuttal can settle a
  # finding in an earlier round, while later reviews may otherwise hide that
  # rationale by becoming the only prior context presented to the model.
  REVIEW_NOTE_IDS=$(printf '%s\n' "$REVIEW_NOTES" | jq -r \
    --arg prefix "$REVIEW_PREFIX" --arg bot "$TRUSTED_BOT_USERNAME" '
    [.[] | . as $note | select(
      if ($note | type) != "object" then false
      elif ($note.author | type) != "object" then false
      elif ($note.id | type) != "number" then false
      elif ($note.id != ($note.id | floor) or $note.id <= 0) then false
      elif ($note.author.username | type) != "string" then false
      elif $note.author.username != $bot then false
      elif ($note.body | type) != "string" then false
      else ($note.body | startswith($prefix))
      end
    )]
    | sort_by(.id) | reverse | .[].id
  ')
  REVIEW_NOTE_IDS_ASC=$(printf '%s\n' "$REVIEW_NOTE_IDS" | sort -n)
  PRIOR_REVIEW_HISTORY=""
  AUTHOR_RESPONSE_TIMELINE=""
  if [[ "${REVIEW_NOTES_TRUNCATED:-false}" == "true" ]]; then
    PRIOR_REVIEW_HISTORY=$'[PRIOR REVIEW HISTORY TRUNCATED: only the newest 1,000 notes were fetched.]\n\n'
  fi
  FIRST_REVIEW_ID=$(printf '%s\n' "$REVIEW_NOTE_IDS_ASC" | head -n 1)
  if [[ "$FIRST_REVIEW_ID" =~ ^[1-9][0-9]*$ ]]; then
    AUTHOR_RESPONSE_TIMELINE=$(select_author_response \
      "$REVIEW_NOTES" "$FIRST_REVIEW_ID" "$MR_AUTHOR" \
      "$TRUSTED_BOT_USERNAME" "$MAX_AUTHOR_RESPONSE_CHARS" "" true)
  fi
  LATEST_REVIEW_ID=$(printf '%s\n' "${LAST_REVIEW_NOTE:-null}" | jq -r '.id // empty' 2>/dev/null || true)
  REVIEW_NOTE_INDEX=0
  while IFS= read -r REVIEW_NOTE_ID; do
    [[ -z "$REVIEW_NOTE_ID" ]] && continue
    [[ "$REVIEW_NOTE_ID" == "$LATEST_REVIEW_ID" ]] && continue
    REVIEW_NOTE_BODY=$(printf '%s\n' "$REVIEW_NOTES" | jq -r \
      --argjson id "$REVIEW_NOTE_ID" '[.[] | objects | select(.id == $id)][0].body // empty')
    REVIEW_NOTE_INDEX=$((REVIEW_NOTE_INDEX + 1))
    REVIEW_ENTRY=$(printf '### Prior review round %s\n%s' \
      "$REVIEW_NOTE_INDEX" "$REVIEW_NOTE_BODY")
    PRIOR_REVIEW_HISTORY="${PRIOR_REVIEW_HISTORY}${REVIEW_ENTRY}"$'\n\n'
  done <<< "$REVIEW_NOTE_IDS"
  if [[ ${#PRIOR_REVIEW_HISTORY} -gt "$MAX_REVIEW_HISTORY_CHARS" ]]; then
    HISTORY_TRUNCATION_MARKER=$'\n\n[PRIOR REVIEW HISTORY TRUNCATED TO THE CONFIGURED CHARACTER BUDGET]\n'
    HISTORY_PREFIX_CHARS=$((MAX_REVIEW_HISTORY_CHARS - ${#HISTORY_TRUNCATION_MARKER}))
    if [[ "$HISTORY_PREFIX_CHARS" -gt 0 ]]; then
      PRIOR_REVIEW_HISTORY="${PRIOR_REVIEW_HISTORY:0:HISTORY_PREFIX_CHARS}${HISTORY_TRUNCATION_MARKER}"
    else
      PRIOR_REVIEW_HISTORY="${PRIOR_REVIEW_HISTORY:0:MAX_REVIEW_HISTORY_CHARS}"
    fi
  fi

  LAST_REVIEW=""
  if ! LAST_REVIEW=$(printf '%s\n' "${LAST_REVIEW_NOTE:-null}" | jq -r '.body // empty' 2>/dev/null); then
    log "Warning: prior review note was malformed; omitting prior-review context"
    LAST_REVIEW=""
  fi

  if [[ -n "$LAST_REVIEW" ]]; then
    # Truncate the review to avoid blowing up the prompt.
    LAST_REVIEW_TRUNC="${LAST_REVIEW:0:$MAX_PRIOR_REVIEW_CHARS}"
    if [[ ${#LAST_REVIEW} -gt $MAX_PRIOR_REVIEW_CHARS ]]; then
      LAST_REVIEW_TRUNC="${LAST_REVIEW_TRUNC}
... (truncated — full review was ${#LAST_REVIEW} chars)"
    fi

    AUTHOR_TIMELINE_CONTEXT=""
    AUTHOR_TIMELINE_OVERRUN=false
    if [[ -n "$AUTHOR_RESPONSE_TIMELINE" ]]; then
      AUTHOR_TIMELINE_CONTEXT="
### Chronological author notes
These notes are shown in posting order. GitLab thread linkage is not available
in this context, so do not assume each note answers the immediately preceding
review; use the note's concrete rationale and the code evidence to determine
which finding it addresses.
${AUTHOR_RESPONSE_TIMELINE}
"
      if [[ ${#AUTHOR_TIMELINE_CONTEXT} -gt "$MAX_REVIEW_HISTORY_CHARS" ]]; then
        AUTHOR_TIMELINE_MARKER=$'\n[AUTHOR NOTES TRUNCATED; NEWEST SUFFIX RETAINED]\n### Chronological author notes (newest retained)\n'
        AUTHOR_TIMELINE_AVAILABLE=$((MAX_REVIEW_HISTORY_CHARS - ${#AUTHOR_TIMELINE_MARKER}))
        if [[ "$AUTHOR_TIMELINE_AVAILABLE" -gt 0 ]]; then
          AUTHOR_TIMELINE_CONTEXT="${AUTHOR_TIMELINE_MARKER}${AUTHOR_TIMELINE_CONTEXT: -AUTHOR_TIMELINE_AVAILABLE}"
        else
          AUTHOR_TIMELINE_CONTEXT="${AUTHOR_TIMELINE_MARKER:0:MAX_REVIEW_HISTORY_CHARS}"
        fi
        AUTHOR_TIMELINE_OVERRUN=true
        log "Author-note timeline exceeded the overall budget; retained an attributed newest suffix."
      fi
    fi

    if [[ "$AUTHOR_TIMELINE_OVERRUN" == "true" ]]; then
      # This allocation already consumes the complete budget. Do not run it
      # through the later prefix truncation, which would discard its newest
      # characters and potentially the final rebuttal.
      PRIOR_REVIEW_CONTEXT="$AUTHOR_TIMELINE_CONTEXT"
    else
      PRIOR_REVIEW_CONTEXT="${AUTHOR_TIMELINE_CONTEXT}
## Prior review context
The following is the most recent auto-review. Author notes, when present,
appear first so late rebuttals remain available under a tight context budget.
**Do NOT re-raise findings that the author has already addressed, deferred to a
tracked issue, or explained with rationale.** Only raise a finding again if the
code still contains the actual problem after the author's stated fix. If rejecting
a rebuttal, summarize its rationale and explain with concrete evidence why it does
not settle the finding; never silently repeat a rebutted finding.

An author response prefixed with **REBUTTED:** is an explicit false-finding
rebuttal, not an admission that the code was changed. Verify the cited evidence
independently before re-raising it. Do not treat unchanged correct code as proof
that a rebutted finding remains valid; re-raise it only with independently
verified concrete evidence that the actual defect remains.

### Previous auto-review:
${LAST_REVIEW_TRUNC}
"
      PRIOR_REVIEW_CONTEXT="${PRIOR_REVIEW_CONTEXT}
### Review history
The history below includes earlier review rounds. Treat an earlier rebuttal as
settled only when its concrete rationale addresses the finding in question and
current code provides no evidence otherwise.
${PRIOR_REVIEW_HISTORY}
"
    fi
    if [[ ${#PRIOR_REVIEW_CONTEXT} -gt "$MAX_REVIEW_HISTORY_CHARS" ]]; then
      HISTORY_CONTEXT_MARKER=$'\n\n[PRIOR REVIEW CONTEXT TRUNCATED TO THE CONFIGURED CHARACTER BUDGET]\n'
      HISTORY_CONTEXT_PREFIX_CHARS=$((MAX_REVIEW_HISTORY_CHARS - ${#HISTORY_CONTEXT_MARKER}))
      if [[ "$HISTORY_CONTEXT_PREFIX_CHARS" -gt 0 ]]; then
        PRIOR_REVIEW_CONTEXT="${PRIOR_REVIEW_CONTEXT:0:HISTORY_CONTEXT_PREFIX_CHARS}${HISTORY_CONTEXT_MARKER}"
      else
        PRIOR_REVIEW_CONTEXT=""
        log "Prior review context omitted because its budget is smaller than the truncation marker."
      fi
    fi
    log "Prior review context: ${#PRIOR_REVIEW_CONTEXT} bytes (review history + latest response)"
  else
    log "No prior auto-review found — first review for this MR."
  fi
else
  log "No MR notes found — first review for this MR."
fi

# ---------------------------------------------------------------
log_step "FETCHING LAB MANUAL CONTEXT"
# ---------------------------------------------------------------

# Source the lab manual fetcher and pull key pages for ground-truth context.
# This allows the reviewer to cite specific conventions without hallucinating URLs.
# Non-critical: if fetching fails, review proceeds without lab manual context.
#
# NOTE: claude-review.sh is self-contained (doesn't source lib/logging.sh etc.
# like claude-respond.sh does). It sources lib/lab-manual.sh inline here with
# a file-existence guard because the review template only fetches this one lib
# file. claude-respond.sh sources it unconditionally at the top since it has
# the full lib/ directory available. This asymmetry is intentional.
if [[ -f "${SCRIPT_DIR}/lib/lab-manual.sh" ]]; then
  source "${SCRIPT_DIR}/lib/lab-manual.sh"
  fetch_lab_manual_safe
else
  log "  ⚠ lib/lab-manual.sh not found; skipping lab manual context."
fi

if [[ -n "${LAB_MANUAL_CONTENT:-}" ]]; then
  LAB_MANUAL_GUIDANCE='The actual content of key lab manual pages is included below under "SERG Lab Manual Reference" — use that as ground truth for citations.'
else
  LAB_MANUAL_GUIDANCE='No lab manual content was retrieved for this run. Cite only the manual root when a style reference is needed; do not guess specific section anchors.'
fi

# ---------------------------------------------------------------
log_step "LLM API CALL"
# ---------------------------------------------------------------

DATABRICKS_TOKEN="${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
if [[ -z "$DATABRICKS_TOKEN" ]]; then
  log_error "Neither ANTHROPIC_API_KEY nor ANTHROPIC_AUTH_TOKEN is set."
  exit 1
fi

if [[ -z "${ANTHROPIC_BASE_URL:-}" ]]; then
  log_error "ANTHROPIC_BASE_URL is not set."
  exit 1
fi

ENDPOINT_URL="${ANTHROPIC_BASE_URL%/}/${MODEL}/invocations"

PROMPT="You are an expert code reviewer performing an automated review of a GitLab Merge Request.

## Review-only agent contract
This is a synchronous, review-only run. Explore the complete checked-out
repository and the entire MR diff as needed, including unchanged files that
define the behavior under review. Use the supplied read-only repository and
allowlisted documentation tools when injected context is insufficient. Never
edit, stage, commit, push, comment, resolve, merge, schedule follow-up work, or
delegate background work. If a tool call fails or a source is unavailable,
continue with the evidence already available and still produce a verdict.
Do not treat a missing excerpt as proof that an implementation is missing.

## Style & design guide
Use the UC Davis SERG Lab Manual as the authoritative style and design guide:
<https://ucd-serg.github.io/lab-manual/>. Evaluate the changes against its
conventions (code style, documentation, testing, package structure, naming, and
workflow). When a finding relates to a lab-manual convention, cite it and link
to the relevant section, e.g.
[Coding Style](https://ucd-serg.github.io/lab-manual/coding-style.html) or the
most relevant page. Prefer linking specific sections over the manual root.
${LAB_MANUAL_GUIDANCE}

## Your task
Review the ENTIRE MR diff for:
1. **Bugs or logic errors** — anything that would cause incorrect behavior
2. **Security issues** — injection, secrets in code, unsafe operations
3. **Style/quality** — readability, naming, unnecessary complexity; check against
   the SERG Lab Manual and cite/link the relevant section
4. **Missing edge cases** — error handling, boundary conditions

## MR context
- MR: !${MR_IID} — ${MR_TITLE}
- Target branch: ${TARGET_BRANCH}
- All commits in this MR:
${COMMIT_MESSAGES}

## MR description
${MR_DESCRIPTION}

## MR diff (all changes vs ${TARGET_BRANCH})
${DIFF_DISCLOSURE}
\`\`\`diff
${COMMIT_DIFF}
\`\`\`

## File contents (post-change state of modified files)
${SKIPPED_FILES_NOTE}
${KEY_FILES}

${LAB_MANUAL_CONTENT}

${PRIOR_REVIEW_CONTEXT}

${HAC_REVIEW_PROMPT_ADDENDUM:-}

## Agent exploration
You may use the read-only repository and documentation tools supplied with this
review. Use them when the injected context is insufficient, especially to
inspect unchanged files that define configuration or to verify an earlier
rebuttal. Never infer that a missing excerpt means a missing implementation.
The tools cannot edit, comment, push, resolve threads, or merge.

## Output format
Your response MUST contain two sections, separated by the exact marker line
\`---FINDINGS_JSON---\` on its own line:

### Section 1: Human-readable summary (above the marker)
- A short summary of the MR quality, followed by specific findings (if any).
- Be concise and actionable. Use file:line references where possible.
- Use markdown formatting suitable for a GitLab MR comment.
- Keep under 800 words unless there are serious issues.

### Section 2: Structured findings JSON (below the marker)
A JSON array of objects, one per finding that can be pinpointed to a specific
line in a changed file. Each object has:
- \`file\`: the file path (must match a path in the diff exactly)
- \`line\`: the line number in the NEW version of the file
- \`severity\`: one of \"high\", \"medium\", \"low\"
- \`message\`: a concise description of the finding (1-3 sentences, markdown OK)

If there are no findings, output an empty array: \`[]\`

End the human-readable section with an explicit level-3 heading \`### Verdict\`
and one clear status line: \`**Ready for merge**\` or \`**Needs more work**\`.

Example:
\`\`\`
---FINDINGS_JSON---
[{\"file\": \"src/utils.R\", \"line\": 42, \"severity\": \"high\", \"message\": \"Division by zero when \\\`n\\\` is 0.\"}]
\`\`\`

## Instructions
- Review ALL changes in the MR diff holistically — consider how they work together.
- If the diff or the file-contents section is marked INCOMPLETE above, state that
  plainly at the top of your summary and scope your verdict to what you were given.
  Do not approve the MR as a whole, and do not conclude that the omitted region is
  problem-free — you have no evidence either way about content you never received.
- If prior review context is provided above, do NOT re-raise findings that the
  author has already fixed, deferred to a tracked issue, or explained with
  rationale. Only flag an item again if the code STILL contains the problem.
- IMPORTANT: Any prior finding you do NOT re-raise will be automatically resolved.
  This is intentional — by omitting it from your new findings, you are confirming
  that the author adequately addressed it. Only include findings that still apply.
- A prior finding explicitly marked \`REBUTTED:\` by the author is not an addressed
  finding. Preserve the rebuttal context and re-raise it only when concrete
  evidence independently verifies that the defect remains real.
- When citing a style/design convention, link to the relevant SERG Lab Manual section (https://ucd-serg.github.io/lab-manual/).
- Prefer linking pages included in the SERG Lab Manual Reference above. If citing a page not shown there, link only to the manual root or a slug you are confident exists — do not invent URLs.
- NEVER assert the character count, string length, or exact character
  composition of a literal from inspection. You cannot count characters
  reliably — you are shown tokens, not characters — and a confident miscount
  reads exactly like a real finding, so it costs review rounds and can block a
  merge indefinitely. This covers checksums, digests, SHAs, hashes, API keys,
  base64 blobs, UUIDs, and any other fixed-width literal.
  If such a property matters, do NOT state a verdict on it. Name the program
  that decides it and ask the author to run it instead — running 'sha256sum'
  against the file, or pointing at a CI test that already asserts the format.
  For a length, the instruction must use printf rather than echo: echo appends
  a trailing newline, so 'echo VALUE | wc -c' reports 65 for a 64-character
  digest and manufactures the very off-by-one this rule exists to prevent.
  Prefer a form that cannot miscount at all, such as a grep against the exact
  expected shape (for a SHA-256, 64 hex characters anchored at both ends).
  A verifiable instruction is useful; an intuited count is not, however
  certain it feels.
- If the changes look good, say so briefly — don't invent issues.
- Do NOT suggest stylistic changes unless they significantly impact readability.
- Do NOT output <EDIT> or <FILE> blocks — this is a review, not a fix.
- ONLY include files/lines in the JSON that actually appear in the diff. Do NOT
  guess or hallucinate line numbers — if you cannot pinpoint the exact new-file
  line, omit that finding from the JSON (it will still appear in the summary)."

log "Model: $MODEL"
log "Endpoint: $ENDPOINT_URL"
log "Prompt size: $(echo "$PROMPT" | wc -c) bytes"

# Build request body (no temperature — unsupported by Databricks Claude)
# Write prompt to a temp file to avoid ARG_MAX limits with large diffs.
PROMPT_FILE=$(mktemp)
printf '%s' "$PROMPT" > "$PROMPT_FILE"
REQUEST_FILE=$(mktemp)
jq -n --rawfile content "$PROMPT_FILE" \
  --argjson tools "$REVIEW_TOOLS_JSON" \
  --argjson agent_mode "$AGENT_MODE" \
  '{messages: [{role: "user", content: $content}], max_tokens: 8192}
   + (if $agent_mode then {tools:$tools,tool_choice:"auto"} else {} end)' > "$REQUEST_FILE"
INITIAL_REQUEST_FILE=$(mktemp)
cp "$REQUEST_FILE" "$INITIAL_REQUEST_FILE"
rm -f "$PROMPT_FILE"

# Call the endpoint with retry logic
MAX_LLM_RETRIES=3
HTTP_CODE=""
HTTP_BODY=""

MAX_REVIEW_TOOL_ROUNDS=${HAC_MAX_REVIEW_TOOL_ROUNDS:-8}
validate_nonnegative_integer "HAC_MAX_REVIEW_TOOL_ROUNDS" "$MAX_REVIEW_TOOL_ROUNDS" || exit 1
MAX_REVIEW_TOOL_CALLS=${HAC_MAX_REVIEW_TOOL_CALLS:-16}
validate_nonnegative_integer "HAC_MAX_REVIEW_TOOL_CALLS" "$MAX_REVIEW_TOOL_CALLS" || exit 1
MAX_REVIEW_TOOL_RESULT_CHARS=${HAC_MAX_REVIEW_TOOL_RESULT_CHARS:-120000}
validate_nonnegative_integer "HAC_MAX_REVIEW_TOOL_RESULT_CHARS" "$MAX_REVIEW_TOOL_RESULT_CHARS" || exit 1
MAX_REVIEW_RESPONSE_CHARS=${HAC_MAX_REVIEW_RESPONSE_CHARS:-200000}
validate_nonnegative_integer "HAC_MAX_REVIEW_RESPONSE_CHARS" "$MAX_REVIEW_RESPONSE_CHARS" || exit 1
REVIEW_TOOL_ROUND=0
REVIEW_TOOL_RESULT_CHARS=0
FORCE_FINAL_REVIEW=false
TOOL_FALLBACK_USED=false
if [[ "$AGENT_MODE" == "true" && "$MAX_REVIEW_TOOL_ROUNDS" -eq 0 ]]; then
  jq 'del(.tools, .tool_choice)' "$REQUEST_FILE" > "${REQUEST_FILE}.no-tools"
  mv "${REQUEST_FILE}.no-tools" "$REQUEST_FILE"
fi
while true; do
  LLM_ATTEMPT=0
  while [[ $LLM_ATTEMPT -lt $MAX_LLM_RETRIES ]]; do
    REMAINING_SECONDS=$((REVIEW_DEADLINE - $(date +%s)))
    if [[ "$REMAINING_SECONDS" -le 0 ]]; then
      log_error "Automatic review deadline exceeded before the final response."
      HTTP_CODE=408
      break
    fi
    REQUEST_TIMEOUT=120
    [[ "$REMAINING_SECONDS" -lt "$REQUEST_TIMEOUT" ]] && REQUEST_TIMEOUT="$REMAINING_SECONDS"
    LLM_ATTEMPT=$((LLM_ATTEMPT + 1))
    log "Sending request to Databricks (attempt ${LLM_ATTEMPT}/${MAX_LLM_RETRIES})..."
    if ! HTTP_RESPONSE=$(curl -s --max-filesize "$MAX_REVIEW_RESPONSE_CHARS" -w "\n%{http_code}" --max-time "$REQUEST_TIMEOUT" --request POST \
      --header "Authorization: Bearer ${DATABRICKS_TOKEN}" \
      --header "Content-Type: application/json" \
      --data @"$REQUEST_FILE" \
      "$ENDPOINT_URL"); then
      HTTP_BODY=""
      HTTP_CODE=000
      log "Transport failure while contacting the review endpoint."
    else
      HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
      HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
    fi
    log "HTTP status: $HTTP_CODE"

    [[ "$HTTP_CODE" == "200" ]] && break
    if [[ "$HTTP_CODE" == "400" && "$AGENT_MODE" == "true" && "$TOOL_FALLBACK_USED" == "false" ]]; then
      log "Warning: endpoint rejected the agent-mode request; retrying this review in prompt-only mode."
      jq 'del(.tools, .tool_choice)' "$INITIAL_REQUEST_FILE" > "${REQUEST_FILE}.fallback"
      mv "${REQUEST_FILE}.fallback" "$REQUEST_FILE"
      AGENT_MODE=false
      LLM_ATTEMPT=0
      TOOL_FALLBACK_USED=true
      continue
    fi
    if [[ "$HTTP_CODE" =~ ^(000|429|5[0-9][0-9])$ ]] && [[ $LLM_ATTEMPT -lt $MAX_LLM_RETRIES ]]; then
      BACKOFF=$((LLM_ATTEMPT * 15))
      REMAINING_SECONDS=$((REVIEW_DEADLINE - $(date +%s)))
      if [[ "$REMAINING_SECONDS" -le 0 ]]; then
        log_error "Automatic review deadline exceeded during retry backoff."
        HTTP_CODE=408
        break
      fi
      [[ "$BACKOFF" -gt "$REMAINING_SECONDS" ]] && BACKOFF="$REMAINING_SECONDS"
      log "Retryable error (HTTP $HTTP_CODE) — waiting ${BACKOFF}s before retry..."
      sleep $BACKOFF
    else
      break
    fi
  done

  if [[ "$HTTP_CODE" == "200" ]]; then
    if ! RESPONSE_JSON=$(jq -e . <<< "$HTTP_BODY" 2>/dev/null); then
      log_error "Review endpoint returned malformed JSON; preserving existing review threads."
      HTTP_CODE=422
      break
    fi
    if ! RESPONSE_JSON=$(jq -c --argjson max_chars "$MAX_REVIEW_RESPONSE_CHARS" '
      .choices[0].message as $message
      | {choices:[{message:{
          content:(($message.content // "")[:$max_chars]),
          tool_calls:(($message.tool_calls // []) | map({
            id:(.id // ""),
            type:(.type // "function"),
            function:{
              name:((.function.name // "")[:$max_chars]),
              arguments:((.function.arguments // "")[:$max_chars])
            }
          }))
        }}]}' <<< "$RESPONSE_JSON" 2>/dev/null); then
      log_error "Review endpoint response could not be normalized within the response budget."
      HTTP_CODE=422
      break
    fi
    if ! jq -e '
      type == "object"
      and (.choices | type == "array" and length > 0)
      and (.choices[0] | type == "object")
      and (.choices[0].message | type == "object")
      and ((.choices[0].message.tool_calls // []) | type == "array")
      and all((.choices[0].message.tool_calls // [])[];
        type == "object"
        and (.id | type == "string" and length > 0)
        and (.function | type == "object")
        and (.function.name | type == "string" and length > 0)
        and (.function.arguments | type == "string")
      )
    ' <<< "$RESPONSE_JSON" >/dev/null 2>&1; then
      log_error "Review endpoint returned an invalid response schema; preserving existing review threads."
      HTTP_CODE=422
      break
    fi
    TOOL_CALL_COUNT=$(jq -r '(.choices[0].message.tool_calls? // []) | if type == "array" then length else 0 end' <<< "$RESPONSE_JSON")
    REVIEW_TOOL_ROUND=$((REVIEW_TOOL_ROUND + 1))
    if [[ "$AGENT_MODE" == "true" && "$TOOL_CALL_COUNT" -gt 0 && "$FORCE_FINAL_REVIEW" != "true" ]]; then
      if [[ "$REVIEW_TOOL_ROUND" -gt "$MAX_REVIEW_TOOL_ROUNDS" ]]; then
        log "Maximum review tool rounds reached; requesting a final no-tools response."
        jq 'del(.tools, .tool_choice) | .messages += [{role:"user",content:"The read-only exploration budget is exhausted. Provide the final review now in the required output format; do not call tools."}]' "$REQUEST_FILE" > "${REQUEST_FILE}.final"
        mv "${REQUEST_FILE}.final" "$REQUEST_FILE"
        FORCE_FINAL_REVIEW=true
        continue
      fi
      TOOL_CALLS=$(jq -c '.choices[0].message.tool_calls' <<< "$RESPONSE_JSON")
      jq --argjson assistant "$(jq -c '.choices[0].message' <<< "$RESPONSE_JSON")" \
        '.messages += [$assistant]' "$REQUEST_FILE" > "${REQUEST_FILE}.next"
      TOOL_CALL_INDEX=0
      while IFS= read -r TOOL_CALL; do
        TOOL_ID=$(echo "$TOOL_CALL" | jq -r '.id')
        TOOL_REMAINING_SECONDS=$((REVIEW_DEADLINE - $(date +%s)))
        if [[ "$TOOL_REMAINING_SECONDS" -le 0 ]]; then
          TOOL_RESULT='{"error":"automatic review deadline exhausted"}'
        elif [[ "$TOOL_CALL_INDEX" -ge "$MAX_REVIEW_TOOL_CALLS" ]]; then
          TOOL_RESULT='{"error":"per-response tool-call budget exhausted"}'
        else
          TOOL_CALL_INDEX=$((TOOL_CALL_INDEX + 1))
          REVIEW_TOOL_TIMEOUT_SECONDS=10
          [[ "$TOOL_REMAINING_SECONDS" -lt "$REVIEW_TOOL_TIMEOUT_SECONDS" ]] && REVIEW_TOOL_TIMEOUT_SECONDS="$TOOL_REMAINING_SECONDS"
          TOOL_NAME=$(echo "$TOOL_CALL" | jq -r '.function.name')
          if ! TOOL_ARGS=$(echo "$TOOL_CALL" | jq -c '.function.arguments | fromjson' 2>/dev/null); then
            TOOL_RESULT='{"error":"tool arguments were not valid JSON"}'
          else
            TOOL_RESULT=$(execute_review_tool "$TOOL_NAME" "$TOOL_ARGS")
          fi
        fi
        TOOL_RESULT_LENGTH=${#TOOL_RESULT}
        TOOL_RESULT_REMAINING=$((MAX_REVIEW_TOOL_RESULT_CHARS - REVIEW_TOOL_RESULT_CHARS))
        if [[ "$TOOL_RESULT_REMAINING" -le 0 ]]; then
          TOOL_RESULT=""
        elif [[ "$TOOL_RESULT_LENGTH" -gt "$TOOL_RESULT_REMAINING" ]]; then
          TOOL_RESULT='{"error":"total tool-result budget exhausted"}'
          TOOL_RESULT="${TOOL_RESULT:0:TOOL_RESULT_REMAINING}"
        fi
        TOOL_RESULT_LENGTH=${#TOOL_RESULT}
        if [[ "$TOOL_RESULT_LENGTH" -gt 0 ]]; then
          REVIEW_TOOL_RESULT_CHARS=$((REVIEW_TOOL_RESULT_CHARS + TOOL_RESULT_LENGTH))
        else
          log "Read-only tool result omitted because the total tool-result budget is exhausted."
        fi
        jq --arg id "$TOOL_ID" --arg result "$TOOL_RESULT" \
          '.messages += [{role:"tool",tool_call_id:$id,content:$result}]' "${REQUEST_FILE}.next" > "${REQUEST_FILE}.next2"
        mv "${REQUEST_FILE}.next2" "${REQUEST_FILE}.next"
      done < <(echo "$TOOL_CALLS" | jq -c '.[]')
      mv "${REQUEST_FILE}.next" "$REQUEST_FILE"
      continue
    fi
    break
  fi
  break
done

# ---------------------------------------------------------------
log_step "POSTING REVIEW COMMENT"
# ---------------------------------------------------------------

if [[ "$HTTP_CODE" == "200" ]]; then
  RESPONSE=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // .content // "(empty response)"')
  log "Response length: $(echo "$RESPONSE" | wc -c) bytes"

  # -----------------------------------------------------------------
  # Fail loudly on an unusable response (HACtions#51). Some models (observed:
  # databricks-claude-opus-5) return raw `reasoning` blocks with no `text`
  # block at all, instead of the expected review prose. That response still
  # extracts as a non-empty string via the jq filter above, parses as zero
  # findings, and would otherwise be posted and treated as a clean review:
  # silently resolving any prior unresolved findings on changed files.
  #
  # A response is usable if it contains the FINDINGS_JSON marker (the
  # expected format) OR at least one markdown heading (a plausible summary
  # even without the marker). A response that is a bare JSON array or object
  # (the reasoning-block case) or otherwise has neither is rejected: we log
  # an error, post a failure notice, and exit non-zero WITHOUT calling
  # resolve_verified_threads. A failed job is visible; a laundered one is not.
  # Checked against array/object specifically rather than `type` generally, so
  # this check states its own intent: reject the reasoning-block shape, not
  # every JSON-parseable value. Narrowing it changes no verdict today, because
  # a bare scalar carries no heading or marker and the prose fallback below
  # rejects it regardless. It is defence in depth: if that fallback is ever
  # loosened, the JSON check will not start rejecting ordinary prose.
  RESPONSE_IS_JSON=false
  if echo "$RESPONSE" | jq -e 'type == "array" or type == "object"' >/dev/null 2>&1; then
    RESPONSE_IS_JSON=true
  fi
  RESPONSE_HAS_MARKER=false
  echo "$RESPONSE" | grep -qE '^-*[[:space:]]*FINDINGS_JSON[[:space:]]*-*$' && RESPONSE_HAS_MARKER=true
  RESPONSE_HAS_HEADING=false
  # A leading # is intentionally broad: it accepts markdown headings and
  # shebang-bearing diagnostic text as structured review content.
  echo "$RESPONSE" | grep -qE '^#' && RESPONSE_HAS_HEADING=true

  if [[ "$RESPONSE_IS_JSON" == "true" ]] || { [[ "$RESPONSE_HAS_MARKER" == "false" ]] && [[ "$RESPONSE_HAS_HEADING" == "false" ]]; }; then
    log_error "Unusable review response (bare JSON or no prose/marker) - refusing to post it as a clean review."
    # tr strips non-printable/control characters (e.g. stray ANSI escapes from
    # a misbehaving endpoint) before this is written to the CI job log.
    log_error "Response body (first 500 chars): $(echo "$RESPONSE" | head -c 500 | tr -cd '[:print:]\n')"
    post_review_discussion "$MR_IID" "⚠️ **Auto-review failed** for commit ${REVIEW_SHA:0:8}

The model returned a response with no usable review content (no findings marker, no markdown summary). This can happen when the endpoint returns reasoning-only output instead of a review. Existing review threads were left untouched. [See pipeline](${CI_PIPELINE_URL}) for details." || true
    exit 1
  fi

  # Split response into human-readable summary and structured JSON findings.
  # The LLM is instructed to separate them with "---FINDINGS_JSON---".
  # In practice the LLM may emit variations:
  #   - "---FINDINGS_JSON---"        (exact)
  #   - "--- FINDINGS_JSON ---"      (padded)
  #   - "---\nFINDINGS_JSON"         (markdown HR then bare keyword)
  # We match any line containing FINDINGS_JSON surrounded by optional dashes/spaces.
  SUMMARY_TEXT=""
  FINDINGS_JSON=""
  FINDINGS_NORMALIZED_CLEANLY=false
  SEPARATOR_PATTERN='^-*[[:space:]]*FINDINGS_JSON[[:space:]]*-*$'
  if echo "$RESPONSE" | grep -qE "$SEPARATOR_PATTERN"; then
    FINDINGS_NORMALIZED_CLEANLY=true
    # Use the LAST match of the separator pattern, not the first.
    # This handles the self-referential case where the LLM's summary prose
    # quotes the marker format (e.g., when reviewing this very script).
    # Trade-off: if the marker reappears *after* the JSON payload (e.g., the
    # model echoes it as a closing delimiter), we'd split on the wrong line —
    # but the jq validation gate catches that (falls back to []), so the summary
    # still posts and inline comments degrade gracefully to zero.
    # NOTE: no `local` here — this block runs in the main script body, not a function.
    LAST_MARKER_LINE=$(echo "$RESPONSE" | grep -nE "$SEPARATOR_PATTERN" | tail -1 | cut -d: -f1)
    if [[ "$LAST_MARKER_LINE" -le 1 ]]; then
      # Marker is on line 1 (or somehow 0): no summary text above it.
      # head -n 0 would silently produce empty output; log and use empty summary.
      log "Warning: FINDINGS_JSON marker on line $LAST_MARKER_LINE; no summary text above it"
      SUMMARY_TEXT=""
    else
      SUMMARY_TEXT=$(echo "$RESPONSE" | head -n $((LAST_MARKER_LINE - 1)))
    fi
    # Strip only the wrapping fence (first/last lines of the region), not interior
    # lines that happen to start with ```. A global sed '/^```/d' would mangle a
    # pretty-printed JSON array whose message values contain markdown fences.
    FINDINGS_JSON=$(echo "$RESPONSE" | tail -n +$((LAST_MARKER_LINE + 1)) \
      | sed -e '1{' -e '/^```/d' -e '}' | sed -e '${' -e '/^```/d' -e '}')
  else
    # Fallback: LLM didn't follow the format — use entire response as summary.
    # Strip a trailing fenced JSON block (```json ... ```) that the model may have
    # emitted without the FINDINGS_JSON marker, to avoid posting raw JSON in the
    # summary thread. This is the exact leak the flexible-separator regex prevents
    # when the marker IS present; here we handle the marker-absent case.
    SUMMARY_TEXT=$(echo "$RESPONSE" | sed -E '/^[[:space:]]*```json[[:space:]]*$/,/^[[:space:]]*```[[:space:]]*$/d')
    FINDINGS_JSON="[]"
    log "Warning: LLM response missing FINDINGS_JSON marker; inline comments disabled for this review"
  fi

  # Validate the JSON is a parseable array; fall back to empty if not.
  if ! echo "$FINDINGS_JSON" | jq 'if type=="array" then true else error end' >/dev/null 2>&1; then
    log "Warning: findings JSON is not a valid array; skipping inline comments"
    FINDINGS_JSON="[]"
    FINDINGS_NORMALIZED_CLEANLY=false
  fi

  # Keep only complete schema-valid finding objects before any renderer or
  # thread resolver accesses their fields.
  RAW_FINDING_COUNT=$(echo "$FINDINGS_JSON" | jq 'length')
  FINDINGS_JSON=$(normalize_findings_json "$FINDINGS_JSON" "$CHANGED_FILES")
  VALID_FINDING_COUNT=$(echo "$FINDINGS_JSON" | jq 'length')
  if [[ "$VALID_FINDING_COUNT" -lt "$RAW_FINDING_COUNT" ]]; then
    log "Warning: dropped $((RAW_FINDING_COUNT - VALID_FINDING_COUNT)) malformed finding element(s)"
    FINDINGS_NORMALIZED_CLEANLY=false
  fi

  INLINE_COUNT=0
  INLINE_FAILURES=0
  INLINE_DROPPED=0

  # Do not blanket-resolve old review threads before posting this review.
  # The response agent can resolve findings on files it fixes, and this review
  # selectively resolves prior findings only after a clean structured result.
  # Blanket resolution on each run would hide unaddressed findings.
  # See: resolve_addressed_threads() in lib/gitlab-api.sh

  # Post inline diff comments for each finding (if we have version SHAs)
  if [[ -n "$INLINE_HEAD_SHA" ]]; then
    NUM_FINDINGS=$(echo "$FINDINGS_JSON" | jq 'length')
    # Defensive: ensure NUM_FINDINGS is numeric (jq should always return int
    # for array length, but guard against future edits weakening validation)
    [[ "$NUM_FINDINGS" =~ ^[0-9]+$ ]] || NUM_FINDINGS=0
    log "Findings to post as inline comments: $NUM_FINDINGS"

    # Iterate over each finding and post as an inline diff comment.
    # C-style loop: no subshell, no seq portability concern, no zero-guard needed
    # (when NUM_FINDINGS=0 the loop body simply never executes).
    for ((i = 0; i < NUM_FINDINGS; i++)); do
        FINDING_FILE=$(echo "$FINDINGS_JSON" | jq -r ".[$i].file // empty")
        FINDING_LINE=$(echo "$FINDINGS_JSON" | jq -r ".[$i].line // empty")
        FINDING_SEV=$(echo "$FINDINGS_JSON" | jq -r ".[$i].severity // \"medium\"")
        FINDING_MSG=$(echo "$FINDINGS_JSON" | jq -r ".[$i].message // empty")

        # Skip findings with missing required fields
        if [[ -z "$FINDING_FILE" || -z "$FINDING_LINE" || -z "$FINDING_MSG" ]]; then
          log "  Skipping finding $i: missing file/line/message"
          INLINE_DROPPED=$((INLINE_DROPPED + 1))
          continue
        fi

        # Validate line is a positive integer
        if ! [[ "$FINDING_LINE" =~ ^[1-9][0-9]*$ ]]; then
          log "  Skipping finding $i: invalid line number '$FINDING_LINE'"
          INLINE_DROPPED=$((INLINE_DROPPED + 1))
          continue
        fi

        # Validate file is in the changed files list.
        # NOTE: This uses exact whole-line match against `git diff --name-only`.
        # Renamed files (where GitLab's new_path differs from git's output) may
        # be silently skipped. Acceptable trade-off vs. false-positive comments.
        if ! echo "$CHANGED_FILES" | grep -qxF "$FINDING_FILE"; then
          log "  Skipping finding $i: file '$FINDING_FILE' not in MR diff"
          INLINE_DROPPED=$((INLINE_DROPPED + 1))
          continue
        fi

        # Format the inline comment body with severity badge.
        # Clamp to known set; unknown values get a generic badge with truncated text.
        # COUPLED: badge set here must stay in sync with the resolve regex in
        # resolve_addressed_threads() (lib/gitlab-api.sh). Add new badges to both.
        case "$FINDING_SEV" in
          high)   SEV_BADGE="🔴 **High**" ;;
          medium) SEV_BADGE="🟡 **Medium**" ;;
          low)    SEV_BADGE="🔵 **Low**" ;;
          *)      SEV_BADGE="⚪ **${FINDING_SEV:0:20}**" ;;
        esac

        INLINE_BODY="🔍 [${REVIEWER_ID}:${MODEL}] ${SEV_BADGE}: ${FINDING_MSG}"

        if post_inline_comment "$MR_IID" "$INLINE_BODY" "$FINDING_FILE" "$FINDING_LINE" \
             "$INLINE_BASE_SHA" "$INLINE_HEAD_SHA" "$INLINE_START_SHA"; then
          INLINE_COUNT=$((INLINE_COUNT + 1))
        else
          INLINE_FAILURES=$((INLINE_FAILURES + 1))
        fi
    done

    log "Inline comments posted: $INLINE_COUNT (failures: $INLINE_FAILURES, dropped: $INLINE_DROPPED)"
  else
    log "Inline comments skipped (no MR version SHAs available)"
  fi

  # Post the summary as a resolvable discussion thread (always posted).
  # NUM_COMMITS was captured before COMMIT_MESSAGES was capped — recomputing it
  # here would report the truncated line count as the commit total.

  # Build the review comment body. Inline note is only appended when we
  # actually posted inline comments, to avoid blank-line artifacts.
  # Guard: if SUMMARY_TEXT is empty (e.g., marker on line 1), substitute a
  # sentinel so the posted thread isn't a confusing blank body.
  if [[ -z "$SUMMARY_TEXT" ]]; then
    SUMMARY_TEXT="_(No summary text returned by the model.)_"
  fi

  STRUCTURED_FINDINGS=$(echo "$FINDINGS_JSON" | jq -r '
    .[] | "- [\(.severity)] `\(.file):\(.line)` — \(.message)"
  ')

  REVIEW_COMMENT=$(format_review_comment \
    "$SUMMARY_TEXT" \
    "$REVIEWER_ID" \
    "$MODEL" \
    "$MR_IID" \
    "$NUM_COMMITS" \
    "$REVIEW_SHA" \
    "$STRUCTURED_FINDINGS" \
    "$INLINE_COUNT" \
    "${INLINE_FAILURES:-0}" \
    "${INLINE_DROPPED:-0}" \
    "$FINDINGS_NORMALIZED_CLEANLY" \
    "$DIFF_TRUNCATED" \
    "${DIFF_OMITTED_BYTES:-0}" \
    "${DIFF_FULL_SIZE:-0}" \
    "$MAX_DIFF_BYTES" \
    "$PARTIAL_FILES" \
    "$TARGET_BRANCH" \
    "$BRANCH" \
    "$CI_PIPELINE_URL")

  if post_review_discussion "$MR_IID" "$REVIEW_COMMENT" true; then
    log "✅ Posted review comment to MR !${MR_IID}"

    # -----------------------------------------------------------------
    # RESOLVE VERIFIED THREADS: Check prior unresolved auto-review inline
    # threads. If the file they reference was changed in this MR AND the new
    # review did NOT re-raise a finding on the same file+line, the prior
    # finding is considered addressed and gets resolved.
    #
    # Gated on successful post: if the new review summary failed to post, a
    # human reviewer would see threads disappear with no explanation. Only
    # resolve once the new summary is confirmed delivered.
    # -----------------------------------------------------------------
    log "Checking for prior findings now addressed..."
    # Pass only the files in the LATEST PUSH (not the full MR diff) so that
    # only threads on files the reviewer actually re-examined this cycle are
    # eligible for resolution. Threads on files changed earlier in the MR
    # but not in this push are left open until a future review cycle.
    # NOTE: no 'local' here — this block runs in the main script body, not a function.
    latest_push_files=$(git diff-tree --no-commit-id --name-only -r "$REVIEW_SHA" 2>/dev/null || echo "")
    if [[ "$DIFF_TRUNCATED" == "false" &&
      -z "$PARTIAL_FILES" &&
      "$FINDINGS_NORMALIZED_CLEANLY" == "true" &&
      "$INLINE_HEAD_SHA" == "$REVIEW_SHA" &&
      "$INLINE_FAILURES" -eq 0 &&
      "$INLINE_DROPPED" -eq 0 ]]; then
      resolve_verified_threads "$MR_IID" "$FINDINGS_JSON" "$latest_push_files" "$REVIEWER_ID" \
        "${HAC_REVIEW_INCLUDE_LEGACY_THREADS:-true}" || true
    else
      log "Skipping verified thread resolution because review context or structured findings were incomplete."
    fi
  else
    log_error "Failed to post review comment to MR !${MR_IID} — skipping thread resolution"
  fi

  is_bot_authored_tip() {
    local review_sha="$1"
    local tip_author tip_message
    tip_author=$(git log -1 --format='%ae' "$review_sha" 2>/dev/null || true)
    if echo "$tip_author" | grep -qi "claude-bot"; then
      return 0
    fi
    tip_message=$(git log -1 --format='%B' "$review_sha" 2>/dev/null || true)
    echo "$tip_message" | grep -qE "^Acted-By:[[:space:]]*ci-bot[[:space:]]*$"
  }

  # -----------------------------------------------------------------
  # AUTO-TRIGGER: If the reviewed commit was authored by the Claude bot AND
  # the review contains findings, trigger the claude-respond pipeline so the
  # bot can automatically address the review feedback.
  # -----------------------------------------------------------------
  if [[ -n "${CLAUDE_TRIGGER_TOKEN:-}" && "${HAC_REVIEW_AUTO_FIX:-true}" == "true" ]]; then
    # Check only the reviewed tip: historical bot authorship must not grant a
    # human push an autonomous repair.
    IS_BOT_COMMIT=false
    if is_bot_authored_tip "$REVIEW_SHA"; then
      IS_BOT_COMMIT=true
    fi

    # Separate the authorship signal from the gating decision.
    # IS_BOT_COMMIT records whether the commit was authored by the bot (immutable).
    # SHOULD_AUTOTRIGGER starts as IS_BOT_COMMIT and can be flipped to false by
    # concurrency checks below. This avoids misleading log messages like
    # "Human-authored commit" when the real reason is a held lock.
    SHOULD_AUTOTRIGGER="$IS_BOT_COMMIT"

    # Advisory concurrency checks — skip auto-trigger if a wip: signal is held.
    # Fail modes and rationale: docs/adr-wip-lock.md
    # TODO(#7): Reuse MR_DATA.labels instead of 2 separate GETs.
    if [[ "$SHOULD_AUTOTRIGGER" == "true" ]]; then
      # Check 1: bot's own lock held → parent still iterating.
      # Fail-open by design; see adr-wip-lock.md#fail-open.
      if has_bot_wip_signal "$MR_IID"; then
        log "MR !${MR_IID} has active ${WIP_BOT_LABEL} signal — parent job still iterating, skipping auto-trigger"
        SHOULD_AUTOTRIGGER=false
      fi
    fi
    if [[ "$SHOULD_AUTOTRIGGER" == "true" ]]; then
      # Check 2: Skip if a non-bot actor holds a wip: lock (human is working).
      NON_BOT_WIP=$(get_non_self_wip_signals "$MR_IID")
      if [[ "$NON_BOT_WIP" == "__API_ERROR__" ]]; then
        log_error "Cannot verify wip signal state — skipping auto-trigger (fail-closed)"
        SHOULD_AUTOTRIGGER=false
      elif [[ -n "$NON_BOT_WIP" ]]; then
        log "MR !${MR_IID} has non-bot wip signal ($NON_BOT_WIP) — skipping auto-trigger"
        SHOULD_AUTOTRIGGER=false
      fi
    fi

    # Only a clean, non-empty structured result can authorize auto-fix. Review
    # prose is informative but cannot grant code-changing privileges.
    HAS_FINDINGS=false
    if [[ "$FINDINGS_NORMALIZED_CLEANLY" == "true" &&
          "$VALID_FINDING_COUNT" -gt 0 &&
          -n "$INLINE_HEAD_SHA" &&
          "$INLINE_COUNT" -eq "$VALID_FINDING_COUNT" &&
          "$INLINE_FAILURES" -eq 0 &&
          "$INLINE_DROPPED" -eq 0 ]]; then
      HAS_FINDINGS=true
    fi

    # Global cap on review-driven retriggers. Unlike CLAUDE_ITERATION (which the
    # self-iteration loop in iterate.sh increments), the review→respond path used
    # to hardcode CLAUDE_ITERATION=1, resetting the budget on every review cycle
    # and allowing unbounded review→respond loops. We track a separate counter
    # that increments across review-driven retriggers and stop once it hits the
    # max. The respond job propagates this back via the synthetic payload trigger.
    #
    # CI variables don't survive across pipeline boundaries (each branch pipeline
    # triggered by a push to the MR source branch is a fresh context), so we
    # also read the count from the tip commit's "Review-Trigger-Count" trailer as a
    # fallback. The respond job writes this trailer on every commit it creates.
    TRAILER_COUNT=$(git log -1 --format='%B' "$REVIEW_SHA" 2>/dev/null \
      | sed -n 's/^Review-Trigger-Count:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1)
    REVIEW_TRIGGER_COUNT="${CLAUDE_REVIEW_TRIGGER_COUNT:-${TRAILER_COUNT:-0}}"
    # Validate: if trailer/env produced non-numeric text, reset to 0 to avoid
    # aborting the review job with "integer expression expected" under set -e.
    [[ "$REVIEW_TRIGGER_COUNT" =~ ^[0-9]+$ ]] || REVIEW_TRIGGER_COUNT=0
    MAX_REVIEW_TRIGGERS="${CLAUDE_MAX_REVIEW_TRIGGERS:-3}"
    if [[ "$SHOULD_AUTOTRIGGER" == "true" && "$HAS_FINDINGS" == "true" && "$REVIEW_TRIGGER_COUNT" -ge "$MAX_REVIEW_TRIGGERS" ]]; then
      log "Reached max review-driven retriggers ($MAX_REVIEW_TRIGGERS) — not auto-triggering to avoid an unbounded loop."
    elif [[ "$SHOULD_AUTOTRIGGER" == "true" && "$HAS_FINDINGS" == "true" && ! "${POSTED_REVIEW_NOTE_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
      log_error "Review findings cannot trigger auto-fix without an immutable review note ID."
    elif [[ "$SHOULD_AUTOTRIGGER" == "true" && "$HAS_FINDINGS" == "true" ]]; then
      NEXT_REVIEW_TRIGGER_COUNT=$((REVIEW_TRIGGER_COUNT + 1))
      log "Bot-authored commit with review findings — triggering auto-fix (review-trigger ${NEXT_REVIEW_TRIGGER_COUNT}/${MAX_REVIEW_TRIGGERS})..."

      # Build a synthetic payload that tells claude-respond to address the review.
      # Do not embed the full review text because trigger variables have
      # practical size limits. Pass the immutable note ID instead so a later
      # companion review cannot replace the triggering primary review in context.
      RETRIGGER_COMMENT="@claude The auto-review found issues with your last commit (${REVIEW_SHA:0:8}). Please read the attached triggering review and address all findings marked as high priority or blocking. Fix each issue in the code and push."

      # Use "claude-auto-review" as the username — the respond script's bot
      # guard must allowlist this (it's not a real user, just a trigger source).
      RETRIGGER_PAYLOAD=$(jq -n \
        --arg note "$RETRIGGER_COMMENT" \
        --arg noteable_type "MergeRequest" \
        --arg username "claude-auto-review" \
        --arg mr_iid "$MR_IID" \
        --arg review_note_id "${POSTED_REVIEW_NOTE_ID:-}" \
        --arg review_sha "$REVIEW_SHA" \
        --arg review_body_hash "${POSTED_REVIEW_BODY_HASH:-}" \
        '{
          object_attributes: {
            note: $note,
            noteable_type: $noteable_type,
            id: 0,
            review_note_id: $review_note_id,
            review_sha: $review_sha,
            review_body_hash: $review_body_hash
          },
          user: { username: $username },
          merge_request: { iid: ($mr_iid | tonumber) }
        }')

      log "Trigger payload size: ${#RETRIGGER_PAYLOAD} bytes"

      # Trigger on the MR source branch (not main) so the pipeline runs
      # the branch's version of claude-respond.sh (which has the allowlist).
      # Forward the incremented count; respond persists it via the commit
      # trailer (read back on the next branch-pipeline review — GitLab fires
      # a new branch pipeline on every push to the source branch).
      TRIGGER_RESPONSE=$(review_curl -s --request POST \
        --form "token=${CLAUDE_TRIGGER_TOKEN}" \
        --form "ref=${BRANCH}" \
        --form "variables[TRIGGER_PAYLOAD_JSON]=$RETRIGGER_PAYLOAD" \
        --form "variables[CLAUDE_ITERATION]=1" \
        --form "variables[CLAUDE_REVIEW_TRIGGER_COUNT]=${NEXT_REVIEW_TRIGGER_COUNT}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/trigger/pipeline")
      TRIGGERED_ID=$(echo "$TRIGGER_RESPONSE" | jq -r '.id // empty')

      if [[ -n "$TRIGGERED_ID" ]]; then
        log "✅ Triggered claude-respond pipeline #$TRIGGERED_ID to address review findings."
        post_review_discussion "$MR_IID" "🔄 Review findings detected on bot-authored commit — auto-triggering Claude to address them. [Pipeline #${TRIGGERED_ID}](${CI_PROJECT_URL}/-/pipelines/${TRIGGERED_ID})" false || true
      else
        log_error "Failed to trigger claude-respond pipeline."
        log_error "Response: $(echo "$TRIGGER_RESPONSE" | head -c 300)"
      fi
    elif [[ "$SHOULD_AUTOTRIGGER" == "true" ]]; then
      log "Bot-authored commit but no actionable findings — no auto-trigger needed."
    elif [[ "$IS_BOT_COMMIT" == "true" ]]; then
      log "Bot-authored commit but auto-trigger blocked by concurrency check — skipping."
    else
      log "Human-authored commit — no auto-trigger (review is informational only)."
    fi
  elif [[ "${HAC_REVIEW_AUTO_FIX:-true}" != "true" ]]; then
    log "Review auto-fix disabled for this reviewer."
  else
    log "CLAUDE_TRIGGER_TOKEN not set — auto-trigger on review findings disabled."
  fi
else
  log_error "Databricks endpoint returned HTTP $HTTP_CODE after $LLM_ATTEMPT attempt(s)"
  log_error "Response body: $(echo "$HTTP_BODY" | head -c 500)"

  # Post a sanitized failure notice (don't leak raw upstream error bodies)
  post_review_discussion "$MR_IID" "⚠️ **Auto-review failed** for commit ${REVIEW_SHA:0:8}

The review API returned HTTP ${HTTP_CODE}. [See pipeline](${CI_PIPELINE_URL}) for details." false || true
  exit 1
fi

log_step "DONE"
log "Auto-review completed successfully."
