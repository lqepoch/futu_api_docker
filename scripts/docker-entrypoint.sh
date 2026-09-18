#!/usr/bin/env bash
set -Eeuo pipefail

OPEND_HOME="/opt/futu-opend"
RUNTIME_DIR="/run/futu"
SECRET_DIR="/run/futu-secrets"
STATE_DIR="/home/futu/.com.futunn.FutuOpenD"
PERSISTENT_SECRET_DIR="${STATE_DIR}/docker-secrets"
CONFIG_FILE="${RUNTIME_DIR}/FutuOpenD.xml"
READY_MARKER="${STATE_DIR}/.docker-device-ready"

mkdir -p "$RUNTIME_DIR" "$SECRET_DIR" "$PERSISTENT_SECRET_DIR"
chmod 0700 "$SECRET_DIR" "$PERSISTENT_SECRET_DIR"

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

materialize_optional_secret() {
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

prepare_login_password() {
  local target="$SECRET_DIR/login-password"
  rm -f "$target"

  if [[ -n "${FUTU_LOGIN_PASSWORD_B64:-}" ]]; then
    printf '%s' "$FUTU_LOGIN_PASSWORD_B64" | base64 --decode > "$target" || die "invalid FUTU_LOGIN_PASSWORD_B64"
  elif [[ -n "${FUTU_LOGIN_PASSWORD_FILE:-}" ]]; then
    [[ -r "$FUTU_LOGIN_PASSWORD_FILE" ]] || die "FUTU_LOGIN_PASSWORD_FILE is unreadable"
    cp "$FUTU_LOGIN_PASSWORD_FILE" "$target"
  elif [[ -n "${FUTU_LOGIN_PASSWORD:-}" ]]; then
    printf '%s' "$FUTU_LOGIN_PASSWORD" > "$target"
  else
    die "set FUTU_LOGIN_PASSWORD, FUTU_LOGIN_PASSWORD_B64, or FUTU_LOGIN_PASSWORD_FILE"
  fi

  chmod 0600 "$target"
  export FUTU_LOGIN_PASSWORD_RESOLVED_FILE="$target"
  unset FUTU_LOGIN_PASSWORD FUTU_LOGIN_PASSWORD_B64
}

prepare_api_rsa() {
  local runtime_key="$SECRET_DIR/api-rsa.pem"
  local persistent_key="$PERSISTENT_SECRET_DIR/api-rsa.pem"

  if materialize_optional_secret FUTU_API_RSA_PRIVATE_KEY_B64 FUTU_API_RSA_PRIVATE_KEY_FILE "$runtime_key"; then
    printf '%s' "$runtime_key"
    return
  fi

  if [[ ! -s "$persistent_key" ]]; then
    echo "Generating persistent Futu API RSA private key..." >&2
    openssl genrsa -traditional -out "$persistent_key" 1024 >/dev/null 2>&1
    chmod 0600 "$persistent_key"
  fi

  printf '%s' "$persistent_key"
}

prepare_websocket_auth_key_md5() {
  local raw_key=""
  local raw_key_file="$PERSISTENT_SECRET_DIR/websocket-auth-key"

  if [[ -n "${FUTU_WEBSOCKET_AUTH_KEY_MD5:-}" ]]; then
    printf '%s' "$FUTU_WEBSOCKET_AUTH_KEY_MD5"
    return
  fi

  if [[ -n "${FUTU_WEBSOCKET_AUTH_KEY:-}" ]]; then
    raw_key="$FUTU_WEBSOCKET_AUTH_KEY"
  elif [[ -n "${FUTU_WEBSOCKET_AUTH_KEY_FILE:-}" ]]; then
    [[ -r "$FUTU_WEBSOCKET_AUTH_KEY_FILE" ]] || die "FUTU_WEBSOCKET_AUTH_KEY_FILE is unreadable"
    raw_key="$(cat "$FUTU_WEBSOCKET_AUTH_KEY_FILE")"
  else
    if [[ ! -s "$raw_key_file" ]]; then
      openssl rand -hex 32 > "$raw_key_file"
      chmod 0600 "$raw_key_file"
      echo "Generated a persistent WebSocket auth key. Retrieve it with: docker exec futu-opend futu-verify show-ws-key" >&2
    fi
    raw_key="$(cat "$raw_key_file")"
  fi

  printf '%s' "$raw_key" | md5sum | awk '{print $1}'
}

prepare_websocket_tls() {
  local cert="$SECRET_DIR/websocket.crt"
  local key="$SECRET_DIR/websocket.key"
  local persistent_cert="$PERSISTENT_SECRET_DIR/websocket.crt"
  local persistent_key="$PERSISTENT_SECRET_DIR/websocket.key"

  local cert_provided=false
  local key_provided=false
  materialize_optional_secret FUTU_WEBSOCKET_CERT_B64 FUTU_WEBSOCKET_CERT_FILE "$cert" && cert_provided=true
  materialize_optional_secret FUTU_WEBSOCKET_PRIVATE_KEY_B64 FUTU_WEBSOCKET_PRIVATE_KEY_FILE "$key" && key_provided=true

  if [[ "$cert_provided" == "true" || "$key_provided" == "true" ]]; then
    [[ "$cert_provided" == "true" && "$key_provided" == "true" ]] || die "WebSocket TLS certificate and private key must be supplied together"
    printf '%s|%s' "$cert" "$key"
    return
  fi

  if [[ ! -s "$persistent_cert" || ! -s "$persistent_key" ]]; then
    local cn="${FUTU_WEBSOCKET_TLS_CN:-futu-opend}"
    local san="DNS:$cn"
    if [[ "$cn" =~ ^[0-9]+.[0-9]+.[0-9]+.[0-9]+$ ]]; then
      san="IP:$cn"
    fi

    echo "Generating persistent self-signed WebSocket TLS certificate for CN=$cn..." >&2
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
      -keyout "$persistent_key" \
      -out "$persistent_cert" \
      -subj "/CN=$cn" \
      -addext "subjectAltName=$san" >/dev/null 2>&1
    chmod 0600 "$persistent_key"
    chmod 0644 "$persistent_cert"
  fi

  printf '%s|%s' "$persistent_cert" "$persistent_key"
}

write_config() {
  local api_ip="${FUTU_API_IP:-0.0.0.0}"
  local api_port="${FUTU_API_PORT:-11111}"
  local telnet_ip="${FUTU_TELNET_IP:-127.0.0.1}"
  local telnet_port="${FUTU_TELNET_PORT:-22222}"
  local lang="${FUTU_LANG:-en}"
  local log_level="${FUTU_LOG_LEVEL:-info}"
  local push_proto_type="${FUTU_PUSH_PROTO_TYPE:-0}"
  local price_reminder_push="${FUTU_PRICE_REMINDER_PUSH:-1}"
  local auto_hold_quote_right="${FUTU_AUTO_HOLD_QUOTE_RIGHT:-1}"
  local futures_tz="${FUTU_FUTURES_TZ:-UTC+8}"

  local api_rsa_path
  api_rsa_path="$(prepare_api_rsa)"

  local websocket_block=""
  if [[ "${FUTU_WEBSOCKET_ENABLED:-true}" == "true" ]]; then
    local websocket_ip="${FUTU_WEBSOCKET_IP:-0.0.0.0}"
    local websocket_port="${FUTU_WEBSOCKET_PORT:-33333}"
    local tls_pair ws_cert_path ws_key_path ws_key_md5

    tls_pair="$(prepare_websocket_tls)"
    ws_cert_path="${tls_pair%%|*}"
    ws_key_path="${tls_pair#*|}"
    ws_key_md5="$(prepare_websocket_auth_key_md5)"

    websocket_block="  <websocket_ip>$(xml_escape "$websocket_ip")</websocket_ip>
  <websocket_port>$(xml_escape "$websocket_port")</websocket_port>
  <websocket_key_md5>$(xml_escape "$ws_key_md5")</websocket_key_md5>
  <websocket_private_key>$(xml_escape "$ws_key_path")</websocket_private_key>
  <websocket_cert>$(xml_escape "$ws_cert_path")</websocket_cert>"
  fi

  local qot_frequency=""
  if [[ -n "${FUTU_QOT_PUSH_FREQUENCY:-}" ]]; then
    qot_frequency="  <qot_push_frequency>$(xml_escape "$FUTU_QOT_PUSH_FREQUENCY")</qot_push_frequency>"
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
  <rsa_private_key>$(xml_escape "$api_rsa_path")</rsa_private_key>
  <price_reminder_push>$(xml_escape "$price_reminder_push")</price_reminder_push>
  <auto_hold_quote_right>$(xml_escape "$auto_hold_quote_right")</auto_hold_quote_right>
  <future_trade_api_time_zone>$(xml_escape "$futures_tz")</future_trade_api_time_zone>
$websocket_block
</futu_opend>
EOF
  chmod 0600 "$CONFIG_FILE"
}

mark_ready_when_api_listens() {
  local port="${FUTU_API_PORT:-11111}"
  while true; do
    if nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
      touch "$READY_MARKER"
      echo "Futu OpenD API is ready on port $port." >&2
      return 0
    fi
    sleep 2
  done
}

write_config

mode="${1:-serve}"
shift || true

case "$mode" in
  serve)
    [[ -n "${FUTU_LOGIN_ACCOUNT:-}" ]] || die "FUTU_LOGIN_ACCOUNT is required"
    prepare_login_password
    export FUTU_CONFIG_FILE="$CONFIG_FILE"
    export FUTU_READY_MARKER="$READY_MARKER"

    mark_ready_when_api_listens &

    if [[ ! -e "$READY_MARKER" && "${FUTU_AUTO_REQUEST_PHONE_CODE:-true}" == "true" ]]; then
      /usr/local/bin/futu-auto-request-phone-code &
    fi

    exec /usr/local/bin/futu-auto-login "$@"
    ;;
  login)
    exec "$OPEND_HOME/FutuOpenD" -cfg_file="$CONFIG_FILE" "$@"
    ;;
  shell)
    exec /bin/bash "$@"
    ;;
  *)
    exec "$mode" "$@"
    ;;
esac
