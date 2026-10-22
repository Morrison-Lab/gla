#!/usr/bin/env bash
# =============================================================================
# Fetch SERG Lab Manual content for LLM context
# =============================================================================
# Pre-fetches key lab manual pages at CI time and converts them to plain text.
# This gives the reviewer/responder ground-truth content so it can cite specific
# conventions without hallucinating URLs or section names.
#
# Usage:
#   source scripts/lib/lab-manual.sh
#   fetch_lab_manual          # populates $LAB_MANUAL_CONTENT
#   fetch_lab_manual "coding-style.html coding-practices.html"  # specific pages
# =============================================================================

# Fallback if logging.sh isn't sourced (makes standalone usage work under set -e)
type log &>/dev/null || log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Base URL for the lab manual site. Consumers can point this at their own
# manual without changing the shared script.
LAB_MANUAL_BASE_URL="${GLA_LAB_MANUAL_BASE_URL:-https://ucd-serg.github.io/lab-manual}"

# Default pages to fetch when no diff-aware selection is possible.
LAB_MANUAL_DEFAULT_PAGES="${GLA_LAB_MANUAL_DEFAULT_PAGES:-coding-style.html coding-practices.html}"

# Pages included for every diff-aware selection. Keep the SERG default for the
# existing manual, but do not force it on consumers using another manual.
if [[ -n "${GLA_LAB_MANUAL_ALWAYS_PAGES+x}" ]]; then
  LAB_MANUAL_ALWAYS_PAGES="$GLA_LAB_MANUAL_ALWAYS_PAGES"
elif [[ "$LAB_MANUAL_BASE_URL" == "https://ucd-serg.github.io/lab-manual" ]]; then
  LAB_MANUAL_ALWAYS_PAGES="coding-practices.html"
else
  LAB_MANUAL_ALWAYS_PAGES=""
fi

# Attribution shown in the assembled prompt context.
LAB_MANUAL_NAME="${GLA_LAB_MANUAL_NAME:-SERG Lab Manual}"

# Space-separated glob|page rules used for diff-aware selection. Consumers can
# replace this map when their manual uses different page names.
if [[ -n "${GLA_LAB_MANUAL_PAGE_MAP+x}" ]]; then
  LAB_MANUAL_PAGE_MAP="$GLA_LAB_MANUAL_PAGE_MAP"
else
  LAB_MANUAL_PAGE_MAP="*.R|coding-style.html *.r|coding-style.html *.Rmd|coding-style.html *.rmd|coding-style.html *.qmd|coding-style.html *.Rnw|coding-style.html *.yml|continuous-integration.html *.yaml|continuous-integration.html .gitlab-ci*|continuous-integration.html .github/*|continuous-integration.html renv.lock|reproducible-environments.html renv/*|reproducible-environments.html DESCRIPTION|reproducible-environments.html requirements.txt|reproducible-environments.html Pipfile*|reproducible-environments.html *.lock|reproducible-environments.html Dockerfile*|reproducible-environments.html *.md|writing.html vignettes/*|writing.html .gitignore|code-repositories.html .gitattributes|code-repositories.html"
fi

# All page slugs referenced in _select_pages_for_diff have been verified to
# return HTTP 200 on the live site (last verified: 2026-06-16). If a slug 404s,
# curl -f ensures graceful degradation (empty output, skipped with a warning).
# To re-verify after a lab manual restructure:
#   for slug in coding-style coding-practices continuous-integration \
#     reproducible-environments writing code-repositories; do
#     curl -sL -o /dev/null -w "%{http_code} $slug\n" "$LAB_MANUAL_BASE_URL/${slug}.html"
#   done

