#!/usr/bin/env bash
# =============================================================================
# NFTBan - generation marker reader across nftables versions (v1.236.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="generation_read_nft_compat_v1236_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-09"
# meta:description="Hermetic test of nftban_nft_generation_read (lib/nft_probe.sh) and of the real _fw_atomic_load (cmd_firewall.sh) with a stubbed nft. nftables 1.0.2/1.0.6 omit table comments from JSON (measured on Ubuntu 22.04 and Debian 12); the reader then reads the one-tab table comment from the text listing. Strict: failed reads, malformed JSON, wrong family, duplicate tables, a wrong text header, two table comments or a non-string comment are CANNOT_READ; a nested set/chain comment is never taken as the table's. The load is APPLIED only on an exact generation match (JSON and text flavours); a rejected load is REJECTED and a stale (old) generation or an unreadable readback is UNKNOWN — never APPLIED."
#
# meta:inventory.files="generation_read_nft_compat_v1236_1_test.sh"
# meta:inventory.binaries="bash,jq,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR,NFTBAN_NFT_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="generation_read_nft_compat_v1236_1_test"
# meta:ta.owner="firewall"
# meta:ta.module="atomic-load"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
mkdir -p "$tmp/bin" "$tmp/data" "$tmp/lib/bin"
export STUB="$tmp"

# nft stub. Mode files under $STUB select the behaviour; the "kernel" table comment is $STUB/gen.
#   flavour=json  -> `nft -j list table` carries "comment" (nftables >= 1.0.9 behaviour)
#   flavour=text  -> JSON has no comment; the text listing has it (1.0.2 / 1.0.6 behaviour)
cat > "$tmp/bin/nft" <<'S'
#!/usr/bin/env bash
gen="$(cat "$STUB/gen" 2>/dev/null)"; fl="$(cat "$STUB/flavour" 2>/dev/null || echo json)"
case "$*" in
  "-j list table ip nftban")
    [[ -f "$STUB/json_fail" ]] && { echo "Error: Operation not permitted" >&2; exit 1; }
    [[ -f "$STUB/json_raw" ]] && { cat "$STUB/json_raw"; exit 0; }
    if [[ "$fl" == json && -n "$gen" ]]; then
      printf '{"nftables":[{"metainfo":{"json_schema_version":1}},{"table":{"family":"ip","name":"nftban","handle":3,"comment":"%s"}}]}\n' "$gen"
    else
      printf '{"nftables":[{"metainfo":{"json_schema_version":1}},{"table":{"family":"ip","name":"nftban","handle":3}}]}\n'
    fi ;;
  "list table ip nftban")
    [[ -f "$STUB/text_fail" ]] && { echo "Error: No such file or directory" >&2; exit 1; }
    [[ -f "$STUB/text_raw" ]] && { cat "$STUB/text_raw"; exit 0; }
    printf 'table ip nftban {\n'
    [[ -n "$gen" ]] && printf '\tcomment "%s"\n' "$gen"
    printf '\tset blacklist_manual_ipv4 {\n\t\ttype ipv4_addr\n\t\tcomment "nested set comment"\n\t}\n}\n' ;;
  "-f "*)
    [[ -f "$STUB/apply_rc" ]] && exit "$(cat "$STUB/apply_rc")"
    [[ -f "$STUB/apply_noop" ]] && exit 0          # nft says 0 but the commit did not land (stale generation)
    sed -n '/nftban-gen=/{s/^[[:space:]]*comment "\(nftban-gen=[^"]*\)".*/\1/p;q}' "$2" > "$STUB/gen"
    exit 0 ;;
esac
exit 0
S
chmod 755 "$tmp/bin/nft"
export PATH="$tmp/bin:$PATH"

# shellcheck source=/dev/null
source "$LIB/lib/nft_probe.sh"
set +e
rd() { nftban_nft_generation_read ip nftban; echo "rc=$? v=[$NFTBAN_NFT_GEN_VALUE] src=[$NFTBAN_NFT_GEN_SOURCE]"; }
reset() { rm -f "$tmp"/{json_fail,json_raw,text_fail,text_raw,apply_rc,apply_noop}; }

# ---- reader ---------------------------------------------------------------------------------
reset; echo json > "$tmp/flavour"; echo "nftban-gen=A1" > "$tmp/gen"
[[ "$(rd)" == "rc=0 v=[nftban-gen=A1] src=[json]" ]] || fail "R1 json flavour: $(rd)"
pass "R1 JSON carries the comment -> read from JSON"

echo text > "$tmp/flavour"
[[ "$(rd)" == "rc=0 v=[nftban-gen=A1] src=[text]" ]] || fail "R2 text flavour: $(rd)"
pass "R2 JSON without comment (nftables 1.0.2/1.0.6) -> read from the text listing"

: > "$tmp/gen"
[[ "$(rd)" == "rc=0 v=[] src=[text]" ]] || fail "R3 no marker: $(rd)"
pass "R3 readable table without a marker reads as empty (never as a generation)"
grep -q 'nested set comment' <<< "$(nft list table ip nftban)" || fail "R3 stub sanity"
pass "R4 a nested set comment is not taken as the table comment"

