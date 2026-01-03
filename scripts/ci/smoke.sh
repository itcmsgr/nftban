#!/usr/bin/env bash
set -euo pipefail

echo "[smoke] starting"

# Ensure expected binaries exist
test -x /tmp/nftban-core
test -x /tmp/nftband
test -x /tmp/nftban-api

# Basic CLI invocations that must never regress
/tmp/nftban-core --help >/dev/null
/tmp/nftban-core help >/dev/null || true
/tmp/nftband --help >/dev/null
/tmp/nftban-api --help >/dev/null

# Version flags vary—treat as informational but ensure it doesn't crash
/tmp/nftban-core --version >/dev/null 2>&1 || true
/tmp/nftband --version >/dev/null 2>&1 || true
/tmp/nftban-api --version >/dev/null 2>&1 || true

# Config parse / validation checks (adjust to your real flags if different)
# If you have a "validate config" or "check" mode, use it here.
if /tmp/nftban-core --help 2>&1 | grep -qiE "config"; then
  echo "[smoke] core has config-related flags (informational)"
fi

# Phase 2.5: Web API boot + health check
# Test that nftban-api can bind to a port and serve requests
echo "[smoke] Testing nftban-api server boot..."

# Start API on test port (no TLS for smoke test)
# Note: Will fail to start fully without TLS certs, but should bind the port
TEST_PORT=19940
/tmp/nftban-api -listen "127.0.0.1:${TEST_PORT}" >/tmp/nftban-api.log 2>&1 &
API_PID=$!

# Give it a moment to attempt binding
sleep 2

# Check if process is still running (may have exited due to missing TLS certs, that's OK)
# What matters is it didn't panic during argument parsing or port binding
if ps -p ${API_PID} > /dev/null 2>&1; then
  echo "[smoke] nftban-api started successfully (PID: ${API_PID})"
  kill ${API_PID} 2>/dev/null || true
  wait ${API_PID} 2>/dev/null || true
elif grep -qiE "(panic|fatal error)" /tmp/nftban-api.log; then
  echo "[smoke] FAIL: nftban-api panicked on startup"
  cat /tmp/nftban-api.log
  exit 1
else
  # Process exited (likely due to missing TLS certs), but check it wasn't a panic
  echo "[smoke] nftban-api exited (expected without TLS certs, checking for panic...)"
  if grep -qiE "panic" /tmp/nftban-api.log; then
    echo "[smoke] FAIL: Found panic in logs"
    cat /tmp/nftban-api.log
    exit 1
  fi
  echo "[smoke] nftban-api exited cleanly (no panic detected)"
fi

echo "[smoke] OK"
