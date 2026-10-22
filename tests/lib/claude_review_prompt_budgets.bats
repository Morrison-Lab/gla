#!/usr/bin/env bats
# =============================================================================
# Regression tests for claude-review.sh's prompt-budget truncation disclosure
# (issues #53, #55, #56).
# =============================================================================
# Each helper below mirrors the corresponding shell logic in
# scripts/claude-review.sh. Keep the two in sync if either changes. Where a
# helper deliberately mirrors only part of the production behaviour, its own
# comment says so.
#
# What these guard: content dropped from the prompt must be DISCLOSED to the
# model. A silent cut lets the reviewer return a clean verdict over code it
# never received, which reads as a passing review rather than as an error.
#
# Run with: bats tests/lib/claude_review_prompt_budgets.bats

source scripts/lib/validate-nonnegative-integer.sh
REVIEW_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"

# --- #53: diff truncation ----------------------------------------------------

# build_diff_disclosure FULL_SIZE MAX_BYTES
# Prints "truncated" plus the disclosure text when the cap is exceeded,
# otherwise "complete".
#
# Mirrors only the BRANCH CONDITION and the byte-count interpolation, not the
# full disclosure wording -- the production string continues past what is
# asserted here. Asserting the exact prose would make the test fail on a pure
# rewording, which is not a behaviour change.
build_diff_disclosure() {
  local DIFF_FULL_SIZE="$1"
  local MAX_DIFF_BYTES="$2"
  if [[ $DIFF_FULL_SIZE -gt $MAX_DIFF_BYTES ]]; then
    echo "truncated"
    echo "**INCOMPLETE — this diff was truncated to fit a size cap. You are seeing"
    echo "${MAX_DIFF_BYTES} of ${DIFF_FULL_SIZE} bytes."
  else
    echo "complete"
  fi
}

# truncate_diff DIFF MAX_BYTES
# Mirrors the capture-full-then-cap logic, appending the omission marker.
# NOTE: `set -o pipefail` is enabled below to mirror the production script's
# `set -euo pipefail`. Without it the SIGPIPE regression test cannot fail, since
# the whole defect is that the pipeline's exit status is only visible under
# pipefail.
truncate_diff() {
  set -o pipefail
  local COMMIT_DIFF_FULL="$1"
  local MAX_DIFF_BYTES="$2"
  local DIFF_FULL_SIZE COMMIT_DIFF DIFF_OMITTED_BYTES
  DIFF_FULL_SIZE=$(printf '%s' "$COMMIT_DIFF_FULL" | wc -c | tr -d ' ')
  if [[ $DIFF_FULL_SIZE -gt $MAX_DIFF_BYTES ]]; then
    COMMIT_DIFF=$(printf '%s' "$COMMIT_DIFF_FULL" | head -c "$MAX_DIFF_BYTES" || true)
    DIFF_OMITTED_BYTES=$((DIFF_FULL_SIZE - MAX_DIFF_BYTES))
    COMMIT_DIFF="${COMMIT_DIFF}

... [DIFF TRUNCATED — ${DIFF_OMITTED_BYTES} of ${DIFF_FULL_SIZE} bytes omitted to fit the ${MAX_DIFF_BYTES}-byte cap.
This diff is INCOMPLETE. Changes beyond this point were not provided to you.]"
  else
    COMMIT_DIFF="$COMMIT_DIFF_FULL"
  fi
  printf '%s' "$COMMIT_DIFF"
}

@test "diff under the cap is passed through unmarked" {
  run truncate_diff "small diff" 100000
  [ "$status" -eq 0 ]
  [ "$output" = "small diff" ]
}

@test "diff over the cap carries a truncation marker" {
  local big
  big=$(printf 'x%.0s' $(seq 1 200))
  run truncate_diff "$big" 100
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIFF TRUNCATED"* ]]
  [[ "$output" == *"INCOMPLETE"* ]]
}

@test "truncation marker reports the omitted and total byte counts" {
  local big
  big=$(printf 'x%.0s' $(seq 1 200))
  run truncate_diff "$big" 100
  [[ "$output" == *"100 of 200 bytes omitted"* ]]
}

