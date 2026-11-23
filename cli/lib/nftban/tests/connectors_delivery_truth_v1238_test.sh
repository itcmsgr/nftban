#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 connectors: readable by the exporter, authenticated, honest outcomes
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="connectors_delivery_truth_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 BUG-CONNECTOR-CONFIG-UNREADABLE-BY-EXPORTER + BUG-CONNECTORS-EXPORTER-IGNORES-SYSLOG-WEBHOOK-ES-CREDENTIALS (owner GO 2026-11-23: count delivery only after the destination's acknowledgement; configured Elasticsearch authentication must be used; missing required credentials must fail clearly; show skipped/failed/unverified outcomes). Drives the REAL export_connectors against a controlled destination: a 127.0.0.1 HTTP listener that requires Basic auth (sentinel user/password), answers 201 only to an authenticated request and records what it received. Asserts: configured credentials are sent (and never on curl's argv) and the document arrives; a connector without credentials gets 401 and is recorded as failed; user without password fails before any request; credentials do not leak from one connector to the next; an unreadable connector file is reported and fails the cycle; Kafka without kafkacat and syslog/webhook are reported as failed/unsupported; the file connector still writes. Also drives the REAL _connector_save: the file is created 0640 with group nftban (chgrp stubbed, call recorded) and renamed into place. Sentinel credentials, loopback only, no firewall change."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,python3,curl,awk,stat"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_export.sh,cli/lib/nftban/cli/cmd_connector.sh"
# meta:inventory.binaries="bash,python3,curl,awk,stat"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_RUN_DIR,NFTBAN_LOG_DIR,NFTBAN_CONNECTORS_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="127.0.0.1 only"
# meta:inventory.privileges="none"
# meta:ta.id="connectors_delivery_truth_v1238_test"
# meta:ta.owner="metrics"
# meta:ta.module="connectors"
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
CON="$LIB/cli/cmd_connector.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v python3 >/dev/null && command -v curl >/dev/null || { echo "SKIP: python3/curl missing"; exit 0; }

