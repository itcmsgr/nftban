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
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git make bash linux-pam-dev gcc musl-dev

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Install templ for HTML template generation
RUN go install github.com/a-h/templ/cmd/templ@latest
RUN templ generate

# Build all binaries
RUN CGO_ENABLED=1 GOOS=linux go build -o /out/nftban-core ./cmd/nftban-core
RUN CGO_ENABLED=1 GOOS=linux go build -o /out/nftband ./cmd/nftband
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/nftban-ui ./cmd/nftban-ui

# Stage 2: Minimal runtime image
FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    nftables \
    jq \
    curl \
    ca-certificates \
    linux-pam

# Create nftban user and directories
RUN addgroup -S nftban && adduser -S -G nftban nftban
RUN mkdir -p /etc/nftban /var/lib/nftban /var/log/nftban /run/nftban
RUN chown -R nftban:nftban /var/lib/nftban /var/log/nftban /run/nftban

# Copy binaries from builder
COPY --from=builder /out/nftban-core /usr/bin/
COPY --from=builder /out/nftband /usr/bin/
COPY --from=builder /out/nftban-ui /usr/bin/

# Copy CLI scripts
COPY cli/sbin/nftban /usr/sbin/nftban
COPY cli/lib/nftban /usr/lib/nftban

# Copy default configuration
COPY cli/lib/nftban/setup/*.conf /etc/nftban/

# Set permissions
RUN chmod +x /usr/sbin/nftban /usr/bin/nftban-*

# Version label
ARG VERSION=dev
LABEL org.opencontainers.image.title="NFTBan"
LABEL org.opencontainers.image.description="Linux IPS & nftables Firewall Manager"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/itcmsgr/nftban"
LABEL org.opencontainers.image.licenses="MPL-2.0"

# Default command
ENTRYPOINT ["/usr/sbin/nftban"]
CMD ["help"]
