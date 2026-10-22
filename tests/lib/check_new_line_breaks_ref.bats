#!/usr/bin/env bats
# =============================================================================
# Regression tests for templates/check-new-line-breaks.yml's pinned gla commit.
# =============================================================================
# The template fetches scripts/check-new-line-breaks.py at GLA_NLB_REF. A pin to
# a commit that is not in this repository's history makes every consumer job
# fail with a 404 (gla#3), and nothing else reports it. These checks assert that
# each 40-hex ref the template pins exists here and holds the script whose
# SHA-256 is GLA_NLB_SHA256.
#
# Run with: bats tests/lib/check_new_line_breaks_ref.bats

TEMPLATE="templates/check-new-line-breaks.yml"
SCRIPT="scripts/check-new-line-breaks.py"

setup() {
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    skip "shallow clone: pinned commits cannot be resolved"
  fi
}

@test "every full commit SHA pinned in the template exists in this repository" {
  refs=$(grep -oE '\b[0-9a-f]{40}\b' "$TEMPLATE" | sort -u)
  [ -n "$refs" ]
  for ref in $refs; do
    git cat-file -e "${ref}^{commit}" || {
      echo "pinned commit not in history: $ref" >&2
      return 1
    }
  done
}

@test "the script at GLA_NLB_REF matches GLA_NLB_SHA256" {
  ref=$(sed -n 's/^[[:space:]]*GLA_NLB_REF:[[:space:]]*"\([0-9a-f]\{40\}\)".*$/\1/p' "$TEMPLATE" | head -n 1)
  want=$(sed -n 's/^[[:space:]]*GLA_NLB_SHA256:[[:space:]]*"\([0-9a-f]\{64\}\)".*$/\1/p' "$TEMPLATE" | head -n 1)
  [ -n "$ref" ]
  [ -n "$want" ]
  got=$(git show "${ref}:${SCRIPT}" | sha256sum | cut -d' ' -f1)
  [ "$got" = "$want" ]
}
