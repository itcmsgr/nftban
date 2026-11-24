#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238: the daily community submit is anonymous (schema v3, no PRO identity)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="community_submit_anonymous_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-24"
# meta:description="v1.238 BUG-PRIVACY-COMMUNITY-SUBMIT-SENDS-MACHINE-DERIVED-SERVER-ID (owner GO 2026-11-24). Drives the REAL nftban_community_submit (the function nftban-community-stats.service runs) with a recording curl stub; nothing leaves the host. Case 1: opt-in off on a PRO-enrolled host (server_id + token present) -> zero send attempts. Case 2: opt-in on, PRO host -> exactly one POST to https://stats.nftban.com/api/v1/community, schema_version 3, the only identifier is the configured random anonymous_install_id; the request contains no node_id, no PRO server_id (nor its machine-id prefix), no PRO token, no /etc/machine-id value. Case 3: opt-in on, Free host (no server_id, no token) -> same request shape, and no server_id file is created. Also: `community show` previews the same v3 payload. Non-vacuity: the v2 builder (pre-fix submit) carries the PRO server_id sentinel."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,grep"
# meta:inventory.files="cli/lib/nftban/lib/nftban_pro.sh"
# meta:inventory.binaries="bash,jq,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_PRO_SERVER_ID_FILE,NFTBAN_PRO_TOKEN_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="community_submit_anonymous_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="community"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)/lib/nftban_pro.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
SID="f2f2f2f2f2f2f2f2-5e5e5e5e"            # synthetic PRO server_id sentinel
TOK="F2-SENTINEL-PRO-TOKEN-NOT-A-SECRET"   # synthetic PRO token sentinel
IID="0f2e0f2e-1111-4222-8333-944445555666" # synthetic anonymous_install_id
MID=""; [[ -r /etc/machine-id ]] && MID=$(head -c 32 /etc/machine-id)

mkdir -p "$W/bin"
cat > "$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
# recording curl: each call -> its own file, arguments NUL-separated (payloads contain newlines); never sends
n=$(find "$F2_CURL_DIR" -name 'call.*' | wc -l)
printf '%s\0' "$@" > "$F2_CURL_DIR/call.$((n + 1))"
echo -n 200
STUB
chmod 755 "$W/bin/curl"

