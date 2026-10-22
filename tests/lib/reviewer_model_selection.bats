#!/usr/bin/env bats

setup() {
  REVIEW_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
  API_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/gitlab-api.sh"
  AUTHOR_RESPONSE_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/select-author-response.sh"
  REVIEW_NOTE_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/select-review-note.sh"
  VALIDATE_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/validate-nonnegative-integer.sh"
  CHECKOUT_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/checkout.sh"
  GATHER_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/gather.sh"
  PAYLOAD_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/payload.sh"
  TEMPLATE="$BATS_TEST_DIRNAME/../../templates/claude.yml"

  log() {
    printf '%s\n' "$*"
  }

  log_error() {
    printf '%s\n' "$*" >&2
  }
}

mock_gl_api() {
  case "$1" in
    *page=1|*page=1\&*)
      printf '%s\n' '[
        {"id":101,"notes":[{"body":"🔍 [primary:databricks-claude-sonnet-4-6] 🔴 **High**: Primary finding","type":"DiffNote","resolvable":true,"resolved":false,"position":{"new_path":"a.sh","new_line":7}}]},
        {"id":102,"notes":[{"body":"🔍 [claude-companion:databricks-claude-sonnet-4-6] 🔴 **High**: Companion finding","type":"DiffNote","resolvable":true,"resolved":false,"position":{"new_path":"a.sh","new_line":7}}]},
        {"id":103,"notes":[{"body":"🔍 [databricks-gpt-5-6-sol] 🔴 **High**: Transitional finding","type":"DiffNote","resolvable":true,"resolved":false,"position":{"new_path":"a.sh","new_line":7}}]},
        {"id":104,"notes":[{"body":"🔍 🔴 **High**: Legacy finding","type":"DiffNote","resolvable":true,"resolved":false,"position":{"new_path":"a.sh","new_line":7}}]},
        {"id":105,"notes":[{"body":"🔍 [databricks-secondary:databricks-gpt-5-6-sol] 🔴 **High**: Other reviewer finding","type":"DiffNote","resolvable":true,"resolved":false,"position":{"new_path":"a.sh","new_line":7}}]}
      ]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
}

curl() {
  printf '{}\n200\n'
}

@test "GPT-5.6 Sol is the default automatic reviewer" {
  run grep -F 'MODEL="${REVIEW_MODEL:-${CLAUDE_MODEL:-databricks-gpt-5-6-sol}}"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review agent setting accepts only exact boolean values" {
  run bash -c 'source "$1"; validate_boolean GLA_REVIEW_AGENT true' _ "$VALIDATE_SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; validate_boolean GLA_REVIEW_AGENT false' _ "$VALIDATE_SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; validate_boolean GLA_REVIEW_AGENT 1' _ "$VALIDATE_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GLA_REVIEW_AGENT must be exactly true or false"* ]]
}

