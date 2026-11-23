#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 GeoBan country exceptions (CLI side)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="geoban_country_exception_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 BUG-GEOBAN-WHITELIST-CC-WRITES-FILE-NEVER-LOADED, owner GO 2026-11-23 option B: `nftban geoban whitelist <CC>` is a GeoBan exception (GeoBan blocking only; the subtraction itself is in internal/geoban Build, Go-tested). Sources the REAL core/nftban_geoban.sh in a sandbox with a fake curl serving reserved documentation prefixes. Asserts: a valid download installs 40-whitelist-<CC>.conf and queues the GeoBan apply; the output states GeoBan-only scope; the same country cannot be both blocked and excepted (both directions refused, nothing written); invalid or empty country data is rejected with no file installed and an existing good file kept; `geoban list` counts data lines only (the header comments no longer count as IPv6) and labels exceptions as GeoBan-only; help names the exception scope. No network, no firewall change."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_geoban.sh,cli/lib/nftban/cli/cmd_geoban.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_CACHE_DIR,NFTBAN_LOG_DIR,NFTBAN_RUN_DIR,GEOBAN_ENABLED"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="geoban_country_exception_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="geoban"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/etc" "$W/data" "$W/cache" "$W/log" "$W/run"
# fake curl: writes the zone named by $W/zone to the -o file
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""; for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && cat "$W/zone" > "$out"
exit 0
EOF
cat > "$W/bin/nftban" <<'EOF'
#!/usr/bin/env bash
echo "nftban $*" >> "$W/calls"
EOF
chmod 755 "$W/bin/curl" "$W/bin/nftban"
export W PATH="$W/bin:$PATH" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_DATA_DIR="$W/data" \
       NFTBAN_CACHE_DIR="$W/cache" NFTBAN_LOG_DIR="$W/log" NFTBAN_RUN_DIR="$W/run" GEOBAN_ENABLED=true

gb(){ bash -c 'source "$NFTBAN_LIB_DIR/core/nftban_geoban.sh" >/dev/null 2>&1 || exit 97
               nftban_queue_add(){ echo "queue $*" >> "$W/calls"; }
               "$@"' _ "$@" 2>&1; }
F="$W/etc/geoban.d"

echo "=== valid exception ==="
printf '198.51.100.0/24\n203.0.113.0/25\n' > "$W/zone"
rc=0; out=$(gb nftban_geoban_whitelist_countries zz) || rc=$?
[[ $rc -eq 0 && -f "$F/40-whitelist-ZZ.conf" ]] && ok "exception file installed (rc 0)" || no "valid exception" "rc=$rc $out"
[[ "$out" == *"GeoBan blocking only"* && "$out" == *"manual bans keep blocking"* ]] && ok "output states GeoBan-only scope" || no "scope wording" "$out"
grep -q 'queue geoban_apply' "$W/calls" 2>/dev/null && ok "GeoBan apply queued (same path as ban/unban)" || no "apply not queued"

echo "=== same country blocked and excepted ==="
rc=0; out=$(gb nftban_geoban_ban_countries ZZ) || rc=$?
[[ $rc -ne 0 && "$out" == *"has a GeoBan exception"* && ! -e "$F/50-ban-ZZ.conf" ]] && ok "ban of an excepted country refused, nothing written" || no "ban over exception" "rc=$rc"
: > "$F/50-ban-YY.conf"
rc=0; out=$(gb nftban_geoban_whitelist_countries YY) || rc=$?
[[ $rc -ne 0 && "$out" == *"is GeoBan-blocked"* && ! -e "$F/40-whitelist-YY.conf" ]] && ok "exception of a blocked country refused, nothing written" || no "exception over ban" "rc=$rc"
rm -f "$F/50-ban-YY.conf"

echo "=== invalid / empty data ==="
before=$(sha256sum "$F/40-whitelist-ZZ.conf")
printf '198.51.100.0/24\n<html>error page</html>\n' > "$W/zone"
rc=0; out=$(gb nftban_geoban_whitelist_countries ZZ) || rc=$?
[[ $rc -ne 0 && "$out" == *"invalid line"* && "$(sha256sum "$F/40-whitelist-ZZ.conf")" == "$before" ]] \
  && ok "invalid data rejected, existing good file kept, no success" || no "invalid data" "rc=$rc $out"
[[ "$out" != *"exception saved"* ]] && ok "no false success line on invalid data" || no "false success on invalid data"
: > "$W/zone"
rc=0; out=$(gb nftban_geoban_whitelist_countries XX) || rc=$?
[[ $rc -ne 0 && ! -e "$F/40-whitelist-XX.conf" ]] && ok "empty data rejected, no file" || no "empty data" "rc=$rc"
tmpleft=0; for t in "$F"/*.tmp.*; do [[ -e "$t" ]] && tmpleft=1; done
[[ $tmpleft -eq 0 ]] && ok "no temporary file left" || no "temporary file left in geoban.d"

echo "=== list counts and labels ==="
out=$(gb nftban_geoban_list)
[[ "$out" == *"ZZ - 2 IPv4 ranges, 0 IPv6 ranges"* ]] && ok "counts are data lines only (header comments not counted as IPv6)" || no "counts" "$(grep ZZ <<<"$out")"
[[ "$out" == *"GeoBan country exceptions (GeoBan blocking only"* ]] && ok "list labels exceptions as GeoBan-only" || no "list label"
grep -q '^# Coverage: IPv4 only' "$F/40-whitelist-ZZ.conf" && ok "file records its coverage (IPv4 only)" || no "coverage line"

echo "=== help ==="
grep -q 'not a$' "$LIB/cli/cmd_geoban.sh" && grep -q 'global whitelist: feeds, detection modules' "$LIB/cli/cmd_geoban.sh" \
  && ok "help states the exception is not a global whitelist" || no "help wording"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
