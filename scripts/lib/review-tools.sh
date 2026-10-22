#!/usr/bin/env bash
# Read-only tools exposed to the automatic review agent.

REVIEW_TOOLS_JSON='[
  {"type":"function","function":{"name":"list_repository_files","description":"List tracked files in the repository, optionally below a relative directory.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Optional relative directory from the repository root."}},"additionalProperties":false}}},
  {"type":"function","function":{"name":"read_repository_file","description":"Read a tracked text file from the repository. Paths must be relative and cannot escape the repository.","parameters":{"type":"object","properties":{"path":{"type":"string"},"max_chars":{"type":"integer","minimum":1,"maximum":30000}},"required":["path"],"additionalProperties":false}}},
  {"type":"function","function":{"name":"read_merge_request_history","description":"Read the fetched merge-request discussion and prior review history, including author responses.","parameters":{"type":"object","properties":{},"additionalProperties":false}}},
  {"type":"function","function":{"name":"fetch_allowlisted_documentation","description":"Fetch one of the approved fixed documentation pages.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}}}
]'

_review_safe_path() {
  local requested_path="${1:-}"
  [[ -n "$requested_path" && "$requested_path" != /* && "$requested_path" != *$'\n'* && "$requested_path" != *'..'* ]] || return 1
  [[ -e "$requested_path" && ! -L "$requested_path" ]] || return 1
  return 0
}

execute_review_tool() {
  local name="$1" args="$2" requested_path max_chars read_bytes url bounded_file files file_count truncated
  if ! jq -e 'type == "object"' <<< "$args" >/dev/null 2>&1; then
    jq -nc '{error:"tool arguments must be a JSON object"}'
    return 0
  fi
  case "$name" in
    list_repository_files)
      requested_path=$(jq -r '.path // ""' <<< "$args")
      if [[ -n "$requested_path" ]] && {
        [[ "$requested_path" == /* || "$requested_path" == *'..'* || "$requested_path" == *$'\n'* || "$requested_path" == :* || "$requested_path" == !* || "$requested_path" == *['*?[]']* ]] ||
        [[ ! -d "$requested_path" || -L "$requested_path" ]]
      }; then
        jq -nc '{error:"path must be a relative repository directory"}'
        return 0
      fi
      if [[ -n "$requested_path" ]]; then
        files=$(git ls-files -- "$requested_path/" | head -n 1001 || true)
      else
        files=$(git ls-files | head -n 1001 || true)
      fi
      file_count=$(printf '%s\n' "$files" | awk 'NF { count += 1 } END { print count + 0 }')
      truncated=false
      if [[ "$file_count" -gt 1000 ]]; then
        truncated=true
        files=$(printf '%s\n' "$files" | head -n 1000)
      fi
      jq -Rsc --argjson truncated "$truncated" '{files: (split("\n") | map(select(length > 0))),truncated:$truncated,limit:1000}' <<< "$files"
      ;;
    read_repository_file)
      requested_path=$(jq -r '.path // ""' <<< "$args")
      max_chars=$(jq -r '.max_chars // 30000' <<< "$args")
      if ! _review_safe_path "$requested_path" || ! [[ "$max_chars" =~ ^[1-9][0-9]*$ ]] || [[ "$max_chars" -gt 30000 ]]; then
        jq -nc '{error:"invalid or unsafe file request"}'
        return 0
      fi
      if ! git --literal-pathspecs ls-files --error-unmatch -- "$requested_path" >/dev/null 2>&1 || [[ ! -f "$requested_path" ]]; then
        jq -nc '{error:"file is not a tracked regular file"}'
        return 0
      fi
      bounded_file=$(mktemp)
      read_bytes=$((max_chars * 4 + 4))
      if ! head -c "$read_bytes" -- "$requested_path" > "$bounded_file" || \
        ! jq -Rs --arg path "$requested_path" --argjson max_chars "$max_chars" '{path:$path,content:(.[0:$max_chars]),truncated:(length > $max_chars)}' < "$bounded_file"; then
        rm -f "$bounded_file"
        jq -nc '{error:"failed to read tracked file"}'
      else
        rm -f "$bounded_file"
      fi
      ;;
    read_merge_request_history)
      local notes history max_chars serialized
      notes="${REVIEW_NOTES:-}"
      history="${PRIOR_REVIEW_CONTEXT:-}"
      max_chars="${MAX_REVIEW_HISTORY_CHARS:-12000}"
      if ! [[ "$max_chars" =~ ^[0-9]+$ ]]; then
        max_chars=12000
      fi
      if [[ "$max_chars" -eq 0 ]]; then
        jq -n '{discussion:"",prior_review_context:"",truncated:false,max_chars:0}'
        return 0
      fi
      serialized=$(jq -n --arg notes "$notes" --arg history "$history" \
        '{discussion:$notes,prior_review_context:$history}' | jq -c .)
      if [[ ${#serialized} -gt $max_chars ]]; then
        jq -n --arg history "${serialized:0:max_chars}" \
          --argjson max_chars "$max_chars" \
          '{history:$history,truncated:true,max_chars:$max_chars}'
      else
        jq -n --arg notes "$notes" --arg history "$history" \
          '{discussion:$notes,prior_review_context:$history,truncated:false}'
      fi
      ;;
    fetch_allowlisted_documentation)
      url=$(jq -r '.url // ""' <<< "$args")
      case "$url" in
        https://ucd-serg.github.io/lab-manual/|\
        https://ucd-serg.github.io/lab-manual/coding-style.html|\
        https://ucd-serg.github.io/lab-manual/coding-practices.html|\
        https://docs.gitlab.com/ee/ci/yaml/includes.html|\
        https://docs.gitlab.com/ee/ci/pipelines/merge_request_pipelines.html) ;;
        *) jq -nc '{error:"URL is not on the review documentation allowlist"}'; return 0 ;;
      esac
      doc_file=$(mktemp)
      if ! curl --globoff -sf --max-time "${REVIEW_TOOL_TIMEOUT_SECONDS:-10}" --max-filesize 20000 "$url" -o "$doc_file" 2>/dev/null; then
        rm -f "$doc_file"
        jq -nc '{error:"failed to fetch allowlisted documentation"}'
        return 0
      fi
      doc=$(head -c 20000 "$doc_file")
      rm -f "$doc_file"
      jq -Rsc --arg url "$url" '{url:$url,content:split("\n")}' <<< "$doc"
      ;;
    *) jq -nc --arg name "$name" '{error:("unknown review tool: " + $name)}' ;;
  esac
}
