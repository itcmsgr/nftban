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
# expected-exit: 1
# expected-substr: UNESCAPED_BACKTICK_IN_UNQUOTED_HEREDOC

# v1.107.1-class defect simulation: unescaped backticks in unquoted heredoc
# Bash will try to execute `%preun` as a command at heredoc-write time
cat <<EOF
Some doc text
And `%preun` runs too late to help.
This would corrupt generated content.
EOF
