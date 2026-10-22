#!/usr/bin/env bash
# =============================================================================
# Order changed files so review context favors source and tests over artifacts.
# =============================================================================

context_file_priority() {
  local path="$1"
  case "$path" in
    renv.lock|*/renv.lock|package-lock.json|*/package-lock.json|npm-shrinkwrap.json|*/npm-shrinkwrap.json|yarn.lock|*/yarn.lock|pnpm-lock.yaml|*/pnpm-lock.yaml|Cargo.lock|*/Cargo.lock|Gemfile.lock|*/Gemfile.lock|poetry.lock|*/poetry.lock|composer.lock|*/composer.lock|*.lock|*/*.lock|*.map|*/*.map|*.min.js|*/*.min.js|*.min.css|*/*.min.css|vendor/*|*/vendor/*|dist/*|*/dist/*|build/*|*/build/*|_site/*|*/_site/*|generated/*|*/generated/*)
      printf '2\n'
      ;;
    tests/*|test/*|src/*|R/*|scripts/*|lib/*|python/*|app/*|cmd/*|internal/*|*.R|*.r|*.Rmd|*.qmd|*.py|*.sh|*.bash|*.zsh|*.js|*.jsx|*.ts|*.tsx|*.go|*.rs|*.c|*.cc|*.cpp|*.h|*.hh|*.hpp|*.java|*.sql|*.yaml|*.yml|*.toml|*.ini|*.cfg|*.xml|*.json)
      printf '0\n'
      ;;
    *)
      printf '1\n'
      ;;
  esac
}

context_first_pass_budget() {
  local content_budget="$1"
  local reserve_pct="${2:-50}"
  printf '%s\n' "$((content_budget * (100 - reserve_pct) / 100))"
}

context_first_pass_share() {
  local content_budget="$1"
  local file_count="$2"
  local reserve_pct="${3:-50}"
  [[ "$file_count" -gt 0 ]] || { printf '0\n'; return; }
  printf '%s\n' "$(( $(context_first_pass_budget "$content_budget" "$reserve_pct") / file_count ))"
}

context_files_for_review() {
  local reserve_pct="${1:-50}"
  if [[ "$reserve_pct" -eq 0 ]]; then
    cat
  else
    prioritize_context_files
  fi
}

prioritize_context_files() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    printf '%s\t%s\n' "$(context_file_priority "$path")" "$path"
  done | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 | cut -f2-
}
