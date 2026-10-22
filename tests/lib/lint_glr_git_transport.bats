#!/usr/bin/env bats

setup() {
  TEMPLATE="$BATS_TEST_DIRNAME/../../templates/lint.yml"
  SCRIPT="$BATS_TEST_TMPDIR/fetch-glr.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-linting").fetch("script")[2]' \
    "$TEMPLATE" > "$SCRIPT"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/Rscript" <<'EOF'
#!/usr/bin/env sh
case "${2:-}" in
  *'"glr"'*) exit 1 ;;
  *'pak::local_install'*)
    test -z "${GLR_GIT_USERNAME:-}" || exit 1
    test -z "${GLR_GIT_PASSWORD:-}" || exit 1
    test -z "${GIT_ASKPASS:-}" || exit 1
    test -z "${GIT_TERMINAL_PROMPT:-}" || exit 1
    ;;
esac
exit 0
EOF
  cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$GIT_LOG"
if test "${USE_SYSTEM_GIT:-}" = 1; then
  exec "$SYSTEM_GIT" "$@"
fi
case "${CI_JOB_TOKEN:-}" in
  "") ;;
  *) case "$*" in *"$CI_JOB_TOKEN"*) exit 1 ;; esac ;;
esac
test "$LC_ALL" = C || exit 1
test -x "$GIT_ASKPASS"
test "$("$GIT_ASKPASS" 'Username for test')" = "$EXPECTED_USERNAME" || exit 1
test "$("$GIT_ASKPASS" 'Password for test')" = "$EXPECTED_TOKEN" || exit 1
case "$*" in
  *'ls-remote'*'0123456'*) exit 1 ;;
esac
for last_arg; do :; done
case "$*" in
  clone*) mkdir -p "$last_arg" ;;
esac
printf 'abc\trefs/heads/main\n'
EOF
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$CURL_LOG"
for arg; do
  if test "$previous" = -o; then
    output="$arg"
  fi
  previous="$arg"
done
case "$*" in
  *lint-codequality.R*) printf '%s\n' '#!/usr/bin/env Rscript' > "$output" ;;
  *)
    mkdir -p "$FAKE_ARCHIVE_SOURCE/glr"
    printf '%s\n' 'Package: glr' > "$FAKE_ARCHIVE_SOURCE/glr/DESCRIPTION"
    tar czf "$output" -C "$FAKE_ARCHIVE_SOURCE" glr
    ;;
esac
printf '200'
EOF
  cat > "$FAKE_BIN/sed" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod 700 "$FAKE_BIN/Rscript" "$FAKE_BIN/git" "$FAKE_BIN/curl" "$FAKE_BIN/sed"
}

@test "lint template defaults glr source retrieval to safe job-token Git transport" {
  run ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-linting").fetch("variables").fetch("GLA_GLR_FETCH_METHOD")' \
    "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = git ]
}

@test "lint template fetches the lint script without an auth-header file" {
  LINT_SCRIPT="$BATS_TEST_TMPDIR/fetch-lint-script.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-linting").fetch("script")[3]' \
    "$TEMPLATE" > "$LINT_SCRIPT"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  FAKE_ARCHIVE_SOURCE="$BATS_TEST_TMPDIR/archive-source"
  export CURL_LOG FAKE_ARCHIVE_SOURCE

  run env PATH="$FAKE_BIN:$PATH" GITLAB_TOKEN=masked-pat-token CI_JOB_TOKEN=masked-job-token \
    CI_API_V4_URL=https://gitlab.example GLA_PROJECT_ID=2058 GLA_REF=main \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$LINT_SCRIPT"

  [ "$status" -eq 0 ]
  run grep -F 'PRIVATE-TOKEN: masked-pat-token' "$CURL_LOG"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/.gla_auth_header" ]
}

