#!/usr/bin/env bash
# =============================================================================
# Gather key file contents for LLM context (priority: MR diff files first)
# =============================================================================

_gather_key_files() {
  local local_ret local_path CAP_REACHED
  # These are intentionally global — consumed by apply-changes.sh (_check_scope_guard)
  # and post-comment.sh. Do not declare them local.
  MAX_KEY_FILES_BYTES=120000
  KEY_FILES=""
  KEY_FILES_BYTES=0

  # MR_DIFF_FILES is initialized to "" by gather_context and populated for MR context
  # (from JSON, not truncated text). For Issue context it remains empty.
  if [[ -n "${MR_DIFF_FILES:-}" ]]; then
    log "  MR diff touches $(echo "$MR_DIFF_FILES" | wc -l) file(s) — including them first"
  fi

  # Phase 1: Include MR diff files first (highest priority)
  CAP_REACHED=false
  if [[ -n "$MR_DIFF_FILES" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ "$f" != ./* ]] && f="./$f"
      # _add_key_file returns: 0 = added, 1 = skipped (binary/missing), 2 = cap reached
      _add_key_file "$f" && local_ret=0 || local_ret=$?
      if [[ $local_ret -eq 2 ]]; then
        CAP_REACHED=true
        break
      fi
    done <<< "$MR_DIFF_FILES"
  fi

  # Phase 2: Include remaining files alphabetically
  if [[ "$CAP_REACHED" != "true" ]]; then
    while IFS= read -r f; do
      if [[ -n "$MR_DIFF_FILES" ]]; then
        local_path="${f#./}"
        if echo "$MR_DIFF_FILES" | grep -qxF "$local_path"; then
          continue
        fi
      fi
      _add_key_file "$f" && local_ret=0 || local_ret=$?
      if [[ $local_ret -eq 2 ]]; then
        CAP_REACHED=true
        break
      fi
    done < <(find . -type f \
      -not -path './.git/*' \
      -not -path './.gitlab/scripts/*' \
      -not -path './node_modules/*' \
      -not -path './R_libs/*' \
      -not -path './renv/*' \
      -not -path './.Rproj.user/*' \
      -not -path './.vscode/*' \
      | sort)
  fi

  if [[ "$CAP_REACHED" == "true" ]]; then
    log "  Context cap reached (${KEY_FILES_BYTES} bytes) — skipping remaining files"
    KEY_FILES="${KEY_FILES}

[... additional files omitted due to context size limit ...]
"
  fi
  log "  Key files context: ${KEY_FILES_BYTES} bytes (cap: ${MAX_KEY_FILES_BYTES})"
}

# Helper: add a file to KEY_FILES if it passes filters and fits within the cap.
_add_key_file() {
  local f="$1"
  case "$f" in
    *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.pdf|*.rds|*.RData|*.rda|*.o|*.so|*.dll) return 1 ;;
  esac
  [[ -f "$f" ]] || return 1
  local FILE_SIZE
  FILE_SIZE=$(wc -c < "$f")
  [[ $FILE_SIZE -gt 50000 ]] && return 1
  if [[ $((KEY_FILES_BYTES + FILE_SIZE)) -gt $MAX_KEY_FILES_BYTES ]]; then
    return 2  # signal cap reached
  fi
  KEY_FILES="${KEY_FILES}
=== ${f} ===
$(cat "$f")
"
  KEY_FILES_BYTES=$((KEY_FILES_BYTES + FILE_SIZE))
  return 0
}
