#!/usr/bin/env bash
set -Eeuo pipefail

port="${FUTU_TELNET_PORT:-22222}"
delay="${FUTU_PHONE_CODE_REQUEST_DELAY_SECONDS:-8}"
max_wait="${FUTU_TELNET_WAIT_SECONDS:-90}"

for ((i=0; i<max_wait; i++)); do
  if nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
    sleep "$delay"
    echo "Requesting phone verification code once (if this login requires device verification)..." >&2
    /usr/local/bin/futu-opend-cli req_phone_verify_code || true
    echo "If Futu sent an SMS, wait for it and submit only after it arrives: docker exec futu-opend futu-verify phone <CODE>" >&2
    exit 0
  fi
  sleep 1
done

echo "OpenD operation port did not become available; phone-code request was not sent." >&2
exit 0
