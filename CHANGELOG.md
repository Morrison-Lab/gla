# Changelog

All notable changes to gla are documented here.

This project uses **major version tags** (`v1`, `v2`, …) for breaking changes.
Non-breaking improvements land on `main` continuously. We use major-only tags
(not full semver) because gla is consumed via GitLab's `ref:` mechanism,
where floating major tags (like Docker's `image: node:20`) are the standard
pattern — consumers pin to a major for stability and get non-breaking fixes
automatically via `ref: main`.

## Unreleased

### Added

- **`check-new-line-breaks.yml` template.**
  Diff-scoped check that flags
  newly-added Markdown lines packing more than one sentence or clause onto a
  single source line (semantic line breaks convention), borrowing the detector
  and moved-content multiset exemption algorithm from `Morrison-Lab/gha`.
  Produces a GitLab Code Quality report artifact.

- **PHI scanning (`templates/check-phi.yml`).** New optional template that
  scans for content resembling Protected Health Information: Social Security
  numbers, medical record numbers, dates of birth, study/participant
  identifiers, and PHI column headers in data files. On a non-default branch
  only lines added relative to the default branch are scanned; on the default
  branch the whole tracked tree is. Matched values are never printed to the
  job log. Suppress a false positive with a `phi-allow` comment on the line,
  or with a regex in `.gitlab/phi-allowlist.txt`.

  The scanner is `Morrison-Lab/gha`'s `check-phi.py`, fetched from GitHub at a
  **pinned commit SHA** and checksum-verified before it is executed. gla
  does not reimplement it: the script is platform-agnostic, so this template
  only maps GitLab CI context onto its `PHI_*` environment contract. The two
  repos remain separate -- GitLab CI cannot consume a GitHub composite action,
  and vice versa -- but the scripts underneath are shared. See issue #65.

  Requires a `secrets` stage (the same one `security.yml` uses).

- **The bats suite now runs in CI.** `tests/lib/` was only ever exercised by
  hand, so a regression in a shell helper (or in `check-phi.yml`'s pinned SHA)
  could reach `main` unnoticed. A `bats-tests` job in this repo's own
  `.gitlab-ci.yml` now runs it on every branch and tag pipeline.

- **GPT-5.6 automatic review with optional Claude companion review.** Automatic
  MR review now defaults to `databricks-gpt-5-6-sol`. Set `REVIEW_MODEL` for a
  different primary reviewer, or set `GLA_CLAUDE_COMPANION_REVIEW=true` to add
  an independent Claude Sonnet 4.6 pass. The `@claude` response agent is
  unchanged, and existing `CLAUDE_MODEL` review overrides remain compatible.

- **Inline diff comments in auto-review.** The Claude review bot now posts
  findings as inline comments directly on the MR diff (visible in the Changes
  tab), in addition to the existing summary thread. Findings are pinpointed to
  specific file/line locations with severity badges (🔴 High, 🟡 Medium,
  🔵 Low). Old inline comments from previous reviews are auto-resolved.

- **Delayed review job for branches without an MR.** The `claude-review` job
  now also runs on non-default branch pushes that don't yet have an open MR,
  with a 60-second delay. This eliminates the race condition where pushing
  before creating the MR caused the review to be skipped entirely.

### Fixed

- **Content-free LLM responses no longer post as a clean review.** Some
  models can return a response with no usable review content (e.g. raw
  `reasoning` blocks with no prose) that previously extracted as an empty
  findings list and was posted as "clean," silently resolving any prior
  unresolved review threads. `claude-review.sh` now rejects a response that
  has neither the `FINDINGS_JSON` marker nor a markdown heading, posts a
  failure notice instead, and exits non-zero without touching existing
  threads.

- **Backtick escaping in review prompt.** Fixed a bash command-substitution
  error (`n\: command not found`) caused by improperly escaped backticks in
  the JSON example within the LLM prompt string.

- **FINDINGS_JSON separator parsing.** The LLM separator marker is now matched
  with a flexible regex pattern, tolerating common variations (`---FINDINGS_JSON---`,
  `FINDINGS_JSON`, `--- FINDINGS_JSON ---`). Previously, exact-match failure
  caused raw JSON to appear in the posted summary comment.

- **`git add -A` swept up vendored `.gitlab/scripts/` into LLM commits.**
  `commit-push.sh`, `git-push-issue.sh`, and the scope guard in
  `apply-changes.sh` now exclude `.gitlab/scripts/` from `git add -A`.
  Consumer repos that don't track those scripts locally get them fetched into
  the working tree by `claude.yml`'s `before_script`; a bare `git add -A`
  staged them alongside the LLM's real edits, so every bot-authored commit
  carried 17 unrelated files. The scope guard already warned about this but
  didn't block it. See [issue #48](https://gitlab.example.com/example-group/gla/-/work_items/48).

## [v2] — 2025-06-17

### Breaking

- **Renamed `claude-respond` stage to `claude`.**
  Consumers using `claude.yml` must update their `stages:` list:
  ```diff
   stages:
  -  - claude-respond
  +  - claude
  ```
  See [MR !25](https://gitlab.example.com/example-group/gla/-/merge_requests/25).

### Added

- `workflow.yml` template — suppresses duplicate MR-event pipelines
  (consumers should include this first).

## [v1] — 2025-05-30

Initial tagged release. Includes:

- `check-package.yml` — R CMD check
- `lint.yml` — lintr + Code Quality report
- `test-coverage.yml` — covr coverage badge
- `docs-check.yml` — roxygen2 docs freshness check
- `version-check.yml` — DESCRIPTION version bump check
- `pkgdown.yml` — build pkgdown site
- `pkgdown-deploy.yml` — multi-branch site deployment
- `security.yml` — SAST + secret detection
- `claude.yml` — AI code review agent (optional)

---

## How to find the latest tag

```bash
# From a clone:
git ls-remote --tags --refs origin | sed 's#.*/##' | sort -V | tail -1

# Or on the GitLab UI:
# Repository → Tags → sorted by date
```

[v2]: https://gitlab.example.com/example-group/gla/-/tags/v2
[v1]: https://gitlab.example.com/example-group/gla/-/tags/v1
