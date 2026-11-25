#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.1 F1: nft probe capture files never go to /tmp when the labelled dir is usable
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nft_probe_capture_dir_v1238_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-25"
# meta:description="v1.238.1 F1 (owner 2026-11-25). On EL9/EL10 Enforcing nftband (nftband_t, PrivateTmp) could not create the probe's capture files in /tmp (tmp_t), so the BotGuard kernel layer was not applied after a reboot. Runs the REAL nftban_nft_probe_table / nftban_nft_probe_set with a stub nft that records where its stdout/stderr point: with a writable writers dir (NFTBAN_WRITERS_DIR, sandbox) both captures are created there and NOTHING in TMPDIR; captures are removed afterwards; NFTBAN_PROBE_TMPDIR overrides; an unwritable or absent writers dir (non-root CLI) falls back to TMPDIR as before; verdicts PRESENT/ABSENT unchanged. Non-vacuity: the pre-fix code wrote into TMPDIR. Sandbox only; no firewall change."
# meta:input="cli/lib/nftban/lib/nft_probe.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,readlink"
# meta:inventory.files="cli/lib/nftban/lib/nft_probe.sh"
# meta:inventory.binaries="bash,mktemp,readlink"
# meta:inventory.env_vars="NFTBAN_NFT_BIN,NFTBAN_WRITERS_DIR,NFTBAN_PROBE_TMPDIR,TMPDIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nft_probe_capture_dir_v1238_1_test"
# meta:ta.owner="cli"
# meta:ta.module="nft-probe-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/nft_probe.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "${W:?}"' EXIT
mkdir -p "$W/writers" "$W/tmp" "$W/override" "$W/bin"
chmod 0700 "$W/writers"
# stub nft: records the directories its stdout and stderr point to, prints a table listing
cat > "$W/bin/nft" <<'STUB'
#!/usr/bin/env bash
o=$(readlink /proc/$$/fd/1); e=$(readlink /proc/$$/fd/2)   # read before any redirection here
printf '%s\n%s\n' "$(dirname "$o")" "$(dirname "$e")" >> "$NFT_STUB_LOG"
case "$*" in
  "list tables") printf 'table ip nftban\ntable ip6 nftban\n' ;;
  "list sets ip") printf 'table ip nftban {\n\tset blacklist_ipv4 {\n\t\ttype ipv4_addr\n\t}\n}\n' ;;
esac
STUB
chmod +x "$W/bin/nft"

run() { # $1 = writers dir, $2 = NFTBAN_PROBE_TMPDIR ("" = unset), $3 = probe kind -> "verdict"
    : > "$W/log"
    env -i PATH=/usr/bin:/bin HOME="$W" TMPDIR="$W/tmp" NFTBAN_NFT_BIN="$W/bin/nft" NFT_STUB_LOG="$W/log" \
        NFTBAN_WRITERS_DIR="$1" ${2:+NFTBAN_PROBE_TMPDIR="$2"} bash -c '
        source "$0" >/dev/null 2>&1 || exit 9
        if [[ "$1" == table ]]; then nftban_nft_probe_table ip nftban test >/dev/null 2>&1
        else nftban_nft_probe_set ip nftban blacklist_ipv4 test >/dev/null 2>&1; fi
        echo "$NFTBAN_NFT_PROBE_VERDICT"' "$LIB" "$3"
}
dirs() { sort -u "$W/log" | tr '\n' ' '; }
left() { find "$1" -name '.nftban-probe.*' | wc -l; }

echo "=== writable writers dir (root on a package host) ==="
for k in table set; do
    v=$(run "$W/writers" "" $k)
    [[ "$v" == PRESENT && "$(dirs)" == "$W/writers " ]] && ok "$k probe: captures in the writers dir, verdict PRESENT" || no "$k probe" "verdict=$v dirs=$(dirs)"
done
[[ "$(left "$W/tmp")" == 0 && -z "$(ls -A "$W/tmp")" ]] && ok "nothing created in TMPDIR" || no "TMPDIR touched" "$(ls -A "$W/tmp")"
[[ "$(left "$W/writers")" == 0 ]] && ok "captures removed after the probe" || no "captures left behind"

echo "=== override ==="
v=$(run "$W/writers" "$W/override" table)
[[ "$v" == PRESENT && "$(dirs)" == "$W/override " ]] && ok "NFTBAN_PROBE_TMPDIR wins" || no "override" "dirs=$(dirs)"

echo "=== fallback (non-root CLI: writers dir not writable / absent) ==="
chmod 0500 "$W/writers"
v=$(run "$W/writers" "" table)
[[ "$v" == PRESENT && "$(dirs)" == "$W/tmp " ]] && ok "unwritable writers dir: TMPDIR as before" || no "fallback unwritable" "dirs=$(dirs)"
chmod 0700 "$W/writers"
v=$(run "$W/absent" "" set)
[[ "$v" == PRESENT && "$(dirs)" == "$W/tmp " ]] && ok "absent writers dir: TMPDIR as before" || no "fallback absent" "dirs=$(dirs)"
ln -s "$W/writers" "$W/link"
v=$(run "$W/link" "" table)
[[ "$(dirs)" == "$W/tmp " ]] && ok "symlinked writers dir is not used" || no "symlink" "dirs=$(dirs)"

echo "=== verdicts unchanged ==="
v=$(env -i PATH=/usr/bin:/bin TMPDIR="$W/tmp" NFTBAN_NFT_BIN="$W/bin/nft" NFT_STUB_LOG="$W/log" NFTBAN_WRITERS_DIR="$W/writers" bash -c 'source "$0" >/dev/null 2>&1; nftban_nft_probe_table ip6 other test >/dev/null 2>&1; echo "$NFTBAN_NFT_PROBE_VERDICT"' "$LIB")
[[ "$v" == ABSENT ]] && ok "absent table still ABSENT" || no "ABSENT verdict" "$v"

echo "=== non-vacuity ==="
grep -q '"${TMPDIR:-/tmp}/.nftban-probe' "$LIB" && no "the library still builds probe paths from TMPDIR directly" || ok "no direct \${TMPDIR:-/tmp}/.nftban-probe path left in the library"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
