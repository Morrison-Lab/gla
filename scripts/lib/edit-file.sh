#!/usr/bin/env bash
# =============================================================================
# Apply a single edit_file tool call using perl literal replacement
# =============================================================================

_apply_edit_file() {
  local func_args="$1"
  local FPATH SEARCH REPLACE APPLY_RESULT

  FPATH=$(echo "$func_args" | jq -r '.path')
  SEARCH=$(echo "$func_args" | jq -r '.search')
  REPLACE=$(echo "$func_args" | jq -r '.replace')

  if [[ ! -f "$FPATH" ]]; then
    log "  WARN: edit_file targeted non-existent file $FPATH — skipped"
    EDIT_FAILURES="${EDIT_FAILURES}- Could not apply an edit to \`${FPATH}\`: the file does not exist (use create_file for new files).\n"
    return
  fi

  # Use perl for literal (non-regex) single-occurrence replacement
  APPLY_RESULT=$(perl -e '
    use strict;
    my $path = $ARGV[0];
    my $search = $ARGV[1];
    my $replace = $ARGV[2];

    open(my $rf, "<", $path) or do { print "FAIL_READ"; exit; };
    my $orig = do { local $/; <$rf> };
    close($rf);

    my $idx = index($orig, $search);
    if ($idx < 0) { print "FAIL_NOMATCH"; exit; }
    my $idx2 = index($orig, $search, $idx + 1);
    if ($idx2 >= 0) { print "FAIL_MULTI"; exit; }

    substr($orig, $idx, length($search)) = $replace;
    open(my $wf, ">", $path) or do { print "FAIL_WRITE"; exit; };
    print $wf $orig;
    close($wf);
    print "OK";
  ' "$FPATH" "$SEARCH" "$REPLACE")

  case "$APPLY_RESULT" in
    OK)
      log "  Edited: $FPATH"
      FILES_CHANGED=$((FILES_CHANGED + 1)) ;;
    FAIL_NOMATCH)
      log "  WARN: SEARCH text not found in $FPATH — skipped"
      EDIT_FAILURES="${EDIT_FAILURES}- Could not apply an edit to \`${FPATH}\`: the search text did not match the current file.\n" ;;
    FAIL_MULTI)
      log "  WARN: SEARCH text matched multiple times in $FPATH — skipped"
      EDIT_FAILURES="${EDIT_FAILURES}- Could not apply an edit to \`${FPATH}\`: the search text matched more than once (ambiguous).\n" ;;
    FAIL_READ|FAIL_WRITE)
      log "  WARN: Could not read/write $FPATH — skipped"
      EDIT_FAILURES="${EDIT_FAILURES}- Could not apply an edit to \`${FPATH}\`: file I/O error.\n" ;;
    *)
      log "  WARN: Unknown result for $FPATH: $APPLY_RESULT"
      EDIT_FAILURES="${EDIT_FAILURES}- Could not apply an edit to \`${FPATH}\` (unknown error).\n" ;;
  esac
}
