#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: nft probe/observe/listing captures use NO file (pipes only)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nft_capture_without_files_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-26"
# meta:description="v1.238.2 (owner 2026-11-26, v1.238.1 RC acceptance). v1.238.1 moved the nft probe capture FILES to /run/nftban-writers; nftban-boot-content.service runs nft in iptables_t, which may not write there, so on EL9/EL10 Enforcing the boot probe read EMPTY_OUTPUT_NO_ABSENCE_PROOF and the durable bans/whitelist were not loaded at early boot. The captures now go through pipes (_nftban_capture3). Runs the REAL nftban_nft_probe_table / nftban_nft_probe_set, nft_fragment_observe_chain/_jumps/_set and the DDoS Suricata block-rule listing with a stub nft that records what its stdout/stderr are: NO call may write to a regular file, nothing is created in the writers dir or TMPDIR, verdicts PRESENT/ABSENT unchanged; on failure the exit status and the nft diagnostic are preserved (probe RC/CLASS/STDERR, observe reason, listing error and the remove-on-missing-table rule); works under a caller's errexit and for a listing larger than a pipe buffer. Non-vacuity: v1.238.1 code wrote capture files. Sandbox only; no firewall change."
# meta:input="cli/lib/nftban/lib/nft_probe.sh, cli/lib/nftban/lib/nft_fragment.sh, cli/lib/nftban/core/nftban_ddos_suricata.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,readlink"
# meta:inventory.files="cli/lib/nftban/lib/nft_probe.sh,cli/lib/nftban/lib/nft_fragment.sh,cli/lib/nftban/core/nftban_ddos_suricata.sh"
# meta:inventory.binaries="bash,mktemp,readlink"
# meta:inventory.env_vars="NFTBAN_NFT_BIN,NFTBAN_WRITERS_DIR,NFTBAN_LIB_DIR,TMPDIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nft_capture_without_files_v1238_2_test"
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
mkdir -p "$W/writers" "$W/tmp" "$W/bin" "$W/etc/rules.d"
chmod 0700 "$W/writers"