W=$(mktemp -d)
SRV_PID=""
cleanup(){ [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/etc/connectors" "$W/run" "$W/log" "$W/bin"
U="sentineluser"; P="sentinel$(printf '0%.0s' {1..16})"

# controlled destination: Basic auth required; 201 only when authenticated; records requests
cat > "$W/srv.py" <<'EOF'
import base64, http.server, sys, os
want = "Basic " + base64.b64encode(f"{sys.argv[2]}:{sys.argv[3]}".encode()).decode()
log = sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        auth = self.headers.get("Authorization", "")
        ok = auth == want
        with open(log, "a") as f:
            f.write(f"{self.path} auth={'ok' if ok else ('wrong' if auth else 'none')} bytes={len(body)} metric={b'nftban_test_metric' in body}\n")
        self.send_response(201 if ok else 401); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
python3 "$W/srv.py" "$W/port" "$U" "$P" "$W/recv" & SRV_PID=$!
for _ in $(seq 50); do [[ -s "$W/port" ]] && break; sleep 0.1; done
PORT=$(cat "$W/port")

printf 'nftban_test_metric 42 1700000000\n' > "$W/metrics.cache"
# argv spy: wraps the real curl
REALCURL=$(command -v curl)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/curl_argv"\nexec "%s" "$@"\n' "$W" "$REALCURL" > "$W/bin/curl"
chmod 755 "$W/bin/curl"

conf(){ printf '%s\n' "${@:2}" > "$W/etc/connectors/$1.conf"; chmod 640 "$W/etc/connectors/$1.conf"; }
run(){ rm -f "$W/recv" "$W/curl_argv"
       PATH="$W/bin:$PATH" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_RUN_DIR="$W/run" NFTBAN_LOG_DIR="$W/log" METRICS_CACHE="$W/metrics.cache" \
       bash -c 'log_info(){ echo "INFO $*"; }; log_warn(){ echo "WARN $*"; }
                source "$1"; set +e; export_connectors; rc=$?
                for t in elasticsearch kafka file syslog; do echo "R $t ${EXPORT_SUCCESSES[$t]:-0}/${EXPORT_FAILURES[$t]:-0}"; done
                echo "RC=$rc"' _ "$EXP" 2>&1; }
URL="http://127.0.0.1:$PORT"

echo "=== Elasticsearch with configured credentials ==="
conf a-es 'CONNECTOR_NAME="a-es"' 'CONNECTOR_TYPE="elasticsearch"' 'CONNECTOR_ENABLED="true"' "CONNECTOR_ES_URL=\"$URL\"" "CONNECTOR_ES_USER=\"$U\"" "CONNECTOR_ES_PASS=\"$P\""
out=$(run)
grep -q 'auth=ok' "$W/recv" 2>/dev/null && grep -q 'metric=True' "$W/recv" && ok "document received at the destination with the configured credentials" || no "ES delivery/auth" "$(cat "$W/recv" 2>/dev/null) $out"
[[ "$out" == *"R elasticsearch 1/0"* && "$out" == *"RC=0"* ]] && ok "recorded as delivered only after the 201 acknowledgement" || no "ES result" "$out"
grep -qF "$P" "$W/curl_argv" && no "password visible in curl argv" || ok "password not on curl argv (netrc file)"
[[ -z "$(ls -A "$W/run")" ]] && ok "netrc file removed" || no "netrc file left in run dir"

echo "=== a second connector does not inherit the first one's credentials ==="
conf b-es 'CONNECTOR_NAME="b-es"' 'CONNECTOR_TYPE="elasticsearch"' 'CONNECTOR_ENABLED="true"' "CONNECTOR_ES_URL=\"$URL\""
out=$(run)
[[ "$(grep -c 'auth=ok' "$W/recv")" == 1 && "$(grep -c 'auth=none' "$W/recv")" == 1 ]] && ok "b-es sent without credentials (no leak from a-es)" || no "credential leak between connectors" "$(cat "$W/recv")"
[[ "$out" == *"R elasticsearch 1/1"* && "$out" == *"RC=1"* && "$out" == *"b-es, curl rc=22"* ]] && ok "401 recorded as a failure with its reason; cycle fails" || no "401 handling" "$out"
rm -f "$W/etc/connectors/b-es.conf"

echo "=== user without password ==="
conf c-es 'CONNECTOR_NAME="c-es"' 'CONNECTOR_TYPE="elasticsearch"' 'CONNECTOR_ENABLED="true"' "CONNECTOR_ES_URL=\"$URL\"" "CONNECTOR_ES_USER=\"$U\""
out=$(run)
[[ "$(grep -c . "$W/recv")" == 1 && "$out" == *"has CONNECTOR_ES_USER but no CONNECTOR_ES_PASS"* ]] && ok "incomplete credentials fail clearly, no request sent" || no "incomplete credentials" "$out"
rm -f "$W/etc/connectors/c-es.conf"

echo "=== unreadable connector file ==="
if [[ $EUID -ne 0 ]]; then
    conf d-es 'CONNECTOR_NAME="d-es"' 'CONNECTOR_TYPE="elasticsearch"' 'CONNECTOR_ENABLED="true"' "CONNECTOR_ES_URL=\"$URL\""
    chmod 000 "$W/etc/connectors/d-es.conf"
    out=$(run)
    [[ "$out" == *"d-es.conf is not readable"* && "$out" == *"RC=1"* ]] && ok "unreadable connector reported and the cycle fails" || no "unreadable connector" "$out"
    rm -f "$W/etc/connectors/d-es.conf"
else
    echo "  - skipped as root (mode 000 readable); covered on the lab as the nftban user"
fi

echo "=== Kafka without kafkacat, syslog, file ==="
conf e-kafka 'CONNECTOR_NAME="e-kafka"' 'CONNECTOR_TYPE="kafka"' 'CONNECTOR_ENABLED="true"' 'CONNECTOR_KAFKA_BROKERS="127.0.0.1:1"'
conf f-syslog 'CONNECTOR_NAME="f-syslog"' 'CONNECTOR_TYPE="syslog"' 'CONNECTOR_ENABLED="true"'
conf g-file 'CONNECTOR_NAME="g-file"' 'CONNECTOR_TYPE="file"' 'CONNECTOR_ENABLED="true"' "CONNECTOR_FILE_PATH=\"$W/log/out.json\""
out=$(PATH="/usr/bin:/bin" run)
if command -v kafkacat >/dev/null 2>&1; then echo "  - kafkacat installed here; missing-tool case not exercised"
else [[ "$out" == *"kafkacat is not installed"* && "$out" == *"R kafka 0/1"* ]] && ok "Kafka without kafkacat reported as failed (was silent)" || no "kafka missing" "$out"; fi
[[ "$out" == *"syslog (f-syslog) is not sent by the periodic exporter"* && "$out" == *"R syslog 0/1"* ]] && ok "syslog reported as not supported by the timer (was silent)" || no "syslog" "$out"
grep -q 'nftban_test_metric' "$W/log/out.json" 2>/dev/null && [[ "$out" == *"R file 1/0"* ]] && ok "file connector writes and is recorded" || no "file connector" "$out"

echo "=== connector add: file mode and group (real _connector_save) ==="
printf '#!/usr/bin/env bash\necho "chgrp $*" >> "%s/chgrp_calls"\n' "$W" > "$W/bin/chgrp"; chmod 755 "$W/bin/chgrp"
mkdir -p "$W/cdir"
save_fn=$(awk '/^_connector_save\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$CON")
PATH="$W/bin:$PATH" NFTBAN_CONNECTORS_DIR="$W/cdir" bash -c '
  _connector_config_path(){ echo "$NFTBAN_CONNECTORS_DIR/$1.conf"; }
  _connector_print_error(){ echo "ERR $*"; }
  eval "$1"; _connector_save es1 elasticsearch "CONNECTOR_ES_PASS=\"x\""' _ "$save_fn"
f="$W/cdir/es1.conf"
[[ -f "$f" && "$(stat -c %a "$f")" == 640 ]] && grep -q "chgrp nftban" "$W/chgrp_calls" && ok "saved 0640 with group nftban requested" || no "save mode/group" "$(stat -c %a "$f" 2>/dev/null) $(cat "$W/chgrp_calls" 2>/dev/null)"
leftover=0; for t in "$W/cdir"/.es1.conf.*; do [[ -e "$t" ]] && leftover=1; done
[[ $leftover -eq 0 ]] && ok "temporary file renamed into place" || no "temporary file left"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
