#!/usr/bin/env bash
set -Eeuo pipefail

port="${FUTU_TELNET_PORT:-22222}"
signal_wait="${FUTU_PHONE_CODE_SIGNAL_WAIT_SECONDS:-60}"
post_signal_delay="${FUTU_PHONE_CODE_REQUEST_DELAY_SECONDS:-2}"
phone_needed="/run/futu/phone-code-needed"
requested="/run/futu/phone-code-requested"
ready_marker="${FUTU_READY_MARKER:-/home/futu/.com.futunn.FutuOpenD/.docker-device-ready}"

request_once() {
  [[ -e "$requested" ]] && return 0
  if ! nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
    return 1
  fi

  sleep "$post_signal_delay"
  echo "Requesting Futu phone verification code once..." >&2
  /usr/local/bin/futu-opend-cli req_phone_verify_code || true
  touch "$requested"
  echo "SMS request sent. Wait for the message; submission remains a separate operator action:" >&2
  echo "  docker exec futu-opend futu-verify phone <CODE>" >&2
  return 0
}

for ((i=0; i<signal_wait; i++)); do
  [[ -e "$ready_marker" ]] && exit 0

  if [[ -e "$phone_needed" ]]; then
    request_once || true
    exit 0
  fi

  sleep 1
done

# Compatibility fallback: if an OpenD release changes the textual status message,
# make one request only when the first login is still not READY.
if [[ ! -e "$ready_marker" && ! -e "$requested" ]]; then
  echo "No recognizable NeedPhoneVerifyCode text was observed; making one guarded fallback request." >&2
  request_once || echo "OpenD operation port unavailable; no phone-code request was sent." >&2
fi

exit 0
