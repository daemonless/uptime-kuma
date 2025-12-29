# Uptime Kuma - Self-hosted monitoring tool
# Multi-stage build: compile with npm, run with node + chromium

ARG BASE_VERSION=15
FROM ghcr.io/daemonless/base:${BASE_VERSION} AS builder

# Build dependencies (including C compiler for native modules like sqlite3)
RUN pkg update && pkg install -y \
    node22 npm-node22 git-lite python311 \
    gmake pkgconf sqlite3 FreeBSD-clang FreeBSD-toolchain FreeBSD-clibs-dev \
    && pkg clean -ay

# Get latest release version
ARG UPTIME_KUMA_VERSION=""
RUN if [ -z "${UPTIME_KUMA_VERSION}" ]; then \
        UPTIME_KUMA_VERSION=$(fetch -qo - "https://api.github.com/repos/louislam/uptime-kuma/releases/latest" | \
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'); \
    fi && \
    echo "Building Uptime Kuma ${UPTIME_KUMA_VERSION}" && \
    git clone --depth 1 --branch "${UPTIME_KUMA_VERSION}" \
        https://github.com/louislam/uptime-kuma.git /app/uptime-kuma && \
    echo "${UPTIME_KUMA_VERSION}" > /app/version

WORKDIR /app/uptime-kuma

# Install and build (skip git checkout from npm run setup - we already have the right version)
RUN npm ci --omit dev && npm run download-dist

# Patch Playwright for FreeBSD compatibility
RUN sed -i '' "s/process.platform === 'linux'/process.platform === 'freebsd'/" \
    node_modules/playwright-core/lib/server/registry/index.js

# Production image
FROM ghcr.io/daemonless/base:${BASE_VERSION}

ARG FREEBSD_ARCH=amd64
ARG PACKAGES="node22 chromium"

LABEL org.opencontainers.image.title="Uptime Kuma" \
    org.opencontainers.image.description="A fancy self-hosted monitoring tool on FreeBSD" \
    org.opencontainers.image.source="https://github.com/daemonless/uptime-kuma" \
    org.opencontainers.image.url="https://uptime.kuma.pet/" \
    org.opencontainers.image.documentation="https://github.com/louislam/uptime-kuma/wiki" \
    org.opencontainers.image.licenses="BSD-2-Clause" \
    org.opencontainers.image.vendor="daemonless" \
    org.opencontainers.image.authors="daemonless" \
    io.daemonless.port="3001" \
    io.daemonless.arch="${FREEBSD_ARCH}" \
    io.daemonless.config-mount="/config" \
    io.daemonless.category="Utilities" \
    io.daemonless.upstream-mode="github" \
    io.daemonless.upstream-repo="louislam/uptime-kuma" \
    io.daemonless.packages="${PACKAGES}" \
    org.freebsd.jail.allow.raw_sockets="required"

# Runtime dependencies
RUN pkg update && \
    pkg install -y ${PACKAGES} && \
    pkg clean -ay && \
    rm -rf /var/cache/pkg/* /var/db/pkg/repos/*

# Create chromium symlink for Uptime Kuma compatibility
RUN ln -sf /usr/local/bin/chrome /usr/bin/chromium || true

# Copy built application from builder (with correct ownership)
COPY --from=builder --chown=bsd:bsd /app/uptime-kuma /app/uptime-kuma
COPY --from=builder --chown=bsd:bsd /app/version /app/version

# Create directories
RUN mkdir -p /config && chown bsd:bsd /config

# Copy service files
COPY root/ /
RUN chmod +x /etc/services.d/*/run /etc/cont-init.d/* 2>/dev/null || true

# Environment for Chromium support
ENV UPTIME_KUMA_IS_CONTAINER=1
ENV UPTIME_KUMA_ALLOW_ALL_CHROME_EXEC=1
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV DATA_DIR=/config

EXPOSE 3001
VOLUME /config
