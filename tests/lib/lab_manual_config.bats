#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/lab-manual.sh"
}

@test "lab manual keeps the SERG defaults when no overrides are set" {
  run bash -c '
    source "$1"
    printf "%s\n" "$LAB_MANUAL_BASE_URL"
    printf "%s\n" "$LAB_MANUAL_DEFAULT_PAGES"
    _select_pages_for_diff "scripts/example.R\ntemplates/ci.yml"
  ' _ "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"https://ucd-serg.github.io/lab-manual"* ]]
  [[ "$output" == *"coding-style.html coding-practices.html"* ]]
  [[ "$output" == *"continuous-integration.html"* ]]
}

@test "consumers can override the base URL, defaults, and page map" {
  export GLA_LAB_MANUAL_BASE_URL=https://example.test/manual
  export GLA_LAB_MANUAL_DEFAULT_PAGES="overview.html style.html"
  export GLA_LAB_MANUAL_ALWAYS_PAGES=
  export GLA_LAB_MANUAL_PAGE_MAP="*.R|r-style.html *.sh|shell.html"
  export GLA_LAB_MANUAL_NAME="Example Manual"
  source "$SCRIPT"
  [ "$LAB_MANUAL_BASE_URL" = "https://example.test/manual" ]
  [ "$LAB_MANUAL_DEFAULT_PAGES" = "overview.html style.html" ]
  [ -z "$LAB_MANUAL_ALWAYS_PAGES" ]
  [ "$LAB_MANUAL_NAME" = "Example Manual" ]
  run _select_pages_for_diff "$(printf '%s\n' scripts/example.R scripts/example.sh README.md)"

  [ "$status" -eq 0 ]
  [ "$output" = $'r-style.html\nshell.html' ]
}

@test "always-pages override accepts multiple page names" {
  export GLA_LAB_MANUAL_BASE_URL=https://example.test/manual
  export GLA_LAB_MANUAL_ALWAYS_PAGES="overview.html practices.html"
  export GLA_LAB_MANUAL_PAGE_MAP=
  source "$SCRIPT"

  run _select_pages_for_diff "README.md"

  [ "$status" -eq 0 ]
  [ "$output" = $'overview.html\npractices.html' ]
}
