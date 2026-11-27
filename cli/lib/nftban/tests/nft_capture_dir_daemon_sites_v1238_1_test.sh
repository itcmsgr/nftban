#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.1: daemon-reachable nft capture/batch files use the labelled runtime dir, not /tmp
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nft_capture_dir_daemon_sites_v1238_1_test"
# meta:type="test"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-25"
# meta:description="v1.238.1 (owner GO 2026-11-25). nftband (nftband_t, PrivateTmp) reaches five temp-file sites besides the probe: N1 nft_fragment_observe_chain/_jumps/_set (.nftban-obs.*), N2 _nftban_ddos_suricata_block_rule (plain mktemp), N3 nftban_portscan_classic_process_logs (journal batch). Runs the REAL functions with stub nft/journalctl that record where their stdout/stderr point: with a writable writers dir (NFTBAN_WRITERS_DIR, sandbox) every capture is in the writers dir and NOTHING is left in TMPDIR; with an unwritable writers dir they fall back to TMPDIR (non-root CLI) as before. Non-vacuity: the pre-fix code captured in TMPDIR. Sandbox only (NFTBAN_CONFIG_DIR, cursor and state paths in a temp dir); no firewall change."
# meta:input="cli/lib/nftban/lib/{nft_probe,nft_fragment}.sh, cli/lib/nftban/core/{nftban_ddos_suricata,nftban_portscan_classic}.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,readlink"
# meta:inventory.files="cli/lib/nftban/lib/nft_probe.sh,cli/lib/nftban/lib/nft_fragment.sh,cli/lib/nftban/core/nftban_ddos_suricata.sh,cli/lib/nftban/core/nftban_portscan_classic.sh"
# meta:inventory.binaries="bash,mktemp,readlink"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_NFT_BIN,NFTBAN_WRITERS_DIR,TMPDIR,PATH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nft_capture_dir_daemon_sites_v1238_1_test"
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
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "${W:?}"' EXIT
mkdir -p "$W/writers" "$W/tmp" "$W/bin" "$W/etc/conf.d/portscan" "$W/cursor" "$W/state"
chmod 0700 "$W/writers"

