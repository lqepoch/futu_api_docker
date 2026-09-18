# syntax=docker/dockerfile:1.7

ARG FUTU_OPEND_DOWNLOAD_URL="https://www.futunn.com/download/fetch-lasted-link?name=opend-ubuntu"
ARG FUTU_OPEND_ARCHIVE_SHA256=""

FROM ubuntu:24.04 AS downloader
ARG FUTU_OPEND_DOWNLOAD_URL
ARG FUTU_OPEND_ARCHIVE_SHA256
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

RUN set -eux; \
    effective_url="$(curl --fail --location --show-error --silent \
      --retry 5 --retry-delay 2 --retry-all-errors \
      --output /tmp/futu-opend.tar.gz \
      --write-out '%{url_effective}' \
      "${FUTU_OPEND_DOWNLOAD_URL}")"; \
    printf '%s\n' "$effective_url" > /tmp/FUTU_UPSTREAM_URL; \
    if [ -n "${FUTU_OPEND_ARCHIVE_SHA256}" ]; then \
      printf '%s  %s\n' "${FUTU_OPEND_ARCHIVE_SHA256}" /tmp/futu-opend.tar.gz | sha256sum -c -; \
    fi; \
    tar -tzf /tmp/futu-opend.tar.gz >/dev/null; \
    mkdir -p /tmp/unpacked /opt/futu-opend; \
    tar -xzf /tmp/futu-opend.tar.gz -C /tmp/unpacked; \
    executable="$(find /tmp/unpacked -type f -name FutuOpenD -print -quit)"; \
    test -n "$executable"; \
    cp -a "$(dirname "$executable")/." /opt/futu-opend/; \
    cp /tmp/FUTU_UPSTREAM_URL /opt/futu-opend/FUTU_UPSTREAM_URL; \
    chmod 0755 /opt/futu-opend/FutuOpenD; \
    test -f /opt/futu-opend/FutuOpenD.xml

FROM ubuntu:24.04 AS runtime
ARG FUTU_OPEND_VERSION="unknown"

LABEL org.opencontainers.image.source="https://github.com/lqepoch/futu_api_docker" \
      org.opencontainers.image.title="Futu OpenD on Ubuntu 24.04" \
      org.opencontainers.image.description="Futu OpenD with native interactive login, persistent state, API RSA and WSS" \
      org.opencontainers.image.version="${FUTU_OPEND_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Hong_Kong \
    HOME=/home/futu \
    FUTU_API_IP=0.0.0.0 \
    FUTU_API_PORT=11111 \
    FUTU_TELNET_IP=127.0.0.1 \
    FUTU_TELNET_PORT=22222 \
    FUTU_WEBSOCKET_IP=0.0.0.0 \
    FUTU_WEBSOCKET_PORT=33333

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates netcat-openbsd openssl tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /bin/bash futu \
    && install -d -o futu -g futu -m 0700 /home/futu/.com.futunn.FutuOpenD

COPY --from=downloader --chown=futu:futu /opt/futu-opend /opt/futu-opend
COPY --chmod=0755 scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN ldd /opt/futu-opend/FutuOpenD | tee /tmp/futu-ldd.txt \
    && ! grep -q 'not found' /tmp/futu-ldd.txt

USER futu:futu
WORKDIR /opt/futu-opend

VOLUME ["/home/futu/.com.futunn.FutuOpenD"]
EXPOSE 11111 33333

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
  CMD nc -z -w 3 127.0.0.1 "${FUTU_API_PORT:-11111}" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
