# Agent notes for gla

Working facts for anyone (human or `@claude`) developing this repo itself.

## Known gotchas

- **Reviewer-assignment API**: `glab api -X PUT "projects/<project-id>/merge_requests/<mr-iid>" -f "reviewer_ids=<reviewer-id>"`.
  Use `reviewer_ids=<reviewer-id>` with no brackets; `reviewer_ids[]=<reviewer-id>` returns
  HTTP 400.
- **`.gitlab/scripts/` pollution**: `git add -A` in `commit-push.sh`,
  `git-push-issue.sh`, and `apply-changes.sh` used to stage this repo's own
  vendored runtime scripts (fetched into `.gitlab/scripts/` by `before_script`)
  alongside LLM edits.
  Fixed by scoping to `git add -A -- . ':!.gitlab/scripts'` at all three
  call sites.
- **`claude-review` CI timing**: the review job runs on push, before the MR
  exists.
  When the MR is opened after the push, the job finds no open MR and skips.
  Mitigation: post a self-review manually as an MR comment.
- **GitHub Actions review**: pull requests on GitHub are reviewed by
  `.github/workflows/claude-review.yml`, a caller of `Morrison-Lab/gha`;
  a trusted author's `/review` comment re-runs it.
  This is separate from the GitLab `claude-review` job above.