echo "nftban-gen=A1" > "$tmp/gen"; touch "$tmp/json_fail"
[[ "$(rd)" == rc=1* ]] || fail "R5 json read failure: $(rd)"; reset
printf '{"nftables":[{"table":' > "$tmp/json_raw"
[[ "$(rd)" == rc=1* ]] || fail "R6 malformed json: $(rd)"; reset
printf '{"nftables":[{"table":{"family":"ip6","name":"nftban","handle":3,"comment":"nftban-gen=A1"}}]}' > "$tmp/json_raw"
[[ "$(rd)" == rc=1* ]] || fail "R7 wrong family: $(rd)"; reset
printf '{"nftables":[{"table":{"family":"ip","name":"nftban"}},{"table":{"family":"ip","name":"nftban"}}]}' > "$tmp/json_raw"
[[ "$(rd)" == rc=1* ]] || fail "R8 two matching tables: $(rd)"; reset
printf '{"nftables":[{"table":{"family":"ip","name":"nftban","comment":7}}]}' > "$tmp/json_raw"
[[ "$(rd)" == rc=1* ]] || fail "R9 non-string comment: $(rd)"; reset
pass "R5-R9 JSON read failure, malformed, wrong family, duplicate table, non-string comment -> CANNOT_READ"

echo text > "$tmp/flavour"; touch "$tmp/text_fail"
[[ "$(rd)" == rc=1* ]] || fail "R10 text read failure: $(rd)"; reset
printf 'table inet nftban {\n\tcomment "nftban-gen=A1"\n}\n' > "$tmp/text_raw"
[[ "$(rd)" == rc=1* ]] || fail "R11 wrong text header: $(rd)"; reset
printf 'table ip nftban {\n\tcomment "nftban-gen=A1"\n\tcomment "nftban-gen=B2"\n}\n' > "$tmp/text_raw"
[[ "$(rd)" == rc=1* ]] || fail "R12 two table comments: $(rd)"; reset
: > "$tmp/text_raw"
[[ "$(rd)" == rc=1* ]] || fail "R13 empty text listing: $(rd)"; reset
pass "R10-R13 text read failure, wrong header, two table comments, empty listing -> CANNOT_READ"

# ---- the real _fw_atomic_load -----------------------------------------------------------------
eval "$(awk '/^_fw_atomic_load\(\) \{/,/^\}/' "$LIB/cli/cmd_firewall.sh")"
declare -F _fw_atomic_load >/dev/null || fail "could not extract _fw_atomic_load"
nftban_writers_acquire() { return 0; }
nftban_writers_release() { return 0; }
nftban_module_effective_enabled() { return 1; }
cat > "$tmp/lib/bin/nftban-core" <<'S'
#!/usr/bin/env bash
nonce=""; while [[ $# -gt 0 ]]; do [[ "$1" == --nonce ]] && nonce="$2"; shift; done
printf 'table ip nftban {\n    comment "nftban-gen=%s"\n}\n' "$nonce"
echo "RULESET_CONTENT elements=0" >&2
S
chmod 755 "$tmp/lib/bin/nftban-core"
mkdir -p "$tmp/lib/lib"; cp "$LIB/lib/nft_probe.sh" "$tmp/lib/lib/"
export NFTBAN_LIB_DIR="$tmp/lib" NFTBAN_DATA_DIR="$tmp/data"
load() { _fw_atomic_load "$tmp/schema.nft" true > "$tmp/load.out" 2>&1; echo $?; }
: > "$tmp/schema.nft"

reset; echo text > "$tmp/flavour"; echo "nftban-gen=OLD" > "$tmp/gen"
[[ "$(load)" == 0 ]] || fail "L1 text flavour applied load not APPLIED: $(cat "$tmp/load.out")"
grep -q "^nftban-gen=" "$tmp/gen" && ! grep -q OLD "$tmp/gen" || fail "L1 stub did not apply"
pass "L1 nftables 1.0.2/1.0.6 flavour: an applied load is APPLIED (rc 0)"

reset; echo json > "$tmp/flavour"; echo "nftban-gen=OLD" > "$tmp/gen"
[[ "$(load)" == 0 ]] || fail "L2 json flavour applied load not APPLIED: $(cat "$tmp/load.out")"
pass "L2 JSON flavour: an applied load is APPLIED (rc 0)"

for fl in text json; do
  reset; echo $fl > "$tmp/flavour"; echo "nftban-gen=OLD" > "$tmp/gen"; echo 1 > "$tmp/apply_rc"
  r="$(load)"; [[ "$r" == 1 ]] || fail "L3 $fl rejected load rc=$r: $(cat "$tmp/load.out")"
  grep -q "REJECTED" "$tmp/load.out" || fail "L3 $fl no REJECTED text"
  reset; echo $fl > "$tmp/flavour"; echo "nftban-gen=OLD" > "$tmp/gen"; touch "$tmp/apply_noop"
  r="$(load)"; [[ "$r" == 2 ]] || fail "L4 $fl stale generation rc=$r: $(cat "$tmp/load.out")"
  grep -q "generation readback: 'nftban-gen=OLD', expected" "$tmp/load.out" || fail "L4 $fl message: $(cat "$tmp/load.out")"
done
pass "L3/L4 both flavours: a rejected load is REJECTED (1); an old generation is UNKNOWN (2), never APPLIED"

reset; echo text > "$tmp/flavour"; echo "nftban-gen=OLD" > "$tmp/gen"; touch "$tmp/json_fail"
r="$(load)"; [[ "$r" == 2 ]] || fail "L5 unreadable readback rc=$r"
grep -q "generation readback: unreadable" "$tmp/load.out" || fail "L5 message: $(cat "$tmp/load.out")"
pass "L5 unreadable readback after an apply is UNKNOWN (2), never APPLIED"
echo "ALL PASS"
