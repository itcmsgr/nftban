#!/usr/bin/env bash
# =============================================================================
# NFTBan - Firewall Validate Run Wrapper (Option C output capture)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="firewall_validate_run"
# meta:type="helper"
# meta:version="1.131.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:description="V131.1 D13 Option C output-capture wrapper. ExecStart target of nftban-firewall-validate.service: runs the audited read-only nftban-validate --json as root+CAP_NET_ADMIN, then writes the validator JSON to a group-readable file under /run/nftban/firewall-validate/last.json (chgrp nftban, chmod 0640) so nftban-group operators can read the result WITHOUT root and WITHOUT systemd-journal/adm membership. The journal-read path (D10) failed cross-family for non-root operators because the unit journal is not readable by an unprivileged nftban-group member; this file hand-off fixes that. Also echoes the JSON to stdout so the root/audit journal copy is preserved, and PRESERVES the validator exit code (DEGRADED states return non-zero and must propagate)."
# meta:input="None (delegates to nftban-validate which reads kernel nft state)"
# meta:output="/run/nftban/firewall-validate/last.json (group nftban, 0640) + stdout copy"
# meta:depends="/usr/lib/nftban/bin/nftban-validate"
# meta:inventory.files="/run/nftban/firewall-validate/last.json"
# meta:inventory.binaries="/usr/lib/nftban/bin/nftban-validate"
# meta:inventory.env_vars="NFTBAN_RUN_DIR,NFTBAN_VALIDATE_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-firewall-validate.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# Runtime contract:
#   - Runs ONLY as the ExecStart of nftban-firewall-validate.service (root).
#   - Writes a group-readable JSON snapshot the CLI reads back (see
#     cli/lib/nftban/cli/cmd_firewall.sh::_invoke_validator_json).
#   - The NFTBAN_RUN_DIR / NFTBAN_VALIDATE_BIN overrides exist ONLY so the
#     deterministic test can exercise this on a dev host without root or the
#     nftban group. Production uses /run/nftban and the installed validator.
#   - chgrp/chmod are best-effort (|| true): a non-nftban-group dev host must
#     not fail. The file-write + chmod happen REGARDLESS of validator rc.
# =============================================================================

set -Eeuo pipefail

# Runtime dir + output file (NFTBAN_RUN_DIR override is test-only).
_dir="${NFTBAN_RUN_DIR:-/run/nftban}/firewall-validate"
_file="$_dir/last.json"

# Validator binary (NFTBAN_VALIDATE_BIN override is test-only).
_bin="${NFTBAN_VALIDATE_BIN:-/usr/lib/nftban/bin/nftban-validate}"

# Pre-run stale-output guard: never let the CLI read a previous run's JSON if
# this run produces nothing (e.g. validator crashes before printing).
rm -f "$_file" 2>/dev/null || true

# Ensure the runtime dir exists and is group-readable by the nftban group.
# V131.2 D13 / v1.175: under the service the dir is created per-start by the
# unit's `+`-prefixed ExecStartPre (/usr/bin/install -d -o root -g nftban -m 2750);
# it is NO LONGER created by tmpfiles (v1.175 BUG-TMPFILES: the root-under-nftban
# transition tripped systemd-tmpfiles exit 73). ReadWritePaths binds that
# existing dir writable. This mkdir is a best-effort no-op for the standalone/dev
# path; under the narrow ReadWritePaths a parent-write mkdir of the bound subdir
# would fail, so it MUST NOT abort the wrapper under set -e before the write attempt.
mkdir -p "$_dir" 2>/dev/null || true
chgrp nftban "$_dir" 2>/dev/null || true
chmod 0750 "$_dir" 2>/dev/null || true

# Run the validator, capturing stdout and PRESERVING its exit code. The
# `|| rc=$?` form is required under `set -e`: a bare `out=$(...)` assignment
# from a non-zero command substitution would trigger errexit and abort before
# we could write the file or read $? (DEGRADED states return non-zero).
rc=0
out=$("$_bin" --json 2>/dev/null) || rc=$?

# Write the group-readable snapshot the non-root CLI reads back. This MUST
# happen regardless of validator rc (DEGRADED states still emit JSON we want).
printf '%s\n' "$out" > "$_file"
chgrp nftban "$_file" 2>/dev/null || true
chmod 0640 "$_file" 2>/dev/null || true

# Keep the journal/audit copy for root (StandardOutput=journal).
printf '%s\n' "$out"

# Propagate the validator's true exit code (non-zero DEGRADED must surface).
exit "$rc"
