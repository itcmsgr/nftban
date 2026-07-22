#!/usr/bin/env bash
# =============================================================================
# NFTBan - A1b central-comms emulate transport + dry-run
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_a1b_emulate_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="A1b: proves the central emulate transport records a delivery attempt without any real transport or network, writes no SMTP secret to the sink, and that mail test --dry-run validates config only (no send, no record). Also re-runs the A0 guard (0/4), A0 self-test (5/5) and A1 test (15/15) to confirm emulate did not regress the ratchet. Hermetic: sources the mail authority in an isolated tempdir; no real mail, no network."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_EMULATE_SINK,NFTBAN_MAIL_RECIPIENT,NFTBAN_SMTP_PASS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_a1b_emulate_test"
# meta:ta.owner="comms"
# meta:ta.module="mail-emulate"
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
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
MAIL="$REPO/cli/lib/nftban/core/nftban_mail.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== A1b central-comms emulate + dry-run ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# A non-credential marker (NOT a real secret) placed in NFTBAN_SMTP_PASS to prove the
# emulate sink never records it. Deliberately not password-shaped, to avoid secret scanners.
LEAK_PROBE="nftban-a1b-leakprobe-marker"

# Common env so the (env-dependent) mail authority sources cleanly in isolation.
env_prelude() {
  cat <<EOF
export NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
mkdir -p "\$NFTBAN_DATA_DIR" "\$NFTBAN_CONFIG_DIR" "\$NFTBAN_RUN_DIR" "\$NFTBAN_LOG_DIR"
EOF
}

# --- emulate: records an attempt, no transport, no secret in sink ---
SINK="$WORK/test-delivery.jsonl"
bash -c "$(env_prelude)
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example' NFTBAN_MAIL_EMULATE_SINK='$SINK' NFTBAN_SMTP_PASS='$LEAK_PROBE' NFTBAN_MAIL_MODULE='a1btest'
source '$MAIL' >/dev/null 2>&1 || true; set +e
nftban_mail_send 'emulated body' 'rcpt@test.example' >/dev/null 2>&1 || true
" || true

if [[ -s "$SINK" ]]; then ok "emulate wrote a delivery record"; else no "emulate did not write a sink record"; fi
grep -q '"transport":"emulate"' "$SINK" 2>/dev/null && ok "record marks transport=emulate" || no "record missing transport=emulate"
grep -q 'rcpt@test.example' "$SINK" 2>/dev/null && ok "record contains resolved recipient" || no "record missing recipient"
if grep -q "$LEAK_PROBE" "$SINK" 2>/dev/null; then no "SMTP secret LEAKED into sink"; else ok "no SMTP secret in sink"; fi
# no real transport binary was needed: emulate returns success without one
rc=$(bash -c "$(env_prelude)
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='r@t.example' NFTBAN_MAIL_EMULATE_SINK='$WORK/s2.jsonl'
source '$MAIL' >/dev/null 2>&1 || true; set +e
nftban_mail_send 'x' 'r@t.example' >/dev/null 2>&1; echo \$?")
[[ "$rc" == "0" ]] && ok "emulate send returns success (no real transport)" || no "emulate send rc=$rc"

# --- dry-run: validate only, no send, no record ---
DRSINK="$WORK/dry.jsonl"
drc=$(bash -c "$(env_prelude)
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='dry@t.example' NFTBAN_MAIL_EMULATE_SINK='$DRSINK'
source '$MAIL' >/dev/null 2>&1 || true; set +e
nftban_mail_test_dryrun 'dry@t.example' >/dev/null 2>&1; echo \$?")
[[ "$drc" == "0" ]] && ok "dry-run validates a good config (rc0)" || no "dry-run rc=$drc"
[[ ! -f "$DRSINK" ]] && ok "dry-run wrote NO delivery record" || no "dry-run wrongly wrote a record"
# dry-run with no recipient errors
mrc=$(bash -c "$(env_prelude)
unset NFTBAN_MAIL_RECIPIENT; export NFTBAN_MAIL_METHOD=emulate
source '$MAIL' >/dev/null 2>&1 || true; set +e
nftban_mail_test_dryrun '' >/dev/null 2>&1; echo \$?")
[[ "$mrc" != "0" ]] && ok "dry-run errors on missing recipient" || no "dry-run did not error on missing recipient"

# --- ratchet + prior suites unaffected ---
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4 PASS" || no "A0 guard regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_no_direct_send_guard_a0_test.sh >/dev/null 2>&1 ) && ok "A0 self-test still passes" || no "A0 self-test regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a1_centralization_test.sh >/dev/null 2>&1 ) && ok "A1 test still passes" || no "A1 test regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