@test "review responses are capped and normalized before transcript append" {
  run grep -F 'MAX_REVIEW_RESPONSE_CHARS=${GLA_MAX_REVIEW_RESPONSE_CHARS:-200000}' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F -- '--max-filesize "$MAX_REVIEW_RESPONSE_CHARS"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'content:(($message.content // "")[:$max_chars])' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review deadline is established before MR lookup" {
  run awk '/REVIEW_DEADLINE=/{deadline=NR} /MR_DATA=\$\(gl_api/{lookup=NR} END{exit !(deadline > 0 && deadline < lookup)}' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "reviewer script fetch retries with GITLAB_TOKEN after a job-token failure" {
  local test_dir="$BATS_TEST_TMPDIR/fetch_fallback_test"
  mkdir -p "$test_dir"
  local fetch_script="$test_dir/fetch.sh"
  local curl_log="$test_dir/curl.log"

  ruby -ryaml -e '
    puts YAML.load_file(ARGV[0]).fetch(".gla-claude-review").fetch("before_script")[1]
  ' "$TEMPLATE" > "$fetch_script"

  run bash -c '
    test_dir="$1"
    fetch_script="$2"
    curl_log="$3"
    export CURL_LOG="$curl_log"
    export CI_JOB_TOKEN="mock-job-token"
    export GITLAB_TOKEN="mock-pat-token"
    export CI_API_V4_URL="https://gitlab.example/api/v4"
    export GLA_PROJECT_ID="2058"
    export GLA_REF="main"

    curl() {
      local header=""
      local dest=""
      local url=""
      local prev=""
      for arg in "$@"; do
        if [[ "$prev" == "--header" ]]; then
          header="$arg"
        elif [[ "$prev" == "-o" ]]; then
          dest="$arg"
        fi
        if [[ "$arg" == http* ]]; then
          url="$arg"
        fi
        prev="$arg"
      done

      printf "%s -> %s -> %s\n" "$header" "$url" "$dest" >> "$CURL_LOG"

      if [[ "$header" == JOB-TOKEN:* ]]; then
        return 22
      elif [[ "$header" == PRIVATE-TOKEN:* ]]; then
        mkdir -p "$(dirname "$dest")"
        printf "mock content for %s\n" "$dest" > "$dest"
        return 0
      fi
      return 1
    }

    cd "$test_dir" && source "$fetch_script"
  ' _ "$test_dir" "$fetch_script" "$curl_log"

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: Job-token fetch failed for scripts%2Fclaude-review.sh; retrying with GITLAB_TOKEN."* ]]
  [[ "$output" == *"Successfully fetched claude-review.sh"* ]]
  [[ "$output" == *"Fetched lib/logging.sh"* ]]
  [[ "$output" == *"Fetched lib/gitlab-api.sh"* ]]
  [[ "$output" == *"Fetched lib/select-author-response.sh"* ]]
  [[ "$output" == *"Fetched lib/select-review-note.sh"* ]]
  [[ "$output" == *"Fetched lib/validate-nonnegative-integer.sh"* ]]
  [[ "$output" == *"Fetched lib/format-review-comment.sh"* ]]
  [[ "$output" == *"Fetched lib/review-tools.sh"* ]]

  [ -f "$test_dir/.gitlab/scripts/claude-review.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/lab-manual.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/logging.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/gitlab-api.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/select-author-response.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/select-review-note.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/validate-nonnegative-integer.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/format-review-comment.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/review-tools.sh" ]

  run grep -F 'JOB-TOKEN: mock-job-token' "$curl_log"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]

  run grep -F 'PRIVATE-TOKEN: mock-pat-token' "$curl_log"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]

  first_call=$(sed -n '1p' "$curl_log")
  second_call=$(sed -n '2p' "$curl_log")
  [[ "$first_call" == "JOB-TOKEN: mock-job-token -> https://gitlab.example/api/v4/projects/2058/repository/files/scripts%2Fclaude-review.sh/raw?ref=main -> .gitlab/scripts/claude-review.sh" ]]
  [[ "$second_call" == "PRIVATE-TOKEN: mock-pat-token -> https://gitlab.example/api/v4/projects/2058/repository/files/scripts%2Fclaude-review.sh/raw?ref=main -> .gitlab/scripts/claude-review.sh" ]]
}

@test "reviewer script fetch uses JOB-TOKEN directly when successful without retrying" {
  local test_dir="$BATS_TEST_TMPDIR/fetch_success_test"
  mkdir -p "$test_dir"
  local fetch_script="$test_dir/fetch.sh"
  local curl_log="$test_dir/curl.log"

  ruby -ryaml -e '
    puts YAML.load_file(ARGV[0]).fetch(".gla-claude-review").fetch("before_script")[1]
  ' "$TEMPLATE" > "$fetch_script"

  run bash -c '
    test_dir="$1"
    fetch_script="$2"
    curl_log="$3"
    export CURL_LOG="$curl_log"
    export CI_JOB_TOKEN="mock-job-token"
    export GITLAB_TOKEN="mock-pat-token"
    export CI_API_V4_URL="https://gitlab.example/api/v4"
    export GLA_PROJECT_ID="2058"
    export GLA_REF="main"

    curl() {
      local header=""
      local dest=""
      local url=""
      local prev=""
      for arg in "$@"; do
        if [[ "$prev" == "--header" ]]; then
          header="$arg"
        elif [[ "$prev" == "-o" ]]; then
          dest="$arg"
        fi
        if [[ "$arg" == http* ]]; then
          url="$arg"
        fi
        prev="$arg"
      done

      printf "%s -> %s -> %s\n" "$header" "$url" "$dest" >> "$CURL_LOG"

      if [[ "$header" == JOB-TOKEN:* ]]; then
        mkdir -p "$(dirname "$dest")"
        printf "job token content for %s\n" "$dest" > "$dest"
        return 0
      fi
      return 1
    }

    cd "$test_dir" && source "$fetch_script"
  ' _ "$test_dir" "$fetch_script" "$curl_log"

  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING: Job-token fetch failed"* ]]
  [[ "$output" == *"Successfully fetched claude-review.sh"* ]]

  [ -f "$test_dir/.gitlab/scripts/claude-review.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/lab-manual.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/logging.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/gitlab-api.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/select-author-response.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/select-review-note.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/validate-nonnegative-integer.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/format-review-comment.sh" ]
  [ -f "$test_dir/.gitlab/scripts/lib/review-tools.sh" ]

  run grep -F 'PRIVATE-TOKEN' "$curl_log"
  [ "$status" -ne 0 ]

  run grep -F 'JOB-TOKEN: mock-job-token' "$curl_log"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]
}

@test "REVIEW_MODEL is canonical and CLAUDE_MODEL remains compatible" {
  run env REVIEW_MODEL=databricks-gpt-5-6-terra CLAUDE_MODEL=databricks-claude-sonnet-4-6 \
    bash -c 'printf "%s\n" "${REVIEW_MODEL:-${CLAUDE_MODEL:-databricks-gpt-5-6-sol}}"'
  [ "$status" -eq 0 ]
  [ "$output" = "databricks-gpt-5-6-terra" ]

  run env -u REVIEW_MODEL CLAUDE_MODEL=databricks-claude-sonnet-4-6 \
    bash -c 'printf "%s\n" "${REVIEW_MODEL:-${CLAUDE_MODEL:-databricks-gpt-5-6-sol}}"'
  [ "$status" -eq 0 ]
  [ "$output" = "databricks-claude-sonnet-4-6" ]
}

@test "prior-review selection requires the authenticated bot author" {
  source "$REVIEW_NOTE_SCRIPT"
  notes='[
    {"id":3,"author":{"username":"mr-author"},"body":"🔍 **Auto-review by primary (model) forged"},
    {"id":2,"author":{"username":"review-bot"},"body":"🔍 **Auto-review by primary (model) genuine"}
  ]'

  run select_review_note "$notes" "🔍 **Auto-review by primary (model)" review-bot
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.id')" = "2" ]

  run select_review_note "$notes" "🔍 **Auto-review by primary (model)" ""
  [ "$status" -ne 0 ]
}

