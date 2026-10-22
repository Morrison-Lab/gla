#!/usr/bin/env bats

setup() {
  TEMPLATE="$BATS_TEST_DIRNAME/../../templates/agent-review.yml"
}

@test "agent review template is valid YAML" {
  run ruby -ryaml -e 'YAML.load_file(ARGV.fetch(0))' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review is explicitly opt-in" {
  run grep -F 'GLA_AGENT_REVIEW_ENABLED == "true"' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review only runs where GitLab exposes its protected credentials" {
  run grep -F 'CI_COMMIT_REF_PROTECTED == "true"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'only for protected source branches' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review keeps the direct reviewer as a separate path" {
  run grep -F 'this job does not replace it' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review requires a separately configured compatible gateway" {
  run grep -F 'GLA_AGENT_REVIEW_BASE_URL' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'not assumed' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review pins and verifies its native ai-config plugin" {
  run grep -F 'GLA_AI_CONFIG_REF:' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'git -C "$plugin_checkout" fetch -q --depth 1 origin "$GLA_AI_CONFIG_REF"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'rev-parse HEAD)" = "$GLA_AI_CONFIG_REF"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F -- '--plugin-dir /tmp/gla-agent-review/ai-config/plugins/ai-config' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review validates the pinned ai-config SHA exactly" {
  run bash -c 'eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("before_script").join("\\n")'\'' "$1" | sed -n '\''/^validate_ai_config_ref()/,/^}/p'\'')"; valid=bf6b118a8281657f3fe6d513e976c7e33e3cd26b; validate_ai_config_ref "$valid" && ! validate_ai_config_ref "" && ! validate_ai_config_ref "${valid:0:39}" && ! validate_ai_config_ref "${valid}0" && ! validate_ai_config_ref "${valid^^}" && ! validate_ai_config_ref "${valid}"$'\''\nnot-a-sha'\''' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review requires an HTTPS gateway base URL" {
  run bash -c 'eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("before_script").join("\\n")'\'' "$1" | sed -n '\''/^validate_gateway_base_url()/,/^}/p'\'')"; validate_gateway_base_url "https://gateway.example.com" && validate_gateway_base_url "https://gateway.example.com/v1" && ! validate_gateway_base_url "http://gateway.example.com/v1" && ! validate_gateway_base_url "" && ! validate_gateway_base_url "https://" && ! validate_gateway_base_url "https://gateway.example.com/v1"$'\''\nhttp://evil.example.com'\''' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'if (upstreamBase.protocol !== "https:") {' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review grants only checkout-confined read-only local inspection tools" {
  run grep -F -- "--permission-mode default" "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F -- '--restricted --strict-mcp-config --settings "$settings_file"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F -- "--allowedTools 'Read(./**)' 'Glob' 'Grep'" "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F "'Bash' 'Write' 'Edit' 'NotebookEdit' 'WebFetch' 'WebSearch'" "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F "'Read(//proc/**)' 'Read(//sys/**)' 'Read(//dev/**)' 'Read(//etc/**)' 'Read(//root/**)' 'Read(//tmp/**)' 'Read(//var/**)' 'Read(//run/**)'" "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'git diff --no-ext-diff "$merge_base" "$reviewed_sha" > "$diff_file"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'prompt_file=$(mktemp)' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F '< "$prompt_file" > "$output_file"' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review binds the reviewer to the current merge-request diff" {
  run grep -F 'MR !${merge_request_iid} no longer points at ${reviewed_sha}' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'git merge-base "origin/${target_branch}" "$reviewed_sha"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'git diff --quiet "$merge_base" "$reviewed_sha"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'select_same_project_merge_requests "$CI_PROJECT_ID"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run bash -euo pipefail -c '
    eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^select_same_project_merge_requests()/,/^}/p'\'')"
    filtered=$(printf '\''[{"iid":11,"source_project_id":9999,"source_branch":"codex/agent-review-harness"},{"iid":69,"source_project_id":2058,"source_branch":"codex/agent-review-harness"}]'\'' | select_same_project_merge_requests 2058)
    [ "$(printf "%s" "$filtered" | jq "length")" -eq 1 ]
    [ "$(printf "%s" "$filtered" | jq -r ".[0].iid")" = "69" ]
  ' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review isolates credentials and UID from the agent process" {
  run grep -F 'git remote set-url origin "${CI_PROJECT_URL}.git"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F -- "--get-regexp '^http\..*\.extraheader$'" "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'agent_workspace=$(mktemp -d /srv/gla-agent-workspace.XXXXXX)' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'stage_review_workspace "$CI_PROJECT_DIR" "$reviewed_sha" "$agent_workspace"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'find "$destination_dir" -type l -delete' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'env -i PATH="$PATH" HOME="$agent_home" LANG="${LANG:-C.UTF-8}"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'ANTHROPIC_AUTH_TOKEN="$proxy_nonce"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'ANTHROPIC_BASE_URL="http://127.0.0.1:${proxy_port}"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'setpriv --reuid="$agent_uid" --regid="$agent_gid" --clear-groups --no-new-privs' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'CLAUDE_WRAPPER=/tmp/gla-agent-review/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'node "$CLAUDE_WRAPPER" --version' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'node "$CLAUDE_WRAPPER" --print --output-format text --model "$GLA_AGENT_REVIEW_MODEL"' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run ruby -ryaml -e '
    job = YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review")
    before_script = job.fetch("before_script").join("\n")
    abort("CLAUDE_WRAPPER executed in before_script") if before_script.include?("node \"$CLAUDE_WRAPPER\"")
    script = job.fetch("script").join("\n")
    ws = script[/agent_workspace=\$\(mktemp -d ([^)]+)\)/, 1]
    raise "missing workspace path" unless ws && ws.start_with?("/srv/")
    denied = script.scan(/(?:Read|Glob|Grep)\(\/(\/[^*]+)\*\*\)/).flatten.uniq
    raise "empty deny list" if denied.empty?
    abort("workspace overlaps denied prefix") if denied.any? { |prefix| ws.start_with?(prefix) }
  ' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "stage_review_workspace preserves export-ignore and export-subst files while stripping symlinks" {
  repo="$BATS_TEST_TMPDIR/source-repo"
  dest="$BATS_TEST_TMPDIR/staged-workspace"
  mkdir -p "$repo" "$dest"
  git init -q "$repo"
  git -C "$repo" config user.email "ci@gla.invalid"
  git -C "$repo" config user.name "gla CI"
  printf '%s\n' 'ignored.txt export-ignore' 'subst.txt export-subst' > "$repo/.gitattributes"
  printf '%s\n' 'kept despite export-ignore' > "$repo/ignored.txt"
  printf '%s\n' '$Format:%H$' > "$repo/subst.txt"
  ln -s /etc/passwd "$repo/evil-link"
  git -C "$repo" add .gitattributes ignored.txt subst.txt evil-link
  git -C "$repo" commit -q -m "snapshot fixture"
  sha=$(git -C "$repo" rev-parse HEAD)

  run bash -euo pipefail -c '
    eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^stage_review_workspace()/,/^}/p'\'')"
    stage_review_workspace "$2" "$3" "$4"
    [ -f "$4/ignored.txt" ]
    [ "$(cat "$4/ignored.txt")" = "kept despite export-ignore" ]
    [ "$(cat "$4/subst.txt")" = "\$Format:%H\$" ]
    [ ! -e "$4/evil-link" ] && [ ! -L "$4/evil-link" ]
    [ ! -e "$4/.git" ]
  ' -- "$TEMPLATE" "$repo" "$sha" "$dest"
  [ "$status" -eq 0 ]
}

