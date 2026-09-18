#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${FUTU_IMAGE:-ghcr.io/lqepoch/futu_api_docker:latest}"
CONTAINER="${FUTU_CONTAINER_NAME:-futu-opend}"
VOLUME="${FUTU_STATE_VOLUME:-futu-opend-data}"
ENV_DIR="${FUTU_ENV_DIR:-/etc/futu-opend}"
ENV_FILE="$ENV_DIR/futu.env"
META_FILE="$ENV_DIR/deploy.env"
API_PORT="${FUTU_API_PORT:-11111}"
WS_PORT="${FUTU_WEBSOCKET_PORT:-33333}"
API_PUBLISH="${FUTU_API_PUBLISH_ADDRESS:-127.0.0.1}"
WS_PUBLISH="${FUTU_WEBSOCKET_PUBLISH_ADDRESS:-0.0.0.0}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this installer with sudo/root." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found; installing Ubuntu docker.io package..." >&2
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io ca-certificates curl openssl
  systemctl enable --now docker
fi

if ! command -v openssl >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
fi

if ! docker info >/dev/null 2>&1; then
  systemctl enable --now docker
fi

read_from_tty() {
  local prompt="$1"
  local value=""
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r value </dev/tty
  printf '%s' "$value"
}

read_secret_from_tty() {
  local prompt="$1"
  local value=""
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r -s value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "$value"
}

account="${FUTU_LOGIN_ACCOUNT:-}"
password="${FUTU_LOGIN_PASSWORD:-}"

if [[ -z "$account" ]]; then
  account="$(read_from_tty 'Futu account / email / phone: ')"
fi
if [[ -z "$password" ]]; then
  password="$(read_secret_from_tty 'Futu login password: ')"
fi

[[ -n "$account" ]] || { echo "Futu account cannot be empty." >&2; exit 1; }
[[ -n "$password" ]] || { echo "Futu password cannot be empty." >&2; exit 1; }

password_b64="$(printf '%s' "$password" | base64 -w0)"
unset password FUTU_LOGIN_PASSWORD

ws_auth_key="${FUTU_WEBSOCKET_AUTH_KEY:-}"
if [[ -z "$ws_auth_key" ]]; then
  ws_auth_key="$(openssl rand -hex 32)"
fi

install -d -m 0700 "$ENV_DIR"
cat > "$ENV_FILE" <<EOF
FUTU_LOGIN_ACCOUNT=$account
FUTU_LOGIN_PASSWORD_B64=$password_b64
FUTU_AREA_CODE=${FUTU_AREA_CODE:-}
FUTU_REMEMBER_PASSWORD=false
FUTU_AUTO_REQUEST_PHONE_CODE=true
FUTU_PHONE_CODE_REQUEST_DELAY_SECONDS=8
FUTU_API_IP=0.0.0.0
FUTU_API_PORT=$API_PORT
FUTU_API_PUBLISH_ADDRESS=$API_PUBLISH
FUTU_TELNET_IP=127.0.0.1
FUTU_TELNET_PORT=22222
FUTU_WEBSOCKET_ENABLED=true
FUTU_WEBSOCKET_IP=0.0.0.0
FUTU_WEBSOCKET_PORT=$WS_PORT
FUTU_WEBSOCKET_PUBLISH_ADDRESS=$WS_PUBLISH
FUTU_WEBSOCKET_AUTH_KEY=$ws_auth_key
FUTU_WEBSOCKET_TLS_CN=${FUTU_WEBSOCKET_TLS_CN:-futu-opend}
FUTU_LANG=en
FUTU_LOG_LEVEL=info
FUTU_PUSH_PROTO_TYPE=0
FUTU_PRICE_REMINDER_PUSH=1
FUTU_AUTO_HOLD_QUOTE_RIGHT=1
FUTU_FUTURES_TZ=UTC+8
EOF
chmod 0600 "$ENV_FILE"

cat > "$META_FILE" <<EOF
FUTU_IMAGE=$IMAGE
FUTU_CONTAINER_NAME=$CONTAINER
FUTU_STATE_VOLUME=$VOLUME
FUTU_ENV_FILE=$ENV_FILE
EOF
chmod 0600 "$META_FILE"