@test "lint template suppresses lint-script credentials in xtrace output" {
  LINT_SCRIPT="$BATS_TEST_TMPDIR/fetch-lint-script.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".gla-linting").fetch("script")[3]' \
    "$TEMPLATE" > "$LINT_SCRIPT"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  FAKE_ARCHIVE_SOURCE="$BATS_TEST_TMPDIR/archive-source"
  export CURL_LOG FAKE_ARCHIVE_SOURCE

  run env PATH="$FAKE_BIN:$PATH" GITLAB_TOKEN=trace-lint-script-token \
    CI_API_V4_URL=https://gitlab.example GLA_PROJECT_ID=2058 GLA_REF=main \
    sh -c 'cd "$1" && bash -x "$2" 2>&1' sh "$BATS_TEST_TMPDIR" "$LINT_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *trace-lint-script-token* ]]
  run grep -F 'PRIVATE-TOKEN: trace-lint-script-token' "$CURL_LOG"
  [ "$status" -eq 0 ]
}

@test "lint template retrieves glr through safe job-token Git transport" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN=masked-test-token EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=masked-test-token \
    CI_SERVER_URL=https://gitlab.example/gitlab GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  run grep -F 'https://gitlab.example/gitlab/group/glr.git' "$GIT_LOG"
  [ "$status" -eq 0 ]
  run grep -F -- '-C .gla-tmp/glr fetch --depth 1 origin main' "$GIT_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'masked-test-token' "$GIT_LOG"
  [ "$status" -ne 0 ]
}

@test "lint template suppresses CI job tokens in Git xtrace output" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN=trace-ci-token EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=trace-ci-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash -x "$2" 2>&1' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *trace-ci-token* ]]
}

@test "lint template preserves PAT-only Git transport" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  CI_JOB_TOKEN=runner-job-token
  export CI_JOB_TOKEN GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN= GITLAB_TOKEN=masked-pat-token EXPECTED_USERNAME=oauth2 EXPECTED_TOKEN=masked-pat-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  run grep -F 'masked-pat-token' "$GIT_LOG"
  [ "$status" -ne 0 ]
}

@test "lint template suppresses PATs in Git xtrace output" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  CI_JOB_TOKEN=runner-job-token
  export CI_JOB_TOKEN GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN= GITLAB_TOKEN=trace-pat-token EXPECTED_USERNAME=oauth2 EXPECTED_TOKEN=trace-pat-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash -x "$2" 2>&1' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *trace-pat-token* ]]
}

@test "lint template prefers CI job tokens over GitLab access tokens" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN=masked-job-token GITLAB_TOKEN=masked-pat-token EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=masked-job-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  run grep -F 'masked-job-token' "$GIT_LOG"
  [ "$status" -ne 0 ]
  run grep -F 'masked-pat-token' "$GIT_LOG"
  [ "$status" -ne 0 ]
}

@test "lint template clears inherited credential aliases after Git retrieval" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN=masked-job-token GLR_GIT_USERNAME=poison-user GLR_GIT_PASSWORD=poison-password GIT_ASKPASS=/poison/askpass GIT_TERMINAL_PROMPT=1 EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=masked-job-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
}

@test "lint template preserves archive retrieval as an explicit compatibility mode" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  FAKE_ARCHIVE_SOURCE="$BATS_TEST_TMPDIR/archive-source"
  export GIT_LOG CURL_LOG FAKE_ARCHIVE_SOURCE

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN=masked-test-token GITLAB_TOKEN=masked-pat-token EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=masked-test-token \
    CI_API_V4_URL=https://gitlab.example GLA_GLR_PROJECT_ID=2071 \
    GLA_GLR_REF=0123456789012345678901234567890123456789 \
    GLA_GLR_FETCH_METHOD=archive \
    sh -c 'cd "$1" && bash "$2"' \
    sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  run grep -F 'repository/archive.tar.gz?sha=0123456789012345678901234567890123456789' "$CURL_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'PRIVATE-TOKEN: masked-pat-token' "$CURL_LOG"
  [ "$status" -eq 0 ]
  run grep -F 'masked-test-token' "$CURL_LOG"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/.gla_auth_header" ]
  [ ! -e "$GIT_LOG" ]
}