run() { # $1 case dir, $2 opt-in yes|no, $3 pro yes|no, $4 function -> stdout
    local d="$W/$1"; rm -rf "$d"; mkdir -p "$d/etc/conf.d"
    printf 'COMMUNITY_STATS_ENABLED="%s"\nCOMMUNITY_STATS_ID="%s"\n' "$2" "$IID" > "$d/etc/conf.d/community_stats.conf"
    if [[ "$3" == yes ]]; then printf '%s\n' "$SID" > "$d/etc/server_id"; printf '%s\n' "$TOK" > "$d/etc/pro.token"; fi
    mkdir -p "$d/curl"
    env -i PATH="$W/bin:/usr/bin:/bin" HOME="$d" F2_CURL_DIR="$d/curl" NFTBAN_CONFIG_DIR="$d/etc" \
        NFTBAN_PRO_SERVER_ID_FILE="$d/etc/server_id" NFTBAN_PRO_TOKEN_FILE="$d/etc/pro.token" \
        bash -c 'source "$1" >/dev/null 2>&1; NFTBAN_COMMUNITY_CONF="$NFTBAN_CONFIG_DIR/conf.d/community_stats.conf"; "$2"' _ "$LIB" "$4" 2>&1
}
calls() { find "$W/$1/curl" -name 'call.*' 2>/dev/null | wc -l | tr -d ' '; }
field() { # $1 case -> value after -d / --data* in the first call
    local -a a; mapfile -d '' a < "$W/$1/curl/call.1" || true
    local i; for ((i = 0; i < ${#a[@]}; i++)); do
        case "${a[i]}" in -d|--data|--data-binary|--data-raw) printf '%s' "${a[i+1]:-}"; return ;; esac
    done
}
url_of() { local -a a; mapfile -d '' a < "$W/$1/curl/call.1" || true; local x u=""; for x in "${a[@]}"; do [[ "$x" == http://* || "$x" == https://* ]] && u="$x"; done; printf '%s' "$u"; }
noleak() { # $1 case, $2 label
    local all; all=$(cat "$W/$1"/curl/call.* 2>/dev/null | tr '\0' ' ')
    local bad=""
    [[ "$all" == *"$SID"* || "$all" == *"${SID:0:16}"* ]] && bad+="server_id "
    [[ "$all" == *"$TOK"* ]] && bad+="token "
    [[ "$all" == *'"node_id"'* ]] && bad+="node_id "
    [[ -n "$MID" && ( "$all" == *"$MID"* || "$all" == *"${MID:0:16}"* ) ]] && bad+="machine-id "
    [[ -z "$bad" ]] && ok "$2: request carries no node_id / PRO server_id / PRO token / machine-id" || no "$2: request leaks $bad"
}

echo "=== case 1: opt-in OFF on a PRO-enrolled host ==="
run c1 no yes nftban_community_submit >/dev/null
[[ "$(calls c1)" == 0 ]] && ok "zero send attempts" || no "send attempted with opt-in off" "$(calls c1)"

echo "=== case 2: opt-in ON, host with a PRO server_id + token ==="
run c2 yes yes nftban_community_submit >/dev/null
[[ "$(calls c2)" == 1 ]] && ok "exactly one send attempt" || no "send attempts" "$(calls c2)"
[[ "$(url_of c2)" == "https://stats.nftban.com/api/v1/community" ]] && ok "destination stats.nftban.com/api/v1/community" || no "destination" "$(url_of c2)"
b=$(field c2)
[[ "$(jq -r .schema_version <<<"$b" 2>/dev/null)" == 3 ]] && ok "schema_version 3" || no "schema" "$(head -c 200 <<<"$b")"
[[ "$(jq -r .anonymous_install_id <<<"$b" 2>/dev/null)" == "$IID" ]] && ok "identifier = the configured random anonymous_install_id" || no "install id"
ids=$(jq -r '[paths(scalars) | map(tostring) | join(".") | select(test("(^|\\.)(node_id|server_id|machine_id|host_key|token|hostname)$"))] | length' <<<"$b" 2>/dev/null || echo jq-failed)
[[ "$ids" == 0 ]] && ok "no other identifier field in the payload" || no "identifier fields present" "$ids"
noleak c2 "PRO host"

echo "=== case 3: opt-in ON, Free host (no account, no token, no enrollment) ==="
run c3 yes no nftban_community_submit >/dev/null
[[ "$(calls c3)" == 1 && "$(url_of c3)" == "https://stats.nftban.com/api/v1/community" ]] && ok "same destination, one attempt" || no "free host send" "$(calls c3) $(url_of c3)"
[[ "$(jq -r '.schema_version,.anonymous_install_id' <<<"$(field c3)" 2>/dev/null | tr '\n' ' ')" == "3 $IID " ]] && ok "same v3 shape and identifier" || no "free host payload"
[[ ! -e "$W/c3/etc/server_id" ]] && ok "no PRO server_id created on a Free host" || no "server_id file created on a Free host"
noleak c3 "Free host"

echo "=== preview + non-vacuity ==="
s_rc=0; s=$(run c4 yes yes nftban_community_show) || s_rc=$?   # keep the rc: a failing builder must report, not abort the script
[[ "$s" == *'"schema_version": 3'* && "$s" == *"$IID"* && "$s" != *"$SID"* ]] && ok "community show previews the same v3 payload" || no "show differs from submit" "rc=$s_rc $(tail -3 <<<"$s")"
v2_rc=0; v2=$(run c5 yes yes nftban_community_build_payload) || v2_rc=$?
[[ "$v2" == *"$SID"* ]] && ok "non-vacuity: the v2 builder (pre-fix submit) carries the PRO server_id" || no "non-vacuity: v2 sentinel not seen" "rc=$v2_rc $(tail -5 <<<"$v2")"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
