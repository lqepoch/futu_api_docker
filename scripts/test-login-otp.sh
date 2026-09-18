#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expect_script="$script_dir/futu-opend-direct-otp.expect"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

real_nc="$(command -v nc)"
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

fake_opend="$test_dir/fake-opend.sh"
cat > "$fake_opend" <<'EOF'
#!/usr/bin/env bash
printf 'input_phone_verify_code -code=1234\n'
sleep 10
EOF
chmod 0755 "$fake_opend"

run_case() {
  local name="$1" otp="$2" mode="$3" expected_status="$4" expected_marker="$5"
  local otp_file="$test_dir/${name}.otp" output status telnet_pid nc_log telnet_port
  nc_log="$test_dir/${name}.nc"
  telnet_port=23456
  [[ "$name" == valid_length ]] && telnet_port=23457
  printf '%s\n' "$otp" > "$otp_file"
  "$real_nc" -k -l 127.0.0.1 "$telnet_port" >/dev/null 2>&1 &
  telnet_pid=$!
  for _ in {1..20}; do
    "$real_nc" -z -w 1 127.0.0.1 "$telnet_port" >/dev/null 2>&1 && break
    sleep 0.05
  done

  set +e
  output="$({
    PATH="$fake_bin:$PATH" \
    FAKE_NC_MODE="$mode" \
    FAKE_NC_LOG="$nc_log" \
    FUTU_LOGIN_OTP_FILE="$otp_file" \
    FUTU_LOGIN_READY_TIMEOUT=1 \
    FUTU_LOGIN_TELNET_HOST=127.0.0.1 \
    FUTU_TELNET_PORT="$telnet_port" \
    timeout 5 expect -f "$expect_script" "$fake_opend"
  } 2>&1)"
  status=$?
  kill "$telnet_pid" 2>/dev/null || true
  wait "$telnet_pid" 2>/dev/null || true
  set -e

  [[ "$status" -eq "$expected_status" ]] || {
    printf 'case %s: expected status %s, got %s\n%s\n' "$name" "$expected_status" "$status" "$output" >&2
    exit 1
  }
  if [[ "$expected_marker" == yes ]]; then
    grep -Fq 'FUTU_LOGIN_READY_MARKER' <<<"$output"
    grep -Fxq 11111 "$nc_log"
    grep -Fxq 33333 "$nc_log"
  else
    ! grep -Fq 'FUTU_LOGIN_READY_MARKER' <<<"$output"
  fi
  ! grep -Fq "$otp" <<<"$output"
  [[ ! -e "$otp_file" ]] || {
    printf 'case %s: OTP file was not removed\n' "$name" >&2
    exit 1
  }
}

run_case valid_success 1234 success 124 yes
run_case valid_length 12345678 success 124 yes
run_case readiness_failure 1234 fail 1 no

echo 'login OTP tests passed'
