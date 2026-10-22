#!/usr/bin/env bash
# =============================================================================
# Logging helpers with GitLab CI collapsible sections
# =============================================================================

CURRENT_SECTION=""

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# log_step: opens a new collapsible section in GitLab CI job logs.
# Each section is auto-closed when the next one opens (or at script end).
log_step() {
  local section_name
  section_name=$(echo "$1" | tr '[:upper:] ' '[:lower:]_')
  # Close previous section if one is open
  if [[ -n "$CURRENT_SECTION" ]]; then
    echo -e "\e[0Ksection_end:$(date +%s):${CURRENT_SECTION}\r\e[0K"
  fi
  CURRENT_SECTION="$section_name"
  echo -e "\e[0Ksection_start:$(date +%s):${section_name}[collapsed=false]\r\e[0K\e[36;1m=== [$1] $(date '+%H:%M:%S') ===\e[0m"
}

log_error() { echo "[$(date '+%H:%M:%S')] ❌ ERROR: $*" >&2; }

# Close any open section on exit
close_sections() {
  if [[ -n "$CURRENT_SECTION" ]]; then
    echo -e "\e[0Ksection_end:$(date +%s):${CURRENT_SECTION}\r\e[0K"
    CURRENT_SECTION=""
  fi
}
