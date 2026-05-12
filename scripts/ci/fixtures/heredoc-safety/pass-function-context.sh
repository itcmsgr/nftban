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

# Unquoted heredoc inside usage() function — Option-α PASS_FUNCTION_CONTEXT
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]
Version: $VERSION
EOF
}

usage
