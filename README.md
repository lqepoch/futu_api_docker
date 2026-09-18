# futu_api_docker

Ready-to-run **Futu OpenD** Docker image for Ubuntu 24.04.

Published image:

```text
ghcr.io/lqepoch/futu_api_docker:latest
ghcr.io/lqepoch/futu_api_docker:<OpenD-version>
```

The image already contains the official Futu OpenD Ubuntu package. **Deployment hosts do not build the image and do not need to clone this repository.** Runtime settings are supplied with Docker environment variables / `--env-file`.

## Fastest deployment

On an Ubuntu 24.04 cloud server:

```bash
curl -fsSL https://raw.githubusercontent.com/lqepoch/futu_api_docker/main/install.sh \
  -o /tmp/futu-opend-install.sh \
  && sudo bash /tmp/futu-opend-install.sh
```

The installer asks only for:

1. Futu account / email / phone
2. Futu login password

It then automatically:

- installs Docker if it is missing;
- pulls `ghcr.io/lqepoch/futu_api_docker:latest`;
- creates a persistent OpenD state volume;
- writes a root-only runtime env file at `/etc/futu-opend/futu.env`;
- generates an API RSA key when none is supplied;
- generates a persistent WebSocket authentication key when none is supplied;
- generates a persistent self-signed WSS certificate when none is supplied;
- starts the container;
- drives OpenD's interactive account/password login automatically;
- requests a phone verification code once on the first unverified device login.

OpenD 10.10+ uses interactive account/password login. The container automates that interactive step instead of writing obsolete login-password fields into `FutuOpenD.xml`.

### If Futu sends an SMS code

Wait until the SMS actually arrives, then run:

```bash
sudo futu-opendctl verify 123456
```

Replace `123456` with the received code.

The request and submission are intentionally separate. Futu limits phone-code requests to one per 60 seconds.

Then check:

```bash
sudo futu-opendctl status
sudo futu-opendctl logs
```

## Runtime ports

| Service | Default |
| --- | --- |
| Futu API TCP | container `11111`, host `127.0.0.1:11111` |
| WebSocket/WSS | container `33333`, host `0.0.0.0:33333` |
| OpenD operation/Telnet | container-local `127.0.0.1:22222`, never published by default |

Keeping the Futu API bound to host loopback is the safer default when your trading bot runs on the same machine.

## Runtime environment variables

`.env.example` is a **runtime environment template**. It is not a Docker build configuration.

Minimum direct Docker deployment:

```dotenv
FUTU_LOGIN_ACCOUNT=your-account
FUTU_LOGIN_PASSWORD_B64=<base64-of-login-password>

FUTU_API_IP=0.0.0.0
FUTU_API_PORT=11111
FUTU_API_PUBLISH_ADDRESS=127.0.0.1

FUTU_WEBSOCKET_ENABLED=true
FUTU_WEBSOCKET_IP=0.0.0.0
FUTU_WEBSOCKET_PORT=33333
FUTU_WEBSOCKET_PUBLISH_ADDRESS=0.0.0.0
```

You may use `FUTU_LOGIN_PASSWORD` directly, but `FUTU_LOGIN_PASSWORD_B64` avoids quoting problems in Docker env files. Base64 is encoding, not encryption; protect the env file with mode `0600`.

Optional overrides:

```dotenv
# phone-number account
FUTU_AREA_CODE=+86

# fixed WebSocket authentication key
FUTU_WEBSOCKET_AUTH_KEY=replace-with-your-own-secret

# existing API RSA PKCS#1 private key
FUTU_API_RSA_PRIVATE_KEY_B64=<base64>

# existing CA-signed WSS certificate and unencrypted private key
FUTU_WEBSOCKET_CERT_B64=<base64>
FUTU_WEBSOCKET_PRIVATE_KEY_B64=<base64>
FUTU_WEBSOCKET_TLS_CN=opend.example.com
```

If the RSA key, WSS cert/key, or WebSocket auth key are omitted, the container creates persistent values in the OpenD state volume.

## Direct `docker run` without installer

Create an env file:

```bash
sudo install -d -m 700 /etc/futu-opend
sudo nano /etc/futu-opend/futu.env
sudo chmod 600 /etc/futu-opend/futu.env
```

Example:

```dotenv
FUTU_LOGIN_ACCOUNT=10000000
FUTU_LOGIN_PASSWORD_B64=BASE64_PASSWORD
FUTU_API_IP=0.0.0.0
FUTU_API_PORT=11111
FUTU_API_PUBLISH_ADDRESS=127.0.0.1
FUTU_WEBSOCKET_ENABLED=true
FUTU_WEBSOCKET_IP=0.0.0.0
FUTU_WEBSOCKET_PORT=33333
FUTU_WEBSOCKET_PUBLISH_ADDRESS=0.0.0.0
FUTU_AUTO_REQUEST_PHONE_CODE=true
FUTU_PHONE_CODE_REQUEST_DELAY_SECONDS=8
FUTU_LANG=en
FUTU_LOG_LEVEL=info
```

