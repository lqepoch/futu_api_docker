# futu_api_docker

Ubuntu 24.04 container image for the official **Futu OpenD** Linux package.

Image target:

```text
ghcr.io/lqepoch/futu_api_docker:latest
ghcr.io/lqepoch/futu_api_docker:<OpenD-version>
```

The repository downloads the official Futu Ubuntu OpenD archive at build time. GitHub Actions checks the official Ubuntu package every day, compares both the OpenD version and SHA-256, and publishes a new image to GHCR only when the upstream artifact changes.

## Important: OpenD 10.10+ login behavior

OpenD 10.10 removed account/password settings from the command-line configuration file. The real first-login flow is interactive:

1. start OpenD;
2. enter the Futu account;
3. enter the Futu login password;
4. choose to remember the password;
5. if device-lock verification is required, request the phone verification code separately;
6. wait for the SMS to arrive;
7. submit the received code separately;
8. after login reaches Ready, later starts can use `-login_account=... -login_by_remember=1`.

The container persists `~/.com.futunn.FutuOpenD`, including the device identity used by OpenD. Do not clone the same persisted `Device.dat` to multiple servers.

Futu limits `req_phone_verify_code` to one request per 60 seconds. This image never guesses an SMS arrival delay and never chains request + submit into one timed script.

## Ports

| Function | Container port | Default host publish | Notes |
| --- | ---: | --- | --- |
| Futu API TCP | 11111 | `127.0.0.1:11111` | Change bind address only when a remote strategy host needs access |
| WebSocket / WSS | 33333 | `0.0.0.0:33333` | TLS certificate and unencrypted TLS private key are required by this image |
| OpenD Telnet operations | 22222 | not published | Intentionally limited to container localhost; use `docker exec ... futu-opend-cli` |

## 1. Deploy on an Ubuntu 24.04 server

The following assumes Docker Engine and Docker Compose plugin are already installed.

```bash
sudo mkdir -p /opt/futu-opend
sudo chown "$USER":"$USER" /opt/futu-opend
cd /opt/futu-opend

git clone https://github.com/lqepoch/futu_api_docker.git .
cp .env.example .env
mkdir -p secrets

docker pull ghcr.io/lqepoch/futu_api_docker:latest
```

Edit `.env` before the first launch.

### API RSA key

For a remote trading API connection, OpenD requires protocol encryption. Futu documents a PKCS#1 RSA private key and currently uses a 1024-bit RSA key for this protocol.

Generate one locally on the server:

```bash
openssl genrsa -traditional -out secrets/futu_api_rsa.pem 1024
chmod 600 secrets/futu_api_rsa.pem
```

The default `.env` already points OpenD at:

```text
/run/user-secrets/futu_api_rsa.pem
```

Your Futu API strategy/client must use the same RSA private-key file and enable protocol encryption.

### WebSocket TLS certificate and private key

For a public/non-local WebSocket listener, OpenD requires SSL. The TLS private key must not have a password.

For a temporary self-signed certificate, replace `opend.example.com` with your real DNS name:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
  -keyout secrets/websocket.key \
  -out secrets/websocket.crt \
  -subj "/CN=opend.example.com" \
  -addext "subjectAltName=DNS:opend.example.com"

chmod 600 secrets/websocket.key
chmod 644 secrets/websocket.crt
```

For an Internet-facing browser/JavaScript client, use a CA-signed certificate for the actual DNS name.

Set a WebSocket authentication key in `.env`:

```dotenv
FUTU_WEBSOCKET_AUTH_KEY=replace-with-a-long-random-secret
```

The entrypoint calculates the required 32-character MD5 value inside the container. You can instead provide `FUTU_WEBSOCKET_AUTH_KEY_MD5`.

## 2. First login: account + password + optional verification code

Stop any existing service first:

```bash
cd /opt/futu-opend
docker compose down
```

Start a temporary interactive OpenD container:

```bash
docker compose run --rm --service-ports \
  --name futu-opend-login \
  futu-opend login
```

OpenD will prompt in this terminal for:

```text
account
login password
whether to remember the password
```

Choose the option that allows OpenD to remember the password. If the account is a phone number, OpenD also supports entering it in the interactive account field as `+country-code phone-number`.

### If OpenD requires a phone verification code

Keep the first terminal and the `futu-opend-login` container running.

Open a **second SSH terminal** and request the SMS only after OpenD reports that phone verification is required:

```bash
docker exec -it futu-opend-login \
  futu-opend-cli req_phone_verify_code
```

Now wait for the SMS. There is deliberately no fixed sleep timer here.

After the code arrives:

```bash
docker exec -it futu-opend-login \
  futu-opend-cli input_phone_verify_code -code=123456
```

Replace `123456` with the actual code.

The official OpenD limits are:

- request phone code: at most 1 request per 60 seconds;
- submit phone code: at most 10 requests per 60 seconds.

### If OpenD requires a picture verification code

The operation commands are separate as well:

```bash
docker exec -it futu-opend-login futu-opend-cli req_pic_verify_code
docker exec -it futu-opend-login futu-opend-cli input_pic_verify_code -code=1234
```

Use the code shown/provided by OpenD.

### Finish first login

Wait until OpenD reports that login is ready. Then stop the temporary interactive process with `Ctrl+C`.

The named Compose volume `futu-state` retains the remembered-login state and device identity.

## 3. Configure remembered login

Put the account in `.env`:

```dotenv
FUTU_LOGIN_ACCOUNT=your-account
```

For a phone-number account used by remembered login:

```dotenv
FUTU_LOGIN_ACCOUNT=13800138000
FUTU_AREA_CODE=+86
```

The login password is not stored in `.env`. OpenD reads the remembered credential from its persisted state.

Start the normal background service:

```bash
docker compose up -d
docker compose ps
docker compose logs -f --tail=200 futu-opend
```

Check OpenD's internal operations port:

```bash
docker exec -it futu-opend futu-opend-cli ping
```

If a later security event causes OpenD to request phone verification, use the same two-step sequence against the running service:

```bash
docker exec -it futu-opend futu-opend-cli req_phone_verify_code