@test "diff truncated exactly at the cap boundary is not marked" {
  local exact
  exact=$(printf 'x%.0s' $(seq 1 100))
  run truncate_diff "$exact" 100
  [ "$output" = "$exact" ]
}

@test "UTF-8 diff truncation stops before a partial multibyte line" {
  eval "$(sed -n '/^truncate_utf8_lines()/,/^}/p' "$REVIEW_SCRIPT")"
  local input="$BATS_TEST_TMPDIR/utf8-input"
  local output="$BATS_TEST_TMPDIR/utf8-output"
  printf 'ascii line\nééé line\nlast line\n' > "$input"

  truncate_utf8_lines "$input" "$output" 12

  [ "$(cat "$output")" = "ascii line" ]
  [ "$(wc -c < "$output" | tr -d ' ')" -eq 11 ]
  iconv -f UTF-8 -t UTF-8 "$output" >/dev/null
}

@test "lab manual truncation uses the same UTF-8-safe line boundary" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/lab-manual.sh"
  local input="$BATS_TEST_TMPDIR/manual-utf8-input"
  local output="$BATS_TEST_TMPDIR/manual-utf8-output"
  printf 'manual line\nééé line\nlast line\n' > "$input"

  truncate_utf8_lines "$input" "$output" 12

  [ "$(cat "$output")" = "manual line" ]
  iconv -f UTF-8 -t UTF-8 "$output" >/dev/null
}

