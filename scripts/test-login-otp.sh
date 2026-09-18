#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expect_script="$script_dir/futu-opend-direct-otp.expect"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/nc" <<'EOF'
#!/usr/bin/env bash
port="${!#}"
printf '%s\n' "$port" >> "${FAKE_NC_LOG:?}"
if [[ "${FAKE_NC_MODE:-fail}" == success && ( "$port" == 11111 || "$port" == 33333 ) ]]; then
  exit 0
fi
exit 1
EOF
chmod 0755 "$fake_bin/nc"

run_otp_case() {
  local name="$1" value="$2" expected_status="$3" expected_text="$4"
  local otp_file="$test_dir/${name}.otp" output status
  printf '%s\n' "$value" > "$otp_file"
  set +e
  output="$(PATH="$fake_bin:$PATH" \
    FUTU_LOGIN_TEST_MODE=otp \
    FUTU_LOGIN_OTP_FILE="$otp_file" \
    expect -f "$expect_script" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]]
  grep -Fqx "$expected_text" <<<"$output"
  ! grep -Fq "$value" <<<"$output"
  [[ ! -e "$otp_file" ]]
}

run_ready_case() {
  local name="$1" mode="$2" expected_status="$3" expected_marker="$4"
  local nc_log="$test_dir/${name}.nc" output status
  set +e
  output="$(PATH="$fake_bin:$PATH" \
    FAKE_NC_MODE="$mode" \
    FAKE_NC_LOG="$nc_log" \
    FUTU_LOGIN_TEST_MODE=ready \
    FUTU_LOGIN_READY_TIMEOUT=1 \
    expect -f "$expect_script" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]]
  if [[ "$expected_marker" == yes ]]; then
    grep -Fqx 'FUTU_LOGIN_READY_MARKER' <<<"$output"
    grep -Fxq 11111 "$nc_log"
    grep -Fxq 33333 "$nc_log"
  else
    ! grep -Fq 'FUTU_LOGIN_READY_MARKER' <<<"$output"
  fi
}

run_otp_case four_digits 1234 0 OTP_VALID
run_otp_case eight_digits 12345678 0 OTP_VALID
run_otp_case invalid_digits 123 1 OTP_INVALID
run_ready_case ready_success success 0 yes
run_ready_case ready_failure fail 1 no

echo 'login OTP tests passed'
