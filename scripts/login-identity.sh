#!/usr/bin/env bash

# Normalize the non-secret account input accepted by Futu OpenD. Passwords
# and verification codes deliberately stay in OpenD's native interactive
# flow and never pass through this helper.

futu_trim_login_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

futu_normalize_area_code() {
  local value
  value="$(futu_trim_login_value "${1:-}")"
  [[ -n "$value" ]] || return 1
  [[ "$value" =~ ^\+?[0-9]{1,4}$ ]] || return 1
  [[ "$value" == +* ]] || value="+$value"
  printf '%s' "$value"
}

futu_phone_digits() {
  local value="$1"
  value="${value//[[:space:]]/}"
  value="${value//-/}"
  value="${value//./}"
  [[ "$value" =~ ^[0-9]{5,15}$ ]] || return 1
  printf '%s' "$value"
}

# Sets these output variables and returns non-zero only for malformed input:
#   FUTU_LOGIN_ACCOUNT_NORMALIZED
#   FUTU_LOGIN_AREA_CODE_NORMALIZED
#   FUTU_LOGIN_ACCOUNT_KIND (phone, email, or id)
futu_normalize_login_account() {
  local raw area_code phone
  raw="$(futu_trim_login_value "${1:-}")"
  area_code="$(futu_normalize_area_code "${2:-+86}")" || {
    echo "invalid phone area code" >&2
    return 2
  }

  FUTU_LOGIN_ACCOUNT_NORMALIZED=""
  FUTU_LOGIN_AREA_CODE_NORMALIZED=""
  FUTU_LOGIN_ACCOUNT_KIND=""
  [[ -n "$raw" ]] || return 0

  if [[ "$raw" == *'@'* ]]; then
    # A country code is meaningful only for a phone number. Remove an
    # accidentally prepended +86 from an email, but preserve a normal local
    # part such as 86alice@example.com.
    if [[ "$raw" == +86* ]]; then raw="${raw:3}"; fi
    [[ "$raw" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || {
      echo "invalid email login account" >&2
      return 2
    }
    FUTU_LOGIN_ACCOUNT_NORMALIZED="$raw"
    FUTU_LOGIN_ACCOUNT_KIND="email"
    return 0
  fi

  if [[ "$raw" =~ ^\+86[[:space:]-]*([0-9][0-9[:space:].-]*)$ ]]; then
    phone="$(futu_phone_digits "${BASH_REMATCH[1]}")" || {
      echo "invalid phone login account" >&2
      return 2
    }
    FUTU_LOGIN_ACCOUNT_NORMALIZED="$phone"
    FUTU_LOGIN_AREA_CODE_NORMALIZED="+86"
    FUTU_LOGIN_ACCOUNT_KIND="phone"
    return 0
  fi

  if [[ "$raw" =~ ^0086[[:space:]-]*([0-9][0-9[:space:].-]*)$ ]]; then
    phone="$(futu_phone_digits "${BASH_REMATCH[1]}")" || {
      echo "invalid phone login account" >&2
      return 2
    }
    FUTU_LOGIN_ACCOUNT_NORMALIZED="$phone"
    FUTU_LOGIN_AREA_CODE_NORMALIZED="+86"
    FUTU_LOGIN_ACCOUNT_KIND="phone"
    return 0
  fi

  if [[ "$raw" =~ ^\+([0-9]{1,4})[[:space:]-]+([0-9][0-9[:space:].-]*)$ ]]; then
    phone="$(futu_phone_digits "${BASH_REMATCH[2]}")" || {
      echo "invalid phone login account" >&2
      return 2
    }
    FUTU_LOGIN_ACCOUNT_NORMALIZED="$phone"
    FUTU_LOGIN_AREA_CODE_NORMALIZED="+${BASH_REMATCH[1]}"
    FUTU_LOGIN_ACCOUNT_KIND="phone"
    return 0
  fi

  if [[ "$raw" =~ ^[0-9][0-9[:space:].-]*$ ]]; then
    phone="$(futu_phone_digits "$raw")" || {
      echo "invalid phone login account" >&2
      return 2
    }
    FUTU_LOGIN_ACCOUNT_NORMALIZED="$phone"
    FUTU_LOGIN_AREA_CODE_NORMALIZED="$area_code"
    FUTU_LOGIN_ACCOUNT_KIND="phone"
    return 0
  fi

  [[ "$raw" != *[[:space:]]* ]] || {
    echo "invalid Futu ID login account" >&2
    return 2
  }
  FUTU_LOGIN_ACCOUNT_NORMALIZED="$raw"
  FUTU_LOGIN_ACCOUNT_KIND="id"
}