@test "diff disclosure reports bytes actually retained after line trimming" {
  run grep -F 'DIFF_OMITTED_BYTES=$((DIFF_FULL_SIZE - DIFF_INCLUDED_BYTES))' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F '${DIFF_INCLUDED_BYTES} of ${DIFF_FULL_SIZE} bytes' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'COMMIT_DIFF=$(cat "$TRUNCATED_DIFF_FILE"; printf' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'COMMIT_DIFF="${COMMIT_DIFF%$'"'\\001'"'}"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

# Regression: a diff big enough that printf is still writing when head exits
# takes SIGPIPE (141), which `set -o pipefail` surfaces as a pipeline failure and
# `set -e` turns into an abort. The 200-byte cases above are too small to trigger
# it — printf finishes before head closes the pipe — so this needs a real payload.
# This is the bug the earlier draft of the fix actually shipped: the cap aborted
# the review on exactly the large diffs it existed to handle.
@test "a diff far over the cap does not abort under pipefail (SIGPIPE guard)" {
  local huge
  huge=$(printf 'x%.0s' $(seq 1 200000))
  run truncate_diff "$huge" 100
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIFF TRUNCATED"* ]]
  [[ "$output" == *"199900 of 200000 bytes omitted"* ]]
}

@test "disclosure says complete when the diff fits" {
  run build_diff_disclosure 500 100000
  [ "${lines[0]}" = "complete" ]
}

@test "disclosure says truncated and names both sizes when it does not fit" {
  run build_diff_disclosure 110000 100000
  [ "${lines[0]}" = "truncated" ]
  [[ "$output" == *"100000 of 110000 bytes"* ]]
}

# --- per-file cap derivation -------------------------------------------------

# derive_caps [HAC_MAX_KEY_FILES_BYTES] [HAC_MAX_SINGLE_FILE_PCT] [HAC_MAX_SINGLE_FILE_BYTES]
# Prints "<total> <per-file>". Mirrors the production derivation.
derive_caps() {
  local HAC_MAX_KEY_FILES_BYTES="${1:-}"
  local HAC_MAX_SINGLE_FILE_PCT="${2:-}"
  local HAC_MAX_SINGLE_FILE_BYTES="${3:-}"
  local MAX_KEY_FILES_BYTES SINGLE_FILE_PCT MAX_SINGLE_FILE_BYTES
  MAX_KEY_FILES_BYTES=${HAC_MAX_KEY_FILES_BYTES:-250000}
  SINGLE_FILE_PCT=${HAC_MAX_SINGLE_FILE_PCT:-60}
  MAX_SINGLE_FILE_BYTES=${HAC_MAX_SINGLE_FILE_BYTES:-$((MAX_KEY_FILES_BYTES * SINGLE_FILE_PCT / 100))}
  echo "$MAX_KEY_FILES_BYTES $MAX_SINGLE_FILE_BYTES"
}

@test "per-file cap defaults to 60% of the total" {
  run derive_caps
  [ "$output" = "250000 150000" ]
}

@test "per-file cap tracks the total when the total is overridden" {
  run derive_caps 200000
  [ "$output" = "200000 120000" ]
}

@test "per-file percentage is overridable" {
  run derive_caps 150000 50
  [ "$output" = "150000 75000" ]
}

@test "an explicit per-file byte override wins over the derivation" {
  run derive_caps 150000 60 40000
  [ "$output" = "150000 40000" ]
}

@test "budget settings accept non-negative decimal integers" {
  run validate_nonnegative_integer HAC_MAX_KEY_FILES_BYTES 0
  [ "$status" -eq 0 ]

  run validate_nonnegative_integer HAC_MAX_KEY_FILES_BYTES 1000000000
  [ "$status" -eq 0 ]

  run validate_nonnegative_integer HAC_MAX_SINGLE_FILE_PCT 100 100
  [ "$status" -eq 0 ]
}

@test "budget settings reject malformed, negative, and out-of-range values" {
  run validate_nonnegative_integer HAC_MAX_KEY_FILES_BYTES -1
  [ "$status" -ne 0 ]

  run validate_nonnegative_integer HAC_MAX_KEY_FILES_BYTES 08
  [ "$status" -ne 0 ]

  run validate_nonnegative_integer HAC_MAX_KEY_FILES_BYTES 1000000001
  [ "$status" -ne 0 ]

  run validate_nonnegative_integer HAC_MAX_KEY_FILES_BYTES 999999999999999999999999999999
  [ "$status" -ne 0 ]

  run validate_nonnegative_integer HAC_MAX_SINGLE_FILE_PCT 101 100
  [ "$status" -ne 0 ]
}

@test "the per-file cap is always below the total, so it can never be vacuous" {
  local total per_file
  read -r total per_file <<< "$(derive_caps)"
  [ "$per_file" -lt "$total" ]
}

# Regression for the condition that made the reviewer blind to its own source:
# claude-review.sh grew past a hard-coded 50000 per-file cap, so it was skipped
# from the prompt entirely. The derived cap must admit a file this size.
@test "the derived per-file cap admits a file the size of claude-review.sh" {
  local per_file
  per_file=$(derive_caps | cut -d' ' -f2)
  [ "$per_file" -gt 60000 ]
}

allocate_first_pass() {
  local total_bytes="$1"
  shift
  local file_count=$#
  local fair_share=$((total_bytes / file_count))
  local file_size included=""
  for file_size in "$@"; do
    [[ $file_size -gt $fair_share ]] && file_size=$fair_share
    included="${included}${file_size} "
  done
  printf '%s' "${included% }"
}

allocate_first_pass_after_headers() {
  local total_bytes="$1" header_bytes="$2"
  shift 2
  local file_count=$#
  local content_budget=$((total_bytes - header_bytes))
  [[ $content_budget -lt 0 ]] && content_budget=0
  allocate_first_pass "$content_budget" "$@"
}

capture_excerpt() {
  local file_path="$1" byte_count="$2" excerpt
  excerpt=$(head -c "$byte_count" -- "$file_path"; printf '\001')
  printf '%s' "${excerpt%$'\001'}"
}

is_binary_file() {
  head -c "$2" -- "$1" | od -An -v -t x1 | grep '00' >/dev/null
}

@test "context priority puts source and tests before lockfiles" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/context-priority.sh"
  run prioritize_context_files <<'EOF'
renv.lock
tests/test-review.R
README.md
src/review.sh
EOF
  [ "$status" -eq 0 ]
  [ "$output" = $'src/review.sh\ntests/test-review.R\nREADME.md\nrenv.lock' ]

  run context_file_priority frontend/package-lock.json
  [ "$output" = "2" ]
  run context_file_priority packages/app/dist/bundle.js
  [ "$output" = "2" ]
}

