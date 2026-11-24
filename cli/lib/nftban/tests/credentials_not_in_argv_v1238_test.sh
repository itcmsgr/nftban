#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 credentials never on the curl command line (portal API key, Pro token)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="credentials_not_in_argv_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 OBS-PORTAL-API-KEY-IN-ARGV (owner GO 2026-11-23: remove secrets from process arguments, verify with sentinel credentials). /proc/<pid>/cmdline is readable by every local user, so a bearer token passed as curl -H 'Authorization: Bearer ...' leaks while the request runs. Drives the REAL export_portal and nftban_pro_check_license with a fake curl on PATH that records its argv, the -H @file header content and stdin. Asserts: the sentinel key is absent from argv; it reaches curl only through a 0600 header file that is removed afterwards; the portal payload goes on stdin; a non-https portal URL fails with insecure_url before any curl call; and a census finds no 'Authorization: Bearer $' argument left in shipped shell. Sentinel values only; no network."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,awk,grep,stat"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_export.sh,cli/lib/nftban/lib/nftban_pro.sh,cli/lib/nftban/cli/cmd_pro.sh"
# meta:inventory.binaries="bash,awk,grep,stat"
# meta:inventory.env_vars="NFTBAN_RUN_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="credentials_not_in_argv_v1238_test"
# meta:ta.owner="metrics"
# meta:ta.module="credentials"
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
EXP="$LIB/exporters/nftban_unified_exporter_export.sh"
PRO="$LIB/lib/nftban_pro.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
SENT="SENTINELcred0v1238x0000000000000000"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/run"
# fake curl: argv (one per line) -> $W/argv; every -H @file's content (+ its mode) -> $W/hdr; stdin -> $W/stdin
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$W/argv"
prev=""; for a in "$@"; do
  if [[ "$prev" == "-H" && "$a" == @* ]]; then f="${a#@}"; echo "MODE $(stat -c %a "$f")" >> "$W/hdr"; cat "$f" >> "$W/hdr"; echo "$f" >> "$W/hdrfiles"; fi
  if [[ "$prev" == "-d" && "$a" == "@-" ]]; then cat >> "$W/stdin"; fi
  prev="$a"; done
out=""; prev=""; for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && echo '{"status":"active"}' > "$out"
case " $* " in *" -w "*"\n%{http_code}"*) printf '{}\n200' ;; *) printf '200' ;; esac
EOF
chmod 755 "$W/bin/curl"
export W NFTBAN_RUN_DIR="$W/run"
clean(){ rm -f "$W/argv" "$W/hdr" "$W/stdin" "$W/hdrfiles"; }
fn(){ awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^\}/ {f=0}' "$1"; }

echo "=== portal export (real export_portal) ==="
# The exporter file only defines functions and the result arrays (its heredocs hold column-0
# braces, so it is sourced, not cut out).
run_portal(){ PATH="$W/bin:$PATH" bash -c '
  log_info(){ echo "INFO $*"; }; log_warn(){ echo "WARN $*"; }
  source "$1"; set +e; METRICS_CACHE=/dev/null; export_portal; rc=$?
  echo "RESULT ${EXPORT_SUCCESSES[portal]:-0}/${EXPORT_FAILURES[portal]:-0} rc=$rc"' _ "$EXP" 2>&1; }
clean; out=$(NFTBAN_PORTAL_ENABLED=true NFTBAN_PORTAL_API_KEY="$SENT" NFTBAN_PORTAL_URL="https://portal.example.invalid/api" run_portal)
if grep -q "$SENT" "$W/argv"; then no "portal: sentinel key is in curl argv"; else ok "portal: sentinel key absent from curl argv"; fi
grep -qx "Authorization: Bearer $SENT" "$W/hdr" && grep -qx 'MODE 600' "$W/hdr" && ok "portal: key passed via a 0600 header file" || no "portal: header file" "$(cat "$W/hdr" 2>/dev/null)"
f=$(head -1 "$W/hdrfiles" 2>/dev/null || true); [[ -n "$f" && ! -e "$f" ]] && ok "portal: header file removed after the request" || no "portal: header file left behind ($f)"
grep -q '"host_key"' "$W/stdin" 2>/dev/null && ! grep -q '"host_key"' "$W/argv" && ok "portal: payload sent on stdin, not argv" || no "portal: payload not on stdin"
[[ "$out" == *"RESULT 1/0"* ]] && ok "portal: 2xx still recorded as success" || no "portal result" "$out"
clean; out=$(NFTBAN_PORTAL_ENABLED=true NFTBAN_PORTAL_API_KEY="$SENT" NFTBAN_PORTAL_URL="http://portal.example.invalid/api" run_portal)
[[ ! -e "$W/argv" && "$out" == *"must use https://"* && "$out" == *"RESULT 0/1"* ]] && ok "portal: http:// URL refused before any request (insecure_url)" || no "portal http" "$out"

echo "=== Pro licence check (real nftban_pro_check_license) ==="
mkdir -p "$W/pro"; printf '%s\n' "$SENT" > "$W/pro.token"; echo "srv-test" > "$W/server_id"
pro_fns="$(fn "$PRO" nftban_pro_get_server_id; fn "$PRO" nftban_pro_check_license)"
clean; PATH="$W/bin:$PATH" NFTBAN_PRO_TOKEN_FILE="$W/pro.token" NFTBAN_PRO_SERVER_ID_FILE="$W/server_id" \
  NFTBAN_PRO_DATA_DIR="$W/pro" NFTBAN_PRO_LICENSE_FILE="$W/pro/license.json" NFTBAN_PRO_TIMEOUT=1 \
  NFTBAN_PRO_STATUS_URL="https://pro.example.invalid/status" bash -c 'eval "$1"; nftban_pro_check_license' _ "$pro_fns" >/dev/null 2>&1 || true
if [[ -s "$W/argv" ]] && ! grep -q "$SENT" "$W/argv" && grep -qx "Authorization: Bearer $SENT" "$W/hdr"; then
    ok "pro licence: token only in the header file, not argv"; else no "pro licence: token in argv or not sent"; fi

echo "=== census: no bearer token on a curl command line in shipped shell ==="
hits=$(grep -rnE -- '-H "Authorization: Bearer \$' "$LIB" --include=*.sh 2>/dev/null | grep -v '/tests/' || true)
[[ -z "$hits" ]] && ok "no '-H \"Authorization: Bearer \$…\"' argument remains" || no "inline bearer header remains" "$hits"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
