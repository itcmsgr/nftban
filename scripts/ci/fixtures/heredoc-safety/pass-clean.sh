#!/usr/bin/env bash
# =============================================================================
# NFTBan V108 Item 3 — CI Gate Test Fixture
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="heredoc-safety-fixture"
# meta:type="test-fixture"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-10"
# meta:description="Synthetic shell script for V108 Item 3 CI gate testing"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
# expected-exit: 0
# expected-substr: PASS

# Quoted heredoc with all kinds of risk tokens — all literal
PKG_VERSION=1.0.0
cat <<'QUOTED'
This contains a backtick: `literal`
And command subst: $(date)
And arith: $((1+1))
And vars: $PKG_VERSION ${PKG_VERSION}
All literal because heredoc is quoted.
QUOTED

# Unquoted heredoc with intentional var-ref expansion (REQUIRED_EXPANSION)
cat <<EOF
Version: ${PKG_VERSION}
Built by: gituser
EOF
