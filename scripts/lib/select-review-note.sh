#!/usr/bin/env bash

select_review_note() {
  local review_notes="$1" review_prefix="$2" bot_username="$3"

  [[ -n "$bot_username" ]] || return 1
  echo "$review_notes" | jq -c --arg prefix "$review_prefix" --arg bot "$bot_username" '
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
    | .[0] // empty
  '
}

fetch_prior_review_notes() {
  local mr_iid="$1" review_prefix="$2" bot_username="$3"
  local page page_notes page_count page_chars total_chars max_chars remaining_chars

  REVIEW_NOTES="[]"
  LAST_REVIEW_NOTE=""
  REVIEW_NOTES_TRUNCATED=false

  max_chars="${MAX_REVIEW_NOTES_CHARS:-500000}"
  [[ "$max_chars" =~ ^[0-9]+$ ]] || max_chars=500000
  if [[ "$max_chars" -eq 0 ]]; then
    return 0
  fi
  total_chars=0

  for page in {1..10}; do
    remaining_chars=$((max_chars - total_chars))
    if (( remaining_chars <= 0 )); then
      log "Warning: prior-review notes reached the ${max_chars}-character history budget; omitting incomplete context"
      REVIEW_NOTES="[]"
      LAST_REVIEW_NOTE=""
      return 1
    fi
    if ! page_notes=$(GL_API_MAX_BYTES="$remaining_chars" gl_api "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${mr_iid}/notes?sort=desc&per_page=100&page=${page}"); then
      log "Warning: prior-review notes page ${page} was unavailable; omitting incomplete context"
      REVIEW_NOTES="[]"
      LAST_REVIEW_NOTE=""
      return 1
    fi
    page_chars=${#page_notes}
    if (( page_chars > max_chars || total_chars + page_chars > max_chars )); then
      log "Warning: prior-review notes exceeded the ${max_chars}-character history budget; omitting incomplete context"
      REVIEW_NOTES="[]"
      LAST_REVIEW_NOTE=""
      return 1
    fi
    total_chars=$((total_chars + page_chars))
    if ! page_count=$(printf '%s\n' "$page_notes" | jq -er 'if type == "array" then length else error("not an array") end' 2>/dev/null); then
      log "Warning: prior-review notes page was malformed; omitting incomplete context"
      REVIEW_NOTES="[]"
      LAST_REVIEW_NOTE=""
      return 1
    fi
    REVIEW_NOTES=$(printf '%s\n%s\n' "$REVIEW_NOTES" "$page_notes" | jq -cs '.[0] + .[1]')
    LAST_REVIEW_NOTE=$(select_review_note "$REVIEW_NOTES" "$review_prefix" "$bot_username" || true)
    [[ "$page_count" -lt 100 ]] && return 0
  done

  log "Warning: prior-review history is limited to the newest 1,000 notes"
  REVIEW_NOTES_TRUNCATED=true
}
