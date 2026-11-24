#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 install telemetry requires explicit consent; anonymised by default
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="install_telemetry_consent_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 BUG-PRIVACY-RPM-INSTALL-RESULT-SENT-WITHOUT-OPTIN (owner 2026-11-23: keep install telemetry, gated by the user's explicit COMMUNITY_STATS_ENABLED=yes; an unset value is not consent; participation and anonymisation are separate; COMMUNITY_STATS_ANONYMIZE=yes default; never send a machine-id-derived identifier as anonymous; same policy DEB and RPM; failure never fails the install). Drives the REAL nftban_send_install_result with a fake curl recording any request. Asserts: no config / unset / 'no' / 'YES' / symlinked config -> no request, no marker, no server_id file; consent with default anonymisation -> one request without node_id and without anything derived from machine-id; ANONYMIZE=no -> node_id is the random COMMUNITY_STATS_ID; second call sends nothing (one-time marker); a failing curl returns 0; both the RPM %post (build_nftban.sh) and the DEB postinst call it; no inline payload on curl argv."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,grep"
# meta:inventory.files="cli/lib/nftban/lib/nftban_pro.sh,packaging/build_nftban.sh,packaging/deb/postinst"
# meta:inventory.binaries="bash,jq,grep"
# meta:inventory.env_vars="NFTBAN_COMMUNITY_CONF,NFTBAN_PRO_DATA_DIR,NFTBAN_INSTALL_RESULT_MARKER,NFTBAN_PRO_SERVER_ID_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="install_telemetry_consent_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="telemetry"
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
ROOT="$(cd "$LIB/../../.." && pwd)"
PRO="$LIB/lib/nftban_pro.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$W/argv"
cat > "$W/body"
echo 1 >> "$W/requests"
[[ -f "$W/curl_fail" ]] && exit 7
exit 0
EOF
chmod 755 "$W/bin/curl"
export W
MID=$(head -c 16 /etc/machine-id 2>/dev/null || echo "0123456789abcdef")

fn=$(awk '/^(_nftban_community_conf_value|nftban_send_install_result)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$PRO")
run(){ rm -f "$W/argv" "$W/body" "$W/requests"
       PATH="$W/bin:$PATH" NFTBAN_COMMUNITY_CONF="$W/community.conf" NFTBAN_PRO_DATA_DIR="$W/pro" \
       NFTBAN_INSTALL_RESULT_MARKER="$W/pro/install_result_sent" NFTBAN_INSTALL_RESULT_URL="https://stats.example.invalid/x" \
       NFTBAN_PRO_SERVER_ID_FILE="$W/server_id" bash -c 'eval "$1"; nftban_send_install_result; echo "RC=$?"' _ "$fn" 2>&1; }
reset(){ rm -rf "$W/pro" "$W/server_id" "$W/community.conf" "$W/curl_fail"; }
nothing(){ [[ ! -e "$W/requests" && ! -e "$W/pro/install_result_sent" && ! -e "$W/server_id" ]]; }

echo "=== no consent -> nothing sent, nothing written ==="
reset; out=$(run); nothing && [[ "$out" == *RC=0* ]] && ok "no config file" || no "no config file sent/wrote something"
for v in '' 'no' 'YES' 'true'; do
  reset; printf 'COMMUNITY_STATS_ENABLED=%s\n' "$v" > "$W/community.conf"; run >/dev/null
  nothing && ok "COMMUNITY_STATS_ENABLED='$v' is not consent" || no "value '$v' treated as consent"
done
reset; printf 'COMMUNITY_STATS_ENABLED=yes\n' > "$W/real.conf"; ln -s "$W/real.conf" "$W/community.conf"; run >/dev/null
nothing && ok "symlinked config is not read as consent" || no "symlinked config accepted"; rm -f "$W/real.conf"

echo "=== consent, default anonymised ==="
reset; printf 'COMMUNITY_STATS_ENABLED="yes"\nCOMMUNITY_STATS_ID="11111111-2222-3333-4444-555555555555"\n' > "$W/community.conf"
out=$(run)
[[ "$(cat "$W/requests" 2>/dev/null)" == 1 ]] && jq -e . "$W/body" >/dev/null 2>&1 && ok "one request with valid JSON" || no "consented send" "$out"
[[ "$(jq -r 'has("node_id")' "$W/body" 2>/dev/null)" == false ]] && ok "anonymised by default: no node_id" || no "node_id present by default"
grep -q "$MID" "$W/body" 2>/dev/null && no "machine-id-derived value in payload" || ok "nothing derived from machine-id"
[[ ! -e "$W/server_id" ]] && ok "no server_id file created" || no "server_id created"
grep -q '"install_result"' "$W/argv" && no "payload on curl argv" || ok "payload not on curl argv (stdin)"
out=$(run); [[ ! -e "$W/requests" ]] && ok "second call sends nothing (one-time)" || no "sent twice"

echo "=== consent, anonymisation off ==="
reset; printf 'COMMUNITY_STATS_ENABLED=yes\nCOMMUNITY_STATS_ANONYMIZE=no\nCOMMUNITY_STATS_ID="11111111-2222-3333-4444-555555555555"\n' > "$W/community.conf"
run >/dev/null
[[ "$(jq -r .node_id "$W/body" 2>/dev/null)" == "11111111-2222-3333-4444-555555555555" ]] && ok "node_id is the random community id" || no "node_id" "$(cat "$W/body" 2>/dev/null)"

echo "=== failure never fails the caller ==="
reset; printf 'COMMUNITY_STATS_ENABLED=yes\n' > "$W/community.conf"; touch "$W/curl_fail"
out=$(run); [[ "$out" == *RC=0* ]] && ok "curl failure -> rc 0" || no "curl failure propagated" "$out"

echo "=== both package types call the gated function ==="
grep -q 'nftban_send_install_result' "$ROOT/packaging/build_nftban.sh" && ok "RPM %post calls it" || no "RPM call missing"
grep -q 'nftban_send_install_result' "$ROOT/packaging/deb/postinst" && ok "DEB postinst calls it" || no "DEB call missing"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
