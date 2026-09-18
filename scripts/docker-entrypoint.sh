#!/usr/bin/env bash
set -Eeuo pipefail

OPEND_HOME="/opt/futu-opend"
RUNTIME_DIR="/run/futu"
SECRET_DIR="/run/futu-secrets"
CONFIG_FILE="${RUNTIME_DIR}/FutuOpenD.xml"
UPSTREAM_CONFIG="${OPEND_HOME}/FutuOpenD.xml"

mkdir -p "$RUNTIME_DIR" "$SECRET_DIR"
chmod 0700 "$SECRET_DIR"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

materialize_secret() {
  local b64_var="$1"
  local file_var="$2"
  local destination="$3"
  local b64_value="${!b64_var:-}"
  local file_value="${!file_var:-}"

  rm -f "$destination"

  if [[ -n "$b64_value" ]]; then
    printf '%s' "$b64_value" | base64 --decode > "$destination" || die "invalid base64 in $b64_var"
    chmod 0600 "$destination"
    return 0
  fi

  if [[ -n "$file_value" ]]; then
    [[ -r "$file_value" ]] || die "$file_var points to an unreadable file: $file_value"
    cp "$file_value" "$destination"
    chmod 0600 "$destination"
    return 0
  fi

  return 1
}

write_config() {
  local api_ip="${FUTU_API_IP:-0.0.0.0}"
  local api_port="${FUTU_API_PORT:-11111}"
  local telnet_ip="${FUTU_TELNET_IP:-127.0.0.1}"
  local telnet_port="${FUTU_TELNET_PORT:-22222}"
  local lang="${FUTU_LANG:-chs}"
  local log_level="${FUTU_LOG_LEVEL:-info}"
  local push_proto_type="${FUTU_PUSH_PROTO_TYPE:-0}"
  local price_reminder_push="${FUTU_PRICE_REMINDER_PUSH:-1}"
  local auto_hold_quote_right="${FUTU_AUTO_HOLD_QUOTE_RIGHT:-1}"
  local futures_tz="${FUTU_FUTURES_TZ:-UTC+8}"

  local api_rsa_path=""
  if materialize_secret FUTU_API_RSA_PRIVATE_KEY_B64 FUTU_API_RSA_PRIVATE_KEY_FILE       "$SECRET_DIR/api_rsa_private_key.pem"; then
    api_rsa_path="$SECRET_DIR/api_rsa_private_key.pem"
  elif [[ "${FUTU_REQUIRE_API_RSA:-true}" == "true" && "$api_ip" != "127.0.0.1" && "$api_ip" != "localhost" ]]; then
    die "remote API listening is enabled but no API RSA private key was provided"
  fi

  local websocket_block=""
  if [[ "${FUTU_WEBSOCKET_ENABLED:-true}" == "true" ]]; then
    local websocket_ip="${FUTU_WEBSOCKET_IP:-0.0.0.0}"
    local websocket_port="${FUTU_WEBSOCKET_PORT:-33333}"
    local ws_cert_path="$SECRET_DIR/websocket.crt"
    local ws_key_path="$SECRET_DIR/websocket.key"

    materialize_secret FUTU_WEBSOCKET_CERT_B64 FUTU_WEBSOCKET_CERT_FILE "$ws_cert_path"       || die "WebSocket is enabled but no certificate was provided"
    materialize_secret FUTU_WEBSOCKET_PRIVATE_KEY_B64 FUTU_WEBSOCKET_PRIVATE_KEY_FILE "$ws_key_path"       || die "WebSocket is enabled but no private key was provided"

    local ws_key_md5="${FUTU_WEBSOCKET_AUTH_KEY_MD5:-}"
    if [[ -z "$ws_key_md5" && -n "${FUTU_WEBSOCKET_AUTH_KEY_MD5_FILE:-}" ]]; then
      [[ -r "$FUTU_WEBSOCKET_AUTH_KEY_MD5_FILE" ]] || die "FUTU_WEBSOCKET_AUTH_KEY_MD5_FILE is unreadable"
      ws_key_md5="$(tr -d '\r\n' < "$FUTU_WEBSOCKET_AUTH_KEY_MD5_FILE")"
    fi
    if [[ -z "$ws_key_md5" && -n "${FUTU_WEBSOCKET_AUTH_KEY:-}" ]]; then
      ws_key_md5="$(printf '%s' "$FUTU_WEBSOCKET_AUTH_KEY" | md5sum | awk '{print $1}')"
    fi
    if [[ -z "$ws_key_md5" && -n "${FUTU_WEBSOCKET_AUTH_KEY_FILE:-}" ]]; then
      [[ -r "$FUTU_WEBSOCKET_AUTH_KEY_FILE" ]] || die "FUTU_WEBSOCKET_AUTH_KEY_FILE is unreadable"
      ws_key_md5="$(cat "$FUTU_WEBSOCKET_AUTH_KEY_FILE" | md5sum | awk '{print $1}')"
    fi

    websocket_block="  <websocket_ip>$(xml_escape "$websocket_ip")</websocket_ip>
  <websocket_port>$(xml_escape "$websocket_port")</websocket_port>"
    if [[ -n "$ws_key_md5" ]]; then
      websocket_block+="
  <websocket_key_md5>$(xml_escape "$ws_key_md5")</websocket_key_md5>"
    fi
    websocket_block+="
  <websocket_private_key>$(xml_escape "$ws_key_path")</websocket_private_key>
  <websocket_cert>$(xml_escape "$ws_cert_path")</websocket_cert>"
  fi

  local qot_frequency=""
  if [[ -n "${FUTU_QOT_PUSH_FREQUENCY:-}" ]]; then
    qot_frequency="  <qot_push_frequency>$(xml_escape "$FUTU_QOT_PUSH_FREQUENCY")</qot_push_frequency>"
  fi

  local rsa_line=""
  if [[ -n "$api_rsa_path" ]]; then
    rsa_line="  <rsa_private_key>$(xml_escape "$api_rsa_path")</rsa_private_key>"
  fi

  cat > "$CONFIG_FILE" <<EOF
<futu_opend>
  <ip>$(xml_escape "$api_ip")</ip>
  <api_port>$(xml_escape "$api_port")</api_port>
  <lang>$(xml_escape "$lang")</lang>
  <log_level>$(xml_escape "$log_level")</log_level>
  <push_proto_type>$(xml_escape "$push_proto_type")</push_proto_type>
$qot_frequency
  <telnet_ip>$(xml_escape "$telnet_ip")</telnet_ip>
  <telnet_port>$(xml_escape "$telnet_port")</telnet_port>
$rsa_line
  <price_reminder_push>$(xml_escape "$price_reminder_push")</price_reminder_push>
  <auto_hold_quote_right>$(xml_escape "$auto_hold_quote_right")</auto_hold_quote_right>
  <future_trade_api_time_zone>$(xml_escape "$futures_tz")</future_trade_api_time_zone>
$websocket_block
</futu_opend>
EOF
  chmod 0600 "$CONFIG_FILE"
}