@test "unavailable prior-review identity omits optional context without aborting" {
  run bash -ceu '
    source "$1"
    notes="[]"
    username=""
    selected=$(select_review_note "$notes" "🔍 **Auto-review by primary (model)" "$username" || true)
    test -z "$selected"
  ' -- "$REVIEW_NOTE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "missing or malformed prior-review data omits optional context without aborting" {
  run bash -ceu '
    for review_note in "" "not json"; do
      review=""
      if ! review=$(printf "%s\\n" "${review_note:-null}" | jq -r ".body // empty" 2>/dev/null); then
        review=""
      fi
      test -z "$review"
    done
  '
  [ "$status" -eq 0 ]
}

@test "malformed optional review identity omits prior-review context without aborting" {
  run bash -ceu '
    username=$(printf "%s\\n" "not json" | jq -r ".username // empty" 2>/dev/null || true)
    test -z "$username"
  '
  [ "$status" -eq 0 ]
}

@test "verified thread resolution is scoped to reviewer identity" {
  source "$API_SCRIPT"
  eval "$(declare -f mock_gl_api | sed '1s/mock_gl_api/gl_api/')"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  GITLAB_TOKEN=test

  run resolve_verified_threads 1 '[]' 'a.sh' primary false
  [ "$status" -eq 0 ]
  [[ "$output" == *"101"* ]]
  [[ "$output" != *"102"* ]]
  [[ "$output" != *"104"* ]]
}

@test "primary review can verify legacy untagged findings" {
  source "$API_SCRIPT"
  eval "$(declare -f mock_gl_api | sed '1s/mock_gl_api/gl_api/')"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  GITLAB_TOKEN=test

  run resolve_verified_threads 1 '[]' 'a.sh' primary true
  [ "$status" -eq 0 ]
  [[ "$output" == *"101"* ]]
  [[ "$output" == *"104"* ]]
  [[ "$output" == *"103"* ]]
  [[ "$output" != *"102"* ]]
  [[ "$output" != *"105"* ]]
}

@test "verified thread resolution fails closed without reviewer identity" {
  source "$API_SCRIPT"
  eval "$(declare -f mock_gl_api | sed '1s/mock_gl_api/gl_api/')"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  GITLAB_TOKEN=test

  run resolve_verified_threads 1 '[]' 'a.sh' '' true
  [ "$status" -eq 0 ]
  [[ "$output" == *"reviewer identity is empty"* ]]
  [[ "$output" != *"Resolved verified-addressed thread"* ]]
}

@test "verified thread resolution requires complete review context" {
  run grep -F '[[ "$DIFF_TRUNCATED" == "false" &&' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]

  run grep -F -- '-z "$PARTIAL_FILES" &&' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "respond-side resolution clears primary findings but leaves companion findings open" {
  source "$API_SCRIPT"
  eval "$(declare -f mock_gl_api | sed '1s/mock_gl_api/gl_api/')"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  GITLAB_TOKEN=test

  run resolve_addressed_threads 1 'a.sh'
  [ "$status" -eq 0 ]
  [[ "$output" == *"101"* ]]
  [[ "$output" != *"102"* ]]
  [[ "$output" == *"103"* ]]
  [[ "$output" == *"104"* ]]
  [[ "$output" != *"105"* ]]
}

@test "Claude companion review is opt-in and cannot trigger auto-fixes" {
  run grep -F 'GLA_CLAUDE_COMPANION_REVIEW == "true"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'REVIEW_MODEL=databricks-claude-sonnet-4-6 GLA_REVIEWER_ID=claude-companion GLA_REVIEW_AUTO_FIX=false GLA_REVIEW_INCLUDE_LEGACY_THREADS=false' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "Claude companion review waits for the primary review" {
  run ruby -e '
    require "yaml"
    ARGV.each do |path|
      companion = YAML.load_file(path).fetch("claude-companion-review")
      abort unless companion.fetch("needs") == ["claude-review"]
      abort unless companion.fetch("rules").first.fetch("when") == "always"
    end
  ' "$TEMPLATE" "$BATS_TEST_DIRNAME/../../.gitlab-ci.yml"
  [ "$status" -eq 0 ]
}

