#!/usr/bin/env bash
# Register one self-hosted GitHub Actions runner for the Morrison-Lab org,
# on cf463-02 (WWU network) or Ezra's XPS PC (run under WSL or any Linux there;
# native Windows needs the Windows runner and is not covered).
# Runs as the current user with no sudo. Idempotent: does nothing if a runner
# is already configured in $RUNNER_DIR.
#
# The registration token is minted here with the gh login on this machine and
# is never printed or written to disk.
#
# Safety: the runner joins a runner group that must be limited to PRIVATE
# repositories. Never let a public repository use it, because a fork pull
# request can run arbitrary code on this machine.
set -euo pipefail

ORG="${ORG:-Morrison-Lab}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-private}"
RUNNER_NAME="${RUNNER_NAME:-private-$(hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-private-runner,$(hostname -s)}"
RUNNER_GROUP="${RUNNER_GROUP:-private-runners}"

if [ -f "$RUNNER_DIR/.runner" ]; then
  echo "Runner already configured in $RUNNER_DIR; nothing to do."
  exit 0
fi

command -v gh > /dev/null || { echo "gh is not installed" >&2; exit 1; }
gh auth status > /dev/null

# The group admits private repositories only; create it if missing.
if ! gh api "orgs/${ORG}/actions/runner-groups" --paginate --jq '.runner_groups[].name' \
  | grep -qx "$RUNNER_GROUP"; then
  gh api -X POST "orgs/${ORG}/actions/runner-groups" \
    -f name="$RUNNER_GROUP" -f visibility=private > /dev/null
  echo "Created runner group $RUNNER_GROUP (private repositories only)."
fi

version=$(gh api repos/actions/runner/releases/latest --jq .tag_name)
version=${version#v}
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
curl -sSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
tar xzf runner.tar.gz
rm runner.tar.gz

token=$(gh api -X POST "orgs/${ORG}/actions/runners/registration-token" --jq .token)
./config.sh --unattended \
  --url "https://github.com/${ORG}" \
  --token "$token" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --runnergroup "$RUNNER_GROUP"
unset token

# Run in the background as this user; no systemd unit needed.
nohup ./run.sh > runner.log 2>&1 &
echo "Runner $RUNNER_NAME started (log: $RUNNER_DIR/runner.log)."
echo "Callers use: runs-on: private-runner (gha check and lint workflows with the runs-on input)."
