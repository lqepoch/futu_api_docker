#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/futu-opend-auto-attach.expect"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" > "${FAKE_DOCKER_INVOCATION:?}"
[[ "${1:-}" == attach && "${2:-}" == futu-opend ]] || exit 64
: "${FAKE_DOCKER_LOG:?}"
: "${FAKE_DOCKER_SENTINEL:?}"
printf '%s\n' 'supervisor-running' > "$FAKE_DOCKER_SENTINEL"
if [[ "${FAKE_DOCKER_MODE:-}" == marker ]]; then
  stty raw -echo 2>/dev/null || true
  printf '%s\n' 'FUTU_LOGIN_READY_MARKER'
  sleep 1
  bytes="$(dd if=/dev/stdin bs=1 count=2 status=none)"
  hex="$(printf '%s' "$bytes" | od -An -t x1 | tr -d '[:space:]')"
  printf '%s\n' "$hex" > "$FAKE_DOCKER_LOG"
  [[ "$hex" == 1011 ]]
  exit 0
fi
printf '%s\n' 'healthy'
while :; do sleep 1; done
EOF
chmod 0755 "$fake_bin/docker"

cat > "$test_dir/outer-harness.expect" <<'EOF'
set timeout 10
set helper [lindex $argv 0]
set timed_out 0
spawn -noecho expect -f $helper futu-opend
expect {
  -re {timed out waiting for FUTU_LOGIN_READY_MARKER} {set timed_out 1}
  -re {FUTU_LOGIN_READY_MARKER} {}
  eof {}
  timeout {exit 124}
}
set wait_result [wait]
if {$timed_out} {exit 124}
exit [lindex $wait_result 3]
EOF

run_case() {
  local mode="$1" timeout_value="$2" name="$3"
  local log="$test_dir/$name.log" sentinel="$test_dir/$name.sentinel" invocation="$test_dir/$name.invocation" output status
  : > "$log"
  set +e
  output="$(
    env \
      PATH="$fake_bin:$PATH" \
      FAKE_DOCKER_MODE="$mode" \
      FAKE_DOCKER_LOG="$log" \
      FAKE_DOCKER_SENTINEL="$sentinel" \
      FAKE_DOCKER_INVOCATION="$invocation" \
      FUTU_LOGIN_AUTO_ATTACH_TIMEOUT="$timeout_value" \
      timeout 10 expect -f "$test_dir/outer-harness.expect" "$helper" 2>&1)"
  status=$?
  set -e

  [[ -s "$sentinel" ]] || { printf '%s sentinel missing\n' "$mode" >&2; exit 1; }
  [[ "$(<"$invocation")" == "attach futu-opend" ]] || {
    printf '%s invocation=%s\n' "$mode" "$(<"$invocation")" >&2
    exit 1
  }
  if [[ "$mode" == marker ]]; then
    [[ "$status" -eq 0 ]] || { printf 'marker status=%s\n%s\n' "$status" "$output" >&2; exit 1; }
    [[ "$(<"$log")" == 1011 ]] || { printf 'marker detach log=%s\n' "$(<"$log")" >&2; exit 1; }
  else
    [[ "$status" -eq 124 ]] || { printf 'no-marker status=%s\n%s\n' "$status" "$output" >&2; exit 1; }
    [[ ! -s "$log" ]] || { printf 'no-marker detach log=%s\n' "$(<"$log")" >&2; exit 1; }
  fi
}

run_case marker 5 marker
run_case no-marker 1 no-marker
echo 'auto-attach contract tests passed'
