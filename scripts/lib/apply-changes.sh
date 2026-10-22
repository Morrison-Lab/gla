#!/usr/bin/env bash
# =============================================================================
# Apply tool calls (edit_file / create_file) from the LLM response
# =============================================================================
# Requires: _apply_edit_file (sourced from edit-file.sh)

apply_changes() {
  log_step "APPLYING FILE CHANGES"

  FILES_CHANGED=0
  EDIT_FAILURES=""   # accumulates human-readable notes about tool calls that didn't apply

  if [[ -n "$TOOL_CALLS" && "${TOOL_CALL_COUNT:-0}" -gt 0 ]]; then
    log "Processing ${TOOL_CALL_COUNT} tool call(s)..."

    for i in $(seq 0 $((TOOL_CALL_COUNT - 1))); do
      FUNC_NAME=$(echo "$TOOL_CALLS" | jq -r ".[$i].function.name")
      FUNC_ARGS=$(echo "$TOOL_CALLS" | jq -r ".[$i].function.arguments")

      case "$FUNC_NAME" in
        edit_file)
          _apply_edit_file "$FUNC_ARGS"
          ;;
        create_file)
          _apply_create_file "$FUNC_ARGS"
          ;;
        *)
          log "  WARN: Unknown tool call: $FUNC_NAME — skipped"
          ;;
      esac
    done

    log "Applied $FILES_CHANGED change(s)."

    # SCOPE GUARD: Warn if changes touch files outside the MR diff
    if [[ "$NOTEABLE_TYPE" == "MergeRequest" && -n "${MR_DIFF_FILES:-}" && $FILES_CHANGED -gt 0 ]]; then
      _check_scope_guard
    fi
  else
    log "No tool calls in response — nothing to commit."
    log "  (If you expected code changes, the model may have only provided a review.)"
    log "  Response preview (first 300 chars):"
    echo "$RESPONSE" | head -c 300
    echo ""
  fi
}

_apply_create_file() {
  local func_args="$1"
  local FPATH CONTENT FDIR

  FPATH=$(echo "$func_args" | jq -r '.path')
  CONTENT=$(echo "$func_args" | jq -r '.content')

  FDIR=$(dirname "$FPATH")
  if [[ -n "$FDIR" && "$FDIR" != "." ]]; then
    mkdir -p "$FDIR"
  fi

  if printf '%s' "$CONTENT" > "$FPATH"; then
    log "  Created: $FPATH"
    FILES_CHANGED=$((FILES_CHANGED + 1))
  else
    log "  WARN: Could not write new file $FPATH"
    EDIT_FAILURES="${EDIT_FAILURES}- Could not create \`${FPATH}\`: write failed.\n"
  fi
}

_check_scope_guard() {
  local MODIFIED_FILES OUT_OF_SCOPE
  # Stage all changes so we catch both modified AND newly created files.
  # commit-push also runs git add -A, so leaving changes staged is fine.
  # Exclude .gitlab/scripts/: see commit-push.sh for why. HACtions#48.
  git add -A -- . ':!.gitlab/scripts' 2>/dev/null || true
  MODIFIED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
  OUT_OF_SCOPE=""
  while IFS= read -r modified; do
    [[ -z "$modified" ]] && continue
    if ! echo "$MR_DIFF_FILES" | grep -qxF "$modified"; then
      OUT_OF_SCOPE="${OUT_OF_SCOPE}  - ${modified}\n"
    fi
  done <<< "$MODIFIED_FILES"

  if [[ -n "$OUT_OF_SCOPE" ]]; then
    log "  ⚠️  SCOPE GUARD: Changes touch files outside the MR diff:"
    printf '%b' "$OUT_OF_SCOPE" | while read -r line; do log "    $line"; done
    EDIT_FAILURES="${EDIT_FAILURES}\n⚠️ **Scope warning:** The following files were modified but are NOT part of this MR's diff:\n$(printf '%b' "$OUT_OF_SCOPE")\nThis may indicate an unintended edit. Please review before merging.\n"
  fi
}
