#!/usr/bin/env bats

PROMPT_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/prompt.sh"

setup_prompt_context() {
  NOTEABLE_TYPE=Issue
  ISSUE_TITLE="Test issue"
  ISSUE_DESCRIPTION="Test description"
  NEW_BRANCH="test-branch"
  REPO_TREE="tree"
  KEY_FILES="files"
  CLAUDE_COMMENT_BODY="test request"
  ISSUE_NOTES=""
  MR_NOTES=""
  TRIGGERING_REVIEW=""
  unset LAB_MANUAL_CONTENT
  fetch_lab_manual_safe() { :; }
  source "$PROMPT_SCRIPT"
}

@test "unavailable lab manual context tells the model not to guess anchors" {
  setup_prompt_context
  build_prompt

  [[ "$SYSTEM_PROMPT" == *"No lab manual content was retrieved for this run"* ]]
  [[ "$SYSTEM_PROMPT" == *"do not guess specific section anchors"* ]]
  [[ "$SYSTEM_PROMPT" != *"actual content of key lab manual pages is included"* ]]
}

@test "retrieved lab manual context permits grounded citations" {
  setup_prompt_context
  LAB_MANUAL_CONTENT="## SERG Lab Manual Reference"
  build_prompt

  [[ "$SYSTEM_PROMPT" == *"actual content of key lab manual pages is included"* ]]
  [[ "$SYSTEM_PROMPT" != *"No lab manual content was retrieved for this run"* ]]
}

@test "review prompt uses conditional lab manual guidance" {
  grep -Fq 'LAB_MANUAL_GUIDANCE' "$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
  grep -Fq 'do not guess specific section anchors' "$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
}