@test "review helpers are included in consumer and review dependency lists" {
  run grep -E 'LIB_FILES="[^"]*select-author-response\.sh[^"]*select-review-note\.sh[^"]*validate-nonnegative-integer\.sh[^"]*format-review-comment\.sh' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -E 'REVIEW_LIBS="[^"]*select-author-response\.sh[^"]*select-review-note\.sh[^"]*validate-nonnegative-integer\.sh[^"]*format-review-comment\.sh' "$BATS_TEST_DIRNAME/../../.gitlab-ci.yml"
  [ "$status" -eq 0 ]

  run grep -F 'lib/select-review-note.sh' "$TEMPLATE"
  [ "$status" -eq 0 ]

  run grep -F 'lib/validate-nonnegative-integer.sh' "$TEMPLATE"
  [ "$status" -eq 0 ]

  run grep -F 'lib/format-review-comment.sh' "$TEMPLATE"
  [ "$status" -eq 0 ]

  run grep -F 'lib/context-priority.sh' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "review bootstrap fetches every helper sourced by claude-review.sh" {
  run ruby -ryaml -e '
    template = YAML.load_file(ARGV[0]).fetch(".gla-claude-review")
    before_script = template.fetch("before_script").join("\n")
    script = File.binread(ARGV[1]).force_encoding(Encoding::BINARY)
    sourced = script.scan(%r{source "\$\{SCRIPT_DIR\}/lib/([^" ]+)"}).flatten
    missing = sourced.reject do |library|
      fetch = "fetch_gla_file scripts%2Flib%2F#{library} .gitlab/scripts/lib/#{library}"
      source_file = File.join(File.dirname(ARGV[1]), "lib", library)
      File.file?(source_file) && before_script.include?(fetch)
    end
    abort "missing review bootstrap fetches: #{missing.join(%q{, })}" unless missing.empty?
  ' "$TEMPLATE" "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "command-level companion model overrides the project reviewer model" {
  run env REVIEW_MODEL=databricks-gpt-5-6-terra bash -c \
    'REVIEW_MODEL=databricks-claude-sonnet-4-6 GLA_REVIEW_AUTO_FIX=false sh -c '\''printf "%s %s\n" "$REVIEW_MODEL" "$GLA_REVIEW_AUTO_FIX"'\'''
  [ "$status" -eq 0 ]
  [ "$output" = "databricks-claude-sonnet-4-6 false" ]
}

@test "reviewer-tagged findings are not treated as author responses" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":6,"system":false,"author":{"username":"maintainer"},"body":"Unrelated human response"},
    {"id":5,"system":false,"author":{"username":"project_2058_bot_example"},"body":"An ordinary automated note with no known prefix"},
    {"id":4,"system":false,"author":{"username":"project_2058_bot_example"},"body":"🔍 [claude-companion:databricks-claude-sonnet-4-6] 🔴 **High**: companion finding"},
    {"id":3,"system":false,"author":{"username":"release-service","bot":true},"body":"Another ordinary automated note"},
    {"id":2,"system":false,"author":{"username":"robotics-lead"},"body":"MR author response"},
    {"id":1,"system":false,"body":"🔍 **Auto-review by primary (databricks-gpt-5-6-sol) of MR !1**"}
  ]'

  run select_author_response "$notes" 1 "robotics-lead" ""
  [ "$status" -eq 0 ]
  [ "$output" = "MR author response" ]
}

@test "responding prompt documents the REBUTTED status" {
  run grep -F 'REBUTTED:' "$BATS_TEST_DIRNAME/../../scripts/lib/prompt.sh"
  [ "$status" -eq 0 ]
  run grep -F 'code may remain unchanged' "$BATS_TEST_DIRNAME/../../scripts/lib/prompt.sh"
  [ "$status" -eq 0 ]
}

@test "author response selection preserves every response in chronological order" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":4,"system":false,"author":{"username":"author"},"body":"Second thread rebuttal"},
    {"id":3,"system":true,"author":{"username":"author"},"body":"added 1 commit"},
    {"id":2,"system":false,"author":{"username":"author"},"body":"ARD summary with first rebuttal"}
  ]'

  run select_author_response "$notes" 1 "author" ""
  [ "$status" -eq 0 ]
  [ "$output" = $'ARD summary with first rebuttal\n\nSecond thread rebuttal' ]
}

@test "author response selection stops at the next review round" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":5,"system":false,"author":{"username":"author"},"body":"Response to newer review"},
    {"id":4,"system":false,"author":{"username":"author"},"body":"Response to older review"}
  ]'

  run select_author_response "$notes" 1 "author" "" 2000 5
  [ "$status" -eq 0 ]
  [ "$output" = "Response to older review" ]
}

@test "author response budget represents both old and new rebuttals" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":3,"system":false,"author":{"username":"author"},"body":"Newest rebuttal has a detailed rationale that exceeds its share"},
    {"id":2,"system":false,"author":{"username":"author"},"body":"Oldest rebuttal has a detailed rationale that exceeds its share"}
  ]'

  run select_author_response "$notes" 1 "author" "" 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"Oldest "* ]]
  [[ "$output" == *"Newest "* ]]
  [ "${#output}" -le 50 ]
}

@test "author response budget never overflows when separators do not fit" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":5,"system":false,"author":{"username":"author"},"body":"Zulu newest note"},
    {"id":4,"system":false,"author":{"username":"author"},"body":"Charlie note"},
    {"id":3,"system":false,"author":{"username":"author"},"body":"Bravo note"},
    {"id":2,"system":false,"author":{"username":"author"},"body":"Alpha oldest note"}
  ]'

  run select_author_response "$notes" 1 "author" "" 1
  [ "$status" -eq 0 ]
  [ "$output" = "Z" ]
}

@test "zero author response budget cleanly disables response context" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[{"id":2,"system":false,"author":{"username":"author"},"body":"rebuttal"}]'

  run select_author_response "$notes" 1 "author" "" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "author response selection ignores missing or null bodies" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":4,"system":false,"author":{"username":"author"},"body":null},
    {"id":3,"system":false,"author":{"username":"author"}},
    {"id":2,"system":false,"author":{"username":"author"},"body":"MR author response"}
  ]'

  run select_author_response "$notes" 1 "author" ""
  [ "$status" -eq 0 ]
  [ "$output" = "MR author response" ]
}