@test "context priority reserves budget for ordered redistribution" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/context-priority.sh"
  run context_first_pass_budget 1000 50
  [ "$status" -eq 0 ]
  [ "$output" = "500" ]

  run context_first_pass_share 1000 2 50
  [ "$status" -eq 0 ]
  [ "$output" = "250" ]

  run context_first_pass_budget 1000 0
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ]
}

@test "zero reserve preserves legacy changed-file order" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/context-priority.sh"
  run context_files_for_review 0 <<'EOF'
renv.lock
README.md
src/review.sh
EOF
  [ "$status" -eq 0 ]
  [ "$output" = $'renv.lock\nREADME.md\nsrc/review.sh' ]
}

@test "first-pass context allocation includes every changed file" {
  run allocate_first_pass 150 100 100 100
  [ "$status" -eq 0 ]
  [ "$output" = "50 50 50" ]
}

@test "first-pass allocation gives small changed files their complete content" {
  run allocate_first_pass 150 20 100 100
  [ "$status" -eq 0 ]
  [ "$output" = "20 50 50" ]
}

@test "first-pass allocation reserves every entry header before sharing content" {
  run allocate_first_pass_after_headers 150 30 100 100 100
  [ "$status" -eq 0 ]
  [ "$output" = "40 40 40" ]

  run allocate_first_pass_after_headers 20 30 100 100
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

@test "excerpt capture preserves trailing and newline-only file content" {
  local fixture captured
  fixture=$(mktemp)
  captured=$(mktemp)
  printf '\n\n' > "$fixture"

  capture_excerpt "$fixture" 2 > "$captured"
  [ "$(wc -c < "$captured" | tr -d ' ')" = "2" ]

  printf 'content\n' > "$fixture"
  capture_excerpt "$fixture" 8 > "$captured"
  [ "$(wc -c < "$captured" | tr -d ' ')" = "8" ]
  rm -f "$fixture" "$captured"
}

@test "content-based binary detection rejects embedded NUL bytes" {
  local text_file binary_file large_binary_file beyond_limit_file
  text_file=$(mktemp)
  binary_file=$(mktemp)
  large_binary_file=$(mktemp)
  beyond_limit_file=$(mktemp)
  printf 'plain text\n' > "$text_file"
  printf 'a\000b' > "$binary_file"
  {
    printf '\000'
    head -c 131072 /dev/zero | tr '\000' x
  } > "$large_binary_file"
  {
    head -c 128 /dev/zero | tr '\000' x
    printf '\000'
  } > "$beyond_limit_file"

  run is_binary_file "$text_file" 150000
  [ "$status" -ne 0 ]

  run is_binary_file "$binary_file" 150000
  [ "$status" -eq 0 ]

  run is_binary_file "$large_binary_file" 150000
  [ "$status" -eq 0 ]

  run is_binary_file "$beyond_limit_file" 128
  [ "$status" -ne 0 ]
  rm -f "$text_file" "$binary_file" "$large_binary_file" "$beyond_limit_file"
}

@test "context excerpts protect option-like changed filenames" {
  run grep -F 'head -c "$EXCERPT_BYTES" -- "$f"' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F 'tail -c +$((INCLUDED_BYTES + 1)) -- "$f"' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F "EXCERPT=\$(head -c \"\$EXCERPT_BYTES\" -- \"\$f\"; printf '\\001')" scripts/claude-review.sh
  [ "$status" -eq 0 ]
}

@test "context collection skips symlinks and accounts for rendered entry headers" {
  run grep -F '[[ -L "$f" ]] && continue' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F 'AVAILABLE_BYTES=$((MAX_KEY_FILES_BYTES - KEY_FILES_BYTES - HEADER_BYTES))' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F 'REMAINING_BUDGET=$((MAX_KEY_FILES_BYTES - KEY_FILES_BYTES - HEADER_BYTES))' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F 'CONTENT_BUDGET=$((MAX_KEY_FILES_BYTES - FIRST_PASS_HEADER_BYTES))' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F '[[ $BINARY_SCAN_BYTES -gt $MAX_KEY_FILES_BYTES ]] && BINARY_SCAN_BYTES=$MAX_KEY_FILES_BYTES' scripts/claude-review.sh
  [ "$status" -eq 0 ]

  run grep -F "head -c \"\$BINARY_SCAN_BYTES\" -- \"\$f\" | od -An -v -t x1 | grep '00' >/dev/null" scripts/claude-review.sh
  [ "$status" -eq 0 ]
}

# --- #55: skipped-file disclosure -------------------------------------------

# build_skipped_note OVERSIZE BUDGET MAX_SINGLE MAX_TOTAL
# Prints the prompt note disclosing skipped files, or nothing when none skipped.
build_skipped_note() {
  local SKIPPED_OVERSIZE="$1"
  local SKIPPED_BUDGET="$2"
  local MAX_SINGLE_FILE_BYTES="$3"
  local MAX_KEY_FILES_BYTES="$4"
  local SKIPPED_FILES_NOTE=""
  if [[ -n "$SKIPPED_OVERSIZE" || -n "$SKIPPED_BUDGET" ]]; then
    SKIPPED_FILES_NOTE="
**INCOMPLETE — full contents were NOT provided for every changed file.**
Review the paths below from the diff alone, and say so in your summary."
    if [[ -n "$SKIPPED_OVERSIZE" ]]; then
      SKIPPED_FILES_NOTE="${SKIPPED_FILES_NOTE}
- Exceeds the ${MAX_SINGLE_FILE_BYTES}-byte per-file cap:${SKIPPED_OVERSIZE}"
    fi
    if [[ -n "$SKIPPED_BUDGET" ]]; then
      SKIPPED_FILES_NOTE="${SKIPPED_FILES_NOTE}
- Dropped after the ${MAX_KEY_FILES_BYTES}-byte total budget was exhausted:${SKIPPED_BUDGET}"
    fi
  fi
  printf '%s' "$SKIPPED_FILES_NOTE"
}

@test "no note when nothing was skipped" {
  run build_skipped_note "" "" 50000 80000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "oversize skip is disclosed with its reason and path" {
  run build_skipped_note " big.R" "" 50000 80000
  [[ "$output" == *"INCOMPLETE"* ]]
  [[ "$output" == *"per-file cap: big.R"* ]]
}

@test "budget skip is disclosed with its reason and path" {
  run build_skipped_note "" " late.R" 50000 80000
  [[ "$output" == *"total budget was exhausted: late.R"* ]]
}

@test "both skip reasons are reported separately when both apply" {
  run build_skipped_note " big.R" " late.R" 50000 80000
  [[ "$output" == *"per-file cap: big.R"* ]]
  [[ "$output" == *"total budget was exhausted: late.R"* ]]
}

# --- #56: commit-list cap ----------------------------------------------------

# cap_commits COMMIT_MESSAGES MAX_LINES
# Mirrors the commit-list cap, appending a marker naming the true total.
cap_commits() {
  set -o pipefail
  local COMMIT_MESSAGES="$1"
  local MAX_COMMIT_LINES="$2"
  local NUM_COMMITS
  NUM_COMMITS=$(printf '%s\n' "$COMMIT_MESSAGES" | wc -l | tr -d ' ')
  if [[ $NUM_COMMITS -gt $MAX_COMMIT_LINES ]]; then
    COMMIT_MESSAGES="$(printf '%s\n' "$COMMIT_MESSAGES" | head -n "$MAX_COMMIT_LINES" || true)
... [truncated — showing $MAX_COMMIT_LINES of $NUM_COMMITS commits]"
  fi
  printf '%s' "$COMMIT_MESSAGES"
}

@test "commit list under the cap is unchanged" {
  run cap_commits "$(printf 'aaa one\nbbb two')" 100
  [ "$output" = "$(printf 'aaa one\nbbb two')" ]
}

@test "commit list over the cap is truncated with a marker naming the true total" {
  local many
  many=$(for i in $(seq 1 10); do echo "sha$i msg$i"; done)
  run cap_commits "$many" 3
  [[ "$output" == *"showing 3 of 10 commits"* ]]
  [[ "$output" == *"sha1 msg1"* ]]
  [[ "$output" != *"sha9 msg9"* ]]
}

# Same SIGPIPE-under-pipefail regression as the diff cap. Needs a payload big
# enough that the writer is still streaming when head exits; the 10-line case
# above passes either way.
@test "a commit list far over the cap does not abort under pipefail" {
  local many
  many=$(for i in $(seq 1 5000); do echo "sha$i msg$i"; done)
  run cap_commits "$many" 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"showing 10 of 5000 commits"* ]]
}