# Stubs record the directory of every regular file their stdout/stderr point to (pipes/ttys ignored).
cat > "$W/bin/rec" <<'STUB'
o=$(readlink /proc/$$/fd/1); e=$(readlink /proc/$$/fd/2)
for f in "$o" "$e"; do [[ "$f" == /* && -f "$f" ]] && dirname "$f" >> "$STUB_LOG"; done
STUB
cat > "$W/bin/nft" <<'STUB'
#!/usr/bin/env bash
source "$(dirname "$0")/rec"
args=" $* "
case "$args" in
  *" list tables "*) printf 'table ip nftban\ntable ip6 nftban\n' ;;
  *" list chains "*) printf 'table %s nftban {\n\tchain input {\n\t}\n\tchain portscan_detection {\n\t}\n}\n' "${3:-ip}" ;;
  *" list sets "*)   printf 'table %s nftban {\n\tset ddos_blocked {\n\t\ttype ipv4_addr\n\t}\n}\n' "${3:-ip}" ;;
  *" list chain "*)  printf 'table ip nftban {\n\tchain input { # handle 1\n\t\tjump portscan_detection # handle 7\n\t}\n}\n' ;;
  *) printf 'table ip nftban {\n}\n' ;;
esac
STUB
cat > "$W/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
source "$(dirname "$0")/rec"
printf -- '-- cursor: s=0000;i=1\n'
STUB
chmod +x "$W/bin/nft" "$W/bin/journalctl"

# run <writers-dir> <snippet>  — fresh shell, sandboxed env, the REAL libraries from this tree.
run() {
    : > "$W/log"
    env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" TMPDIR="$W/tmp" STUB_LOG="$W/log" \
        NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_NFT_BIN="$W/bin/nft" \
        NFTBAN_WRITERS_DIR="$1" PORTSCAN_CLASSIC_USE_JOURNALCTL=true PORTSCAN_CLASSIC_CURSOR_DIR="$W/cursor" \
        PORTSCAN_CLASSIC_STATE_FILE="$W/state/ps.db" PORTSCAN_CLASSIC_LOG_FILE="$W/absent.log" \
        NFTBAN_LOG_DIR="$W/state" bash -c "$2" >/dev/null 2>&1
}
dirs() { sort -u "$W/log" | tr '\n' ' '; }
N1='source "$NFTBAN_LIB_DIR/lib/nft_fragment.sh"; nft_fragment_observe_chain ip nftban input; nft_fragment_observe_jumps ip nftban input; nft_fragment_observe_set ip nftban ddos_blocked'
N2='source "$NFTBAN_LIB_DIR/core/nftban_ddos_suricata.sh"; _nftban_ddos_suricata_block_rule "ip nftban" ddos_blocked remove'
N3='source "$NFTBAN_LIB_DIR/core/nftban_portscan_classic.sh"; nftban_portscan_classic_process_logs'

check() { # <label> <snippet> <min-records>
    run "$W/writers" "$2"
    local n; n=$(grep -c . "$W/log")
    if [[ "$n" -ge "$3" && "$(dirs)" == "$W/writers " ]]; then ok "$1: every capture in the writers dir ($n records)"
    else no "$1" "records=$n dirs=$(dirs)"; fi
    [[ -z "$(ls -A "$W/tmp")" ]] && ok "$1: nothing left in TMPDIR" || no "$1: TMPDIR touched" "$(ls -A "$W/tmp" | tr '\n' ' ')"
    [[ -z "$(find "$W/writers" -mindepth 1 -print -quit)" ]] && ok "$1: captures removed" || no "$1: left in writers dir" "$(ls -A "$W/writers" | tr '\n' ' ')"
    rm -rf "${W:?}/tmp/"* "${W:?}/writers/"* 2>/dev/null
}
# v1.238.2: N1 and N2 capture through pipes (lib/nft_probe.sh _nftban_capture3), so they must
# create NO capture file at all, in any directory. N3 (the daemon's journal batch) still uses the
# writers dir. See nft_capture_without_files_v1238_2_test for the full no-file contract.
nofile() { # <label> <snippet>
    run "$W/writers" "$2"
    [[ "$(grep -c . "$W/log")" -eq 0 ]] && ok "$1: no capture file in any directory" || no "$1 wrote a file" "dirs=$(dirs)"
    [[ -z "$(ls -A "$W/tmp")" && -z "$(ls -A "$W/writers")" ]] && ok "$1: writers dir and TMPDIR untouched" || no "$1: dirs touched"
}
echo "=== writable writers dir (root on a package host) ==="
nofile "N1 observe_chain/_jumps/_set" "$N1"
nofile "N2 ddos suricata block-rule listing" "$N2"
check "N3 portscan journal batch" "$N3" 1

echo "=== fallback (non-root CLI: writers dir not writable) ==="
chmod 0500 "$W/writers"
run "$W/writers" "$N3"
[[ "$(dirs)" == "$W/tmp " ]] && ok "N3: TMPDIR as before" || no "N3 fallback" "dirs=$(dirs)"
rm -rf "${W:?}/tmp/"* 2>/dev/null
chmod 0700 "$W/writers"

echo "=== non-vacuity (static) ==="
grep -nE 'mktemp "\$\{TMPDIR:-/tmp\}/\.nftban-obs' "$LIBDIR/lib/nft_fragment.sh" >/dev/null && no "N1 still builds .nftban-obs paths from TMPDIR" || ok "N1: no direct TMPDIR .nftban-obs path"
grep -nE '^\s*nerr=\$\(mktemp\)' "$LIBDIR/core/nftban_ddos_suricata.sh" >/dev/null && no "N2 still uses a plain mktemp" || ok "N2: no plain mktemp"
grep -nE 'mktemp "\$\{TMPDIR:-/tmp\}/nftban-portscan-journal' "$LIBDIR/core/nftban_portscan_classic.sh" >/dev/null && no "N3 still builds the batch path from TMPDIR" || ok "N3: no direct TMPDIR batch path"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
