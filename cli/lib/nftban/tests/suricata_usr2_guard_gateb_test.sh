#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — Z5 Suricata USR2 reintroduction guard (REAL logrotate)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="suricata_usr2_guard_gateb_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Z5 DIRECT + FAIL-CLOSED behavioral guard against reintroducing the Suricata eve USR2 postrotate reopen (the R1 regression). Extracts the eve-alerts stanza from the parity-bound shipped template (install/config/nftban-suricata.logrotate — bound byte-for-byte to the generator by the Go inventory-parity test), retargets it at a temp eve.json held open by a long-lived writer (as suricatad holds its eve fd), and runs the REAL logrotate binary. Asserts: (1) the stanza uses copytruncate and contains NO USR2 and NO postrotate/endscript block; (2) the held-fd writer keeps writing the LIVE inode across rotation (copytruncate held-fd continuity — the property USR2+rename+create would break); (3) a second rotation is idempotent. FAIL-CLOSED: if logrotate is unavailable the test FAILS (never silently skips a safety proof)."
# meta:input="install/config/nftban-suricata.logrotate; temp eve.json + generated logrotate config"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure or missing logrotate"
# meta:depends="bash,logrotate,awk,sed,grep,stat"
# meta:inventory.files="install/config/nftban-suricata.logrotate"
# meta:inventory.binaries="logrotate,awk,sed,grep,stat"
# meta:inventory.env_vars=""
# meta:inventory.config_files="install/config/nftban-suricata.logrotate"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (writes only under a temp dir)"
# =============================================================================
set -Eeuo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }

# FAIL-CLOSED: a safety proof cannot pass without proving rotation.
if ! command -v logrotate >/dev/null 2>&1; then
    echo "FAIL: Suricata USR2 guard requires logrotate — refusing to pass without proving rotation (fail-closed)."
    exit 1
fi

# Locate repo root + the shipped (parity-bound) suricata template.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here"
while [ "$root" != "/" ] && [ ! -f "$root/install/config/nftban-suricata.logrotate" ]; do root="$(dirname "$root")"; done
TEMPLATE="$root/install/config/nftban-suricata.logrotate"
[ -f "$TEMPLATE" ] || { echo "FAIL: cannot locate install/config/nftban-suricata.logrotate"; exit 1; }

set +e
me="$(id -un) $(id -gn)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EVE="$WORK/eve-alerts.json"; : > "$EVE"
STATE="$WORK/lr.state"
CONF="$WORK/eve.conf"

# Extract the eve-alerts stanza from the shipped template (path line .. matching }),
# retarget its path at our temp EVE, and DROP su/create (they reference the
# suricata/nftban users which do not exist in the test env) — we keep the
# rotation MECHANISM (copytruncate, compress, rotate, size) which is what the
# USR2 guard is about.
awk '/^\/var\/log\/nftban\/suricata\/eve-alerts\.json/{f=1} f{print} f&&/^}/{exit}' "$TEMPLATE" \
  | sed -e "s#^/var/log/nftban/suricata/eve-alerts\.json#$EVE#" \
        -e '/^[[:space:]]*su /d' \
        -e "s#^[[:space:]]*create .*#    create 0640 $me#" \
  > "$CONF"

echo "== stanza mechanism: copytruncate, NO USR2, NO postrotate =="
if [ ! -s "$CONF" ]; then no "failed to extract eve-alerts stanza from template"; fi
grep -q "copytruncate" "$CONF"                    && ok "eve stanza uses copytruncate" || no "eve stanza missing copytruncate"
grep -q "USR2" "$CONF"                             && no "eve stanza contains USR2 (R1 regression reintroduced)" || ok "eve stanza contains no USR2"
grep -qE "postrotate|endscript" "$CONF"            && no "eve stanza contains a postrotate/endscript block" || ok "eve stanza has no postrotate block"

# eve stanza uses `compress` without `delaycompress`, so the rotated file may be
# immediately gzipped (.1.gz). Read the rotated content from either form.
rotated(){ { zcat "$EVE.1.gz" 2>/dev/null; cat "$EVE.1" 2>/dev/null; } || true; }

echo "== REAL logrotate: held-fd writer stays on the live inode (copytruncate) =="
exec 9>>"$EVE"                       # long-lived writer, as suricatad holds its eve fd
printf '{"event":"A_eve"}\n' >&9
logrotate -f -s "$STATE" "$CONF" >/dev/null 2>&1
printf '{"event":"B_eve"}\n' >&9    # keeps writing via the SAME fd after rotation
exec 9>&-
rotated | grep -q A_eve              && ok "pre-rotation record snapshotted into rotated .1(.gz)" || no "A not in rotated file (copytruncate snapshot failed)"
grep -q B_eve "$EVE"                 && ok "post-rotation record in the LIVE eve file (held fd not stranded)" || no "B not in active eve file (USR2/rename would strand it)"
rotated | grep -q B_eve              && no "post-rotation record leaked into rotated .1(.gz)" || ok "no post-rotation leak into rotated file"

echo "== second rotation is idempotent (writer keeps going) =="
exec 9>>"$EVE"
logrotate -f -s "$STATE" "$CONF" >/dev/null 2>&1
printf '{"event":"C_eve"}\n' >&9
exec 9>&-
grep -q C_eve "$EVE" && ok "second rotation: writer continues on the live file" || no "second rotation broke the writer"

echo
echo "======================================================================"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