# Stub nft. Records, per call, the kind of its stdout and stderr: "file" (a regular file) or
# "other" (pipe, tty, /dev/null). NFT_STUB_MODE selects the answer.
cat > "$W/bin/nft" <<'STUB'
#!/usr/bin/env bash
k() { local t; t=$(readlink "/proc/$$/fd/$1" 2>/dev/null); [[ "$t" == /* && -f "$t" ]] && echo file || echo other; }
echo "$(k 1) $(k 2) $*" >> "$NFT_STUB_LOG"
case "${NFT_STUB_MODE:-ok}" in
  fail)  echo "Error: Could not process rule: Operation not permitted" >&2; exit 1 ;;
  nochain) echo "Error: No such file or directory; did you mean table 'nftban' in family ip?" >&2; exit 1 ;;
  empty) exit 0 ;;
  big)   printf 'table ip nftban\n'; for i in $(seq 1 12000); do printf 'table ip filler%05d\n' "$i"; done; printf 'table ip6 nftban\n'; exit 0 ;;
esac
args=" $* "
case "$args" in
  *" list tables "*) printf 'table ip nftban\ntable ip6 nftban\n' ;;
  *" list chains "*) printf 'table ip nftban {\n\tchain input {\n\t}\n\tchain portscan_detection {\n\t}\n}\n' ;;
  *" list sets "*)   printf 'table ip nftban {\n\tset blacklist_ipv4 {\n\t\ttype ipv4_addr\n\t}\n\tset ddos_blocked {\n\t\ttype ipv4_addr\n\t}\n}\n' ;;
  *" list set "*)    printf 'table ip nftban {\n\tset ddos_blocked {\n\t\ttype ipv4_addr\n\t}\n}\n' ;;
  *" list chain "*)  printf 'table ip nftban {\n\tchain input { # handle 1\n\t\tjump portscan_detection # handle 7\n\t}\n}\n' ;;
  *) printf 'table ip nftban {\n}\n' ;;
esac
STUB
chmod +x "$W/bin/nft"

# run <mode> <snippet> -> stdout of the snippet; every nft call is logged in $W/log
run() {
    : > "$W/log"
    env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" TMPDIR="$W/tmp" NFT_STUB_LOG="$W/log" NFT_STUB_MODE="$1" \
        NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_NFT_BIN="$W/bin/nft" \
        NFTBAN_WRITERS_DIR="$W/writers" bash -c "source \"\$NFTBAN_LIB_DIR/lib/nft_probe.sh\" >/dev/null 2>&1; $2" 2>"$W/stderr"
}
files_used() { grep -c '^file\|^[a-z]* file' "$W/log"; }
calls() { grep -c . "$W/log"; }
clean_dirs() { [[ -z "$(ls -A "$W/tmp")" && -z "$(ls -A "$W/writers")" ]]; }

P_TABLE='nftban_nft_probe_table ip nftban t; echo "$NFTBAN_NFT_PROBE_VERDICT|$NFTBAN_NFT_PROBE_RC|$NFTBAN_NFT_PROBE_CLASS|$NFTBAN_NFT_PROBE_STDERR"'
P_SET='nftban_nft_probe_set ip nftban blacklist_ipv4 t; echo "$NFTBAN_NFT_PROBE_VERDICT|$NFTBAN_NFT_PROBE_RC|$NFTBAN_NFT_PROBE_CLASS"'
OBS='source "$NFTBAN_LIB_DIR/lib/nft_fragment.sh" >/dev/null 2>&1
nft_fragment_observe_chain ip nftban input; echo "C:$?|$NFT_FRAGMENT_OBS_STATE|$NFT_FRAGMENT_OBS_REASON"
nft_fragment_observe_jumps ip nftban input; echo "J:$?|$NFT_FRAGMENT_OBS_JUMPS|$NFT_FRAGMENT_OBS_REASON"
nft_fragment_observe_set ip nftban ddos_blocked; echo "S:$?|$NFT_FRAGMENT_OBS_STATE|$NFT_FRAGMENT_OBS_REASON"'
LST='source "$NFTBAN_LIB_DIR/core/nftban_ddos_suricata.sh" >/dev/null 2>&1; _nftban_ddos_suricata_block_rule "ip nftban" ddos_blocked remove; echo "rc=$?"'

echo "=== healthy answers: no capture file anywhere ==="
out=$(run ok "$P_TABLE")
[[ "$out" == PRESENT\|0\|NONE\|* ]] && ok "table probe PRESENT" || no "table probe" "$out"
[[ $(calls) -ge 1 && $(files_used) -eq 0 ]] && ok "table probe: nft stdout/stderr are not files ($(calls) calls)" || no "table probe used a file" "$(cat "$W/log")"
clean_dirs && ok "table probe: writers dir and TMPDIR untouched" || no "dirs touched" "$(ls -A "$W/tmp" "$W/writers")"
out=$(run ok "$P_SET")
[[ "$out" == PRESENT\|0\|NONE ]] && ok "set probe PRESENT" || no "set probe" "$out"
[[ $(files_used) -eq 0 ]] && ok "set probe: no file" || no "set probe used a file" "$(cat "$W/log")"
out=$(run ok 'nftban_nft_probe_table ip6 other t; echo "$NFTBAN_NFT_PROBE_VERDICT"')
[[ "$out" == ABSENT ]] && ok "absent table still ABSENT" || no "ABSENT" "$out"
out=$(run ok "$OBS")
[[ "$out" == *"C:0|PRESENT|"* && "$out" == *"J:0|1|"* && "$out" == *"S:0|PRESENT|"* ]] && ok "N1 observe chain/jumps/set unchanged" || no "N1 observe" "$out"
[[ $(calls) -ge 5 && $(files_used) -eq 0 ]] && ok "N1 observe: no file ($(calls) calls)" || no "N1 used a file" "$(cat "$W/log")"
clean_dirs && ok "N1: dirs untouched" || no "N1 dirs touched"
out=$(run ok "$LST")
[[ "$out" == "rc=0" && $(calls) -ge 1 && $(files_used) -eq 0 ]] && ok "N2 listing: rc 0, no file" || no "N2 listing" "$out / $(cat "$W/log")"
clean_dirs && ok "N2: dirs untouched" || no "N2 dirs touched"

echo "=== failures keep the exit status and the nft diagnostic ==="
out=$(run fail "$P_TABLE")
[[ "$out" == CANNOT_READ\|1\|*\|*"Operation not permitted"* ]] && ok "table probe: CANNOT_READ, rc 1, stderr kept" || no "table probe failure" "$out"
out=$(run fail "$P_SET")
[[ "$out" == CANNOT_READ\|1\|* ]] && ok "set probe: CANNOT_READ, rc 1" || no "set probe failure" "$out"
out=$(run empty "$P_TABLE")
[[ "$out" == CANNOT_READ\|* ]] && ok "rc 0 with empty output is still CANNOT_READ (never ABSENT)" || no "empty output" "$out"
out=$(run fail "$OBS")
[[ "$out" == *"C:1|"* ]] && ok "N1 observe: a failing nft is a failed observation" || no "N1 failure" "$out"
out=$(run nochain "$LST")
[[ "$out" == "rc=0" ]] && ok "N2 remove: nft 'No such file or directory' still means nothing to remove" || no "N2 nochain" "$out"
out=$(run fail "$LST")
[[ "$out" == "rc=1" ]] && grep -q "Operation not permitted" "$W/stderr" && ok "N2: other failures refused, diagnostic printed" || no "N2 failure" "$out / $(cat "$W/stderr")"

echo "=== caller errexit, large listing ==="
out=$(run fail "set -e; $P_TABLE")
[[ "$out" == CANNOT_READ\|1\|* ]] && ok "under set -e the rc is still captured" || no "errexit" "$out"
out=$(run big "$P_TABLE")
[[ "$out" == PRESENT\|0\|* ]] && ok "listing larger than a pipe buffer read completely" || no "big listing" "$out"

echo "=== non-vacuity (static) ==="
grep -nE 'mktemp .*\.nftban-probe' "$LIBDIR/lib/nft_probe.sh" >/dev/null && no "probe still creates capture files" || ok "probe: no capture mktemp"
grep -nE 'mktemp .*\.nftban-obs' "$LIBDIR/lib/nft_fragment.sh" >/dev/null && no "observe still creates capture files" || ok "observe: no capture mktemp"
grep -nE 'mktemp .*\.nftban-ddos-suricata' "$LIBDIR/core/nftban_ddos_suricata.sh" >/dev/null && no "listing still creates a capture file" || ok "listing: no capture mktemp"
grep -nE 'rm -f "\$ef"' "$LIBDIR/lib/nft_fragment.sh" >/dev/null && no "observe still removes \$ef as a path (it is stderr text now)" || ok "observe: no rm of the stderr text"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
