#!/usr/bin/env bash
# =============================================================================
# NFTBan - Duplicate-redactor retirement P-retire-2: fail-loud when the redactor is unavailable
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_redact_failloud_p_retire2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="SEC-P1-2 P-retire-2: the legacy weak/passthrough fallbacks are retired. With the shared redaction authority (lib/nftban_redact.sh) UNAVAILABLE, every secret-redaction wrapper (_redact_secrets/_redact_comms/_support_scrub_stream in cmd_support, _debug_scrub_stream in cmd_debug, _fx_redact in cmd_update_helpers) FAILS LOUD/CLOSED: emits exactly '[REDACTION-UNAVAILABLE: do not share]' to stdout, discards raw stdin (no passthrough), writes a [SECURITY][ERROR] to stderr, and returns 0 — never a raw secret and never the weak SECRET_PATTERNS/sed fallback. Also asserts no 'else cat' passthrough or SECRET_PATTERNS array remains, verify_installation asserts the lib, and coverage does not shrink with the lib present. Hermetic; no real mail; no network; non-secret markers."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_redact_failloud_p_retire2_test"
# meta:ta.owner="security"
# meta:ta.module="redaction"
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
SUPPORT="$REPO/cli/lib/nftban/cli/cmd_support.sh"
DEBUG="$REPO/cli/lib/nftban/cli/cmd_debug.sh"
UPD="$REPO/cli/lib/nftban/cli/cmd_update_helpers.sh"
VERIFY="$REPO/install/verify_installation.sh"
LIB="$REPO/cli/lib/nftban/lib/nftban_redact.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== SEC-P1-2 P-retire-2 fail-loud + fallback retirement ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
M="LEAKMARK"
MARKER='[REDACTION-UNAVAILABLE: do not share]'
NOLIB="$WORK/nolib"; mkdir -p "$NOLIB/lib"   # NFTBAN_LIB_DIR with NO nftban_redact.sh

extract() { awk "/^$2\(\) \{/{f=1} f{print} f&&/^\}/{exit}" "$1"; }

# --- cmd_support wrappers (use _redact_unavailable) — force lib unavailable ---
SFN="$WORK/support_fns.sh"
extract "$SUPPORT" "_redact_unavailable" >  "$SFN"
extract "$SUPPORT" "_redact_secrets"     >> "$SFN"
extract "$SUPPORT" "_redact_comms"       >> "$SFN"
extract "$SUPPORT" "_support_scrub_stream" >> "$SFN"

# _redact_secrets fail-loud (string)
out=$(bash -c "source '$SFN'; set +e; _redact_secrets 'NFTBAN_SMTP_PASS=${M}-a'" 2>"$WORK/e1"); rc=$?
echo "$out" | grep -qF "$MARKER" && ! echo "$out" | grep -q "$M" && [ "$rc" = 0 ] && grep -q 'SECURITY..ERROR. nftban_redact.sh unavailable' "$WORK/e1" \
  && ok "_redact_secrets fail-loud: marker, no secret, stderr alarm, rc0" || no "_redact_secrets: out='$out' rc=$rc err=$(cat "$WORK/e1")"

# _redact_comms fail-loud (string)
out=$(bash -c "source '$SFN'; set +e; _redact_comms 'NFTBAN_SMTP_PASS=${M}-b'" 2>/dev/null)
echo "$out" | grep -qF "$MARKER" && ! echo "$out" | grep -q "$M" && ok "_redact_comms fail-loud: marker, no secret" || no "_redact_comms: $out"

# _support_scrub_stream fail-loud (stream — must DISCARD stdin, not cat)
out=$(bash -c "source '$SFN'; set +e; printf '%s\n' 'NFTBAN_SMTP_PASS=${M}-c' 'attacker 1.2.3.4' | _support_scrub_stream" 2>/dev/null)
echo "$out" | grep -qF "$MARKER" && ! echo "$out" | grep -q "$M" && ! echo "$out" | grep -q '1.2.3.4' \
  && ok "_support_scrub_stream fail-loud: marker, stdin discarded (no passthrough)" || no "_support_scrub_stream: $out"

# --- cmd_debug _debug_scrub_stream (self-sources; point NFTBAN_LIB_DIR at a lib-less dir) ---
DFN="$WORK/debug_fn.sh"; extract "$DEBUG" "_debug_scrub_stream" > "$DFN"
out=$(bash -c "export NFTBAN_LIB_DIR='$NOLIB'; source '$DFN'; set +e; printf '%s\n' 'NFTBAN_SMTP_PASS=${M}-d' | _debug_scrub_stream" 2>"$WORK/e2"); rc=$?
echo "$out" | grep -qF "$MARKER" && ! echo "$out" | grep -q "$M" && [ "$rc" = 0 ] && grep -q 'SECURITY..ERROR' "$WORK/e2" \
  && ok "_debug_scrub_stream fail-loud: marker, no secret, stderr, rc0 (no else cat)" || no "_debug_scrub_stream: out='$out' rc=$rc"

# --- cmd_update _fx_redact (self-sources; lib-less dir) ---
FFN="$WORK/fx_fn.sh"; extract "$UPD" "_fx_redact" > "$FFN"
out=$(bash -c "export NFTBAN_LIB_DIR='$NOLIB'; source '$FFN'; set +e; printf '%s\n' 'NFTBAN_SMTP_PASS=${M}-e' | _fx_redact" 2>/dev/null)
echo "$out" | grep -qF "$MARKER" && ! echo "$out" | grep -q "$M" && ok "_fx_redact fail-loud: marker, no secret (weak sed retired)" || no "_fx_redact: $out"

# --- source-level retirement assertions ---
[ "$(grep -c 'else cat' "$SUPPORT" "$DEBUG" "$UPD" 2>/dev/null | awk -F: '{s+=$2}END{print s}')" = 0 ] && ok "no 'else cat' passthrough remains in any wrapper" || no "else cat still present"
grep -qE '^\s*readonly -a SECRET_PATTERNS' "$SUPPORT" && no "SECRET_PATTERNS array still present" || ok "SECRET_PATTERNS array retired"
grep -q 'source .*nftban_redact.sh' "$VERIFY" && grep -q 'declare -F nftban_redact_string' "$VERIFY" && ok "verify_installation asserts nftban_redact.sh + API" || no "verify_installation missing redactor assertion"

# --- no coverage shrink WITH the lib present (wrappers still redact via the authority) ---
out=$(bash -c "source '$LIB'; source '$SFN'; set +e; _redact_secrets 'NFTBAN_SMTP_PASS=${M}-f NFTBAN_CONNECTOR_KAFKA_PARTITION_KEY=part-keep bypass=5'")
! echo "$out" | grep -q "$M" && echo "$out" | grep -q 'part-keep' && echo "$out" | grep -q 'bypass=5' \
  && ok "lib present: *_PASS redacted, KAFKA_PARTITION_KEY + bypass= survive (no shrink)" || no "no-shrink: $out"

# --- regressions ---
for t in comms_redact_p2a_noleak comms_redact_p2b1 comms_redact_debug_p_retire1; do
  ( cd "$REPO" && bash "cli/lib/nftban/tests/${t}_test.sh" >/dev/null 2>&1 ) && ok "${t} still passes" || no "${t} regressed"
done
o=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 ); echo "$o" | grep -q '0/4 DEBT' && echo "$o" | grep -q 'PASS' && ok "A0 guard 0/4" || no "A0 guard regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
