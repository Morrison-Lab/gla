#!/usr/bin/env bash

select_author_response() {
  local notes="$1"
  local review_id="$2"
  local mr_author="$3"
  local configured_bot="${4:-}"
  local max_chars="${5:-2000}"
  local before_id="${6:-}"
  local include_trusted_bot_rebuttals="${7:-false}"

  [[ "$max_chars" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ -z "$before_id" || "$before_id" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$include_trusted_bot_rebuttals" == "true" || "$include_trusted_bot_rebuttals" == "false" ]] || return 1
  [[ "$max_chars" == "0" ]] && return 0

  # Missing identity is a valid no-response result. Return success because the
  # caller runs this command substitution under set -e and expects empty output.
  [[ -n "$mr_author" ]] || return 0
  [[ "$review_id" =~ ^[1-9][0-9]*$ ]] || return 0

  jq -r \
    --argjson review_id "$review_id" \
    --arg mr_author "$mr_author" \
    --arg configured_bot "$configured_bot" \
    --argjson max_chars "$max_chars" \
    --arg before_id "$before_id" \
    --argjson include_trusted_bot_rebuttals "$include_trusted_bot_rebuttals" '
    [.[] | . as $note | select(
      if ($note | type) != "object" then false
      elif $note.system != false then false
      elif ($note.author | type) != "object" then false
      elif ($note.author.username | type) != "string" then false
      elif $note.author.username != $mr_author then false
      elif ($note.id | type) != "number" then false
      elif ($note.id != ($note.id | floor) or $note.id <= $review_id) then false
      elif ($before_id != "" and (($note.id | tostring) | tonumber) >= ($before_id | tonumber)) then false
      elif ($note.body | type) != "string" then false
      elif (($note.author.bot == true or
             ($configured_bot != "" and $mr_author == $configured_bot) or
             ($mr_author | test("^project_[0-9]+_bot_"))) and
            (($include_trusted_bot_rebuttals and
              $configured_bot != "" and $mr_author == $configured_bot and
              ($note.body | startswith("REBUTTED:"))) | not)) then false
      elif ($note.body | test("^(🔍 (\\*\\*Auto-review|\\[[^]]+\\]|[🔴🟡🔵⚪])|🔄|⚠️ \\*\\*Auto-review failed)")) then false
      else true
      end
    )]
    | sort_by(.id)
    | if length == 0 then ""
      else
        (length) as $count
        | (if $max_chars >= (($count * 1) + (($count - 1) * 2))
           then "\n\n" else "" end) as $separator
        | ($max_chars - (($count - 1) * ($separator | length))) as $body_budget
        | (($body_budget / $count) | floor) as $per_note
        | ($body_budget % $count) as $remainder
        | to_entries
        | map(.value.body as $body
              | ($per_note + (if .key >= ($count - $remainder) then 1 else 0 end)) as $note_budget
              | if ($body | length) <= $note_budget then $body
                elif $note_budget > 17 then $body[0:($note_budget - 17)] + "\n... (truncated)"
                else $body[0:$note_budget]
                end)
        | join($separator)
      end
  ' <<< "$notes"
}