print_login_help() {
  cat <<'EOF'
OpenD 10.10+ first-login flow:
  1. OpenD prompts for account.
  2. OpenD prompts for login password.
  3. Choose to remember the password.
  4. If OpenD reports NeedPhoneVerifyCode, keep this container running.
     In a SECOND SSH terminal request the SMS:
       docker exec -it futu-opend-login futu-opend-cli req_phone_verify_code
     Wait until the SMS actually arrives, then submit it:
       docker exec -it futu-opend-login futu-opend-cli input_phone_verify_code -code=123456
  5. When login reaches Ready, stop the temporary login container with Ctrl+C.
  6. Start the normal service with FUTU_LOGIN_ACCOUNT configured.

The SMS request is intentionally separate from code submission.
OpenD limits phone-code requests to one per 60 seconds.
EOF
}

write_config

mode="${1:-serve}"
shift || true

case "$mode" in
  login)
    print_login_help
    exec "$OPEND_HOME/FutuOpenD" -cfg_file="$CONFIG_FILE" "$@"
    ;;
  serve)
    [[ -n "${FUTU_LOGIN_ACCOUNT:-}" ]] || die "FUTU_LOGIN_ACCOUNT is required for remembered-password startup; run the documented interactive login first"
    args=(
      "-cfg_file=$CONFIG_FILE"
      "-login_account=$FUTU_LOGIN_ACCOUNT"
      "-login_by_remember=1"
    )
    if [[ -n "${FUTU_AREA_CODE:-}" ]]; then
      args+=("-area_code=$FUTU_AREA_CODE")
    fi
    exec "$OPEND_HOME/FutuOpenD" "${args[@]}" "$@"
    ;;
  shell)
    exec /bin/bash "$@"
    ;;
  *)
    exec "$mode" "$@"
    ;;
esac