# wait until the SMS actually arrives

docker exec -it futu-opend \
  futu-opend-cli input_phone_verify_code -code=123456
```

## 4. Environment-variable secret injection

File mounts are the default server deployment because they keep key material out of normal environment inspection. The image also supports base64 environment variables for secret managers, CI/CD, or orchestrators.

Supported variables:

```text
FUTU_API_RSA_PRIVATE_KEY_B64
FUTU_WEBSOCKET_CERT_B64
FUTU_WEBSOCKET_PRIVATE_KEY_B64
```

Example:

```bash
API_RSA_B64="$(base64 -w0 secrets/futu_api_rsa.pem)"
WS_CERT_B64="$(base64 -w0 secrets/websocket.crt)"
WS_KEY_B64="$(base64 -w0 secrets/websocket.key)"

FUTU_API_RSA_PRIVATE_KEY_B64="$API_RSA_B64" \
FUTU_WEBSOCKET_CERT_B64="$WS_CERT_B64" \
FUTU_WEBSOCKET_PRIVATE_KEY_B64="$WS_KEY_B64" \
docker compose up -d
```

When both base64 and file variables are present, the base64 variable takes precedence.

## 5. Network exposure

### Strategy bot on the same cloud server

Keep:

```dotenv
FUTU_API_BIND_ADDRESS=127.0.0.1
FUTU_API_HOST_PORT=11111
```

The strategy connects to:

```text
127.0.0.1:11111
```

No public firewall rule for port 11111 is required.

### Strategy bot on another server

Set:

```dotenv
FUTU_API_BIND_ADDRESS=0.0.0.0
```

Restrict the server firewall/security group to the strategy server's source IP:

```bash
sudo ufw allow from <STRATEGY_SERVER_IP> to any port 11111 proto tcp
```

Keep `FUTU_REQUIRE_API_RSA=true`.

### WSS

If WSS really needs Internet access:

```bash
sudo ufw allow from <TRUSTED_CLIENT_IP> to any port 33333 proto tcp
```

Port 22222 is intentionally not published. Verification and operations use `docker exec`, so the Telnet operation interface is not exposed to the Internet.

## 6. Update and rollback

Pull the latest successfully published image:

```bash
cd /opt/futu-opend
docker compose pull
docker compose up -d
```

For deterministic deployment, pin an OpenD image version in `.env`:

```dotenv
FUTU_IMAGE=ghcr.io/lqepoch/futu_api_docker:10.10.7008
```

Rollback is then only an image-tag change followed by:

```bash
docker compose pull
docker compose up -d
```

The persistent login/device volume is kept across image upgrades.

## 7. GitHub Actions automatic upstream update

Workflow:

```text
.github/workflows/docker-publish.yml
```

Behavior:

1. runs on relevant pushes to `main`, manual dispatch, and once per day;
2. downloads the official latest Ubuntu OpenD archive;
3. validates the tar archive;
4. parses the real OpenD version from the archive;
5. calculates SHA-256;
6. compares with `VERSION` and `UPSTREAM_SHA256`;
7. a scheduled run exits without building when both are unchanged;
8. on change, builds the Ubuntu 24.04 image for `linux/amd64`;
9. verifies the exact upstream SHA-256 again during Docker build;
10. publishes:
   - `ghcr.io/lqepoch/futu_api_docker:latest`
   - `ghcr.io/lqepoch/futu_api_docker:<detected-version>`
11. emits SBOM/provenance and a GitHub artifact attestation;
12. after a successful publish, commits the detected version and checksum back to the repository.

The workflow uses `GITHUB_TOKEN` with `packages: write`; no Docker Hub account is involved.

## 8. GHCR public visibility

This repository is public and the image carries:

```text
org.opencontainers.image.source=https://github.com/lqepoch/futu_api_docker
```

The workflow publishes with the repository `GITHUB_TOKEN`, linking the container package to this repository. After the first successful publish, verify the package page shows **Public**. Organization-level package policy can override default inheritance; if that policy is enabled, set the package visibility to Public once in the package settings.

Public GHCR images can be pulled anonymously:

```bash
docker pull ghcr.io/lqepoch/futu_api_docker:latest
```

## 9. Operational checks

```bash
# running state
docker compose ps

# logs
docker compose logs --tail=200 futu-opend

# health status
docker inspect --format '{{json .State.Health}}' futu-opend

# OpenD operation-channel ping
docker exec -it futu-opend futu-opend-cli ping

# inspect persisted device file
docker exec futu-opend \
  sh -lc 'ls -l ~/.com.futunn.FutuOpenD/F3CNN/Device.dat'
```

If `Device.dat` disappears or is damaged, OpenD generates a new device identity and device-lock verification can be triggered again.
