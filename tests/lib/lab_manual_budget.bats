#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/lib/lab-manual.sh"
}

@test "legacy lab-manual byte budget remains supported" {
  run bash -c 'export MAX_LAB_MANUAL_BYTES=123; unset HAC_MAX_LAB_MANUAL_BYTES; source "$1"; printf "%s\n" "$MAX_LAB_MANUAL_BYTES"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "HAC-prefixed lab-manual byte budget takes precedence" {
  run bash -c 'export MAX_LAB_MANUAL_BYTES=123 HAC_MAX_LAB_MANUAL_BYTES=456; source "$1"; printf "%s\n" "$MAX_LAB_MANUAL_BYTES"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "456" ]
}
