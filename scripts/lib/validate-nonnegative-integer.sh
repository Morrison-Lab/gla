#!/usr/bin/env bash

validate_nonnegative_integer() {
  local setting_name="$1" setting_value="$2" maximum_value="${3:-}"

  [[ "$setting_value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  maximum_value="${maximum_value:-1000000000}"
  [[ "$maximum_value" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ ${#setting_value} -lt ${#maximum_value} ]] && return 0
  [[ ${#setting_value} -gt ${#maximum_value} ]] && return 1
  [[ "$setting_value" < "$maximum_value" || "$setting_value" == "$maximum_value" ]]
}

validate_boolean() {
  local setting_name="$1" setting_value="$2"
  [[ "$setting_value" == "true" || "$setting_value" == "false" ]] || {
    printf '%s must be exactly true or false\n' "$setting_name" >&2
    return 1
  }
}
