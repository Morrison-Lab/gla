#!/usr/bin/env bats
# The lint template's third script step fetches the R helpers that
# scripts/lint-codequality.R sources (scripts/R/, formerly the glr package).

setup() {
  TEMPLATE="$BATS_TEST_DIRNAME/../../templates/lint.yml"
  SCRIPT="$BATS_TEST_TMPDIR/fetch-helpers.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-linting").fetch("script")[2]' \
    "$TEMPLATE" > "$SCRIPT"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  # The fake curl writes a body chosen by FAKE_BODY and prints FAKE_CODE.
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$CURL_LOG"
for arg; do
  if test "$previous" = -o; then
    output="$arg"
  fi
  previous="$arg"
done
helper=$(basename "$output" .R)
case "${FAKE_BODY:-ok}" in
  ok) printf '%s <- function(x) x\n' "$helper" > "$output" ;;
  html) printf '%s\n' '<html><body>Sign in</body></html>' > "$output" ;;
esac
printf '%s' "${FAKE_CODE:-200}"
EOF
  chmod 700 "$FAKE_BIN/curl"
  cd "$BATS_TEST_TMPDIR"
}

run_fetch() {
  run env PATH="$FAKE_BIN:$PATH" CURL_LOG="$CURL_LOG" \
    CI_API_V4_URL=https://gitlab.example/api/v4 GLA_PROJECT_ID=2058 GLA_REF=v1.2.3 \
    GLA_R_HELPERS_DIR=.gla-R "$@" bash "$SCRIPT"
}

@test "lint template defines no glr variables" {
  run grep -n 'GLA_GLR_' "$TEMPLATE"
  [ "$status" -eq 1 ]
}

@test "lint template defaults GLA_R_HELPERS_DIR to .gla-R" {
  run ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-linting").fetch("variables").fetch("GLA_R_HELPERS_DIR")' \
    "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = ".gla-R" ]
}

@test "fetches every helper at GLA_REF with the job token" {
  run_fetch CI_JOB_TOKEN=job-token
  [ "$status" -eq 0 ]
  for helper in safe_char safe_num map_severity lint_to_codequality; do
    [ -s ".gla-R/${helper}.R" ]
    grep -F "repository/files/scripts%2FR%2F${helper}.R/raw?ref=v1.2.3" "$CURL_LOG"
  done
  grep -F 'JOB-TOKEN: job-token' "$CURL_LOG"
}

@test "prefers GITLAB_TOKEN when both tokens are set" {
  run_fetch CI_JOB_TOKEN=job-token GITLAB_TOKEN=api-token
  [ "$status" -eq 0 ]
  grep -F 'PRIVATE-TOKEN: api-token' "$CURL_LOG"
}

@test "fails without any token" {
  run_fetch
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires GITLAB_TOKEN or CI_JOB_TOKEN"* ]]
}

@test "fails on an HTTP error" {
  run_fetch CI_JOB_TOKEN=job-token FAKE_CODE=404
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch scripts/R/safe_char.R from gla (HTTP 404)"* ]]
}

@test "fails when the body is not the helper's definition" {
  run_fetch CI_JOB_TOKEN=job-token FAKE_BODY=html
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not define safe_char()"* ]]
}

@test "the helper list matches the files in scripts/R" {
  repo="$BATS_TEST_DIRNAME/../.."
  listed=$(grep -oE 'for helper in [a-z_ ]+;' "$TEMPLATE" | sed 's/for helper in //; s/;//' | tr ' ' '\n' | sort)
  present=$(cd "$repo/scripts/R" && ls ./*.R | sed 's|^\./||; s|\.R$||' | sort)
  [ "$listed" = "$present" ]
  sourced=$(grep -oE 'helper_names <- c\([^)]*\)' "$repo/scripts/lint-codequality.R" | grep -oE '"[a-z_]+"' | tr -d '"' | sort)
  [ "$sourced" = "$present" ]
}