@test "bare legacy findings are not treated as author responses" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[
    {"id":3,"system":false,"author":{"username":"author"},"body":"🔍 🔴 **High**: legacy finding"},
    {"id":2,"system":false,"author":{"username":"author"},"body":"MR author response"}
  ]'

  run select_author_response "$notes" 1 "author" ""
  [ "$status" -eq 0 ]
  [ "$output" = "MR author response" ]
}

@test "author response selection fails closed without MR author metadata" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[{"id":2,"system":false,"body":"Authorless response"}]'

  run select_author_response "$notes" 1 "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "author response selection fails closed without a positive review ID" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[{"id":2,"system":false,"author":{"username":"author"},"body":"Response"}]'

  run select_author_response "$notes" 0 "author" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run select_author_response "$notes" invalid "author" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "author response selection excludes bot identities even when they match the MR author" {
  source "$AUTHOR_RESPONSE_SCRIPT"

  run select_author_response '[{"id":2,"system":false,"author":{"username":"service-user","bot":true},"body":"Bot response"}]' 1 "service-user" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run select_author_response '[{"id":2,"system":false,"author":{"username":"configured-service"},"body":"Configured bot response"}]' 1 "configured-service" "configured-service"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run select_author_response '[{"id":2,"system":false,"author":{"username":"project_2058_bot_example"},"body":"Project bot response"}]' 1 "project_2058_bot_example" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "trusted bot rebuttals are preserved when explicitly enabled" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes='[{"id":2,"system":false,"author":{"username":"configured-service"},"body":"REBUTTED: the checksum test disproves this finding"}]'

  run select_author_response "$notes" 1 "configured-service" "configured-service" 2000 "" true
  [ "$status" -eq 0 ]
  [ "$output" = "REBUTTED: the checksum test disproves this finding" ]
}

@test "prior-review lookup paginates until it finds a trusted review" {
  source "$REVIEW_NOTE_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  gl_api() {
    if [[ "$1" == *"page=1" ]]; then
      jq -nc '[range(1; 101) | {id: (200 - .), author: {username: "author"}, body: "response"}]'
    else
      printf '%s\n' '[{"id":1,"author":{"username":"review-bot"},"body":"🔍 **Auto-review by primary (model) genuine"}]'
    fi
  }

  fetch_prior_review_notes 1 "🔍 **Auto-review by primary (model)" review-bot
  [ "$(printf '%s\n' "$REVIEW_NOTES" | jq 'length')" -eq 101 ]
  [ "$(printf '%s\n' "$LAST_REVIEW_NOTE" | jq -r '.id')" -eq 1 ]
}

@test "prior-review lookup discloses the ten-page history boundary" {
  source "$REVIEW_NOTE_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  MAX_REVIEW_NOTES_CHARS=500000
  gl_api() {
    jq -nc '[range(1; 101) | {id: ., author: {username: "author"}, body: "response"}]'
  }

  fetch_prior_review_notes 1 "🔍 **Auto-review by primary (model)" review-bot
  [ "$REVIEW_NOTES_TRUNCATED" = "true" ]
}

@test "prior-review lookup discards partial context after an API failure" {
  source "$REVIEW_NOTE_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  gl_api() {
    if [[ "$1" == *"page=1" ]]; then
      jq -nc '[range(1; 101) | {id: (200 - .), author: {username: "author"}, body: "response"}]'
    else
      return 1
    fi
  }

  if fetch_prior_review_notes 1 "🔍 **Auto-review by primary (model)" review-bot; then
    false
  fi
  [ "$REVIEW_NOTES" = "[]" ]
  [ -z "$LAST_REVIEW_NOTE" ]
}

@test "prior-review lookup fails closed when note responses exceed the byte budget" {
  source "$REVIEW_NOTE_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  MAX_REVIEW_NOTES_CHARS=100
  gl_api() {
    jq -nc --arg body "$(printf '%0500d' 0)" '[{id: 1, author: {username: "author"}, body: $body}]'
  }

  if fetch_prior_review_notes 1 "🔍 **Auto-review by primary (model)" review-bot; then
    false
  fi
  [ "$REVIEW_NOTES" = "[]" ]
  [ -z "$LAST_REVIEW_NOTE" ]
}

@test "zero prior-review note budget skips API history fetches" {
  source "$REVIEW_NOTE_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  MAX_REVIEW_NOTES_CHARS=0
  gl_api() { false; }

  fetch_prior_review_notes 1 "🔍 **Auto-review by primary (model)" review-bot
  [ "$REVIEW_NOTES" = "[]" ]
  [ -z "$LAST_REVIEW_NOTE" ]
}

@test "prior-review selection ignores malformed note members" {
  source "$REVIEW_NOTE_SCRIPT"
  notes=$(jq -nc '[{id: {bad: true}, author: {username: "review-bot"}, body: "🔍 **Auto-review by primary (model) malformed id"}, {id: 1, author: {username: "review-bot"}}, {id: 2, author: {username: "review-bot"}, body: null}, {id: 3, author: {username: "review-bot"}, body: "🔍 **Auto-review by primary (model) valid"}]')
  run select_review_note "$notes" "🔍 **Auto-review by primary (model)" review-bot
  [ "$status" -eq 0 ]
  [ "$(jq -r .id <<< "$output")" -eq 3 ]
}

