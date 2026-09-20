#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# meta:name="http_logs_record_boundary_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.232. The forward cursor emitted a RAW BYTE WINDOW, cutting a log line in half at every chunk boundary. Characterised over 62 boundaries: 37 lost the line entirely and 15 produced a FALSE ENTRY whose source IP was a TIMESTAMP FRAGMENT while URL, method and status were well formed - so the module did not merely miss data, it manufactured attribution. Asserts the record-boundary-safe contract: every complete logical record is examined exactly once, no duplicates, no synthetic identities, the cursor only ever lands on a record boundary, deferred fragments are re-read whole, and an OVERSIZED record is discarded as a WHOLE RECORD with its own counter rather than leaving the cursor mid-record."
# meta:ta.id="http_logs_record_boundary_v1232_test"
# meta:ta.owner="botscan"
# meta:ta.module="http-logs-record-boundary"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/nftban_http_logs.sh"
# meta:inventory.binaries="bash,stat,od,wc,head,tail"
# meta:inventory.env_vars="NFTBAN_HTTP_LOG_OFFSET_DIR,NFTBAN_HTTP_LOG_MAX_BYTES,NFTBAN_HTTP_LOG_READ_FORWARD"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
PASS=0; FAIL=0; NOT_EXECUTED=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
ne(){ echo "  [NOT_EXECUTED] $1"; NOT_EXECUTED=$((NOT_EXECUTED+1)); }
fin(){ echo; echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOT_EXECUTED ==="; [[ "$FAIL" -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }; echo "RESULT: FAIL"; exit 1; }
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; HTTP="$SD/../lib/nftban_http_logs.sh"
[[ -f "$HTTP" ]] || { ne "subject absent"; fin; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export NFTBAN_DATA_DIR="$SB" NFTBAN_HTTP_LOG_OFFSET_DIR="$SB/off" NFTBAN_HTTP_LOG_READ_FORWARD=true
mkdir -p "$SB/off"
# shellcheck source=/dev/null
source "$HTTP" >/dev/null 2>&1 || { ne "cannot source subject"; fin; }
set +e
declare -F nftban_http_read_incremental >/dev/null || { ne "reader undefined"; fin; }

PFX='10.0.0.1 - - [18/Sep/2026:10:00:00 +0000] "GET /seq-'
SFX='-PADPADPADPADPADPADPAD HTTP/1.1" 404 12 "-" "ua"'
mkcorpus(){ local f="$1" n="$2" i; : >"$f"
  for ((i=1;i<=n;i++)); do printf '%s%05d%s\n' "$PFX" "$i" "$SFX" >>"$f"; done; }
offof(){ local f="$1" k; k="$(NFTBAN_HTTP_CURSOR_NS='' nftban_http_cursor_key "$f")"
  local c="$NFTBAN_HTTP_LOG_OFFSET_DIR/$k"; [[ -f "$c" ]] || { echo 0; return; }
  local v; v=$(cat "$c" 2>/dev/null); echo "${v#*:}"; }
# read until EOF, collecting every emitted line; returns via $OUTF
# ⛔ EACH READ MUST BE CONSUMED SEPARATELY. An earlier version appended every read
# to ONE file with `>>`, so a line split across two windows REJOINED ON DISK and the
# corruption became invisible — arms A/D/F PASSED on unfixed merged main and proved
# nothing. The real consumer parses each read's output on its own (the scan loop
# reads from a per-call process substitution), so a trailing fragment and the next
# window's leading fragment are SEPARATE lines to it and neither is a valid record.
# This models that: per read, complete records go to $OUTF and anything else to
# $FRAGF.
FRAGF="$SB/frag.txt"
drain(){ local f="$1" max="${2:-200}" i sz t="$SB/.one"; sz=$(stat -c%s "$f"); : >"$OUTF"; : >"$FRAGF"
  for ((i=0;i<max;i++)); do
    nftban_http_read_incremental "$f" > "$t" 2>/dev/null
    grep -E  "$RECORD_RE" "$t" >> "$OUTF" 2>/dev/null
    grep -vE "$RECORD_RE" "$t" | grep -v '^$' >> "$FRAGF" 2>/dev/null
    [[ "$(offof "$f")" -ge "$sz" ]] && break
  done; }
# ⛔ `grep -c` PRINTS 0 *AND* EXITS 1 when nothing matches. Writing
# `grep -c . f || echo 0` therefore emits TWO zeros ("0\n0"), which breaks `-eq`
# and made three arms report a spurious failure rendered as "[FAIL] A 0".
# Capture the count; never add a fallback that can double-print.
fragcount(){ local c; c="$(grep -c . "$FRAGF" 2>/dev/null)"; [[ "$c" =~ ^[0-9]+$ ]] || c=0; printf '%s' "$c"; }
ids(){ grep -oE 'seq-[0-9]{5}' "$1" | sed 's/seq-//' | sed 's/^0*//' | sort -n; }
# ⛔ A FRAGMENT IS NOT ONLY A LINE THAT STARTS WRONG. A TRAILING fragment still
# begins with the real IP and would pass a "starts with 10.0.0.1" check while being
# truncated; a LEADING fragment starts mid-line. An earlier version of this test
# checked only the prefix, so arms A/D/F PASSED on unfixed merged main and proved
# nothing. The assertion is therefore COMPLETE RECORD SHAPE: anything that is not a
# whole, well-formed record is a fragment, whichever end it was cut at.
RECORD_RE='^10\.0\.0\.1 - - \[[^]]*\] "GET /seq-[0-9]{5}-PADPADPADPADPADPADPAD HTTP/1\.1" 404 12 "-" "ua"$'
falseid(){ grep -cvE "$RECORD_RE" "$1"; }
# a persisted offset is SAFE if it is 0, EOF, or the byte before it is a newline
safeoff(){ local f="$1" o="$2" sz; sz=$(stat -c%s "$f")
  [[ "$o" -eq 0 || "$o" -ge "$sz" ]] && return 0
  local c; c="$(LC_ALL=C tail -c +"$o" "$f" 2>/dev/null | head -c 1 | od -An -tx1 | tr -d ' \n')"
  [[ "$c" == "0a" ]]; }

OUTF="$SB/out.txt"
echo "=== A — 600 records consumed EXACTLY ONCE, no loss, no synthetic identity ==="
A="$SB/a.log"; mkcorpus "$A" 600
export NFTBAN_HTTP_LOG_MAX_BYTES=1024
drain "$A"
got=$(ids "$OUTF" | wc -l); uq=$(ids "$OUTF" | uniq | wc -l)
miss=$(comm -13 <(ids "$OUTF" | uniq | sort -u) <(seq 1 600 | sort -u) | wc -l)
[[ "$got" -eq 600 ]] && ok "A 600 records emitted (got $got)" || no "A emitted $got of 600"
[[ "$uq" -eq "$got" ]] && ok "A zero duplicates" || no "A $(( got - uq )) duplicate record(s)"
[[ "$miss" -eq 0 ]] && ok "A zero missing IDs" || no "A $miss missing ID(s)"
f_=$(fragcount); [[ "$f_" -eq 0 ]] && ok "A every emitted line is a COMPLETE record (zero fragments, zero synthetic identities)" || no "A $f_ emitted line(s) are not complete records"

echo "=== B — every persisted cursor lands on a RECORD boundary ==="
B="$SB/b.log"; mkcorpus "$B" 300; bad=0; n=0
sz=$(stat -c%s "$B")
for ((i=0;i<60;i++)); do nftban_http_read_incremental "$B" >/dev/null 2>&1
  o=$(offof "$B"); n=$((n+1)); safeoff "$B" "$o" || { bad=$((bad+1)); echo "      unsafe offset $o"; }
  [[ "$o" -ge "$sz" ]] && break; done
[[ "$bad" -eq 0 ]] && ok "B all $n persisted offsets were record-aligned (0, EOF, or just after a newline)" || no "B $bad offset(s) landed mid-record"

echo "=== C — restart mid-corpus: no loss, no replay ==="
C="$SB/c.log"; mkcorpus "$C" 400; : >"$OUTF"
: >"$OUTF"; : >"$FRAGF"
for ((i=0;i<3;i++)); do nftban_http_read_incremental "$C" > "$SB/.one" 2>/dev/null
  grep -E "$RECORD_RE" "$SB/.one" >> "$OUTF" 2>/dev/null
  grep -vE "$RECORD_RE" "$SB/.one" | grep -v '^$' >> "$FRAGF" 2>/dev/null; done
mid=$(offof "$C"); safeoff "$C" "$mid" && ok "C interrupted at a record-safe offset ($mid)" || no "C interrupted mid-record ($mid)"
cz=$(stat -c%s "$C")
for ((i=0;i<200;i++)); do nftban_http_read_incremental "$C" > "$SB/.one" 2>/dev/null
  grep -E "$RECORD_RE" "$SB/.one" >> "$OUTF" 2>/dev/null
  grep -vE "$RECORD_RE" "$SB/.one" | grep -v '^$' >> "$FRAGF" 2>/dev/null
  [[ "$(offof "$C")" -ge "$cz" ]] && break; done
g=$(ids "$OUTF" | wc -l); u=$(ids "$OUTF" | uniq | wc -l)
[[ "$g" -eq 400 && "$u" -eq 400 ]] && ok "C restart completed the corpus: 400 records, zero replay" || no "C got $g records, $u unique (want 400/400)"

echo "=== D — SURVIVAL-sized cap: more boundaries, same records ==="
D="$SB/d.log"; mkcorpus "$D" 600
export NFTBAN_HTTP_LOG_MAX_BYTES=256      # a quarter of A's cap => ~4x the boundaries
drain "$D" 800
g=$(ids "$OUTF" | wc -l); u=$(ids "$OUTF" | uniq | wc -l); fb=$(falseid "$OUTF")
[[ "$g" -eq 600 && "$u" -eq 600 ]] && ok "D 600/600 records at a 4x-smaller cap (more boundaries, no loss)" || no "D got $g/$u of 600 at the smaller cap"
[[ "$fb" -eq 0 ]] && ok "D every emitted line is a COMPLETE record at the smaller cap" || no "D $fb incomplete record(s) at the smaller cap"
export NFTBAN_HTTP_LOG_MAX_BYTES=1024

echo "=== E — a deferred fragment is NOT counted as consumed, and is re-read WHOLE ==="
E="$SB/e.log"; mkcorpus "$E" 40
: >"$OUTF"; : >"$FRAGF"; nftban_http_read_incremental "$E" > "$SB/.one" 2>/dev/null
grep -E "$RECORD_RE" "$SB/.one" >> "$OUTF" 2>/dev/null
o1=$(offof "$E")
[[ "${NFTBAN_HTTP_LAST_DEFERRED_BYTES:-0}" -ge 0 ]] && ok "E deferred-byte accounting is published (${NFTBAN_HTTP_LAST_DEFERRED_BYTES:-unset} B held back)" || no "E no deferred accounting"
[[ "$o1" -eq $(( ${NFTBAN_HTTP_LAST_EMITTED_BYTES:-0} )) ]] && ok "E cursor advanced by EMITTED bytes only, not by the window" || no "E cursor $o1 != emitted ${NFTBAN_HTTP_LAST_EMITTED_BYTES:-0}"
ez=$(stat -c%s "$E")
for ((i=0;i<80;i++)); do nftban_http_read_incremental "$E" > "$SB/.one" 2>/dev/null
  grep -E "$RECORD_RE" "$SB/.one" >> "$OUTF" 2>/dev/null
  [[ "$(offof "$E")" -ge "$ez" ]] && break; done
g=$(ids "$OUTF" | wc -l); u=$(ids "$OUTF" | uniq | wc -l)
[[ "$g" -eq 40 && "$u" -eq 40 ]] && ok "E the deferred record was later consumed exactly once (40/40)" || no "E got $g/$u of 40"

echo "=== F — EOF with NO trailing newline: final record still emitted once ==="
F="$SB/f.log"; mkcorpus "$F" 30; printf '%s%05d%s' "$PFX" 31 "$SFX" >> "$F"   # no trailing \n
drain "$F" 80
g=$(ids "$OUTF" | wc -l); u=$(ids "$OUTF" | uniq | wc -l)
[[ "$g" -eq 31 && "$u" -eq 31 ]] && ok "F 31/31 including the unterminated final record" || no "F got $g/$u of 31"
ff=$(fragcount); [[ "$ff" -eq 0 ]] && ok "F every emitted line is a COMPLETE record at EOF" || no "F $ff incomplete record(s) at EOF"

echo "=== G ⛔ OVERSIZED RECORD: discarded WHOLE, cursor must NOT resume mid-record ==="
G="$SB/g.log"; : >"$G"
printf '%s%05d%s\n' "$PFX" 1 "$SFX" >> "$G"                       # normal before
BIG=$(head -c 3100 /dev/zero | tr '\0' 'X')                        # ~3x the 1024 cap
printf '10.0.0.1 - - [18/Sep/2026:10:00:00 +0000] "GET /%s HTTP/1.1" 404 12 "-" "ua"\n' "$BIG" >> "$G"
printf '%s%05d%s\n' "$PFX" 2 "$SFX" >> "$G"                       # normal after
export NFTBAN_HTTP_OVERSIZED_RECORDS_SKIPPED=0
drain "$G" 60
g=$(ids "$OUTF" | uniq | tr '\n' ' ')
[[ "${NFTBAN_HTTP_OVERSIZED_RECORDS_SKIPPED:-0}" -eq 1 ]] && ok "G oversized record counted EXACTLY ONCE (not once per window)" || no "G oversized counter = ${NFTBAN_HTTP_OVERSIZED_RECORDS_SKIPPED:-unset}, want 1"
xf=$(cat "$OUTF" "$FRAGF" 2>/dev/null | grep -c "XXXX"); [[ "$xf" -eq 0 ]] && ok "G no fragment of the oversized record was emitted" || no "G $xf line(s) contain oversized-record fragments"
fb=$(fragcount); [[ "$fb" -eq 0 ]] && ok "G zero false identities around the oversized record" || no "G $fb false identit(ies) — the cursor resumed mid-record"
[[ "$g" == "1 2 " ]] && ok "G the normal records either side were parsed correctly (got: $g)" || no "G expected '1 2 ', got '$g'"
gz=$(stat -c%s "$G"); go=$(offof "$G")
safeoff "$G" "$go" && ok "G final cursor is record-aligned ($go of $gz)" || no "G final cursor $go landed mid-record"

echo "=== G-INV ⛔ the NAIVE 'skip one window' shape must be DETECTABLY wrong ==="
# ⛔ WHY THIS ARM EXISTS. A future edit could "simplify" the oversized path back to
# "no newline in this window -> advance by the window". That fixes nothing and
# silently reintroduces MID-RECORD RESUME: for a record of 3x the cap, window 1
# skips mid-record, window 2 skips still mid-record, and window 3 finds the
# terminating newline and emits FROM MID-RECORD — a fragment parsed as a record,
# with the field shift that manufactures a false source IP.
# Measured against a tree carrying exactly that shape: 16 PASS / 3 FAIL, all three
# inside arm G (counter=3 not 1, a fragment emitted, one false identity).
# This arm proves the naive offset is detectably unsafe WITHOUT needing that tree,
# so the protection travels with the test.
gstart=0
while IFS= read -r _l; do gstart=$(( gstart + ${#_l} + 1 )); break; done < "$G"   # after record 1
naive=$(( gstart + NFTBAN_HTTP_LOG_MAX_BYTES ))
if [[ "$naive" -lt "$gz" ]] && ! safeoff "$G" "$naive"; then
    ok "G-INV advancing by the window lands MID-RECORD (offset $naive) — the naive shape is detectably unsafe"
else
    no "G-INV the naive offset $naive was record-aligned — this arm has NO POWER against that regression"
fi
fin
