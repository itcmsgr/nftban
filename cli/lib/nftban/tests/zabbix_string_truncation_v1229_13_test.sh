#!/usr/bin/env bash
# =============================================================================
# NFTBan - a multi-word STRING metric must reach Zabbix intact
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="zabbix-string-truncation-v1229-13-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="zabbix_string_truncation_v1229_13_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="exporter"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="Regression guard for ZBX-D1. Commit 5d245017 (v1.229.11) removed the trailing client-side timestamp from the collector's emission rows, but the Zabbix conversion awk in nftban_unified_exporter_export.sh kept iterating `for (i = 3; i < NF; i++)` with a comment asserting that the last field is a timestamp. With no timestamp present the LAST WORD of every multi-word STRING metric is silently dropped: 'Ubuntu 24.04.1 LTS' ships as 'Ubuntu 24.04.1', and 'Not configured' ships as 'Not'. nftban.version.info is a single token, which is why this survived. Seventeen template inventory_link entries populate Zabbix HOST INVENTORY from these items, so the corruption reaches operator-visible inventory. The awk program is EXTRACTED FROM SOURCE rather than retyped, so editing the exporter without this test is detectable."
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_export.sh,cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
EXP="$ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_export.sh"
COL="$ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s%s\n' "$1" "${2:+ — $2}"; }
echo "=== zabbix_string_truncation_v1229_13 ==="
for f in "$EXP" "$COL"; do [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }; done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# EXTRACT THE REAL awk PROGRAM. Never retype it: the test must bind to the
# shipped conversion, so changing the exporter without this test is detectable.
# ---------------------------------------------------------------------------
awk_prog(){ sed -n "/^[[:space:]]*awk -v host=/,/^[[:space:]]*}' \"\$METRICS_CACHE\"/p" "$1" \
    | sed -e "1s/.*awk -v host=\"\$hostname\" '//" -e "\$s/}' \"\$METRICS_CACHE\".*/}/"; }
PROG="$WORK/prog.awk"; awk_prog "$EXP" > "$PROG"
if [[ ! -s "$PROG" ]] || ! grep -q 'STRING' "$PROG"; then
    bad "could not extract the awk program from the exporter — assertion would be vacuous"
    echo "=== zabbix_string_truncation: PASS=$PASS FAIL=$FAIL ==="; exit 1
fi
ok "awk conversion program extracted from source ($(grep -c '' "$PROG") lines)"

# ---------------------------------------------------------------------------
# THE COLLECTOR EMITS NO TRAILING TIMESTAMP. Pin that, because it is the
# premise the awk got wrong — if a timestamp ever returns, this test must fail
# loudly rather than silently start passing for the wrong reason.
# ---------------------------------------------------------------------------
if grep -qE 'STRING\|\$[A-Za-z_][A-Za-z0-9_]*\\n"' "$COL"; then
    ok "collector emits STRING rows with NO trailing timestamp (the awk premise)"
else
    bad "collector emission shape changed — re-derive the awk contract before trusting this test"
fi

convert(){ printf '%s\n' "$1" | awk -v host=testhost -f "$PROG"; }
expect(){ # label, input row, expected full output line
    local label="$1" row="$2" want="$3" got
    got="$(convert "$row")"
    [[ "$got" == "$want" ]] && ok "$label" || bad "$label" "got [$got] want [$want]"
}

echo "--- STRING values must survive intact, whatever their word count ---"
expect "single token"                 'nftban.version.info |STRING|1.229.13'            'testhost nftban.version.info "1.229.13"'
expect "two words"                    'nftban.server.location |STRING|Not configured'   'testhost nftban.server.location "Not configured"'
expect "three words"                  'nftban.server.os |STRING|Ubuntu 24.04.1 LTS'     'testhost nftban.server.os "Ubuntu 24.04.1 LTS"'
expect "spaces AND punctuation"       'nftban.server.cpu_model |STRING|Intel(R) Xeon(R) CPU E5-2680 v4' \
                                      'testhost nftban.server.cpu_model "Intel(R) Xeon(R) CPU E5-2680 v4"'
expect "trailing token is a number"   'nftban.server.kernel |STRING|Linux 6.8.0 generic 12' \
                                      'testhost nftban.server.kernel "Linux 6.8.0 generic 12"'

echo "--- numeric rows must be untouched by the fix ---"
expect "numeric row"                  'nftban.banned.total 4211'                        'testhost nftban.banned.total 4211'
expect "numeric zero"                 'nftban.feeds.failed 0'                           'testhost nftban.feeds.failed 0'

echo "--- the fix must not reintroduce a timestamp ---"
got="$(convert 'nftban.server.os |STRING|Ubuntu 24.04.1 LTS')"
if [[ "$got" =~ [0-9]{10} ]]; then
    bad "a 10-digit epoch appeared in the converted row" "$got"
else
    ok "no timestamp reintroduced into the converted row"
fi

# ---------------------------------------------------------------------------
# ⛔ THE DEFECT IS THE LOOP BOUND. Assert it structurally too, so a future edit
# that reverts to `i < NF` fails here even if someone changes the fixtures.
# ---------------------------------------------------------------------------
if grep -qE 'for \(i = 3; i < NF; i\+\+\)' "$EXP"; then
    bad "exporter still uses 'i < NF' — the final field of every multi-word STRING is dropped"
else
    ok "exporter does not use the timestamp-assuming 'i < NF' bound"
fi
if grep -qE '\$NF = timestamp' "$EXP"; then
    bad "the stale '\$NF = timestamp' comment survives — it documents a premise removed in 5d245017"
else
    ok "the stale timestamp comment is gone"
fi

echo
echo "=== zabbix_string_truncation: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