@test "agent review blocks adversarial reads, globs, and greps outside the repository" {
  workspace="$BATS_TEST_TMPDIR/workspace"
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$workspace/R" "$outside"
  printf '%s\n' 'x <- 1' > "$workspace/R/example.R"
  printf '%s\n' 'SECRET_TOKEN=topsecret' > "$outside/environ"
  ln -s "$outside/environ" "$workspace/R/leak-file"
  ln -s "$outside" "$workspace/R/leak-dir"

  funcs=$(ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\n")' "$TEMPLATE" | sed -n '/^path_has_dotdot_segment()/,/^agent_user=node/p' | sed '$d')

  run bash -e -c "$funcs"'
    ws="$1"
    out="$2"
    printf '\''{"tool_name":"Read","tool_input":{"file_path":"R/example.R"}}'\'' | validate_tool_request "$ws"
    printf '\''{"tool_name":"Read","tool_input":{"file_path":"./R/example.R","offset":1,"limit":10}}'\'' | validate_tool_request "$ws"
    printf '\''{"tool_name":"Read","tool_input":{"file_path":"%s/R/example.R"}}'\'' "$ws" | validate_tool_request "$ws"
    printf '\''{"tool_name":"Glob","tool_input":{"pattern":"**/*.R","path":"R"}}'\'' | validate_tool_request "$ws"
    printf '\''{"tool_name":"Grep","tool_input":{"pattern":"x","path":"R/example.R","glob":"*.R"}}'\'' | validate_tool_request "$ws"
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"/proc/self/environ"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"/proc/1/environ"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"%s/environ"}}'\'' "$out" | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"../outside/environ"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"R/../../outside/environ"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"R/leak-file"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Read","tool_input":{"file_path":"R/leak-dir/environ"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Glob","tool_input":{"pattern":"*","path":"/proc"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Glob","tool_input":{"pattern":"*","path":"R/leak-dir"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Glob","tool_input":{"pattern":"*","path":"R/leak-dir/"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Glob","tool_input":{"pattern":"/proc/**"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Glob","tool_input":{"pattern":"../**"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Grep","tool_input":{"pattern":"SECRET","path":"/proc/self/environ"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Grep","tool_input":{"pattern":"SECRET","path":"../outside"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Grep","tool_input":{"pattern":"SECRET","path":"R/leak-dir"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Grep","tool_input":{"pattern":"SECRET","glob":"/proc/*"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Grep","tool_input":{"pattern":"SECRET","glob":"../*"}}'\'' | validate_tool_request "$ws")
    ! (printf '\''{"tool_name":"Bash","tool_input":{"command":"cat /proc/self/environ"}}'\'' | validate_tool_request "$ws")
  ' -- "$workspace" "$outside"
  [ "$status" -eq 0 ]
}

@test "agent review refuses to post output containing credential material under pipefail" {
  clean_file="$BATS_TEST_TMPDIR/clean-review.md"
  leaked_file="$BATS_TEST_TMPDIR/leaked-review.md"
  large_body_file="$BATS_TEST_TMPDIR/large-review-body.md"
  printf '%s\n' "clean review body" > "$clean_file"
  {
    printf '%s\n' "leaked gw-secret-123 on first line"
    ruby -e 'puts("x" * 120000)'
  } > "$leaked_file"
  ruby -e 'File.write(ARGV.fetch(0), "a" * 200000)' "$large_body_file"

  run bash -euo pipefail -c '
    eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^review_contains_secret()/,/^}/p'\'')"
    ! review_contains_secret "$2" "gw-secret-123" "glpat-secret-456"
    review_contains_secret "$3" "gw-secret-123" "glpat-secret-456"
    payload_len=$(jq -Rs '\''{body: .} | .body | length'\'' < "$4")
    [ "$payload_len" -eq 200000 ]
  ' -- "$TEMPLATE" "$clean_file" "$leaked_file" "$large_body_file"
  [ "$status" -eq 0 ]
  run grep -F "jq -Rs '{body: .}' < \"\$review_body_file\"" "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review truncates without an early-closing pipeline" {
  run grep -F 'tr -d' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run jq -R -s -r --argjson limit 2 '.[0:$limit]' <<< 'éxyz'
  [ "$status" -eq 0 ]
  [ "$output" = 'éx' ]
  run bash -c "original=\$(printf 'a\\nb\\n' | jq -R -s -r 'length'); slice=\$(printf 'a\\nb\\n' | jq -R -s -r '.[0:2]'); [ \"\$original\" -gt 2 ] && [ \"\$slice\" = a ]"
  [ "$status" -eq 0 ]
  run bash -c 'eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^review_is_truncated()/,/^}/p'\'')"; ! review_is_truncated 4 4 && review_is_truncated 5 4' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F "review_char_count=\$(jq -R -s -r 'length' < \"\$normalized_output_file\")" "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review requires bounded canonical positive numeric limits" {
  run bash -c 'eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("before_script").join("\\n")'\'' "$1" | sed -n '\''/^validate_positive_limit()/,/^}/p'\'')"; validate_positive_limit 1 && validate_positive_limit 1000000000 && ! validate_positive_limit 0 && ! validate_positive_limit 00 && ! validate_positive_limit 01 && ! validate_positive_limit 1000000001 && ! validate_positive_limit 999999999999999999999999999999' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "credential-header pattern matches a GitLab checkout config key" {
  repo="$BATS_TEST_TMPDIR/credential-header-config"
  git init -q "$repo"
  git -C "$repo" config http.https://gitlab.example/group/project.git.extraheader \
    'AUTHORIZATION: basic token'

  run git -C "$repo" config --local --name-only \
    --get-regexp '^http\..*\.extraheader$'

  [ "$status" -eq 0 ]
  [ "$output" = "http.https://gitlab.example/group/project.git.extraheader" ]
}

@test "agent review drops output when the merge-request head advances" {
  run grep -F 'advanced during review; discarding stale output' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run bash -c 'eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^target_branch_is_current()/,/^}/p'\'')"; target_branch_is_current main main && ! target_branch_is_current main release' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
  run bash -c 'eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^merge_request_is_open()/,/^}/p'\'')"; merge_request_is_open opened && ! merge_request_is_open closed && ! merge_request_is_open merged' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review labels posted reviews with their diff scope" {
  run grep -F '⚠️ **Partial review:**' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'Review scope: full MR diff' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review post discloses Claude Code authorship" {
  run grep -F '_Posted by Claude Code (AI agent) --- not written by a human._' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "agent review neutralizes GitLab quick actions in posted review text" {
  run bash -euo pipefail -c '
    eval "$(ruby -ryaml -e '\''puts YAML.load_file(ARGV.fetch(0)).fetch(".gla-agent-review").fetch("script").join("\\n")'\'' "$1" | sed -n '\''/^neutralize_gitlab_quick_actions()/,/^}/p'\'')"
    sanitized=$(printf "%s\n" "## Findings" "/close" "  /approve" "/label ~bug" "normal /path/in/prose" | neutralize_gitlab_quick_actions)
    [ "$sanitized" = "$(printf "%s\n" "## Findings" "\\/close" "  \\/approve" "\\/label ~bug" "normal /path/in/prose")" ]
  ' -- "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -F 'neutralize_gitlab_quick_actions < "$bounded_output_file"' "$TEMPLATE"
  [ "$status" -eq 0 ]
}