# Regression for the review finding on `$()` newline-stripping: the production
# code measures the diff with `wc -c` on a FILE, not on a captured variable,
# because `$()` drops trailing newlines and git diffs always end in one.
@test "measuring a captured variable under-reports; measuring a file does not" {
  local f
  f=$(mktemp)
  printf 'line one\nline two\n' > "$f"
  local file_bytes captured captured_bytes
  file_bytes=$(wc -c < "$f" | tr -d ' ')
  captured=$(cat "$f")
  captured_bytes=$(printf '%s' "$captured" | wc -c | tr -d ' ')
  rm -f "$f"
  [ "$file_bytes" -eq 18 ]
  [ "$captured_bytes" -eq 17 ]
  [ "$file_bytes" -ne "$captured_bytes" ]
}

# Regression for gather.sh repo file tree building under pipefail with >200 files
@test "repo file tree over 200 entries does not abort under pipefail" {
  run bash -c '
    set -euo pipefail
    tmp=$(mktemp -d)
    for i in $(seq 1 300); do
      touch "$tmp/file_$i.txt"
    done
    REPO_TREE=$(find "$tmp" -type f | sort | awk "NR<=200")
    count=$(echo "$REPO_TREE" | wc -l | tr -d " ")
    rm -rf "$tmp"
    [ "$count" -eq 200 ]
  '
  [ "$status" -eq 0 ]
}