@test "author-response selection ignores malformed note members" {
  source "$AUTHOR_RESPONSE_SCRIPT"
  notes=$(jq -nc '["scalar", {system: false, author: "bad", id: 2, body: "bad author"}, {system: false, author: {username: "demorrison"}, id: 3, body: "valid response"}]')
  run select_author_response "$notes" 1 demorrison "" 2000
  [ "$status" -eq 0 ]
  [ "$output" = "valid response" ]
}

@test "late rebuttals are retained in chronological author-note context" {
  run grep -F '### Chronological author notes' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'GitLab thread linkage is not available' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "author-note context is assembled before latest review prose" {
  run awk '/AUTHOR_TIMELINE_CONTEXT=/{timeline=NR} /### Previous auto-review:/{review=NR} END{exit !(timeline > 0 && review > timeline)}' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'retained an attributed newest suffix' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "over-budget author timeline is not truncated a second time" {
  run grep -F 'AUTHOR_TIMELINE_OVERRUN' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'later prefix truncation' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "over-budget author timeline retains attribution" {
  run grep -F 'AUTHOR NOTES TRUNCATED; NEWEST SUFFIX RETAINED' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F '### Chronological author notes (newest retained)' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "prior-review body lookup filters scalar history members" {
  run grep -F '[.[] | objects | select(.id == $id)][0].body' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "prior-review prompt budgets are validated" {
  run grep -F 'validate_nonnegative_integer "GLA_MAX_PRIOR_REVIEW_CHARS"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'validate_nonnegative_integer "GLA_MAX_AUTHOR_RESPONSE_CHARS"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'validate_nonnegative_integer "GLA_MAX_REVIEW_HISTORY_CHARS"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "prior review context retains historical review rounds" {
  run grep -F 'Keep older review rounds as well as the latest one' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'GLA_MAX_REVIEW_HISTORY_CHARS' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'AUTHOR_RESPONSE_TIMELINE' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "main review prompt does not attribute chronology-partitioned responses" {
  run grep -F 'Author response:' "$REVIEW_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "history page fetches carry the cumulative byte cap into curl" {
  run grep -F 'GL_API_MAX_BYTES="$remaining_chars" gl_api' "$REVIEW_NOTE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "history pagination passes only the remaining byte budget" {
  source "$REVIEW_NOTE_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  MAX_REVIEW_NOTES_CHARS=50000
  budget_log="$BATS_TEST_TMPDIR/history-budgets"
  gl_api() {
    printf '%s\n' "$GL_API_MAX_BYTES" >> "$budget_log"
    if [[ "$1" == *"page=1" ]]; then
      jq -nc '[range(1; 101) | {id: ., author: {username: "author"}, body: "x"}]'
    else
      printf '[]\n'
    fi
  }

  fetch_prior_review_notes 1 "🔍 **Auto-review by primary (model)" review-bot
  mapfile -t budgets < "$budget_log"
  [ "${#budgets[@]}" -eq 2 ]
  [ "${budgets[0]}" -eq 50000 ]
  [ "${budgets[1]}" -lt "${budgets[0]}" ]
}

@test "prior review history discloses configured truncation" {
  run grep -F 'PRIOR REVIEW HISTORY TRUNCATED TO THE CONFIGURED CHARACTER BUDGET' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review history budget caps the complete prior-review context" {
  run grep -F 'PRIOR_REVIEW_CONTEXT="${PRIOR_REVIEW_CONTEXT:0:HISTORY_CONTEXT_PREFIX_CHARS}' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "small review history budgets omit rather than hide truncation" {
  run grep -F 'Prior review context omitted because its budget is smaller than the truncation marker.' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "tool-result budget charges and bounds replacement content" {
  run grep -F 'TOOL_RESULT_REMAINING=$((MAX_REVIEW_TOOL_RESULT_CHARS - REVIEW_TOOL_RESULT_CHARS))' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review prompt requires evidence when rejecting a rebuttal" {
  run grep -F 'never silently repeat a rebutted finding.' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "review auto-fix payload carries an immutable primary review anchor" {
  run grep -F 'review_note_id: $review_note_id' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'review_sha: $review_sha' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'Please read the attached triggering review' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'cannot trigger auto-fix without an immutable review note ID' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'address findings only from this triggering' "$BATS_TEST_DIRNAME/../../scripts/lib/prompt.sh"
  [ "$status" -eq 0 ]
  run grep -F '[[ ! "$TRIGGERING_REVIEW_NOTE_ID" =~ ^[1-9][0-9]*$ ]]' "$BATS_TEST_DIRNAME/../../scripts/lib/gather.sh"
  [ "$status" -eq 0 ]
  run grep -F '### Structured actionable findings' "$BATS_TEST_DIRNAME/../../scripts/lib/format-review-comment.sh"
  [ "$status" -eq 0 ]
  run grep -F 'review_body_hash: $review_body_hash' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "auto-fix rejects missing and stale immutable context" {
  source "$CHECKOUT_SCRIPT"

  run validate_triggering_review_head "$(printf 'a%.0s' {1..40})" "$(printf 'a%.0s' {1..40})"
  [ "$status" -eq 0 ]

  run validate_triggering_review_head "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing stale auto-fix"* ]]

  run validate_triggering_review_head "invalid" "$(printf 'b%.0s' {1..40})"
  [ "$status" -eq 1 ]
}

@test "large structured finding output remains complete" {
  run bash -o pipefail -c '
    jq -nr --arg message "$(printf "x%.0s" {1..20000})" \
      '\''[{severity:"medium",file:"a.sh",line:1,message:$message}][] | "- [\(.severity)] `\(.file):\(.line)` — \(.message)"'\'' \
      | wc -c | tr -d " "
  '
  [ "$status" -eq 0 ]
  [ "$output" -gt 20000 ]
}

@test "malformed finding elements are dropped before rendering" {
  source "$API_SCRIPT"
  findings='[
    "unexpected model output",
    {"severity":"medium","file":"a.sh","line":1,"message":"valid finding"},
    {"severity":"low","file":"b.sh","line":"two","message":"invalid line"},
    {"severity":"urgent","file":"c.sh","line":2,"message":"invalid severity"},
    {"severity":"high","file":"","line":3,"message":"empty file"},
    {"severity":"high","file":"d.sh","line":0,"message":"zero line"},
    {"severity":"high","file":"e.sh","line":1.5,"message":"fractional line"},
    {"severity":"high","file":"f.sh","line":4,"message":""}
  ]'

  run normalize_findings_json "$findings" $'a.sh\nb.sh\nc.sh\nd.sh\ne.sh\nf.sh'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"severity":"medium","file":"a.sh","line":1,"message":"valid finding"}]' ]
}

@test "out-of-diff findings make normalization lossy" {
  source "$API_SCRIPT"
  findings='[
    {"severity":"medium","file":"a.sh","line":1,"message":"valid finding"},
    {"severity":"high","file":"outside.sh","line":2,"message":"out of diff"}
  ]'

  normalized=$(normalize_findings_json "$findings" 'a.sh')
  [ "$(jq 'length' <<< "$findings")" -eq 2 ]
  [ "$(jq 'length' <<< "$normalized")" -eq 1 ]
  [ "$(jq -r '.[0].file' <<< "$normalized")" = 'a.sh' ]
}

@test "malformed finding output cannot resolve prior threads" {
  run grep -F '"$INLINE_HEAD_SHA" == "$REVIEW_SHA"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'Skipping verified thread resolution because review context or structured findings were incomplete.' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "missing findings marker cannot resolve prior threads" {
  run grep -F 'FINDINGS_NORMALIZED_CLEANLY=false' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'FINDINGS_NORMALIZED_CLEANLY=true' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "only the summary discussion captures the auto-fix anchor" {
  run grep -F 'post_review_discussion "$MR_IID" "$REVIEW_COMMENT" true' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^  if post_review_discussion .* true' "$REVIEW_SCRIPT")" -eq 1 ]
  [ "$(grep -c '^        post_review_discussion .* false' "$REVIEW_SCRIPT")" -eq 1 ]
  run grep -F 'The review API returned HTTP ${HTTP_CODE}. [See pipeline](${CI_PIPELINE_URL}) for details." false || true' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "only clean structured findings can authorize auto-fix" {
  run grep -F '"$INLINE_COUNT" -eq "$VALID_FINDING_COUNT"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F -- '-n "$INLINE_HEAD_SHA"' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F '"$INLINE_FAILURES" -eq 0' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F '"$INLINE_DROPPED" -eq 0' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'grep -qiE "(bug|error|issue|finding|fix|problem|security|missing|incorrect|broken|fail)' "$REVIEW_SCRIPT"
  [ "$status" -eq 1 ]
}

@test "inline positions require valid current-head version SHAs" {
  run grep -F '[[ ! "$INLINE_HEAD_SHA" =~ ^[0-9a-f]{40}$ ||' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'elif [[ "$INLINE_HEAD_SHA" != "$REVIEW_SHA" ]]' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'MR diff version head does not match reviewed commit' "$REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "triggering review anchor fields are all absent or all valid" {
  source "$PAYLOAD_SCRIPT"
  sha="$(printf 'a%.0s' {1..40})"
  hash="$(printf 'b%.0s' {1..40})"
  COMMENT_AUTHOR=reviewer
  NOTEABLE_TYPE=MergeRequest

  run validate_triggering_review_anchor "" "" ""
  [ "$status" -eq 0 ]

  run validate_triggering_review_anchor "123" "$sha" "$hash"
  [ "$status" -eq 0 ]

  run validate_triggering_review_anchor "123" "" "$hash"
  [ "$status" -eq 1 ]

  run validate_triggering_review_anchor "0" "$sha" "$hash"
  [ "$status" -eq 1 ]
}

@test "synthetic auto-fix requests require a complete merge-request anchor" {
  source "$PAYLOAD_SCRIPT"
  COMMENT_AUTHOR=claude-auto-review
  NOTEABLE_TYPE=MergeRequest

  run validate_triggering_review_anchor "" "" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"require a complete review anchor"* ]]
}

@test "triggering review anchors are rejected for issue payloads" {
  source "$PAYLOAD_SCRIPT"
  COMMENT_AUTHOR=reviewer
  NOTEABLE_TYPE=Issue
  sha="$(printf 'a%.0s' {1..40})"
  hash="$(printf 'b%.0s' {1..40})"

  run validate_triggering_review_anchor "123" "$sha" "$hash"
  [ "$status" -eq 1 ]
  [[ "$output" == *"valid only for merge-request payloads"* ]]
}

@test "stored review hash and prompt extraction preserve trailing newlines" {
  body=$'review body\n\n'
  note=$(jq -n --arg body "$body" '{notes:[{body:$body}]}')
  expected_hash=$(printf '%s' "$body" | git hash-object --stdin)

  run bash -c '
    note=$1
    hash=$(printf "%s" "$note" | jq -j ".notes[0].body" | git hash-object --stdin)
    sentinel=$(printf "\\037")
    extracted=$(printf "%s" "$note" | jq -j ".notes[0].body"; printf "%s" "$sentinel")
    extracted=${extracted%$sentinel}
    extracted_hash=$(printf "%s" "$extracted" | git hash-object --stdin)
    printf "%s\n%s\n" "$hash" "$extracted_hash"
  ' _ "$note"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$expected_hash" ]
  [ "${lines[1]}" = "$expected_hash" ]
}

@test "triggering review retrieval verifies and preserves the stored body" {
  source "$GATHER_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  CLAUDE_MR_IID=2
  CLAUDE_BOT_USERNAME=review-bot
  TRIGGERING_REVIEW_NOTE_ID=123
  TRIGGERING_REVIEW_SHA="$(printf 'a%.0s' {1..40})"
  body=$'review body\n\n'
  body="🔍 **Auto-review by primary (model) of MR !2** (1 commit(s), latest: ${TRIGGERING_REVIEW_SHA:0:8})\n\n${body}"
  MOCK_REVIEW_NOTE=$(jq -n --arg body "$body" '{body:$body,author:{username:"review-bot"}}')
  TRIGGERING_REVIEW_BODY_HASH=$(printf '%s' "$body" | git hash-object --stdin)
  gl_api() {
    printf '%s\n' "$MOCK_REVIEW_NOTE"
  }

  _gather_triggering_review
  [ "$(printf '%s' "$TRIGGERING_REVIEW" | git hash-object --stdin)" = "$TRIGGERING_REVIEW_BODY_HASH" ]

  TRIGGERING_REVIEW_BODY_HASH=$(printf '%s' 'original body' | git hash-object --stdin)
  run _gather_triggering_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer matches its immutable hash"* ]]
}

@test "triggering review retrieval rejects unavailable API content" {
  source "$GATHER_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  CLAUDE_MR_IID=2
  CLAUDE_BOT_USERNAME=review-bot
  TRIGGERING_REVIEW_NOTE_ID=123
  TRIGGERING_REVIEW_SHA="$(printf 'a%.0s' {1..40})"
  TRIGGERING_REVIEW_BODY_HASH="$(printf 'b%.0s' {1..40})"

  gl_api() {
    printf '%s\n' '{"body":""}'
  }
  run _gather_triggering_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"was unavailable"* ]]

  gl_api() {
    printf '%s\n' 'not json'
  }
  run _gather_triggering_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"was unavailable"* ]]

  gl_api() {
    return 1
  }
  run _gather_triggering_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be fetched"* ]]
}

