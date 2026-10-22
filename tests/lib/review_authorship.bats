#!/usr/bin/env bats

setup() {
  REVIEW_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/claude-review.sh"
  eval "$(sed -n '/^  is_bot_authored_tip()/,/^  }$/p' "$REVIEW_SCRIPT" | sed 's/^  //')"
}

new_repo() {
  local repo="$BATS_TEST_TMPDIR/review-authorship"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "human@example.com"
  printf '%s\n' base > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "base"
  printf '%s\n' "$repo"
}

@test "older bot commit does not make a human tip bot-authored" {
  repo=$(new_repo)
  git -C "$repo" -c user.email=claude-bot@gitlab.ci commit --allow-empty -q -m "bot change"
  git -C "$repo" -c user.email=human@example.com commit --allow-empty -q -m "human change"

  cd "$repo"
  run is_bot_authored_tip "$(git -C "$repo" rev-parse HEAD)"
  [ "$status" -ne 0 ]
}

@test "bot tip email still qualifies" {
  repo=$(new_repo)
  git -C "$repo" -c user.email=claude-bot@gitlab.ci commit --allow-empty -q -m "bot change"

  cd "$repo"
  run is_bot_authored_tip "$(git -C "$repo" rev-parse HEAD)"
  [ "$status" -eq 0 ]
}

@test "tip Acted-By trailer remains an intentional bot signal" {
  repo=$(new_repo)
  git -C "$repo" commit --allow-empty -q -m $'human change\n\nActed-By: ci-bot'

  cd "$repo"
  run is_bot_authored_tip "$(git -C "$repo" rev-parse HEAD)"
  [ "$status" -eq 0 ]
}