Run the already-built image:

```bash
docker volume create futu-opend-data

docker pull ghcr.io/lqepoch/futu_api_docker:latest

docker run -d \
  --name futu-opend \
  --restart unless-stopped \
  --init \
  --env-file /etc/futu-opend/futu.env \
  -v futu-opend-data:/home/futu/.com.futunn.FutuOpenD \
  -p 127.0.0.1:11111:11111/tcp \
  -p 0.0.0.0:33333:33333/tcp \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  ghcr.io/lqepoch/futu_api_docker:latest
```

No `docker build` is involved.

## Verification and operations

Phone verification:

```bash
docker exec futu-opend futu-verify phone 123456
```

Request another phone code manually only when needed:

```bash
docker exec futu-opend futu-verify request-phone
```

Picture verification, if Futu requires it:

```bash
docker exec futu-opend futu-verify request-pic
docker exec futu-opend futu-verify pic ABCD
```

OpenD ping:

```bash
docker exec futu-opend futu-verify ping
```

## Keys and certificates

Show the active WebSocket authentication key:

```bash
sudo futu-opendctl ws-key
```

Export the API RSA private key for a client that must use Futu protocol encryption:

```bash
sudo futu-opendctl api-key > futu-api-rsa.pem
chmod 600 futu-api-rsa.pem
```

Export the generated WSS certificate:

```bash
sudo futu-opendctl ws-cert > futu-opend.crt
```

The default WSS certificate is self-signed. For Internet/browser clients, supply a certificate issued for the actual DNS name through `FUTU_WEBSOCKET_CERT_B64` and `FUTU_WEBSOCKET_PRIVATE_KEY_B64`.

## Persistent login/device state

The Docker volume is mounted at:

```text
/home/futu/.com.futunn.FutuOpenD
```

That preserves Futu's device identity, including `F3CNN/Device.dat`. Deleting or corrupting that device file can trigger device-lock verification again. Do not copy the same OpenD state volume to multiple simultaneously running hosts.

The container submits the real login password at startup through OpenD's interactive login flow. It does not depend on `login_by_remember=1` for routine long-running operation.

## Common control commands

Installed by `install.sh`:

```bash
sudo futu-opendctl status
sudo futu-opendctl logs
sudo futu-opendctl verify 123456
sudo futu-opendctl request-code
sudo futu-opendctl ws-key
sudo futu-opendctl api-key
sudo futu-opendctl restart
sudo futu-opendctl update
```

`update` pulls the newest published GHCR image and recreates the container while retaining the state volume.

## Network exposure

If the trading bot is on the same server, keep:

```dotenv
FUTU_API_PUBLISH_ADDRESS=127.0.0.1
```

If another host must connect to TCP 11111, change it to `0.0.0.0` and restrict the cloud security group/UFW rule to the strategy server's source IP.

The OpenD operation/Telnet port 22222 stays container-local. There is no reason to expose that unauthenticated operations surface publicly.

## GitHub Actions: automatic OpenD updates

Workflow:

```text
.github/workflows/docker-publish.yml
```

It runs:

- on relevant commits to `main`;
- manually through `workflow_dispatch`;
- every day at `02:23 UTC`.

The scheduled job:

1. downloads Futu's official latest Ubuntu OpenD archive;
2. validates the tarball;
3. derives the actual OpenD version from the package;
4. computes SHA-256;
5. compares version + SHA-256 against `VERSION` and `UPSTREAM_SHA256`;
6. does nothing when both are unchanged;
7. builds a new Ubuntu 24.04 image when upstream changed;
8. re-verifies the exact upstream SHA-256 during Docker build;
9. publishes:
   - `ghcr.io/lqepoch/futu_api_docker:latest`
   - `ghcr.io/lqepoch/futu_api_docker:<OpenD-version>`
10. generates SBOM/provenance/attestation;
11. records the successfully published upstream version and checksum back into the repository.

The Docker image is therefore built by GitHub Actions, not by deployment machines.

## GHCR visibility

GitHub Container Registry creates new container packages as private by default. This workflow publishes with the repository `GITHUB_TOKEN` and includes:

```text
org.opencontainers.image.source=https://github.com/lqepoch/futu_api_docker
```

That links the package to this repository. After the first successful publish, set the container package visibility to **Public** once in GitHub package settings if the organization does not already enforce the desired visibility. Public GHCR packages can then be pulled anonymously.

## Upstream behavior used by this image

- OpenD 10.10+ defaults to interactive login and asks for account, password, and whether to remember the password.
- Phone-number login supports a country code.
- Phone verification is handled with `req_phone_verify_code` and `input_phone_verify_code -code=...`.
- Futu limits phone-code requests to one per 60 seconds and phone-code submissions to ten per 60 seconds.
- A non-local WebSocket listener requires SSL; certificate and unencrypted private key must be configured together.
- A non-local API listener requires protocol encryption for trading interfaces.
