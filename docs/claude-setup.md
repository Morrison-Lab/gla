# AI Review and Claude Agent Setup Guide

This guide walks you through enabling the `claude.yml` template in your GitLab
project. Once set up, you get:

- **GPT-5.6 code review** on every push to an MR branch, with optional Claude review
- **@claude mentions** in MR and issue comments — ask Claude to review, fix, or
  implement changes

If you push a branch before opening its merge request, that first pipeline does
not run the automatic review because GitLab has not created an MR for the
branch yet.
Open the MR, then push a follow-up commit (even a documentation adjustment) to
trigger the review.
Subsequent pushes to an existing MR branch are reviewed automatically.

**No external server needed** — this uses GitLab's built-in webhook-to-trigger
URL to pass comment payloads directly into a CI job. LLM calls are routed
through **Databricks Foundation Models**.

> **Background:** GitLab does not yet have a native
> `CI_PIPELINE_SOURCE == "comment"` event like GitHub's `issue_comment` trigger.
> This is tracked in
> [gitlab-org/gitlab#553940](https://gitlab.com/gitlab-org/gitlab/-/work_items/553940).
> Until that ships, the workaround is a **webhook + Pipeline Triggers API**,
> which is what this setup implements.

---

## Architecture

```
MR Comment containing "@claude"
  → GitLab Webhook (Note event)
    → GitLab Pipeline Triggers API (built-in webhook URL format)
      → claude-respond CI job
        → Parses $TRIGGER_PAYLOAD for @claude mention
          → Calls Databricks Claude endpoint
            → Posts response as MR comment
            → Optionally commits and pushes code changes
```

**How it works:** GitLab supports a special webhook URL format that points
directly at the Pipeline Triggers API. When a Note event fires, GitLab POSTs
the webhook payload to this URL, which creates a pipeline. The full webhook
JSON is available inside the CI job as the file-type variable `$TRIGGER_PAYLOAD`.
The job reads this file, checks if it's an MR/issue comment mentioning `@claude`,
and either processes the request or exits early (~5 seconds).

**Trade-off:** Every comment in the project triggers a short pipeline.
Non-`@claude` comments exit in seconds, but you'll see these in your CI history.

---

## Prerequisites

- A GitLab project on `gitlab.example.com` running **GitLab 17.3+**
  (the CI/CD job-token allowlist UI required for cross-project access is
  available in this version range)
- A [Databricks Personal Access Token](https://<workspace>.cloud.databricks.com/)
  with access to Foundation Model serving endpoints
- A GitLab runner with Docker support (or a shared runner)

---

## Setup Instructions

### Step 1: Get Your Databricks Personal Access Token (PAT)

The PAT authenticates against the Databricks Foundation Model serving endpoints.

1. Sign in to your Databricks workspace:
   <https://<workspace>.cloud.databricks.com/>
2. Click your user icon (top-right) → **Settings**
3. Go to **Developer → Access tokens → Manage**
4. Click **"Generate new token"**
5. Enter a description (e.g., `GitLab Claude Bot`) and a lifetime (e.g., 90 days)
6. **Scope:** If your workspace shows a scope picker, select **Other APIs** and
   add the **`ai-gateway`** and **`model-server`** scopes (these grant access to
   Foundation Model serving endpoints via the AI Gateway). If no scope picker
   appears, the token is unscoped and has full workspace access by default —
   this works fine. You can verify available scopes in your workspace under
   **Settings → Developer → Access tokens → Generate new token**.
7. Click **Generate** and copy the token immediately — it is shown only once
8. Save it securely; you'll add it as a CI/CD variable in Step 4

> **Tip:** Confirm the model you plan to use (e.g., `databricks-gpt-5-6-sol`)
> is available under **Serving → Serving endpoints** in your workspace.

---

### Step 2: Create a GitLab Project Access Token

This token allows the CI job to read MR data, post comments, and push commits.

1. In your GitLab project, go to **Settings → Access Tokens**
2. Click **"Add new token"**
3. Configure:
   - **Token name:** `claude-bot`
   - **Expiration date:** Set a reasonable expiry (e.g., 1 year)
   - **Role:** `Developer` (needs push access to MR branches)
   - **Scopes:** Check **`api`** and **`write_repository`**
     (`api` covers reading MRs and posting notes; `write_repository` is required
     so the bot can push commits to MR branches)
4. Click **"Create project access token"**
5. Copy the token immediately — you won't see it again
6. Save it securely; you'll add it as a CI/CD variable in Step 4

> **Alternative:** You can use a Personal Access Token instead, but a Project
> Access Token is preferred because it's scoped to this project only and can be
> revoked independently.

The project access token is used for API requests and pushes **inside the
consumer project**.
It is not needed to download the shared HACtions scripts.

### Step 2a: Allow the consumer project to fetch HACtions scripts

HACtions is private, so a HACtions Maintainer must add the consumer project to
HACtions' CI/CD job token allowlist:

1. In the HACtions project, go to **Settings → CI/CD**.
2. Expand **Job token permissions** (**Token Access** on older GitLab
   versions).
3. Under **CI/CD job token allowlist**, select **Add**, then add the consumer
   project.

The `claude.yml` template then fetches scripts with the consumer job's
`CI_JOB_TOKEN` using GitLab's `JOB-TOKEN` header.
GitLab documents this raw repository-file endpoint and the allowlist requirement in its
[CI/CD job token documentation](https://docs.gitlab.com/ci/jobs/ci_job_token/).
The user associated with the pipeline must also have sufficient access to the
private HACtions project.
This includes the identity associated with a scheduled or trigger-created
pipeline, not only the person who configured the consumer repository.
The template retains a `GITLAB_TOKEN` fallback so existing consumers continue
to work while they are migrated.

---

### Step 3: Create a Pipeline Trigger Token

This token allows the webhook to start pipelines via the API.

1. In your GitLab project, go to **Settings → CI/CD**
2. Expand the **"Pipeline trigger tokens"** section
3. Click **"Add new token"** (or "Add trigger" on older GitLab versions)
4. Enter a description: `Claude webhook trigger`
5. Click **"Create pipeline trigger token"**
6. Copy the token value — you'll need it for the webhook URL in Step 5
7. Note your **Project ID** (visible at the top of the project's main page, or
   in Settings → General)

---

### Step 4: Add CI/CD Variables

1. In your GitLab project, go to **Settings → CI/CD**
2. Expand the **"Variables"** section
3. Add each variable below by clicking **"Add variable"**:

| Variable | Value | Type | Protected | Masked | Expanded |
|----------|-------|------|-----------|--------|----------|
| `ANTHROPIC_API_KEY` | Databricks PAT (from Step 1) | Variable | ✅ | ✅ | ❌ |
| `ANTHROPIC_BASE_URL` | `https://<workspace>.cloud.databricks.com/serving-endpoints` | Variable | ✅ | ❌ | ❌ |
| `GITLAB_TOKEN` | Project access token (from Step 2) — used for API requests and pushes in this project; needs `api` + `write_repository` scopes | Variable | ✅ | ✅ | ❌ |
| `CLAUDE_TRIGGER_TOKEN` | Pipeline trigger token (from Step 3) — enables self-iteration | Variable | ✅ | ✅ | ❌ |

The automatic reviewer uses `databricks-gpt-5-6-sol` by default. These optional
variables control reviewer selection:

| Mode | Variables |
|------|-----------|
| GPT only (default) | No additional variables |
| Claude only | `REVIEW_MODEL=databricks-claude-sonnet-4-6` |
| GPT + Claude | `HAC_CLAUDE_COMPANION_REVIEW=true` |
| Another primary model | `REVIEW_MODEL=<Databricks endpoint name>` |

`CLAUDE_MODEL` still controls the default model for `@claude` responses. It is
also a deprecated fallback for automatic review when `REVIEW_MODEL` is unset.

For each variable:
- **Protected:** Yes — ensures the variable is only available on protected
  branches/tags
- **Masked:** Yes (where indicated) — prevents the value from appearing in job
  logs
- **Expanded:** No — prevents GitLab from interpreting `$` characters in the
  value

> **Important:** If your default branch (e.g., `main`) is not marked as
> protected, either protect it (**Settings → Repository → Branch rules**, or
> **Settings → Repository → Protected branches** on older GitLab versions) or
> uncheck "Protected" on the variables. The `claude-respond` job triggers on the
> default branch, so the variables must be available there.

---

### Step 5: Configure the GitLab Webhook

This is the key step. You'll point a webhook directly at the Pipeline Triggers
API — no external server needed.

1. In your GitLab project, go to **Settings → Webhooks**
2. Click **"Add new webhook"**
3. Fill in the form:
   - **URL:** Use this format (replace the placeholders):
     ```
     https://gitlab.example.com/api/v4/projects/<PROJECT_ID>/ref/<DEFAULT_BRANCH>/trigger/pipeline?token=<TRIGGER_TOKEN>
     ```
     For example:
     ```
     https://gitlab.example.com/api/v4/projects/12345/ref/main/trigger/pipeline?token=glptt-abc123def456
     ```
     - Replace `<PROJECT_ID>` with your numeric project ID (from Step 3)
     - Replace `<DEFAULT_BRANCH>` with `main` (or your default branch)
     - Replace `<TRIGGER_TOKEN>` with the pipeline trigger token (from Step 3)
   - **Secret token:** (optional) The trigger token in the URL already
     authenticates the request
   - **Trigger events:** Uncheck everything, then check only **"Comments"**
     (This fires when comments are posted on MRs, issues, commits, and snippets.
     The CI job filters to MR/issue comments containing `@claude`.)
   - **SSL verification:** Enable (GitLab's own API always has valid TLS)
4. Click **"Add webhook"**

---

### Step 6: Include the Template in Your `.gitlab-ci.yml`

Add `claude.yml` to your `include:` list and the `claude` stage:

```yaml
include:
  - project: 'example-group/HACtions'
    ref: main
    file:
      - '/templates/claude.yml'
      # ... other templates you use

stages:
  # ... your existing stages ...
  - claude
```

The template defines two hidden jobs (`.hac-claude-review` and
`.hac-claude-respond`) that extend into real jobs automatically. No additional
job definitions needed.

### Optional: experimental Claude Code agent review

To trial a read-only agent harness alongside the direct reviewer, add
`/templates/agent-review.yml` to the `include:` list and set
`HAC_AGENT_REVIEW_ENABLED=true`.
This does not replace `claude-review`.

The agent job installs the pinned Claude Code CLI and a commit-pinned native
`ai-config` plugin checkout, then permits only local read tools.
It supplies the bounded MR diff directly and permits no shell tool.
It posts the final review text through its outer CI job.
Restricted mode ignores repository settings and strict MCP configuration
prevents merge-request-supplied MCP servers.
The agent never receives GitLab job credentials or a write-capable shell.
The outer job stages a clean tracked-file snapshot of the reviewed commit,
confines `Read`, `Glob`, and `Grep` to that workspace, and runs Claude Code
under an unprivileged UID behind a root-owned loopback gateway proxy so
neither GitLab credentials nor the real gateway token enter the agent's
process environment.
It binds the review to the merge request's current head and merge base.
It drops output if the head advances before posting.

Configure these additional variables as protected and masked where applicable:

| Variable | Value | Type | Protected | Masked | Expanded |
|----------|-------|------|-----------|--------|----------|
| `HAC_AGENT_REVIEW_ENABLED` | `true` | Variable | ❌ | ❌ | ❌ |
| `HAC_AGENT_REVIEW_MODEL` | Model identifier exposed by the agent gateway | Variable | ❌ | ❌ | ❌ |
| `HAC_AGENT_REVIEW_BASE_URL` | Anthropic-compatible gateway base URL | Variable | ✅ | ❌ | ❌ |
| `HAC_AGENT_REVIEW_AUTH_TOKEN` | Gateway token | Variable | ✅ | ✅ | ❌ |

The job deliberately runs only for protected source branches with an open merge
request.
Protect the source-branch pattern used for agent-reviewed work before enabling
`HAC_AGENT_REVIEW_ENABLED`.
Do not make the gateway token unprotected to run the job on ordinary feature
branches.

`HAC_AGENT_REVIEW_BASE_URL` is deliberately separate from `ANTHROPIC_BASE_URL`.
The latter is the direct Databricks serving-endpoint URL for
`claude-review.sh`; it has not been established as Claude Code-compatible.
Validate the gateway in a non-PHI test project before enabling the job for
production repositories.

---

### Step 7: Verify the Full Pipeline

1. Create a new branch and open a merge request with a small change
2. **Test auto-review:** Push a commit to the MR branch — the `claude-review`
    job should run and post a GPT-5.6 review comment on the MR. If companion
    review is enabled, `claude-companion-review` should post a separate Claude
    review after the primary job releases the shared resource group.
3. **Test @claude respond:** In the MR, post a comment:
   ```
   @claude please review this merge request and suggest improvements
   ```
4. Watch for:
   - **GitLab CI/CD → Pipelines:** A new pipeline should appear with source
     "trigger"
   - **The `claude-respond` job:** Should run, parse the payload, find `@claude`,
     and post a comment back on the MR
5. If Claude makes code changes, you'll see a new commit pushed to the MR branch

---

## Troubleshooting

### Pipeline not triggering

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No pipeline appears after commenting | Webhook not firing | Check Settings → Webhooks → "Recent events" for delivery status |
| Webhook shows 4xx error | Trigger token invalid or project ID wrong | Double-check the URL: project ID, branch name, and token |
| Webhook shows 400 | Default branch name wrong in URL | Verify the `ref` in the URL matches your actual default branch |
| Pipeline runs but `claude-respond` doesn't appear | Rule not matching | Ensure `.gitlab-ci.yml` on the default branch includes `claude.yml` and has the `claude` stage |

### Job fails

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| "No TRIGGER_PAYLOAD file found" | Pipeline not triggered via webhook URL | Ensure the webhook URL uses the `/ref/.../trigger/pipeline` format |
| "401 Unauthorized" from GitLab API | `GITLAB_TOKEN` invalid or expired | Regenerate the project access token (Step 2) |
| "404 Not Found" fetching a script from HACtions | Consumer project is not on HACtions' CI/CD job token allowlist, or the pipeline-associated user lacks access to HACtions | Have a HACtions Maintainer add the project under **Settings → CI/CD → Job token permissions** (**Token Access** on older versions) and verify the pipeline identity's access (Step 2a) |
| "401" from Databricks/Anthropic | `ANTHROPIC_API_KEY` (Databricks PAT) invalid or expired | Regenerate the PAT in Databricks (Step 1) |
| "404" or model not found | `ANTHROPIC_BASE_URL` wrong or model not enabled | Verify the URL ends in `/serving-endpoints` and the model exists in your workspace |
| `git push` fails | Token lacks push permission | Ensure the project access token has `write_repository` scope and Developer role |
| Job times out (15 min) | Claude response too long | Increase timeout or simplify the request |

### Bot posts a comment but doesn't push commits

Check the CI job logs for these step markers:

1. **`=== [APPLYING FILE CHANGES] ===`** — Did the model output `<FILE>` blocks?
   - If you see "No file changes in response", the model only reviewed (didn't
     produce code). Try rephrasing: `@claude fix the linting errors` instead of
     `@claude review`.
2. **`=== [COMMIT & PUSH] ===`** — Did the push succeed?
   - If you see "Push FAILED", check the error message (usually token
     permissions).
   - The project access token needs **`write_repository`** scope (not just `api`).
   - If the MR source branch is protected, the token's role must be Maintainer.

### Bot pushed once but won't iterate on follow-up comments

The bot only responds to **webhook-triggered** pipelines
(`CI_PIPELINE_SOURCE == "trigger"`). When the bot pushes a commit, that creates
a regular `push`-sourced pipeline — the `claude-respond` job correctly skips it
to prevent infinite loops.

**To get the bot to iterate automatically**, set up self-iteration:

1. Add `CLAUDE_TRIGGER_TOKEN` as a CI/CD variable (same value as the pipeline
   trigger token from Step 3)
2. The bot will now: push fix → wait for CI → if CI fails → re-trigger itself
   (up to 3 iterations)

**Without self-iteration**, you must post a new `@claude` comment after each
push to get the bot to look at the new CI results.

### Webhook health check

To verify the webhook is working:

1. Go to **Settings → Webhooks**
2. Find the Claude webhook and click **"Edit"**
3. Scroll to **"Recent events"** (or "Recent deliveries")
4. Check for:
   - **200 responses** = webhook is firing and pipeline is being created
   - **4xx responses** = trigger token or project ID is wrong
   - **No events** = the webhook trigger filter doesn't match (ensure "Comments"
     is checked)
5. You can also click **"Test"** → **"Comments"** (labeled **"Note events"** on
   older GitLab versions) to fire a test delivery

### Infinite loop (Claude responding to itself)

The CI job ignores comments from users with "bot" or "claude" in their username.
If your project access token creates a user with a different name, set the
`CLAUDE_BOT_USERNAME` CI/CD variable to the username the token posts as.

Additionally, comments posted via the API (which is how the job responds) do
**not** trigger webhooks in GitLab, so loops shouldn't occur in practice.

### Reserved label namespace: `wip:`

The advisory concurrency system uses labels prefixed with `wip:` to signal
active work on an MR. **Do not** create labels starting with `wip:` for
unrelated purposes — the bot treats any `wip:`-prefixed label as a concurrency
lock and will skip auto-triggering when one is present.

Reserved labels:
- `wip:ci-bot` — set automatically by the respond job while it is active
- `wip:human` — set manually to block the bot while you work on an MR

Any other `wip:*` label will also block the bot. See `docs/adr-wip-lock.md`
for the full design rationale.

---

## How It Works (Step by Step)

1. **Comment posted:** Someone posts a comment on an MR or issue.

2. **Webhook fires:** GitLab sends the Note event payload directly to the
   Pipeline Triggers API URL. This creates a new pipeline on the default branch.

3. **Payload available:** The full webhook JSON is stored as a temporary file.
   The CI job reads it via the `$TRIGGER_PAYLOAD` file-type variable.

4. **CI job filters:** The `claude-respond` job:
   - Reads `$TRIGGER_PAYLOAD`
   - Checks `noteable_type == "MergeRequest"` or `"Issue"`
   - Checks the comment body for `@claude` (exits early if not found)
   - Checks the author isn't a bot (prevents infinite loops)
   - Extracts the MR IID or Issue IID and comment text

5. **Claude processes the request:**
   - Checks out the MR source branch (or creates an issue branch)
   - Fetches MR/issue metadata, full diff, and CI logs via the GitLab API
   - Constructs a prompt with all context
   - Calls the Databricks Claude endpoint
   - Posts Claude's response as a new comment
   - If Claude produced file changes, commits and pushes them

6. **Auto-review (on push):** The `claude-review` job runs on every push to an
   MR branch, reviews the full MR diff, and posts findings as a comment.

---

## Security Considerations

- **Data handling:** All LLM calls are routed through Databricks Foundation
  Models. Prompts and responses stay within the approved environment.
- **Trigger token in URL:** The pipeline trigger token in the webhook URL
  authenticates requests. Keep it confidential. If compromised, revoke it
  (Settings → CI/CD → Pipeline triggers) and create a new one.
- **Bot loop prevention:** The CI job ignores comments from users with "bot" or
  "claude" in their username. Comments posted via the API don't trigger webhooks,
  providing a second layer of protection.
- **Token scoping:** Use a Project Access Token (not a Personal Access Token) so
  GitLab access is limited to this project only. The Databricks PAT is scoped to
  your workspace identity.
- **Protected variables:** Mark all secrets as Protected and Masked in CI/CD
  settings to prevent exposure in logs or to unprotected branches.
- **Timeout:** The 15-minute job timeout prevents runaway executions.

---

## Customization

### Adding a system prompt / project instructions

Create a `CLAUDE.md` file in your repo root. The respond script reads this file
and includes it in the prompt context automatically.

```markdown
# Project Context

This is an R package. When reviewing code:
- Follow tidyverse style guide
- Ensure all exported functions have roxygen2 documentation
- Check that tests cover new functionality
```

### Overriding scripts locally

If you need to customize the Claude scripts for your project, place your own
copies at:

- `.gitlab/scripts/claude-review.sh`
- `.gitlab/scripts/claude-respond.sh`

The template checks for local copies first and only fetches from HACtions if
they don't exist.

### Restricting who can trigger Claude

Add a `CLAUDE_BOT_USERNAME` CI/CD variable to prevent the bot from responding
to its own comments (if the project access token username doesn't contain "bot"
or "claude").

For an allowlist approach, override `claude-respond.sh` locally and add a check
after extracting `COMMENT_AUTHOR`:

```bash
ALLOWED_USERS="your-username teammate1 teammate2"
if ! echo "$ALLOWED_USERS" | grep -qw "$COMMENT_AUTHOR"; then
  echo "User $COMMENT_AUTHOR not in allowlist — skipping."
  exit 0
fi
```

---

## Future: Native Comment-Triggered Pipelines

GitLab is tracking native support for comment-triggered pipelines in
[gitlab-org/gitlab#553940](https://gitlab.com/gitlab-org/gitlab/-/work_items/553940).
The proposed syntax would be:

```yaml
claude-respond:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "comment" && $CI_COMMENT_TEXT =~ /@claude/'
```

When this ships, you can remove the webhook entirely and use the native rule.
The CI job script would remain largely the same — just read `$CI_COMMENT_TEXT`
instead of parsing `$TRIGGER_PAYLOAD`.