docker volume create "$VOLUME" >/dev/null
docker pull "$IMAGE"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --init \
  --env-file "$ENV_FILE" \
  -v "$VOLUME:/home/futu/.com.futunn.FutuOpenD" \
  -p "$API_PUBLISH:$API_PORT:$API_PORT/tcp" \
  -p "$WS_PUBLISH:$WS_PORT:$WS_PORT/tcp" \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  "$IMAGE" >/dev/null

cat > /usr/local/bin/futu-opendctl <<'CTL'
#!/usr/bin/env bash
set -Eeuo pipefail

meta="/etc/futu-opend/deploy.env"
if [[ -r "$meta" ]]; then
  # shellcheck disable=SC1090
  source "$meta"
fi

container="${FUTU_CONTAINER_NAME:-futu-opend}"
volume="${FUTU_STATE_VOLUME:-futu-opend-data}"
image="${FUTU_IMAGE:-ghcr.io/lqepoch/futu_api_docker:latest}"
env_file="${FUTU_ENV_FILE:-/etc/futu-opend/futu.env}"

get_env() {
  local key="$1"
  grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d= -f2-
}

case "${1:-}" in
  status)
    docker ps --filter "name=^/${container}$"
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container"
    ;;
  logs)
    exec docker logs -f --tail="${2:-100}" "$container"
    ;;
  verify)
    [[ -n "${2:-}" ]] || { echo "Usage: futu-opendctl verify <SMS_CODE>" >&2; exit 2; }
    exec docker exec "$container" futu-verify phone "$2"
    ;;
  request-code)
    exec docker exec "$container" futu-verify request-phone
    ;;
  verify-pic)
    [[ -n "${2:-}" ]] || { echo "Usage: futu-opendctl verify-pic <CODE>" >&2; exit 2; }
    exec docker exec "$container" futu-verify pic "$2"
    ;;
  request-pic)
    exec docker exec "$container" futu-verify request-pic
    ;;
  api-key)
    exec docker exec "$container" futu-verify show-api-key
    ;;
  ws-key)
    exec docker exec "$container" futu-verify show-ws-key
    ;;
  ws-cert)
    exec docker exec "$container" futu-verify show-ws-cert
    ;;
  restart)
    exec docker restart "$container"
    ;;
  update)
    api_port="$(get_env FUTU_API_PORT)"
    ws_port="$(get_env FUTU_WEBSOCKET_PORT)"
    api_publish="$(get_env FUTU_API_PUBLISH_ADDRESS)"
    ws_publish="$(get_env FUTU_WEBSOCKET_PUBLISH_ADDRESS)"
    docker pull "$image"
    docker rm -f "$container" >/dev/null 2>&1 || true
    exec docker run -d --name "$container" --restart unless-stopped --init \
      --env-file "$env_file" \
      -v "$volume:/home/futu/.com.futunn.FutuOpenD" \
      -p "$api_publish:$api_port:$api_port/tcp" \
      -p "$ws_publish:$ws_port:$ws_port/tcp" \
      --security-opt no-new-privileges:true --cap-drop ALL "$image"
    ;;
  *)
    echo "Usage: futu-opendctl {status|logs|verify <code>|request-code|verify-pic <code>|request-pic|api-key|ws-key|ws-cert|restart|update}" >&2
    exit 2
    ;;
esac
CTL
chmod 0755 /usr/local/bin/futu-opendctl

echo
echo "Futu OpenD is running from the prebuilt image: $IMAGE"
echo "Runtime env file: $ENV_FILE (mode 0600)"
echo "API endpoint: $API_PUBLISH:$API_PORT"
echo "WSS endpoint: $WS_PUBLISH:$WS_PORT"
echo
echo "Normal next step:"
echo "  sudo futu-opendctl logs"
echo
echo "If Futu sends an SMS, wait for the message and then run exactly one command:"
echo "  sudo futu-opendctl verify 123456"
echo
echo "Useful commands:"
echo "  sudo futu-opendctl status"
echo "  sudo futu-opendctl ws-key"
echo "  sudo futu-opendctl api-key"
echo "  sudo futu-opendctl update"
