# =============================================================================
# NFTBan Docker Image
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# Multi-stage build for minimal production image.
# This image is for development/testing - production deployments should use
# native DEB/RPM packages for proper systemd integration.
#
# Usage:
#   docker build -t nftban .
#   docker run --cap-add NET_ADMIN --network host nftban version
# =============================================================================

# Stage 1: Build Go binaries
# v1.19.0: Pin builder image for OpenSSF Scorecard compliance (R40)
# Update SHA: docker pull golang:1.25-alpine && docker inspect --format='{{index .RepoDigests 0}}' golang:1.25-alpine
FROM golang:1.25-alpine AS builder

# hadolint ignore=DL3018
RUN apk add --no-cache git make bash gcc musl-dev

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Build all binaries
RUN mkdir -p /out && \
    CGO_ENABLED=1 GOOS=linux go build -o /out/nftban-core ./cmd/nftban-core && \
    CGO_ENABLED=1 GOOS=linux go build -o /out/nftband ./cmd/nftband

# Stage 2: Minimal runtime image
# Pinned to SHA for OpenSSF Scorecard compliance
FROM alpine:3.20@sha256:b0cb30c51c47cdfde647364301758b14c335dea2fddc9490d4f007d67ecb2538

# hadolint ignore=DL3018
RUN apk add --no-cache \
    bash \
    nftables \
    jq \
    curl \
    ca-certificates && \
    addgroup -S nftban && \
    adduser -S -G nftban nftban && \
    mkdir -p /etc/nftban /var/lib/nftban /var/log/nftban /run/nftban && \
    chown -R nftban:nftban /var/lib/nftban /var/log/nftban /run/nftban

# Copy binaries from builder
COPY --from=builder /out/nftban-core /usr/bin/
COPY --from=builder /out/nftband /usr/bin/

# Copy CLI scripts
COPY cli/sbin/nftban /usr/sbin/nftban
COPY cli/lib/nftban /usr/lib/nftban

# Copy default configuration and set permissions
COPY cli/lib/nftban/setup/*.conf /etc/nftban/
RUN chmod +x /usr/sbin/nftban /usr/bin/nftban-*

# Version label
ARG VERSION=dev
LABEL org.opencontainers.image.title="NFTBan"
LABEL org.opencontainers.image.description="Linux IPS & nftables Firewall Manager"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/itcmsgr/nftban"
LABEL org.opencontainers.image.licenses="MPL-2.0"

# Run as non-root user (requires --cap-add NET_ADMIN at runtime for nftables)
USER nftban

# Default command
ENTRYPOINT ["/usr/sbin/nftban"]
CMD ["help"]