@test "lint template suppresses archive credentials in xtrace output" {
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  FAKE_ARCHIVE_SOURCE="$BATS_TEST_TMPDIR/archive-source"
  export CURL_LOG FAKE_ARCHIVE_SOURCE

  run env PATH="$FAKE_BIN:$PATH" GITLAB_TOKEN=trace-archive-token \
    CI_API_V4_URL=https://gitlab.example GLA_GLR_PROJECT_ID=2071 \
    GLA_GLR_REF=main GLA_GLR_FETCH_METHOD=archive \
    sh -c 'cd "$1" && bash -x "$2" 2>&1' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *trace-archive-token* ]]
  run grep -F 'PRIVATE-TOKEN: trace-archive-token' "$CURL_LOG"
  [ "$status" -eq 0 ]
}

@test "lint template accepts named hexadecimal refs and rejects a bare commit SHA" {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export GIT_LOG

  run env PATH="$FAKE_BIN:$PATH" LC_ALL=C.UTF-8 CI_JOB_TOKEN=masked-test-token EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=masked-test-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=abcdef0 GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F -- '-C .gla-tmp/glr ls-remote --exit-code origin refs/heads/abcdef0 refs/tags/abcdef0' "$GIT_LOG"
  [ "$status" -eq 0 ]
  run grep -F -- '-C .gla-tmp/glr fetch --depth 1 origin abcdef0' "$GIT_LOG"
  [ "$status" -eq 0 ]

  run env PATH="$FAKE_BIN:$PATH" CI_JOB_TOKEN=masked-test-token EXPECTED_USERNAME=gitlab-ci-token EXPECTED_TOKEN=masked-test-token \
    CI_SERVER_URL=https://gitlab.example GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=0123456 \
    GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'GLA_GLR_FETCH_METHOD=archive'* ]]
}

@test "lint template retrieves a tag from a remote with no branch refs" {
  SYSTEM_GIT="$(command -v git)"
  REMOTE_ROOT="$BATS_TEST_TMPDIR/tag-remote"
  SOURCE_REPO="$BATS_TEST_TMPDIR/tag-source"
  mkdir -p "$REMOTE_ROOT/group"
  "$SYSTEM_GIT" init --bare "$REMOTE_ROOT/group/glr.git"
  "$SYSTEM_GIT" init "$SOURCE_REPO"
  "$SYSTEM_GIT" -C "$SOURCE_REPO" config user.email tests@example.invalid
  "$SYSTEM_GIT" -C "$SOURCE_REPO" config user.name tests
  printf '%s\n' tag-only > "$SOURCE_REPO/DESCRIPTION"
  "$SYSTEM_GIT" -C "$SOURCE_REPO" add DESCRIPTION
  "$SYSTEM_GIT" -C "$SOURCE_REPO" commit -m tag-only
  "$SYSTEM_GIT" -C "$SOURCE_REPO" tag v1.2.3
  "$SYSTEM_GIT" -C "$SOURCE_REPO" push "$REMOTE_ROOT/group/glr.git" refs/tags/v1.2.3

  run env PATH="$FAKE_BIN:$PATH" SYSTEM_GIT="$SYSTEM_GIT" USE_SYSTEM_GIT=1 LC_ALL=C.UTF-8 CI_JOB_TOKEN=masked-test-token \
    CI_SERVER_URL="file://$REMOTE_ROOT" GLA_GLR_PROJECT_PATH=group/glr \
    GLA_GLR_REF=v1.2.3 GLA_GLR_FETCH_METHOD=git \
    sh -c 'cd "$1" && bash "$2"' sh "$BATS_TEST_TMPDIR" "$SCRIPT"

  [ "$status" -eq 0 ]
}