@test "triggering review retrieval rejects a malformed hash" {
  source "$GATHER_SCRIPT"
  TRIGGERING_REVIEW_NOTE_ID=123
  TRIGGERING_REVIEW_BODY_HASH=invalid

  run _gather_triggering_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid triggering review hash"* ]]
}

@test "triggering review retrieval rejects an untrusted note" {
  source "$GATHER_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  CLAUDE_MR_IID=2
  CLAUDE_BOT_USERNAME=review-bot
  TRIGGERING_REVIEW_NOTE_ID=123
  TRIGGERING_REVIEW_SHA="$(printf 'a%.0s' {1..40})"
  body="🔍 **Auto-review by claude-companion (model) of MR !2** (1 commit(s), latest: ${TRIGGERING_REVIEW_SHA:0:8})"
  TRIGGERING_REVIEW_BODY_HASH=$(printf '%s' "$body" | git hash-object --stdin)
  MOCK_REVIEW_NOTE=$(jq -n --arg body "$body" '{body:$body,author:{username:"review-bot"}}')
  gl_api() { printf '%s\n' "$MOCK_REVIEW_NOTE"; }

  run _gather_triggering_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the anchored primary review"* ]]
}

@test "triggering review retrieval derives the documented default bot identity" {
  source "$GATHER_SCRIPT"
  CI_API_V4_URL=https://gitlab.example/api/v4
  CI_PROJECT_ID=1
  CLAUDE_MR_IID=2
  unset CLAUDE_BOT_USERNAME
  TRIGGERING_REVIEW_NOTE_ID=123
  TRIGGERING_REVIEW_SHA="$(printf 'a%.0s' {1..40})"
  body="🔍 **Auto-review by primary (model) of MR !2** (1 commit(s), latest: ${TRIGGERING_REVIEW_SHA:0:8})"
  TRIGGERING_REVIEW_BODY_HASH=$(printf '%s' "$body" | git hash-object --stdin)
  MOCK_REVIEW_NOTE=$(jq -n --arg body "$body" '{body:$body,author:{username:"review-bot"}}')
  gl_api() {
    if [[ "$1" == */user ]]; then
      printf '%s\n' '{"username":"review-bot"}'
    else
      printf '%s\n' "$MOCK_REVIEW_NOTE"
    fi
  }

  run _gather_triggering_review
  [ "$status" -eq 0 ]
}
