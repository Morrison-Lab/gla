# ADR: Advisory WIP Lock Design

**Status:** Accepted  
**Date:** 2026-06-16  
**Related issues:** #7, #9, #12

## Context

The `claude-respond` CI job needs to signal that it is actively working on an MR,
so that concurrent review jobs and human editors can avoid conflicts. GitLab CI
provides `resource_group` for true serialization, but we also need an advisory
signal visible in the MR UI.

## Decision

Use a GitLab label (`wip:ci-bot`) as an **advisory signal**, not a true mutex.
The real serialization is `resource_group: claude-agent` on the respond job.

### Key design choices

1. **Unconditional clear on exit**: The EXIT trap always removes `wip:ci-bot`
   (when `CLAUDE_MR_IID` is set), regardless of whether `set_wip_signal`
   succeeded. This prevents dangling labels from transient network failures
   during set (server applied the label but returned non-200).

2. **Fail-open on acquire, fail-closed on check**: If we can't *check* whether
   another actor is active, we exit (risk of conflict). If we can't *acquire*
   our own signal, we proceed (risk of redundant work, not conflict).

3. **Single clear point**: Only the EXIT trap clears the signal. `finalize()`
   does not duplicate the clear — this avoids a redundant API call on every
   successful run.

4. **No `WIP_LOCK_ACQUIRED` variable**: Previously existed as an informational
   flag but was removed as dead code. The `log "Set ..."` message provides
   the same grep-ability without carrying a variable that invites misuse.

5. **Idempotent clear**: GitLab's `PUT remove_labels` returns 200 even if the
   label doesn't exist. This makes unconditional clear safe.

### Edge cases acknowledged

- **Foreign label stripping**: The EXIT trap unconditionally calls
  `clear_wip_signal` when `CLAUDE_MR_IID` is set, even on the "foreign signal
  held" early-exit path (where we never set our own). This is safe because:
  (a) the foreign-signal check only fires when a non-`wip:ci-bot` label is
  present (e.g. `wip:human`), so `clear_wip_signal` removes a label we
  never set (no-op via idempotent API), (b) if a *concurrent bot job* holds
  `wip:ci-bot`, it won't appear in `get_non_self_wip_signals` (which excludes
  our own label), so the skip path can't trigger on it. The alternative
  (gating clear on a `WIP_LOCK_ACQUIRED` flag) risks dangling labels on
  edge-case failures between set and flag-set.

- **Review job is unserialized**: The `.gla-claude-review` job has no
  `resource_group`. Two rapid pushes can run two review jobs concurrently,
  each potentially triggering a respond pipeline. Bounded by `MAX_ITERATIONS`
  and `resource_group` on the respond side.

- **Bot↔bot TOCTOU**: Two respond jobs can both "acquire" (label add is not
  atomic). `resource_group` prevents actual parallel execution.

- **Parent↔child self-iteration overlap**: When a respond job self-iterates
  (via `iterate.sh`), the parent holds `wip:ci-bot` while the child pipeline
  also sets the same label. When the parent's EXIT trap fires, it removes
  the label out from under the still-running child. This makes the advisory
  signal momentarily misleading (label absent while a bot is active). Not a
  correctness issue because `resource_group` serializes actual execution, but
  external observers (humans, review jobs) may briefly see no signal. Acceptable
  because the child re-sets it on its own startup path.

- **SIGKILL / OOM / runner eviction**: If the runner is killed non-gracefully,
  the EXIT trap does not fire and `wip:ci-bot` is left dangling permanently.
  No TTL or staleness reaper exists. Manual remediation: remove the label from
  the MR. A scheduled cleanup job could automate this (see issue #15).

## Naming

Functions are named `set_wip_signal` / `clear_wip_signal` to reflect their
advisory nature. The previous names (`acquire_wip_lock` / `release_wip_lock`)
were renamed in issue #13 to eliminate the need for "this isn't really a lock"
caveats throughout the codebase.

## Security considerations

- **Trailer spoofability**: The `Acted-By: ci-bot` trailer is not
  cryptographically verified. Any contributor can add it to a commit message,
  causing the review job to treat the commit as bot-authored and potentially
  triggering an auto-fix pipeline. Blast radius is bounded by `wip-lock`,
  `resource_group`, and `MAX_ITERATIONS`/`MAX_REVIEW_TRIGGERS`, but the
  triggered pipeline runs the LLM against attacker-influenced content and
  pushes commits. Acceptable given the bounds; a future improvement could
  verify the committer email against a known bot identity.

- **Label namespace**: The `wip:` prefix is reserved for advisory concurrency
  signals. `get_non_self_wip_signals` matches any label starting with `wip:`
  (case-insensitive). Consumer repos must not use `wip:`-prefixed labels for
  unrelated purposes, or the bot will hard-block on them. See
  `docs/claude-setup.md` for the documented namespace reservation.

## Consequences

- Comments in code can be terse, pointing here for rationale.
- The `WIP_LOCK_ACQUIRED` variable was removed (dead code with no behavioral
  effect). The `log "Set ..."` message provides equivalent diagnostics.
- Extracting wip-signal functions into `lib/wip-signal.sh` (issue #12) would
  make the dependency on `log`/`log_error` explicit via a parameter or source.
