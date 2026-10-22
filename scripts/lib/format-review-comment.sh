#!/usr/bin/env bash
# =============================================================================
# Helper: format the final review comment and footer
# =============================================================================

format_review_comment() {
  local summary_text="$1"
  local reviewer_id="$2"
  local model="$3"
  local mr_iid="$4"
  local num_commits="$5"
  local review_sha="$6"
  local structured_findings="$7"
  local inline_count="$8"
  local inline_failures="$9"
  local inline_dropped="${10}"
  local findings_normalized_cleanly="${11}"
  local diff_truncated="${12}"
  local diff_omitted_bytes="${13}"
  local diff_full_size="${14}"
  local max_diff_bytes="${15}"
  local partial_files="${16}"
  local target_branch="${17}"
  local branch="${18}"
  local ci_pipeline_url="${19}"

  local review_body="🔍 **Auto-review by ${reviewer_id} (${model}) of MR !${mr_iid}** (${num_commits} commit(s), latest: ${review_sha:0:8})

${summary_text}"

  if [[ -n "$structured_findings" ]]; then
    review_body+="

### Structured actionable findings
${structured_findings}"
  fi

  if [[ ${inline_count:-0} -gt 0 ]]; then
    review_body+="

> 📌 **${inline_count} inline comment(s)** posted directly on the diff — see the Changes tab."
  fi
  if [[ ${inline_failures:-0} -gt 0 ]]; then
    review_body+="

> ⚠️ **${inline_failures} finding(s)** could not be pinned to the diff — see summary above."
  fi
  if [[ ${inline_dropped:-0} -gt 0 ]]; then
    review_body+="

> ℹ️ **${inline_dropped} finding(s)** dropped (missing file/line or file not in diff)."
  fi
  if [[ "$findings_normalized_cleanly" != "true" ]]; then
    review_body+="

> ⚠️ Malformed structured findings were dropped. Prior review threads were not auto-resolved."
  fi
  if [[ "$diff_truncated" == "true" ]]; then
    review_body+="

> ⚠️ **Partial review:** MR diff was truncated (${diff_omitted_bytes} of ${diff_full_size} bytes omitted to fit ${max_diff_bytes}-byte cap). Changes beyond the cap were not reviewed."
  fi
  if [[ -n "$partial_files" ]]; then
    review_body+="

> ⚠️ **Partial context:** Full-file contents were omitted or partially truncated for some modified files (binary content or context budget limits)."
  fi

  local diff_scope_label="full MR diff"
  if [[ "$diff_truncated" == "true" || -n "$partial_files" ]]; then
    diff_scope_label="partial MR diff"
  fi

  local review_comment="${review_body}
---
<sub>🤖 Automated review of ${diff_scope_label} vs \`${target_branch}\` · source: \`${branch}\` · [pipeline](${ci_pipeline_url})</sub>"

  printf '%s' "$review_comment"
}
