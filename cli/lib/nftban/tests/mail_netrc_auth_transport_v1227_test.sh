#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.227 Lane-1 — MAIL-F1 netrc-host behavioral transport proof
# =============================================================================
# meta:name="mail_netrc_auth_transport_v1227_test"
# meta:type="test"
# meta:version="1.227.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="MAIL-F1 behavioral proof: drives the real nftban_mail_send curl-SMTP path with a fake curl that captures argv + the generated netrc; asserts the netrc machine == the connection host (NFTBAN_SMTP_HOST) and credentials are present. NO real network. Pre-fix FAIL (machine=localhost via the undefined NFTBAN_SMTP_SERVER), post-fix PASS."
# meta:input="None (sources nftban_mail.sh read-only; fake curl on PATH; no network)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp,awk"
# meta:inventory.files="cli/lib/nftban/core/nftban_mail.sh"
# meta:inventory.binaries="bash,grep,mktemp,awk"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_SMTP_HOST,NFTBAN_SMTP_PORT,NFTBAN_SMTP_USER,NFTBAN_SMTP_PASS,NFTBAN_MAIL_RECIPIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="mail_netrc_auth_transport_v1227_test"
# meta:ta.owner="mail"
# meta:ta.module="mail-smtp-netrc"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MAIL_LIB="$ROOT/cli/lib/nftban/core/nftban_mail.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== mail_netrc_auth_transport_v1227 ==="

# --- one hermetic send with a fake curl; returns the captured netrc + argv paths ---
run_send() {
    # $1=SMTP_HOST  $2=SMTP_USER  $3=SMTP_PASS  -> sets globals CAP NETRC OUT
    local host="$1" user="$2" pass="$3"
    SB="$(mktemp -d)"; mkdir -p "$SB"/{data,run,log,state}
    CAP="$SB/curl.args"; NETRC="$SB/netrc.copy"
    cat > "$SB/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CAP"
prev=""; for a in "\$@"; do [[ "\$prev" == "--netrc-file" ]] && cp "\$a" "$NETRC" 2>/dev/null; prev="\$a"; done
exit 0
EOF
    chmod +x "$SB/curl"
    # shellcheck disable=SC2034  # OUT is a global consumed by the assertions after run_send returns
    OUT="$(
        PATH="$SB:$PATH" \
        NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" NFTBAN_DATA_DIR="$SB/data" NFTBAN_RUN_DIR="$SB/run" \
        NFTBAN_LOG_DIR="$SB/log" NFTBAN_STATE_DIR="$SB/state" \
        NFTBAN_MAIL_METHOD="curl" NFTBAN_SMTP_HOST="$host" NFTBAN_SMTP_PORT="587" \
        NFTBAN_SMTP_USER="$user" NFTBAN_SMTP_PASS="$pass" NFTBAN_MAIL_RECIPIENT="to@example.test" \
        bash -c '
            set -Eeuo pipefail
            # shellcheck disable=SC1090
            source "'"$MAIL_LIB"'"
            nftban_mail_send "hermetic body" "to@example.test" 2>&1 || true
        '
    )"
}

# --- primary case: netrc machine MUST equal the connection host ------------------
run_send "smtp.example.test" "test-user" "test-secret"
assert "curl reached (argv captured)"                '[[ -s "$CAP" ]]'
assert "netrc file was generated + passed to curl"   '[[ -s "$NETRC" ]]'
assert "NETRC_MACHINE = connection host"             'grep -q "^machine smtp.example.test " "$NETRC"'
assert "NETRC_MACHINE_EQUALS_CONNECTION_HOST"        '[[ "$(awk "/^machine/{print \$2; exit}" "$NETRC")" == "smtp.example.test" ]]'
assert "NETRC_LOGIN_PRESENT"                         'grep -q "login test-user" "$NETRC"'
assert "NETRC_PASSWORD_PRESENT"                      'grep -q "password test-secret" "$NETRC"'
assert "CURL_SMTP_URL_HOST = connection host"        'grep -q "smtp://smtp.example.test:587\|smtps://smtp.example.test" "$CAP"'
assert "no localhost machine (the pre-fix bug)"      '! grep -q "^machine localhost " "$NETRC"'
assert "PASSWORD_NOT_PRINTED_IN_DIAGNOSTICS"         '! grep -q "test-secret" <<<"$OUT"'
rm -rf "$SB"

# --- edge (a): host:port on NFTBAN_SMTP_HOST → machine is host only (cut -d: -f1) ---
run_send "h.test:2525" "u2" "p2"
assert "EDGE_HOSTPORT machine strips :port"          '[[ "$(awk "/^machine/{print \$2; exit}" "$NETRC")" == "h.test" ]]'
rm -rf "$SB"

# --- edge (b): empty USER → NO netrc asserting false auth (existing :818 guard) ------
run_send "smtp.example.test" "" ""
assert "EDGE_EMPTY_USER adds no --netrc-file"        '! grep -q -- "--netrc-file" "$CAP"'
assert "EDGE_EMPTY_USER writes no netrc"             '[[ ! -s "$NETRC" ]]'
rm -rf "$SB"

# --- edge (c): IPv6 bracketed host — DOCUMENTED KNOWN LIMITATION, not silently mishandled ---
# cut -d: on "[2001:db8::1]" truncates; the connection host (smtp_url) has the same limitation
# at :798 today. This is out of scope for MAIL-F1 (one failure domain = netrc/connection-host
# equality). Assert only that machine == the cut-derived token so behavior is explicit, and
# flag it: bracketed-IPv6 SMTP host is a separate follow-up (Lane-2 transport-addr, MAIL-F12).
run_send "[2001:db8::1]" "u6" "p6"
_m6="$(awk '/^machine/{print $2; exit}' "$NETRC")"
echo "  [INFO] IPv6-bracketed host: netrc machine='$_m6' (KNOWN LIMITATION — MAIL-F12/Lane-2 follow-up; connection host has same cut behavior at :798)"
rm -rf "$SB"

echo ""
echo "=== mail_netrc_auth_transport_v1227: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
