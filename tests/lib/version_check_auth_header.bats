#!/usr/bin/env bats

setup() {
  TEMPLATE="$BATS_TEST_DIRNAME/../../templates/version-check.yml"
  SCRIPT="$BATS_TEST_TMPDIR/version-check-labels.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch(".hac-version-check").fetch("script")[2]' "$TEMPLATE" > "$SCRIPT"
}

@test "version check sends a PAT with the PRIVATE-TOKEN header" {
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export CURL_LOG
  curl() {
    printf '%s\n' "$*" >> "$CURL_LOG"
    printf '[]'
  }
  export -f curl

  run env GITLAB_TOKEN=pat CI_JOB_TOKEN=job CI_API_V4_URL=https://gitlab.example CI_PROJECT_ID=1 CI_COMMIT_REF_NAME=feature HAC_VERSION_SKIP_LABELS=no-version-bump bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run grep -F -- '--header PRIVATE-TOKEN: pat' "$CURL_LOG"
  [ "$status" -eq 0 ]
}

@test "version check sends CI_JOB_TOKEN with the JOB-TOKEN header" {
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export CURL_LOG
  curl() {
    printf '%s\n' "$*" >> "$CURL_LOG"
    if [[ "$*" == *'merge_requests?'* ]]; then
      printf '[{"iid":7}]'
      return 0
    fi
    printf '[]'
  }
  export -f curl

  run env -u GITLAB_TOKEN CI_JOB_TOKEN=job CI_API_V4_URL=https://gitlab.example CI_PROJECT_ID=1 CI_COMMIT_REF_NAME=feature HAC_VERSION_SKIP_LABELS=no-version-bump bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run grep -cF -- '--header JOB-TOKEN: job' "$CURL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "version check does not fail when optional MR lookups fail" {
  curl() {
    return 22
  }
  export -f curl

  run env -u GITLAB_TOKEN CI_JOB_TOKEN=job CI_API_V4_URL=https://gitlab.example CI_PROJECT_ID=1 CI_COMMIT_REF_NAME=feature HAC_VERSION_SKIP_LABELS=no-version-bump bash -e -o pipefail "$SCRIPT"
  [ "$status" -eq 0 ]
}
