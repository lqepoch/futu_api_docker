#!/usr/bin/env bash
set -Eeuo pipefail

OPEND_HOME="/opt/futu-opend"
STATE_DIR="${HOME:-/home/futu}/.com.futunn.FutuOpenD"
SECURITY_DIR="$STATE_DIR/docker-security"
WSS_DIR="$SECURITY_DIR/wss"
CONFIG_FILE="$STATE_DIR/FutuOpenD.docker.xml"

mkdir -p "$STATE_DIR" "$SECURITY_DIR" "$WSS_DIR"
chmod 0700 "$STATE_DIR" "$SECURITY_DIR" "$WSS_DIR"

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

prepare_api_rsa() {
  local key="${FUTU_API_RSA_PRIVATE_KEY_FILE:-$SECURITY_DIR/api-rsa.pem}"

  if [[ -n "${FUTU_API_RSA_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -r "$key" ]] || die "FUTU_API_RSA_PRIVATE_KEY_FILE is not readable: $key"
  elif [[ ! -s "$key" ]]; then
    echo "[futu-docker] generating persistent PKCS#1 1024-bit API RSA key" >&2
    openssl genrsa -traditional -out "$key" 1024 >/dev/null 2>&1
    chmod 0600 "$key"
  fi

  grep -q "ENCRYPTED" "$key" && die "API RSA private key must not be password protected"
  printf '%s' "$key"
}

prepare_wss() {
  local cert="${FUTU_WEBSOCKET_CERT_FILE:-$WSS_DIR/server.crt}"
  local key="${FUTU_WEBSOCKET_PRIVATE_KEY_FILE:-$WSS_DIR/server.key}"

  if [[ -n "${FUTU_WEBSOCKET_CERT_FILE:-}" || -n "${FUTU_WEBSOCKET_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -n "${FUTU_WEBSOCKET_CERT_FILE:-}" && -n "${FUTU_WEBSOCKET_PRIVATE_KEY_FILE:-}" ]] \
      || die "FUTU_WEBSOCKET_CERT_FILE and FUTU_WEBSOCKET_PRIVATE_KEY_FILE must be configured together"
    [[ -r "$cert" ]] || die "WebSocket certificate is not readable: $cert"
    [[ -r "$key" ]] || die "WebSocket private key is not readable: $key"
  elif [[ ! -s "$cert" || ! -s "$key" ]]; then
    local cn="${FUTU_WEBSOCKET_TLS_CN:-futu-opend}"
    local san="${FUTU_WEBSOCKET_TLS_SAN:-DNS:futu-opend,DNS:localhost,IP:127.0.0.1}"

    echo "[futu-docker] generating persistent self-signed WSS certificate" >&2
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
      -keyout "$key" \
      -out "$cert" \
      -subj "/CN=$cn" \
      -addext "subjectAltName=$san" >/dev/null 2>&1
    chmod 0600 "$key"
    chmod 0644 "$cert"
  fi

  grep -q "ENCRYPTED" "$key" && die "WebSocket private key must not be password protected"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Invalid WebSocket certificate: $cert"

  WSS_CERT="$cert"
  WSS_KEY="$key"
}

prepare_websocket_auth() {
  local persisted="$WSS_DIR/auth.key"

  if [[ -n "${FUTU_WEBSOCKET_AUTH_KEY:-}" ]]; then
    WSS_AUTH_KEY="$FUTU_WEBSOCKET_AUTH_KEY"
  else
    if [[ ! -s "$persisted" ]]; then
      openssl rand -hex 32 > "$persisted"
      chmod 0600 "$persisted"
    fi
    WSS_AUTH_KEY="$(cat "$persisted")"
  fi

  WSS_AUTH_MD5="$(printf '%s' "$WSS_AUTH_KEY" | md5sum | awk '{print $1}')"
}

API_RSA_KEY="$(prepare_api_rsa)"
prepare_wss
prepare_websocket_auth

cat > "$CONFIG_FILE" <<EOF
<futu_opend>
  <ip>$(xml_escape "${FUTU_API_IP:-0.0.0.0}")</ip>
  <api_port>$(xml_escape "${FUTU_API_PORT:-11111}")</api_port>
  <lang>$(xml_escape "${FUTU_LANG:-chs}")</lang>
  <log_level>$(xml_escape "${FUTU_LOG_LEVEL:-info}")</log_level>
  <telnet_ip>$(xml_escape "${FUTU_TELNET_IP:-127.0.0.1}")</telnet_ip>
  <telnet_port>$(xml_escape "${FUTU_TELNET_PORT:-22222}")</telnet_port>
  <rsa_private_key>$(xml_escape "$API_RSA_KEY")</rsa_private_key>
  <websocket_ip>$(xml_escape "${FUTU_WEBSOCKET_IP:-0.0.0.0}")</websocket_ip>
  <websocket_port>$(xml_escape "${FUTU_WEBSOCKET_PORT:-33333}")</websocket_port>
  <websocket_key_md5>$(xml_escape "$WSS_AUTH_MD5")</websocket_key_md5>
  <websocket_private_key>$(xml_escape "$WSS_KEY")</websocket_private_key>
  <websocket_cert>$(xml_escape "$WSS_CERT")</websocket_cert>
</futu_opend>
EOF
chmod 0600 "$CONFIG_FILE"

cat >&2 <<EOF
[futu-docker] OpenD 原生交互登录已启用
[futu-docker] API: ${FUTU_API_IP:-0.0.0.0}:${FUTU_API_PORT:-11111}
[futu-docker] WSS: ${FUTU_WEBSOCKET_IP:-0.0.0.0}:${FUTU_WEBSOCKET_PORT:-33333}（SSL 已配置）
[futu-docker] 持久化目录: $STATE_DIR
[futu-docker] 查看 WebSocket 鉴权 key:
  docker exec futu-opend cat $WSS_DIR/auth.key
[futu-docker] 如触发手机验证，请在另一个终端进入本容器 22222 运维端口处理
EOF

exec "$OPEND_HOME/FutuOpenD" -cfg_file="$CONFIG_FILE" "$@"
