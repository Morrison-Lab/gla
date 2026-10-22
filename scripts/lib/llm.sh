#!/usr/bin/env bash
# =============================================================================
# LLM API call with retry logic (Databricks-hosted Claude, OpenAI schema)
# =============================================================================
# Requires: TOOLS_JSON (sourced from tools-schema.sh)

call_llm() {
  log_step "LLM API CALL"

  MODEL="${CLAUDE_MODEL:-databricks-claude-sonnet-4-6}"

  # Prefer ANTHROPIC_API_KEY, fall back to ANTHROPIC_AUTH_TOKEN
  DATABRICKS_TOKEN="${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
  if [[ -z "$DATABRICKS_TOKEN" ]]; then
    log_error "Neither ANTHROPIC_API_KEY nor ANTHROPIC_AUTH_TOKEN is set."
    exit 1
  fi

  ENDPOINT_URL="${ANTHROPIC_BASE_URL%/}/${MODEL}/invocations"
  log "Model: $MODEL"
  log "Endpoint: $ENDPOINT_URL"
  log "System prompt size: ${#SYSTEM_PROMPT} bytes"
  log "User message size: ${#USER_MESSAGE} bytes"

  # Build the JSON request body using temp files to avoid ARG_MAX
  local sys_file user_file req_file
  sys_file=$(mktemp) || { log_error "mktemp failed"; return 1; }
  user_file=$(mktemp) || { rm -f "$sys_file"; log_error "mktemp failed"; return 1; }
  req_file=$(mktemp) || { rm -f "$sys_file" "$user_file"; log_error "mktemp failed"; return 1; }
  printf '%s' "$SYSTEM_PROMPT" > "$sys_file"
  printf '%s' "$USER_MESSAGE" > "$user_file"
  # TOOLS_JSON is small (schema definitions) — use --argjson for loud failure on bad input
  if ! jq -n \
    --rawfile system "$sys_file" \
    --rawfile user "$user_file" \
    --argjson tools "$TOOLS_JSON" \
    '{
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ],
      max_tokens: 16384,
      tools: $tools,
      tool_choice: "auto"
    }' > "$req_file"; then
    log_error "Failed to build LLM request JSON"
    rm -f "$sys_file" "$user_file" "$req_file"
    return 1
  fi
  rm -f "$sys_file" "$user_file"

  # Call the endpoint with retry logic for transient failures
  MAX_LLM_RETRIES=3
  HTTP_CODE=""
  HTTP_BODY=""

  for LLM_ATTEMPT in $(seq 1 $MAX_LLM_RETRIES); do
    log "Sending request to Databricks (attempt ${LLM_ATTEMPT}/${MAX_LLM_RETRIES})..."
    HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 120 --request POST \
      --header "Authorization: Bearer ${DATABRICKS_TOKEN}" \
      --header "Content-Type: application/json" \
      --data @"$req_file" \
      "$ENDPOINT_URL")

    HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

    log "HTTP status: $HTTP_CODE"

    # Success — break out of retry loop
    if [[ "$HTTP_CODE" == "200" ]]; then
      break
    fi

    # Retryable errors: 429 (rate limit), 5xx (server errors)
    if [[ "$HTTP_CODE" =~ ^(429|5[0-9][0-9])$ ]] && [[ $LLM_ATTEMPT -lt $MAX_LLM_RETRIES ]]; then
      BACKOFF=$((LLM_ATTEMPT * 15))
      log "Retryable error (HTTP $HTTP_CODE) — waiting ${BACKOFF}s before retry..."
      sleep $BACKOFF
      continue
    fi

    # Non-retryable error or last attempt — break and handle below
    break
  done

  if [[ "$HTTP_CODE" == "200" ]]; then
    RESPONSE=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // ""')
    TOOL_CALLS=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.tool_calls // empty')
    TOOL_CALL_COUNT=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.tool_calls | length // 0')

    log "Response text length: ${#RESPONSE} bytes"
    log "Tool calls: ${TOOL_CALL_COUNT:-0}"
  else
    # Redact tokens from error body before logging/posting
    SAFE_BODY="$HTTP_BODY"
    [[ -n "${DATABRICKS_TOKEN:-}" ]] && SAFE_BODY=$(echo "$SAFE_BODY" | sed "s/${DATABRICKS_TOKEN}/***REDACTED***/g")
    log_error "Databricks endpoint returned HTTP $HTTP_CODE after $LLM_ATTEMPT attempt(s)"
    log_error "Response body (first 1000 chars): $(echo "$SAFE_BODY" | head -c 1000)"
    FENCE='```'
    RESPONSE=$(printf '⚠️ Databricks endpoint returned HTTP %s (after %d attempt(s)):\n\n%s\n%s\n%s' \
      "$HTTP_CODE" "$LLM_ATTEMPT" "$FENCE" "$SAFE_BODY" "$FENCE")
    TOOL_CALLS=""
    TOOL_CALL_COUNT=0
  fi

  rm -f "$req_file"
}