# --- UI truncation disclosure and footer scope labelling --------------------

source "$BATS_TEST_DIRNAME/../../scripts/lib/format-review-comment.sh"

@test "complete review comments label the footer as full MR diff and include no partial banners" {
  run format_review_comment "Summary prose" "primary" "gpt-5.6" 1 1 "0123456789abcdef" "" 0 0 0 "true" "false" 0 5000 250000 "" "main" "feat" "https://gitlab.example/pipelines/1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Automated review of full MR diff vs \`main\`"* ]]
  [[ "$output" != *"Partial review"* ]]
  [[ "$output" != *"Partial context"* ]]
}

@test "truncated diff review comments label the footer as partial MR diff and include a warning banner" {
  run format_review_comment "Summary prose" "primary" "gpt-5.6" 1 1 "0123456789abcdef" "" 0 0 0 "true" "true" 31743 131743 100000 "" "main" "feat" "https://gitlab.example/pipelines/1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Automated review of partial MR diff vs \`main\`"* ]]
  [[ "$output" == *"> ⚠️ **Partial review:** MR diff was truncated (31743 of 131743 bytes omitted to fit 100000-byte cap)."* ]]
}

@test "partial file context review comments label the footer as partial MR diff and include a warning banner" {
  run format_review_comment "Summary prose" "primary" "gpt-5.6" 1 1 "0123456789abcdef" "" 0 0 0 "true" "false" 0 50000 250000 " large.png" "main" "feat" "https://gitlab.example/pipelines/1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Automated review of partial MR diff vs \`main\`"* ]]
  [[ "$output" == *"> ⚠️ **Partial context:** Full-file contents were omitted or partially truncated for some modified files"* ]]
}

@test "claude-review.sh defaults HAC_MAX_DIFF_BYTES to 250000" {
  run grep -F 'MAX_DIFF_BYTES=${HAC_MAX_DIFF_BYTES:-250000}' scripts/claude-review.sh
  [ "$status" -eq 0 ]
}

@test "claude-review.sh sources and calls format_review_comment" {
  run grep -F 'source "${SCRIPT_DIR}/lib/format-review-comment.sh"' scripts/claude-review.sh
  [ "$status" -eq 0 ]
  run grep -F 'REVIEW_COMMENT=$(format_review_comment' scripts/claude-review.sh
  [ "$status" -eq 0 ]
}
