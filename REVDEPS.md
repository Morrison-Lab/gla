# Reverse Dependencies (Consumer Repos)

Repos that include gla templates in their `.gitlab-ci.yml`.

> **Note:** This list helps us notify consumers of breaking changes faster.
> It is not authoritative — always verify with a group-wide search
> (`glab api` or GitLab search) when releasing a breaking change.

## How to register

If your repo uses gla, please open an MR adding it below (or file an
issue asking to be added). Similarly, if you stop using gla, open an MR
or issue to be removed.

## Consumer list

| Repo | Templates used | Notes |
|------|---------------|-------|
| [`morri313/mlg`](https://gitlab.cs.wwu.edu/morri313/mlg) (mirror of `Morrison-Lab/mlg`) | `workflow.yml`, `check-new-line-breaks.yml` | Includes from `morri313/gla` at `main` |
