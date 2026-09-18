#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/login-identity.sh"

assert_identity() {
  local input="$1" expected_account="$2" expected_area="$3" expected_kind="$4"
  futu_normalize_login_account "$input" '+86'
  [[ "$FUTU_LOGIN_ACCOUNT_NORMALIZED" == "$expected_account" ]]
  [[ "$FUTU_LOGIN_AREA_CODE_NORMALIZED" == "$expected_area" ]]
  [[ "$FUTU_LOGIN_ACCOUNT_KIND" == "$expected_kind" ]]
}

assert_identity '13800138000' '13800138000' '+86' 'phone'
assert_identity '+86 13800138000' '13800138000' '+86' 'phone'
assert_identity '+8613800138000' '13800138000' '+86' 'phone'
assert_identity '+1 212-555-0100' '2125550100' '+1' 'phone'
assert_identity '+86alice@example.com' 'alice@example.com' '' 'email'
assert_identity 'alice@example.com' 'alice@example.com' '' 'email'
assert_identity 'futu-user' 'futu-user' '' 'id'

if futu_normalize_login_account 'not an account' '+86' 2>/dev/null; then
  echo 'expected malformed whitespace account to fail' >&2
  exit 1
fi

echo 'login identity normalization tests passed'