# ---------------------------------------------------------------------------
# _select_pages_for_diff: Choose lab manual pages based on changed files.
# Reads a newline-separated list of paths from $1.
# Prints a deduplicated newline-separated list of page filenames to stdout.
# Compatible with Bash 3.2+ (no associative arrays).
# ---------------------------------------------------------------------------
_select_pages_for_diff() {
  local files="${1:-}"
  local selected=""

  # Always include coding-practices (universal: naming, structure, design)
  selected=""
  if [[ -n "$LAB_MANUAL_ALWAYS_PAGES" ]]; then
    # Split the documented space-separated value into one page per line.
    selected=$(printf '%s\n' $LAB_MANUAL_ALWAYS_PAGES)
  fi

  # Note: this function is only called when $files is non-empty (fetch_lab_manual
  # falls back to LAB_MANUAL_DEFAULT_PAGES directly when CHANGED_FILES is unset).

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    while IFS= read -r rule; do
      [[ -z "$rule" ]] && continue
      local pattern="${rule%%|*}"
      local page="${rule#*|}"
      if [[ "$f" == $pattern ]]; then
        selected="${selected}"$'\n'"$page"
        break
      fi
    done <<< "${LAB_MANUAL_PAGE_MAP// /$'\n'}"
  done <<< "$files"

  # Deduplicate and output
  echo "$selected" | sort -u | grep -v '^$'
}

# Maximum total bytes of lab manual content to include in prompt.
# This prevents prompt bloat if pages are unexpectedly large.
MAX_LAB_MANUAL_BYTES="${GLA_MAX_LAB_MANUAL_BYTES:-${MAX_LAB_MANUAL_BYTES:-40000}}"

# Write complete UTF-8 lines whose byte total does not exceed the requested cap.
# LC_ALL=C makes awk's length byte-based while preserving the original UTF-8
# bytes; stopping before a partial line avoids splitting a multibyte sequence.
truncate_utf8_lines() {
  local input_file="$1"
  local output_file="$2"
  local byte_cap="$3"
  LC_ALL=C awk -v max="$byte_cap" '
    {
      line = $0 ORS
      if (used + length(line) > max) exit
      printf "%s", line
      used += length(line)
    }
  ' "$input_file" > "$output_file"
}

# ---------------------------------------------------------------------------
# _html_to_text: Strip HTML tags and collapse whitespace.
# Lightweight — no dependency on pandoc/lynx/w3m.
# ---------------------------------------------------------------------------
# NOTE: Range deletes (/<tag/,/<\/tag>/d) assume tags are on separate lines.
# Quarto output is mostly line-separated, but minified HTML could cause
# incomplete stripping. Acceptable for best-effort context extraction.
# ---------------------------------------------------------------------------
_html_to_text() {
  sed -E '
    # Remove script and style blocks
    /<script/,/<\/script>/d
    /<style/,/<\/style>/d
    # Remove nav, header, footer blocks (Quarto boilerplate)
    /<nav /,/<\/nav>/d
    /<header /,/<\/header>/d
    /<footer /,/<\/footer>/d
    # Remove HTML tags
    s/<[^>]*>//g
    # Decode common HTML entities.
    # Note: &amp; is decoded first, so a literal &amp;lt; in source would
    # double-decode to <. This is unlikely in Quarto output and acceptable
    # for best-effort context extraction.
    s/&amp;/\&/g
    s/&lt;/</g
    s/&gt;/>/g
    s/&quot;/"/g
    s/&#39;/'"'"'/g
    s/&nbsp;/ /g
    # Collapse multiple blank lines
    /^[[:space:]]*$/d
  ' | sed '/^$/N;/^\n$/d'
}

