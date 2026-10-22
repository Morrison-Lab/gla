# gla

Reusable GitLab CI/CD templates for R packages in the lab.

## Overview

gla provides shared CI/CD pipeline templates that can be included in any
R package repo via GitLab's
[`include:`](https://docs.gitlab.com/ee/ci/yaml/includes.html) mechanism.
This eliminates copy-paste of CI jobs across repos and provides a single place
to update pipeline logic.

## Versioning

gla uses **major version tags** (`v1`, `v2`, …) for breaking changes.
Non-breaking improvements land on `main` continuously.

| `ref:` value | Behavior |
|---|---|
| `main` | Always latest — you get fixes immediately but may hit breaking changes |
| `v2` | Pinned to a stable release — opt in to breaking changes on your schedule |

> **Current stable tag: `v2`** (2025-06-17) — renamed `claude-respond` stage
> to `claude`. See [CHANGELOG.md](CHANGELOG.md) for details and migration steps.

To find the latest tag:
- **GitLab UI:** Repository → Tags (sorted by date)
- **CLI:** `git ls-remote --tags --refs https://gitlab.example.com/example-group/gla.git | sed 's#.*/##' | sort -V | tail -1`

## Quick Start

In your repo's `.gitlab-ci.yml`:

```yaml
include:
  - project: 'example-group/gla'
    ref: v2  # or 'main' for always-latest
    file:
      # ── Required ──────────────────────────────────────────────────────
      - '/templates/workflow.yml'        # Prevents duplicate pipelines

      # ── Standard R package CI ─────────────────────────────────────────
      - '/templates/check-package.yml'   # R CMD check
      - '/templates/lint.yml'            # lintr + Code Quality report
      # Semantic line breaks check. Added after the v2 tag, so it is only
      # available on `ref: main` until the next tag is cut -- uncommenting it
      # under `ref: v2` fails pipeline creation with "file not found".
      # - '/templates/check-new-line-breaks.yml'
      - '/templates/test-coverage.yml'   # covr coverage badge
      - '/templates/docs-check.yml'      # roxygen2 up-to-date check
      - '/templates/version-check.yml'   # DESCRIPTION version bump check

      # ── Documentation site ───────────────────────────────────────────
      - '/templates/pkgdown.yml'         # Build pkgdown site
      - '/templates/pkgdown-deploy.yml'  # Multi-branch site deployment

      # ── Security ─────────────────────────────────────────────────────
      - '/templates/security.yml'        # SAST + secret detection
      # PHI scan (gha's check-phi.py). Added after the v2 tag, so it is only
      # available on `ref: main` until the next tag is cut -- uncommenting it
      # under `ref: v2` fails pipeline creation with "file not found".
      # - '/templates/check-phi.yml'

      # ── AI review (optional) ─────────────────────────────────────────
      # - '/templates/claude.yml'        # @claude agent + auto-review

image: rocker/verse:latest

variables:
  # Choose dependency manager: "pak" (default) or "renv"
  GLA_DEP_MANAGER: "pak"

stages:
  - build
  - secrets
  - test
  - lint
  - docs
  - version
  - pkgdown
  - pkgdown-move
  - prepare-deploy
  - deploy
  # - claude  # Uncomment if enabling claude.yml
```

> **Tip:** List `workflow.yml` first in the include list for readability
> (include-list ordering has no functional effect on GitLab CI — it's
> purely a convention to signal that this is the foundational template).
>
> **Important:** GitLab allows only one top-level `workflow:` block per
> assembled pipeline. Do not define your own `workflow:` block when including
> this template — it will conflict regardless of include order. See the
> template header comments for details.

## Templates

### Required: `workflow.yml`

> **Always include `workflow.yml`.** Without it, GitLab creates **both** a branch
> pipeline and an MR-event pipeline on every push when an MR is open — doubling
> resource usage and cluttering the Pipelines page.

`workflow.yml` defines a single top-level `workflow:` block that suppresses
MR-event pipelines in favor of branch pipelines. This means:

- `CI_MERGE_REQUEST_*` variables are **not** available. Jobs needing MR context
  (labels, target branch, etc.) query the GitLab API instead (see
  `version-check.yml` for an example).
- GitLab's "Pipelines must succeed" merge setting still works — it gates on the
  latest pipeline for the source branch.
- Trigger pipelines (for `@claude` webhook), scheduled pipelines, and tag
  pipelines always run.

### All templates

| Template | Job(s) | Description |
|----------|--------|-------------|
| `workflow.yml` | _(none — pipeline-level)_ | **Required.** Prevents duplicate branch + MR pipelines |
| `check-package.yml` | `check-package` | R CMD check with `--no-manual` |
| `lint.yml` | `linting` | lintr with GitLab Code Quality report |
| `check-new-line-breaks.yml` | `check-new-line-breaks` | Diff-scoped check for missing semantic line breaks |
| `test-coverage.yml` | `test_coverage` | covr with coverage badge |
| `docs-check.yml` | `docs_check` | Verify roxygen2 docs are up to date |
| `version-check.yml` | `version-check` | Ensure DESCRIPTION version bumped vs main |
| `pkgdown.yml` | `integration` | Build pkgdown site |
| `pkgdown-deploy.yml` | `integration-*`, `gh-pages-prep`, `pages` | Multi-branch site deployment |
| `security.yml` | `sast`, `secret_detection` | GitLab SAST + secret detection |
| `check-phi.yml` | `check-phi` | Scan for PHI-like content (SSNs, MRNs, DOBs, study IDs, PHI column headers). Runs `Morrison-Lab/gha`'s `check-phi.py`, fetched at a pinned SHA. Matched values are never logged. |
| `claude.yml` | `claude-respond`, `claude-review`, `claude-companion-review` | _(Optional.)_ AI code review and `@claude` coding agent. All jobs run in the `claude` stage; the companion review is opt-in. |
| `agent-review.yml` | `agent-review` | _(Experimental, opt-in.)_ A read-only Claude Code review harness. It loads `ai-config` through Claude Code's native marketplace mechanism and requires a separately configured Anthropic-compatible gateway. |

## Configuration Variables

Set these in your repo's `.gitlab-ci.yml` `variables:` block to customize
behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `GLA_DEP_MANAGER` | `"pak"` | Dependency manager: `"pak"` or `"renv"` |
| `GLA_R_LIBS_USER` | `${CI_PROJECT_DIR}/ci/lib` | Library path for installed packages |
| `GLA_CHECK_ARGS` | `"--no-manual"` | Extra args for `R CMD check` |
| `GLA_CHECK_ERROR_ON` | `"warning"` | rcmdcheck error level |
| `GLA_COVERAGE_ALLOW_FAILURE` | `"true"` | Whether coverage job can fail |
| `GLA_PKGDOWN_INSTALL_QUARTO` | `"false"` | Install quarto for .qmd vignettes |
| `LINTR_ERROR_ON_LINT` | `"true"` | Fail pipeline on lint findings |
| `NLB_GLOBS` | `"*.md"` | Space-separated pathspecs for semantic line break check |
| `NLB_PATHS_IGNORE` | `""` | Comma/newline-separated glob patterns to skip in line break check |
| `NLB_FAIL` | `"true"` | Fail pipeline on semantic line break violations |
| `NLB_CLAUSE_BREAKS` | `"true"` | Flag long lines with mid-line semicolons (SemBr rule 5) |
| `NLB_CLAUSE_MIN_LENGTH` | `"80"` | Minimum visible length before clause check applies |
| `GLA_NLB_REF` | pinned commit SHA | Commit SHA to fetch `check-new-line-breaks.py` at |
| `GLA_NLB_SHA256` | digest of pinned file | Expected SHA256 checksum of `check-new-line-breaks.py` |
| `SITE_BY_BRANCH` | `"TRUE"` | Deploy per-branch pkgdown sites |
| `GLA_PROJECT_ID` | (set in the template) | Project ID of gla repo (for script fetching) |
| `GLA_REF` | `"main"` | Branch/tag of gla to fetch scripts from |
| `REVIEW_MODEL` | `"databricks-gpt-5-6-sol"` | Databricks endpoint used for automatic review |
| `GLA_CLAUDE_COMPANION_REVIEW` | `"false"` | Run an additional Claude Sonnet review |
| `GLA_REVIEW_PROMPT_ADDENDUM` | `""` | Optional repository-specific review guidance appended to the agent contract |
| `GLA_REVIEW_AGENT` | `"true"` | Enable bounded read-only repository exploration; set `"false"` for prompt-only mode |
| `GLA_MAX_REVIEW_TOOL_ROUNDS` | `8` | Maximum read-only exploration rounds per review |
| `GLA_MAX_REVIEW_TOOL_CALLS` | `16` | Maximum read-only tool calls in one model response |
| `GLA_MAX_REVIEW_TOOL_RESULT_CHARS` | `120000` | Total tool-result characters retained across a review |
| `GLA_MAX_REVIEW_RESPONSE_CHARS` | `200000` | Maximum endpoint response characters retained per request |
| `GLA_REVIEW_DEADLINE_SECONDS` | `480` | Overall automatic-review deadline, below the 10-minute job timeout |
| `GLA_MAX_REVIEW_NOTES_CHARS` | `500000` | Cumulative MR-note response budget while fetching history |
| `GLA_MAX_REVIEW_HISTORY_CHARS` | `12000` | Maximum historical review context passed to the reviewer |
| `GLA_AGENT_REVIEW_ENABLED` | `"false"` | Enable the experimental Claude Code agent-review job |
| `GLA_AGENT_REVIEW_MODEL` | _(required)_ | Model identifier exposed by the agent gateway |
| `GLA_AGENT_REVIEW_BASE_URL` | _(required)_ | Anthropic-compatible gateway base URL; do not assume the direct Databricks invocation URL works |
| `GLA_AGENT_REVIEW_AUTH_TOKEN` | _(required)_ | Protected token accepted by the agent gateway |
| `GLA_AGENT_REVIEW_MAX_TURNS` | `"12"` | Maximum Claude Code tool-use turns per review |
| `GLA_AGENT_REVIEW_MAX_DIFF_BYTES` | `"250000"` | Positive canonical decimal maximum MR-diff bytes (up to 1,000,000,000); truncation is disclosed in the prompt |
| `GLA_AGENT_REVIEW_MAX_OUTPUT_CHARS` | `"50000"` | Positive canonical decimal maximum characters posted in the agent review note (up to 1,000,000,000) |

The agent-review job runs only on a protected source branch with an open merge
request.
This keeps its protected gateway and GitLab credentials unavailable to ordinary
feature-branch pipelines.
Protect the source-branch pattern used for agent-reviewed changes before
enabling it.

### PHI scan (`check-phi.yml`)

The scanner is fetched from GitHub at job time, so runners need egress to
`raw.githubusercontent.com`, and the image must be Debian/Ubuntu-based (the job
installs `curl` and `git` with `apt-get`).

| Variable | Default | Description |
|----------|---------|-------------|
| `GLA_PHI_IMAGE` | `"python:3.13-slim"` | Image providing `python3`. Debian/Ubuntu-based unless you override `before_script` |
| `GLA_GHA_REPO` | `"Morrison-Lab/gha"` | Repo hosting `check-phi.py` |
| `GLA_GHA_REF` | pinned commit SHA | Commit to fetch at. Pin to a SHA, never a branch: the fetched script is executed |
| `GLA_PHI_SHA256` | digest of the pinned file | Verified before execution. Update in the same change as `GLA_GHA_REF` |
| `GLA_PHI_DETECTORS` | `""` (all defaults) | Comma-separated subset. Defaults: `ssn`, `mrn`, `dob`, `csv_phi_header`, `study_id`; also `phone`, `email` |
| `GLA_PHI_PATHS_IGNORE` | `""` | Comma/newline-separated globs to skip; supports `**` |
| `GLA_PHI_ALLOWLIST_FILE` | `""` | Regex allowlist. When unset, `.gitlab/phi-allowlist.txt` then `.github/phi-allowlist.txt` are used if present |
| `GLA_PHI_FAIL` | `"true"` | `"false"` warns instead of failing the job |

The `check-phi` job sets `GIT_DEPTH: 0` at job level, which overrides a global
`GIT_DEPTH` (the shipped examples set `10`). That is deliberate and not
configurable: diff mode needs the default branch reachable, and a shallow clone
makes the merge base unavailable, so the job would silently widen to a
whole-tree scan.

### Review prompt budgets

`claude-review.sh` bounds every component of the prompt it sends. Raise these if
reviews are missing context; lower them to cut token spend.

| Variable | Default | Description |
|----------|---------|-------------|
| `GLA_MAX_DIFF_BYTES` | `250000` | MR diff cap. Over this, the diff is truncated and the prompt says so |
| `GLA_MAX_KEY_FILES_BYTES` | `250000` | Total cap on inlined contents of changed files |
| `GLA_MAX_SINGLE_FILE_PCT` | `60` | Per-file cap, as a percentage of the total |
| `GLA_MAX_SINGLE_FILE_BYTES` | *derived* | Explicit per-file cap; overrides the percentage |
| `GLA_MAX_COMMIT_LINES` | `100` | Commit-message lines included |
| `GLA_MAX_MR_DESCRIPTION_CHARS` | `2000` | MR description characters |
| `GLA_MAX_PRIOR_REVIEW_CHARS` | `3000` | Previous auto-review characters fed back in |
| `GLA_MAX_AUTHOR_RESPONSE_CHARS` | `2000` | Author's reply-to-review characters |
| `MAX_LAB_MANUAL_BYTES` | `40000` | Lab manual pages fetched for convention citations |
| `GLA_MAX_LAB_MANUAL_BYTES` | `40000` | Lab manual pages fetched for convention citations; takes precedence over the legacy name |
| `GLA_LAB_MANUAL_BASE_URL` | SERG manual | Base URL for fetched manual pages |
| `GLA_LAB_MANUAL_DEFAULT_PAGES` | `coding-style.html coding-practices.html` | Space-separated default page list |
| `GLA_LAB_MANUAL_ALWAYS_PAGES` | `coding-practices.html` for SERG | Space-separated pages included in every diff-aware selection |
| `GLA_LAB_MANUAL_PAGE_MAP` | SERG page map | Space-separated `glob|page` rules for diff-aware selection |
| `GLA_LAB_MANUAL_NAME` | `SERG Lab Manual` | Attribution heading for fetched manual context |

Two things worth knowing:

**Truncation is always disclosed.** When any component is cut, the prompt tells
the model what it is missing and instructs it to scope its verdict accordingly.
A review over a partial diff says so rather than reading as a clean pass.

Changed-file context prioritizes source and test files before ordinary text and
lockfile or generated artifacts.
This preserves the bounded prompt while giving the files most relevant to
correctness the best chance of being complete.
Any remaining partial or omitted files are still disclosed to the reviewer.
The default 50% first-pass reserve can be adjusted with
`GLA_CONTEXT_PRIORITY_RESERVE_PCT`, or set to 0 to retain the legacy allocation.

**The per-file cap is a share of the total, not a fixed size.** It exists so one
large file cannot consume the whole budget and starve the other changed files,
which is a claim about proportion — so raising `GLA_MAX_KEY_FILES_BYTES` moves
the per-file cap with it. Set `GLA_MAX_SINGLE_FILE_BYTES` only if you need a
fixed ceiling regardless of the total.

Sizing headroom: at the defaults, the worst-case prompt is roughly 512,000 bytes
(~128,000 tokens) against ~191,000 tokens of usable input on a 200k-token model,
so there is about 1.5x room.
These defaults are deliberately not near the limit.

## Dependency Management

### pak-based repos (default)

Templates will use `pak::pak()` and `pak::pkg_install()` for dependency
installation. No extra setup needed.

### renv-based repos

Set `GLA_DEP_MANAGER: "renv"` and ensure your repo has:
- `renv.lock` (committed)
- `renv/activate.R` (committed)

Templates will call `renv::restore()` before each job.

## Scripts

The `scripts/` directory contains shared scripts used by the templates:

- **R helper scripts** — used by R package CI jobs
- **`check-new-line-breaks.py`** — diff-scoped semantic line breaks checker
- **`claude-review.sh`** — automated MR code review (reviews full MR diff)
- **`claude-respond.sh`** — responds to @claude mentions in MR/issue comments

All scripts are fetched at runtime via `curl` from the gla repo
(using `$CI_JOB_TOKEN` for authentication). If a local copy exists in your
repo at `.gitlab/scripts/`, it takes precedence over the gla version.

### Claude AI Setup

> To enable, uncomment `'/templates/claude.yml'` in your include list and add
> `claude` to your `stages:` list (see Quick Start above).

The `claude.yml` template provides automated code review and @claude agent
capabilities. See **[docs/claude-setup.md](docs/claude-setup.md)** for the
full step-by-step setup guide.

#### Invoking `@claude`

Mention `@claude` at the **start of a line** (after optional blockquote markers
and a single list bullet) in an MR or issue comment:

```markdown
@claude fix the typo in README.md
> @claude summarize this diff
- @claude add tests for the new helper
1. @claude refactor this function
> > @claude (nested blockquotes OK)
> - @claude (blockquoted list item OK)
```

Mid-line mentions (e.g. `please ask @claude`) are **not** detected — this
prevents false triggers from discussion text. Single-backtick inline mentions
(`` `@claude` ``) are also ignored. Note: `@claude` inside fenced code blocks
(triple-backtick) **will** match if it appears at line-start — avoid putting
literal `@claude` at the start of a line in code examples.

#### Reviewer model selection

Automatic reviews use **GPT-5.6 Sol** by default. Set `REVIEW_MODEL` in GitLab
CI/CD variables to use one different Databricks endpoint instead. For example,
`databricks-claude-sonnet-4-6` gives you Claude-only automatic review.

Set `GLA_CLAUDE_COMPANION_REVIEW=true` to run Claude Sonnet 4.6 in addition to
the primary reviewer. Each pass labels findings with its reviewer identity and
endpoint, so the findings stay independent even if both passes use the same
model. The two jobs share a resource group, so they run serially rather than
creating a token burst. Only the primary review can trigger the `@claude`
auto-fix loop or adopt unresolved findings from the legacy untagged format;
companion reviews only manage their own reviewer-tagged findings.

Automatic review runs in bounded read-only agent mode by default.
The agent can inspect any tracked repository file, read the fetched MR discussion
and prior review history, and fetch only the UC Davis SERG Lab Manual or GitLab
documentation URLs on the built-in allowlist.
It cannot edit files, post comments, push, resolve threads, or merge.
Set `GLA_REVIEW_AGENT=false` to use the prompt-only reviewer.
If the selected endpoint rejects function tools, the job retries prompt-only.
`GLA_MAX_REVIEW_TOOL_ROUNDS` limits exploration (8 by default), and
`GLA_MAX_REVIEW_TOOL_CALLS` limits tool calls in each model response (16 by
default).
Calls beyond either bound receive a bounded error result and cannot execute
repository or network reads.
`GLA_MAX_REVIEW_TOOL_RESULT_CHARS` bounds accumulated tool output across the
review, and `GLA_REVIEW_DEADLINE_SECONDS` leaves cleanup time inside the job's
10-minute timeout.
`GLA_MAX_REVIEW_HISTORY_CHARS` limits historical review context (12,000 by
default).

`CLAUDE_MODEL` remains a compatibility fallback for automatic review, but new
configuration should use `REVIEW_MODEL`.

#### `@claude` response model selection

The `@claude` response workflow continues to use **Claude Sonnet** by default.
To use a different model for a specific request, add `--model <name>` anywhere
in your comment:

```markdown
@claude --model opus refactor this into smaller functions
@claude fix the tests
  --model haiku
```

Supported aliases:

| Alias | Resolves to |
|---|---|
| `sonnet` (default) | `databricks-claude-sonnet-4-6` |
| `opus` | `databricks-claude-opus-4-8` |
| `haiku` | `databricks-claude-haiku-3-5` |

You can also pass a full model name (e.g., `--model databricks-claude-opus-4-8`).

To change the default response model for an entire project, set the
`CLAUDE_MODEL` CI/CD variable in Settings → CI/CD → Variables.

#### The setup guide covers:

- Databricks PAT creation
- GitLab project access token setup
- Pipeline trigger token and webhook configuration
- CI/CD variable configuration
- Troubleshooting and security considerations

## Examples

See `examples/` for complete `.gitlab-ci.yml` files:
- `examples/pak-gitlab-ci.yml` — for repos using pak (like the example)
- `examples/renv-gitlab-ci.yml` — for repos using renv (for example, a consumer repo)

## Migration Guide

To migrate an existing repo:

1. Remove `inst/ci/` scripts from your repo (they now live in gla)
2. Replace your `.gitlab-ci.yml` with the appropriate example
3. Customize variables as needed
4. Commit and push — the pipeline will pull templates from gla

## Reverse Dependencies

See **[REVDEPS.md](REVDEPS.md)** for a list of repos that consume gla
templates. This list helps us notify consumers quickly when we make breaking
changes — but it's advisory, not authoritative. Always verify with a
group-wide search when releasing a breaking change.

**If your repo uses gla**, please open an MR adding it to `REVDEPS.md`
(or file an issue). If you stop using gla, open an MR or issue to be
removed.

## Contributing

Edit templates in `templates/` and scripts in `scripts/`. Changes to `main`
are immediately picked up by repos that reference `ref: main`. For breaking
changes:

1. Merge the breaking change to `main`
2. Create a new major version tag (`git tag -a vN -m "..."` + push)
3. Update [CHANGELOG.md](CHANGELOG.md) with migration instructions
4. Notify consumer repos (see [REVDEPS.md](REVDEPS.md) for known consumers)
5. Update the "Current stable tag" line in this README

## Contributors

- Douglas Ezra Morrison: author and maintainer.
- Matt Ponzini (`mdponzini`): made the code-review size cap a CI/CD variable in `scripts/claude-review.sh` (2026-08-04).
