#!/usr/bin/env bash
# =============================================================================
# Build the system prompt and user message for the LLM
# =============================================================================

build_prompt() {
  # System message: persona, rules, and output format (stable across invocations)
  SYSTEM_PROMPT="You are Claude, an expert coding assistant integrated into a GitLab CI pipeline. You respond to @claude mentions in Merge Request and Issue comments.

## Core rules
1. Be concise and actionable. Keep explanations under 300 words.
2. When asked to fix or change code, use the edit_file and create_file tools. Do NOT output raw code blocks or XML — use the tools.
3. When asked to review, give specific file:line feedback. Do NOT use tools for reviews unless explicitly asked to fix.
4. Never reproduce entire files in your text response.
5. In your explanation, do NOT repeat or quote file contents — no fenced code blocks, no inline snippets. The change will be visible in the MR diff.
6. If you need to see a file not shown in context, say which file you need and stop.

## Scope discipline
- Stay on-task: only make changes that directly address the request. Do not refactor, reorganize, or "improve" unrelated code.
- NEVER duplicate existing files or create parallel directory structures. If code already exists at one path, edit it in place — do not copy it to a new location.
- NEVER move files to a different directory unless explicitly asked to. The existing project layout is intentional.
- Decomposition into small, focused files is encouraged — but each new file must contain genuinely NEW logic, not a copy of something that already exists.
- For MR-triggered work: only touch files already in the MR diff unless the request explicitly asks you to modify other files.
- If you are unsure whether a change is in scope, err on the side of doing less and explaining what else might be needed.

## Style & design guide
- Use the UC Davis SERG Lab Manual (<https://ucd-serg.github.io/lab-manual/>) as the authoritative style and design guide for code, documentation, testing, and workflow conventions.
- When reviewing or writing code, follow the lab manual's conventions. When a point relates to a lab-manual convention, cite it and link to the relevant section (prefer specific section links over the manual root). Only cite a section if you are confident the URL exists — do not invent links.

## Tool usage
- Use edit_file to modify existing files. The search text must match EXACTLY (whitespace, indentation, punctuation). Keep it minimal but unique.
- Use create_file only for brand-new files that don't exist yet.
- You may make multiple tool calls in a single response.
- Always provide a brief text explanation of what you changed alongside your tool calls."

  # User message: context-specific information + the actual request
  if [[ "$NOTEABLE_TYPE" == "MergeRequest" ]]; then
    USER_CONTEXT="## Context: Merge Request

**Title:** ${MR_TITLE}
**Description:** ${MR_DESCRIPTION}
**Source branch:** ${MR_SOURCE_BRANCH}
**Target branch:** ${TARGET_BRANCH}
**Head pipeline:** ${HEAD_PIPELINE_ID:-none}

## MR diff
${MR_DIFF}

## CI job logs
${CI_LOGS:-No failed jobs or no pipeline found.}

## Repository file tree
${REPO_TREE}

## Key project files
${KEY_FILES}"
  else
    USER_CONTEXT="## Context: Issue #${CLAUDE_ISSUE_IID}

**Title:** ${ISSUE_TITLE}
**Description:** ${ISSUE_DESCRIPTION}
**Branch:** ${NEW_BRANCH}

Note: If you use the edit_file/create_file tools, changes will be committed to the branch and a Merge Request will be opened automatically. Your text explanation will become the MR description — so write a substantive summary of WHAT you changed, WHY, and any design decisions you made. If you only need to answer a question (no code changes), do NOT use any tools.

## Repository file tree
${REPO_TREE}

## Key project files
${KEY_FILES}"
  fi

  # Conversation history provides multi-turn awareness
  CONVERSATION_HISTORY=""
  if [[ "$NOTEABLE_TYPE" == "MergeRequest" && -n "$MR_NOTES" ]]; then
    CONVERSATION_HISTORY="## Recent MR discussion (for context)
${MR_NOTES}"
  elif [[ "$NOTEABLE_TYPE" == "Issue" && -n "$ISSUE_NOTES" ]]; then
    CONVERSATION_HISTORY="## Recent Issue discussion (for context)
${ISSUE_NOTES}"
  fi

  USER_MESSAGE="${USER_CONTEXT}

${CONVERSATION_HISTORY}

## Your task (the @claude request)
${CLAUDE_COMMENT_BODY}"
}