# ---------------------------------------------------------------------------
# fetch_lab_manual: Fetch pages and populate LAB_MANUAL_CONTENT
#
# Usage:
#   fetch_lab_manual                     # diff-aware if $CHANGED_FILES is set
#   fetch_lab_manual "page1.html page2.html"  # explicit page list
# ---------------------------------------------------------------------------
fetch_lab_manual() {
  local pages=()
  local total_bytes=0
  local page_text page_url page_name

  LAB_MANUAL_CONTENT=""

  # Determine which pages to fetch
  if [[ $# -gt 0 && -n "$1" ]]; then
    # Explicit page list provided
    read -ra pages <<< "$1"
  elif [[ -n "${CHANGED_FILES:-}" ]]; then
    # Diff-aware: select pages based on what files changed
    while IFS= read -r _p; do
      [[ -n "$_p" ]] && pages+=("$_p")
    done < <(_select_pages_for_diff "$CHANGED_FILES")
  else
    # Fallback to defaults
    read -r -a pages <<< "$LAB_MANUAL_DEFAULT_PAGES"
  fi

  # If diff-aware selection yielded nothing (e.g., only unrecognized file types),
  # fall back to defaults so the reviewer always gets some context.
  if [[ ${#pages[@]} -eq 0 ]]; then
    read -r -a pages <<< "$LAB_MANUAL_DEFAULT_PAGES"
  fi

  log "Fetching ${#pages[@]} lab manual page(s)..."

  for page_name in "${pages[@]}"; do
    page_url="${LAB_MANUAL_BASE_URL}/${page_name}"

    # Fetch with timeout; skip on failure (non-critical).
    # Use -f (--fail) so HTTP errors (404, 500) yield empty output rather than
    # injecting an error page as if it were authoritative lab manual content.
    # Use intermediate variable to avoid set -e / pipefail interaction with $().
    local raw_html=""
    raw_html=$(curl -sfL --max-time 10 "$page_url" 2>/dev/null) || raw_html=""
    page_text=""
    if [[ -n "$raw_html" ]]; then
      page_text=$(printf '%s' "$raw_html" | _html_to_text) || page_text=""
    fi

    if [[ -z "$page_text" ]]; then
      log "  ⚠ Could not fetch: $page_url (skipping)"
      continue
    fi

    # Check byte budget. We measure the full assembled chunk (header + text +
    # separator). The overhead estimate is approximate (±10 bytes from actual
    # newline usage), which is acceptable for a soft guardrail.
    local section_header="### ${page_name%.html} (${page_url})"
    local separator="---"
    # Overhead: header + newlines + separator (approximate)
    local overhead=$(( ${#section_header} + ${#separator} + 10 ))
    local page_bytes
    page_bytes=$(printf '%s' "$page_text" | wc -c | tr -d ' ')
    local chunk_bytes=$(( page_bytes + overhead ))

    if (( total_bytes + chunk_bytes > MAX_LAB_MANUAL_BYTES )); then
      # Truncate this page to fit remaining budget without splitting a UTF-8
      # sequence or emitting a partial line.
      local remaining=$(( MAX_LAB_MANUAL_BYTES - total_bytes - overhead ))
      # Reserve space for the truncation suffix (use wc -c for byte-accurate
      # accounting, consistent with the rest of this function).
      local suffix="... [truncated — full page at ${page_url}]"
      local suffix_bytes
      suffix_bytes=$(printf '%s' "$suffix" | wc -c | tr -d ' ')
      remaining=$(( remaining - suffix_bytes - 1 ))  # -1 for newline before suffix
      if (( remaining > 500 )); then
        local page_source page_truncated
        page_source=$(mktemp)
        page_truncated=$(mktemp)
        printf '%s' "$page_text" > "$page_source"
        truncate_utf8_lines "$page_source" "$page_truncated" "$remaining"
        page_text=$(cat "$page_truncated")
        rm -f "$page_source" "$page_truncated"
        page_text="${page_text}
${suffix}"
        # Recompute page_bytes after truncation
        page_bytes=$(printf '%s' "$page_text" | wc -c | tr -d ' ')
      else
        log "  ⚠ Lab manual byte budget reached; skipping remaining pages."
        break
      fi
    fi

    # Append with clear section header
    LAB_MANUAL_CONTENT+="
${section_header}

${page_text}

${separator}
"
    # Use byte count (not character count) for accurate budget tracking
    total_bytes=$(( total_bytes + page_bytes + overhead ))
    log "  ✓ ${page_name} (${page_bytes} bytes)"
  done

  if [[ -n "$LAB_MANUAL_CONTENT" ]]; then
    LAB_MANUAL_CONTENT="## ${LAB_MANUAL_NAME} Reference (fetched at CI time)

The following is the actual content of key lab manual pages. Use this as
ground truth when citing conventions. Link to the URL shown in each header.

${LAB_MANUAL_CONTENT}"
    log "Lab manual context: $(printf '%s' "$LAB_MANUAL_CONTENT" | wc -c | tr -d ' ') total bytes"
  else
    log "  ⚠ No lab manual content fetched; review will proceed without it."
  fi
}

# ---------------------------------------------------------------------------
# fetch_lab_manual_safe: Wrapper that calls fetch_lab_manual with errexit
# disabled. Lab manual content is non-critical — a fetch failure should never
# abort the calling script. Centralizes the save/restore pattern in one place.
# ---------------------------------------------------------------------------
fetch_lab_manual_safe() {
  local _state
  case $- in *e*) _state=on ;; *) _state=off ;; esac
  set +e
  fetch_lab_manual "$@"
  [[ "$_state" == on ]] && set -e
  return 0
}
