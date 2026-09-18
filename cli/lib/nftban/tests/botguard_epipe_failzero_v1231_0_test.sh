#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.231.0 - BotGuard EPIPE fail-to-zero behavioral regression
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botguard_epipe_failzero_v1231_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-17"
# meta:description="BEHAVIORAL (not source-text) regression guard for the v1.231.0 BotGuard fail-to-zero pair, both of which made a security counter report 0 for a set holding thousands. (F1) SIZE-DEPENDENT EPIPE: the presence test for the 'elements = {' section was a pipeline whose consumer was 'grep -q'. grep -q exits at the FIRST match, and that match is on the 6th line of 'nft list set' output; the producing subshell still has the whole element list to write, blocks on the 64 KiB pipe buffer and dies of SIGPIPE (141). Both cmd_botguard.sh and the cmd_status.sh render/JSON paths run under 'set -Eeuo pipefail' (file scope, and cli/sbin/nftban:30 for the dispatch), so pipefail adopts 141 as the PIPELINE status even though grep MATCHED -- a successful match is reported as a failure and the counter falls back to its 0 initialiser. Measured threshold on this output shape: 928 elements / 43,629 B passes, 929 elements / 43,677 B fails; production rulesets are 168-196 KB, so this fired every time. Ignoring SIGPIPE does NOT help: the producer then takes EPIPE and returns 1, which pipefail adopts identically -- the defect is in the SHORT-CIRCUITING CONSUMER, not the signal disposition. (F2) ARGV SPLIT: _botguard_kernel_set_count and _botguard_kernel_set_exists passed their '<family> <table>' argument as an UNQUOTED \$table, relying on the ambient IFS to split it -- but cmd_botguard.sh sources lib/cmd_common.sh which sources lib/strict.sh which sets IFS=\$'\\n\\t' (NO SPACE), so nft received 'ip nftban' as ONE argv word, every call failed, and the failure arm returns a count. F2 is strictly UPSTREAM of F1 and MASKED it: all twelve counters in _nftban_botguard_stats gate on the _exists predicate and kept their 0 initialiser regardless of kernel truth. This test drives the REAL exported helpers in real child shells (production errexit/pipefail/IFS/traps stay armed inside the subject while the harness stays alive to report), over generated 'nft list set'-shaped fixtures delivered by FILE through an ARGV-FAITHFUL nft stub that serves content only when it receives the family and table as SEPARATE words. It asserts a large set counts correctly, a read-and-empty set stays a known 0 (over-applying UNKNOWN is its own truth defect), an unreadable set never fabricates a nonzero, and the four equivalent cmd_status.sh guards -- located BY SHAPE, extracted from the shipped file and EXECUTED, never inspected -- take their true branch on a large fixture. Closes with a DECLARED INVERSION negative control that restores the pipeline shape INLINE (never read from origin/main, which inverts the moment this merges) and proves the large-fixture arms then report 0, plus a size-dependence control showing a small fixture passes under BOTH shapes while a large one passes only under the fixed shape.Every probe answers through a UNIQUE per-call result file and carries a SUBJECT-SERVED WITNESS: the child records, immediately before the subject runs, how many bytes the subject's own read of ip/nftban/http_bot_suspect returned. A `found:false` over a zero-byte read is NOT_EXECUTED (FIXTURE_NOT_SERVED) with that byte count and the child rc, never the verdict ABSENT -- an unserved fixture and a correct negative are the same string otherwise, and the needle '.*' matches the empty string, so the pattern-injection control would have read FOUND over nothing. An inversion control that WAS served and still answers wrongly still FAILS loudly, and now reports the byte count that proves it was served."
#
# meta:input="Generated nft-list-set-shaped fixtures in a mktemp sandbox; argv-faithful nft stub on PATH"
# meta:output="Pass/fail/not-executed assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed,wc"
# meta:inventory.files="cli/lib/nftban/cli/cmd_botguard.sh,cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash,grep,sed,wc"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="botguard_epipe_failzero_v1231_0_test"
# meta:ta.owner="botguard"
# meta:ta.module="botguard-epipe-failzero"
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
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export NFTBAN_LIB_DIR
BOTGUARD_SRC="$NFTBAN_LIB_DIR/cli/cmd_botguard.sh"
STATUS_SRC="$NFTBAN_LIB_DIR/cli/cmd_status.sh"

PASS=0; FAIL=0; NOTEXEC=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
# A subject that could not be CONSTRUCTED is its own verdict class. It is never a
# pass (nothing was proven) and never a fail (the product was never asked).
nx(){ printf '  [NOT_EXECUTED] %s :: %s\n' "$1" "$2"; NOTEXEC=$((NOTEXEC+1)); }

for _b in grep sed wc; do
  command -v "$_b" >/dev/null 2>&1 || { echo "PRECONDITION_MISSING: $_b (declared in meta:depends)" >&2; exit 1; }
done
[[ -r "$BOTGUARD_SRC" ]] || { echo "PRECONDITION_MISSING: $BOTGUARD_SRC" >&2; exit 1; }
[[ -r "$STATUS_SRC"   ]] || { echo "PRECONDITION_MISSING: $STATUS_SRC" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_CONFIG_DIR="$tmp/noetc"

# ---------------------------------------------------------------------------
# Fixture generator. Reproduces the real `nft list set` layout: the
# `elements = {` marker sits on the 6th line, near the TOP, which is precisely
# why a short-circuiting consumer can exit while most of the payload is unwritten.
# Fixtures are written to FILES. They are NEVER passed through the environment:
# a 250 KB `export` followed by execve returns E2BIG (rc 126), which is an
# environment failure masquerading as a verdict.
# ---------------------------------------------------------------------------
gen_fixture() {
  local n="$1" out="$2" i=0 a b c
  {
    printf 'table ip nftban {\n\tset http_bot_suspect {\n\t\ttype ipv4_addr\n'
    printf '\t\tflags dynamic,timeout\n\t\ttimeout 1h\n\t\telements = {'
    while [ "$i" -lt "$n" ]; do
      a=$(( (i/65536) % 200 + 11 )); b=$(( (i/256) % 256 )); c=$(( i % 256 ))
      [ "$i" -gt 0 ] && printf ','
      printf '\n\t\t\t     %d.%d.%d.%d timeout 1h expires 59m%ds' "$a" "$b" "$c" $((i%250+1)) $((i%60))
      i=$((i+1))
    done
    printf ' }\n\t}\n}\n'
  } > "$out"
}

# A set that was READ successfully and genuinely holds nothing: no elements block.
gen_empty_fixture() {
  printf 'table ip nftban {\n\tset http_bot_suspect {\n\t\ttype ipv4_addr\n\t\tflags dynamic,timeout\n\t\ttimeout 1h\n\t}\n}\n' > "$1"
}

BIG_N=6000; SMALL_N=100
BIG="$tmp/big.nft"; SMALL="$tmp/small.nft"; EMPTY="$tmp/empty.nft"
gen_fixture "$BIG_N" "$BIG"
gen_fixture "$SMALL_N" "$SMALL"
gen_empty_fixture "$EMPTY"
BIG_BYTES=$(wc -c < "$BIG"); SMALL_BYTES=$(wc -c < "$SMALL")

# ---------------------------------------------------------------------------
# ARGV-FAITHFUL nft stub. It serves the fixture ONLY when it is invoked the way
# real nft must be invoked -- family and table as SEPARATE argv words. A stub
# that ignored its arguments would have reported a green count while F2 was live,
# which is exactly how that defect survived. It also records argc so the split
# itself is assertable, and it writes the WHOLE fixture, so a short-circuiting
# consumer downstream produces a genuine SIGPIPE rather than a simulated one.
# NFT_FIXTURE is a PATH (a few dozen bytes), never the payload.
# ---------------------------------------------------------------------------
cat > "$tmp/nft" <<'STUB'
#!/usr/bin/env bash
printf 'ARGC=%s\n' "$#" >> "$NFT_ARGLOG"
printf 'ARGV=%s\n' "$(printf '<%s>' "$@")" >> "$NFT_ARGLOG"
[[ "${NFT_FIXTURE:-}" == "UNREADABLE" ]] && exit 1
if [[ "${1:-}" == list && "${2:-}" == set && "${3:-}" == ip && "${4:-}" == nftban && "${5:-}" == http_bot_suspect ]]; then
  cat "$NFT_FIXTURE"; exit 0
fi
exit 1
STUB
chmod +x "$tmp/nft"
export PATH="$tmp:$PATH"
export NFT_ARGLOG="$tmp/argv.log"

# ---------------------------------------------------------------------------
# Subject runner. The subject ALWAYS executes in a real child process, so the
# production shell contract -- errexit, pipefail, strict.sh's IFS=$'\n\t' and its
# ERR/EXIT traps -- stays fully armed INSIDE the subject while this harness stays
# alive to report. `( ... ) || true` would have disarmed errexit inside the
# subshell and quietly changed the thing under test.
#
# $1 fixture path (or the literal UNREADABLE)
# $2 optional: shell code eval'd AFTER sourcing, used ONLY by the declared
#    inversion controls to restore the pre-fix shape.
# Result is written to a FILE, never stdout: the sourced ERR/EXIT traps are free
# to emit whatever they like without corrupting the measured value.
# ---------------------------------------------------------------------------
cat > "$tmp/run_count.sh" <<'CHILD'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/cli/cmd_botguard.sh"
[[ -n "${INVERSION_CODE:-}" ]] && eval "$INVERSION_CODE"
rc=0
val="$(_botguard_kernel_set_count "ip nftban" "http_bot_suspect")" || rc=$?
printf '%s\n' "$val" > "$RESULT_FILE"
printf '%s\n' "$rc"  > "$RESULT_FILE.rc"
exit 0
CHILD
chmod +x "$tmp/run_count.sh"

RESULT_VAL=""; RESULT_RC=""
run_count() {
  local fixture="$1" inversion="${2:-}"
  : > "$NFT_ARGLOG"
  RESULT_VAL=""; RESULT_RC=""
  local rf="$tmp/result.$RANDOM"
  local child_rc=0
  NFT_FIXTURE="$fixture" INVERSION_CODE="$inversion" RESULT_FILE="$rf" \
    bash "$tmp/run_count.sh" >/dev/null 2>&1 || child_rc=$?
  if [[ ! -f "$rf" ]]; then
    # The child never reached its own write. That is a harness/precondition
    # failure with a named diagnostic, not a product verdict.
    RESULT_VAL="__CHILD_DIED__"; RESULT_RC="$child_rc"; return 1
  fi
  RESULT_VAL="$(cat "$rf")"; RESULT_RC="$(cat "$rf.rc")"
  return 0
}

# The pre-fix shape, DECLARED INLINE. It is never read from origin/main: that
# subject inverts the instant this lane merges, so a control sourced from it
# would silently stop controlling anything.
INVERT_BOTGUARD=$'_botguard_kernel_set_count() {\n  local table="$1"; local set_name="$2"\n  local -a _tbl=(); IFS=\' \' read -r -a _tbl <<< "$table"\n  local output\n  output=$(nft list set "${_tbl[@]+"${_tbl[@]}"}" "$set_name" 2>/dev/null) || { echo "0"; return; }\n  if ! echo "$output" | grep -q \'elements = {\'; then echo "0"; return; fi\n  local elements_section\n  elements_section=$(echo "$output" | sed -n \'/elements = {/,/}/p\')\n  local count\n  count=$(echo "$elements_section" | grep -o \' timeout \' | wc -l)\n  echo "${count:-0}"\n}'

echo "=== BotGuard EPIPE fail-to-zero (v1.231.0) ==="
printf '  fixtures: big=%s elements / %s bytes | small=%s elements / %s bytes\n' \
  "$BIG_N" "$BIG_BYTES" "$SMALL_N" "$SMALL_BYTES"

# ---------------------------------------------------------------------------
# A0 NON-VACUITY. An arm that never crossed the pipe-buffer threshold would pass
# under the defect too, proving nothing. Assert the big fixture is unambiguously
# past it before any verdict depends on it.
# ---------------------------------------------------------------------------
if [[ "$BIG_BYTES" -ge 250000 ]]; then
  ok "A0 big fixture is $BIG_BYTES B (>= 250000, and >> the 65536 B pipe buffer) -- arm is non-vacuous"
else
  no "A0 big fixture is only $BIG_BYTES B -- arm would be vacuous"
fi
if [[ "$SMALL_BYTES" -lt 43629 ]]; then
  ok "A0 small fixture is $SMALL_BYTES B (< the 43629 B last-passing size) -- below threshold as intended"
else
  no "A0 small fixture is $SMALL_BYTES B -- not below the measured threshold"
fi

# ---------------------------------------------------------------------------
# A1 A LARGE MATCHED SET MUST NOT BECOME 0. The core contract.
# ---------------------------------------------------------------------------
if run_count "$BIG"; then
  if [[ "$RESULT_VAL" == "$BIG_N" ]]; then
    ok "A1 large set ($BIG_BYTES B) counted $RESULT_VAL -- exact, not 0"
  elif [[ "$RESULT_VAL" == "0" ]]; then
    no "A1 large set ($BIG_BYTES B) reported 0 -- fail-to-zero is LIVE"
  else
    no "A1 large set ($BIG_BYTES B) reported '$RESULT_VAL', expected $BIG_N"
  fi
else
  nx "A1 large-set count" "subject child exited $RESULT_RC without producing a result"
fi

# ---------------------------------------------------------------------------
# A7 ARGV SPLIT (F2). The upstream defect that masked F1. Proven by observing
# what the stub actually received, not by reading the source.
# ---------------------------------------------------------------------------
argc_ok=0
argc_ok=$(grep -c '^ARGC=5$' "$NFT_ARGLOG") || argc_ok=0   # grep -c exits 1 on zero
if [[ "$argc_ok" -ge 1 ]]; then
  ok "A7 nft received family and table as SEPARATE argv words (ARGC=5) under IFS=\$'\\n\\t'"
else
  no "A7 nft did not receive a split argv; log says: $(tr '\n' ' ' < "$NFT_ARGLOG")"
fi

# ---------------------------------------------------------------------------
# A2 A LEGITIMATE EMPTY SET IS A KNOWN 0. Read-and-empty must stay 0. Promoting
# it to UNKNOWN would be its own truth defect -- over-applying UNKNOWN destroys a
# real measurement just as surely as fabricating a 0 destroys a real absence.
# ---------------------------------------------------------------------------
if run_count "$EMPTY"; then
  if [[ "$RESULT_VAL" == "0" ]]; then
    ok "A2 read-and-empty set reported 0 -- a known zero, not promoted to UNKNOWN"
  else
    no "A2 read-and-empty set reported '$RESULT_VAL', expected 0"
  fi
else
  nx "A2 empty-set count" "subject child exited $RESULT_RC without producing a result"
fi

# ---------------------------------------------------------------------------
# A3 AN UNREADABLE SET MUST NOT FABRICATE A COUNT.
# The three-valued (UNKNOWN) contract is owned by the FU-5 lane, which is NOT an
# ancestor of this branch. So this arm splits: the invariant that holds under
# BOTH contracts is asserted hard, and the strict UNKNOWN expectation is probed
# and reported as NOT_EXECUTED with a named diagnostic while FU-5 is absent. It
# becomes a real PASS the moment FU-5 composes -- it is not silently skipped.
# ---------------------------------------------------------------------------
if run_count "UNREADABLE"; then
  if [[ "$RESULT_VAL" =~ ^[0-9]+$ ]] && [[ "$RESULT_VAL" -gt 0 ]]; then
    no "A3 unreadable set fabricated a nonzero count '$RESULT_VAL'"
  else
    ok "A3 unreadable set did not fabricate a nonzero count (reported '$RESULT_VAL')"
  fi
  if [[ "$RESULT_VAL" == "UNKNOWN" ]]; then
    ok "A3b unreadable set reported UNKNOWN -- three-valued contract present"
  elif [[ "$RESULT_VAL" == "0" ]]; then
    nx "A3b unreadable-set UNKNOWN contract" \
       "THREE_VALUED_CONTRACT_NOT_IN_TREE: this branch descends from origin/main, where the unreadable arm returns 0; the UNKNOWN contract is owned by the FU-5 lane and is not an ancestor here"
  else
    no "A3b unreadable set reported '$RESULT_VAL' -- neither 0 nor UNKNOWN"
  fi
else
  nx "A3 unreadable-set count" "subject child exited $RESULT_RC without producing a result"
fi

# ---------------------------------------------------------------------------
# A4 NEGATIVE CONTROL BY DECLARED INVERSION. Restore the pipeline shape and
# prove the large-set arm DOES report 0 -- i.e. A1 can fail. An arm that cannot
# fail is not a test.
# ---------------------------------------------------------------------------
if run_count "$BIG" "$INVERT_BOTGUARD"; then
  if [[ "$RESULT_VAL" == "0" ]]; then
    ok "A4 INVERSION: pipeline shape reported 0 for the $BIG_BYTES B set -- A1 is discriminating"
  else
    no "A4 INVERSION FAILED TO REPRODUCE: pipeline shape reported '$RESULT_VAL', expected 0. The control no longer controls anything -- A1's pass is not evidence."
  fi
else
  nx "A4 inversion control" "inverted child exited $RESULT_RC without producing a result"
fi

# ---------------------------------------------------------------------------
# A5 THE DEFECT IS SIZE-DEPENDENT, not a parse bug. A small fixture must pass
# under BOTH shapes; only the large one separates them. This is what proves the
# mechanism is the pipe buffer rather than a malformed fixture.
# ---------------------------------------------------------------------------
small_fixed=""; small_inverted=""
run_count "$SMALL"                    && small_fixed="$RESULT_VAL"
run_count "$SMALL" "$INVERT_BOTGUARD" && small_inverted="$RESULT_VAL"
if [[ "$small_fixed" == "$SMALL_N" && "$small_inverted" == "$SMALL_N" ]]; then
  ok "A5 small set ($SMALL_BYTES B) counted $SMALL_N under BOTH shapes -- below the buffer, both correct"
else
  no "A5 small set: fixed='$small_fixed' inverted='$small_inverted', both expected $SMALL_N"
fi

# ---------------------------------------------------------------------------
# A6 THE FOUR cmd_status.sh SITES. Located BY SHAPE (never by line number: line
# numbers drift under every parallel lane, and the numbers this lane was handed
# were in fact read off a different branch). The shipped guard and its body are
# extracted VERBATIM from the file and EXECUTED over the big fixture -- this is a
# behavioral arm on the real bytes, not a source-text inspection. If the shape
# ever regresses to a pipeline, the extracted text regresses with it and this
# arm reports 0.
# ---------------------------------------------------------------------------
extract_site() {
  # $1 = shipped variable name. Anchored on the quote+dollar prefix because
  # _bg_out_v4 is a SUBSTRING of _json_bg_out_v4 and a bare match would conflate
  # the render path with the JSON path.
  local var="$1" lines guard body
  lines="$(grep -F -- "\"\$$var\"" "$STATUS_SRC" | grep -F 'elements = {')" || return 1
  guard="$(printf '%s\n' "$lines" | grep -F 'if ' | head -1)" || return 1
  body="$(printf '%s\n'  "$lines" | grep -F 'sed -n' | head -1)" || return 1
  [[ -n "$guard" && -n "$body" ]] || return 1
  printf '%s\n%s\n' "$guard" "$body"
}

run_status_site() {
  # $1 var name, $2 counter name, $3 fixture, $4 optional inversion guard line
  local var="$1" counter="$2" fixture="$3" force_guard="${4:-}"
  local pair guard body
  pair="$(extract_site "$var")" || return 1
  guard="$(printf '%s\n' "$pair" | sed -n '1p')"
  body="$(printf '%s\n' "$pair" | sed -n '2p')"
  [[ -n "$force_guard" ]] && guard="$force_guard"
  local s="$tmp/site.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf "IFS=\$'\\\\n\\\\t'\n"          # production IFS, per strict.sh
    printf '%s="$(cat "$FIXTURE")"\n' "$var"
    printf '%s=0\n' "$counter"
    printf '%s\n' "$guard"
    printf '%s\n' "$body"
    printf 'fi\n'
    printf 'printf "%%s\\n" "$%s" > "$RESULT_FILE"\n' "$counter"
  } > "$s"
  local rf="$tmp/site.result"; rm -f "$rf"
  FIXTURE="$fixture" RESULT_FILE="$rf" bash "$s" >/dev/null 2>&1 || true
  [[ -f "$rf" ]] || return 1
  cat "$rf"
}

# The inverted guard for each site, declared inline (same discipline as A4).
inverted_guard_for() { printf 'if echo "$%s" | grep -q %s; then' "$1" "'elements = {'"; }

for site in "_bg_out_v4:v4_suspects" "_bg_out_v6:v6_suspects" \
            "_json_bg_out_v4:json_bg_v4" "_json_bg_out_v6:json_bg_v6"; do
  IFS=':' read -r var counter <<< "$site"   # IFS pinned: strict IFS has no ':'
  got=""
  if ! got="$(run_status_site "$var" "$counter" "$BIG")"; then
    nx "A6 cmd_status.sh site \$$var" "SITE_NOT_LOCATED: no 'if ... elements = {' guard plus 'sed -n' body found for \$$var in $STATUS_SRC"
    continue
  fi
  if [[ "$got" == "$BIG_N" ]]; then
    ok "A6 cmd_status.sh \$$var -> $counter counted $got on a $BIG_BYTES B set"
  elif [[ "$got" == "0" ]]; then
    no "A6 cmd_status.sh \$$var -> $counter reported 0 on a $BIG_BYTES B set -- fail-to-zero is LIVE at this site"
  else
    no "A6 cmd_status.sh \$$var -> $counter reported '$got', expected $BIG_N"
  fi

  inv=""
  if inv="$(run_status_site "$var" "$counter" "$BIG" "$(inverted_guard_for "$var")")"; then
    if [[ "$inv" == "0" ]]; then
      ok "A6-INV \$$var: pipeline guard reported 0 -- this site's arm is discriminating"
    else
      no "A6-INV \$$var: pipeline guard reported '$inv', expected 0 -- control is inert"
    fi
  else
    nx "A6-INV \$$var" "inverted site harness produced no result"
  fi
done

# ---------------------------------------------------------------------------
# A8 `nftban botguard test <ip>` -- the SIXTH site. Same BotGuard surface, and
# the only one of the six whose wrong answer is a SECURITY FALSE NEGATIVE: it
# told an operator an address was absent from every bot guard set while the
# kernel held it. Here the pipeline's producer is `nft` ITSELF, so the SIGPIPE
# lands on the real process rather than on an `echo` subshell.
#
# The defect is POSITION-dependent as well as size-dependent: `grep -q` leaves at
# its FIRST match, so the EARLIER the address sits in a large set, the more
# certainly nft is still writing when the pipe closes. An address at the END is
# found even by the broken shape -- which is exactly why this survived testing.
# ---------------------------------------------------------------------------
# Fixture whose FIRST element and LAST element are both known.
FIRST_IP="11.0.0.1"                       # element 0 of gen_fixture
# Derive the last element's address from the generator's own arithmetic so the
# arm cannot silently drift if the generator changes.
_li=$((BIG_N-1))
LAST_IP="$(( (_li/65536) % 200 + 11 )).$(( (_li/256) % 256 )).$(( _li % 256 )).$(( _li % 250 + 1 ))"

# SUBJECT-SERVED WITNESS. `found:false` is a legitimate product answer AND what
# this child emits when the fixture never reached the subject at all -- the stub
# not on PATH, NFT_FIXTURE unreadable, the sandbox gone. Those are NOT_EXECUTED,
# and reporting them as ABSENT hands an arm a verdict nobody measured. So the
# child records, immediately BEFORE the subject runs, how many bytes the subject's
# OWN read of the suspect set returns. The witness is taken through the same stub
# on the same PATH, so it cannot agree with the subject by construction; it is an
# observation, never a substitute for the subject's answer.
cat > "$tmp/run_test_cmd.sh" <<'CHILD'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/cli/cmd_botguard.sh"
[[ -n "${INVERSION_CODE:-}" ]] && eval "$INVERSION_CODE"
_witness="$(nft list set ip nftban http_bot_suspect 2>/dev/null)" || _witness=""
printf 'SETBYTES=%s\n' "${#_witness}" > "$RESULT_FILE.diag"
out="$(_nftban_botguard_test "$PROBE_IP" true)" || true
printf '%s\n' "$out" > "$RESULT_FILE"
exit 0
CHILD
chmod +x "$tmp/run_test_cmd.sh"

# The pre-fix membership test, DECLARED INLINE (never read from origin/main).
# argv is left CORRECT here so the arm isolates the pipeline/regex defect rather
# than re-proving the argv one, which A7 already owns.
INVERT_MEMBERSHIP=$'_botguard_set_contains_ip() {\n  local output="$1"; local needle="$2"\n  printf \'%s\\n\' "$output" | grep -q "$needle"\n}'

# The witness travels through a FILE, not a variable. Every caller invokes
# probe_membership inside a command substitution -- `r="$(probe_membership ...)"`
# -- which runs it in a SUBSHELL, so any variable it assigned would be discarded
# the moment it returned and every reader would see the empty string. That is the
# same class of mistake the witness exists to catch, so it is worth naming: a
# diagnostic that cannot survive its own call site reports "unknown" forever and
# looks exactly like the condition it was added to detect.
PROBE_WITNESS="$tmp/probe.witness"
probe_setbytes() { sed -n 's/^SETBYTES=//p' "$PROBE_WITNESS" 2>/dev/null; }
probe_childrc()  { sed -n 's/^RC=//p'       "$PROBE_WITNESS" 2>/dev/null; }
# true iff the subject's own read came back with bytes in it
probe_served() { local b; b="$(probe_setbytes)"; [[ -n "$b" && "$b" != "0" ]]; }
probe_membership() {  # $1 fixture, $2 ip, $3 optional inversion
  # A UNIQUE result path per call. The previous fixed `$tmp/tc.result` was
  # correct only for as long as `rm -f` never failed: any surviving file would be
  # read as THIS probe's verdict, and the arm that runs immediately before every
  # inversion control is a `-> ABSENT` arm, so a stale read is indistinguishable
  # from an inert control. Not a bug that was observed -- a shape in which that
  # bug could not have been seen. `run_count` already randomises for this reason.
  local rf="$tmp/tc.$RANDOM$RANDOM.result"
  rm -f "$rf" "$rf.diag"
  local _crc=0 _sb=""
  rm -f "$PROBE_WITNESS"
  NFT_FIXTURE="$1" PROBE_IP="$2" INVERSION_CODE="${3:-}" RESULT_FILE="$rf" \
    bash "$tmp/run_test_cmd.sh" >/dev/null 2>&1 || _crc=$?
  [[ -f "$rf.diag" ]] && _sb="$(sed -n 's/^SETBYTES=//p' "$rf.diag")"
  printf 'SETBYTES=%s\nRC=%s\n' "${_sb:-}" "$_crc" > "$PROBE_WITNESS"
  # The child never reached its own write: a harness/precondition failure with a
  # name, never a product verdict.
  [[ -f "$rf" ]] || { printf '__CHILD_DIED__'; return 1; }
  case "$(cat "$rf")" in
    *'"found":true'*)  printf 'FOUND'  ;;
    *'"found":false'*) printf 'ABSENT' ;;
    *)                 printf '__UNPARSEABLE__' ;;
  esac
}

# An inversion control asserts that the PRE-FIX shape produced a wrong answer.
# It can only assert that if the pre-fix shape was actually handed the fixture.
# If the subject's own read came back empty, the control neither passed nor
# failed -- it never ran, and says so with the byte count and the child's rc.
inv_arm() {  # $1 label-on-pass, $2 label-stem, $3 observed verdict
  if [[ "$3" == "FOUND" ]]; then
    ok "$1"
  elif ! probe_served; then
    nx "$2" "FIXTURE_NOT_SERVED: the subject's own read of ip/nftban/http_bot_suspect returned '$(probe_setbytes)' bytes (child rc=$(probe_childrc)), so the pre-fix shape was never given the set to match against -- '$3' is not a measurement of the control"
  else
    no "$2 reported '$3', expected FOUND -- control is inert (subject read $(probe_setbytes) bytes, so it WAS served)"
  fi
}

# --- A8a EPIPE at this site: first element of a large set must be FOUND -------
got="$(probe_membership "$BIG" "$FIRST_IP")" || true
if [[ "$got" == "FOUND" ]]; then
  ok "A8a first element $FIRST_IP of a $BIG_BYTES B set -> FOUND"
else
  no "A8a first element $FIRST_IP of a $BIG_BYTES B set -> $got (expected FOUND; security false negative)"
fi
inv="$(probe_membership "$BIG" "$FIRST_IP" "$INVERT_MEMBERSHIP")" || true
if [[ "$inv" == "ABSENT" ]]; then
  ok "A8a-INV pipeline shape reported $FIRST_IP ABSENT from the set that holds it -- arm is discriminating"
else
  no "A8a-INV pipeline shape reported '$inv', expected ABSENT -- control is inert"
fi

# --- A8b position dependence: the LAST element is found even when broken ------
# This is what makes A8a's failure mode invisible to a casual test, and it is
# why the arm must probe the FIRST element specifically.
inv_last="$(probe_membership "$BIG" "$LAST_IP" "$INVERT_MEMBERSHIP")" || true
fix_last="$(probe_membership "$BIG" "$LAST_IP")" || true

# ⛔ ONLY THE FIXED SHAPE IS ASSERTED HERE. An earlier revision also REQUIRED the
#    broken shape to return FOUND for the last element, on the reasoning that a
#    match at the very end leaves the producer nothing more to write. That is NOT a
#    robust invariant: whether the producer still holds a pending chunk when grep
#    exits depends on pipe-buffer alignment at that instant, so it is host- and
#    size-dependent. MEASURED 2026-09-17: FOUND on the authoring host, ABSENT on
#    lab2 (Ubuntu 24.04) for the same fixture — and ABSENT is the broken shape
#    failing MORE, not the fix failing. Asserting it turned a property of the
#    DEFECT into a pass criterion for the FIX.
#    The discriminating claim is already carried by A8a-INV (first element must be
#    ABSENT under the broken shape). Here the inverted result is RECORDED, not
#    required.
if [[ "$fix_last" == "FOUND" ]]; then
  ok "A8b last element $LAST_IP -> FOUND under the fixed shape (broken shape observed: $inv_last)"
else
  no "A8b last element $LAST_IP -> $fix_last under the FIXED shape (expected FOUND)"
fi
case "$inv_last" in
  FOUND)  echo "      [OBSERVED] broken shape still found the LAST element here — the defect is position-dependent on this host, which is why A8a probes the FIRST element" ;;
  ABSENT) echo "      [OBSERVED] broken shape missed even the LAST element on this host — buffer alignment made it fail regardless of position; strictly worse than position-dependence" ;;
  *)      echo "      [OBSERVED] broken shape returned '$inv_last' for the LAST element" ;;
esac

# ---------------------------------------------------------------------------
# A9 SEMANTICS: the regex->literal change is a DELIBERATE TIGHTENING, asserted
# as such. The old spelling searched the whole rendered set for an unanchored
# BASIC REGULAR EXPRESSION, so it could answer "member" on text that is not an
# element. These arms are run on a SMALL fixture so no EPIPE is in play and the
# only thing under test is matching semantics.
# ---------------------------------------------------------------------------
SEM="$tmp/sem.nft"
{
  printf 'table ip nftban {\n\tset http_bot_suspect {\n\t\ttype ipv4_addr\n'
  printf '\t\tflags dynamic,timeout\n\t\tsize 65535\n\t\ttimeout 1h\n\t\telements = {'
  printf '\n\t\t\t     10.0.0.12 timeout 1h expires 59m58s,'
  printf '\n\t\t\t     192.168.10.5 timeout 1h expires 59m57s }\n\t}\n}\n'
} > "$SEM"

# A9a exact membership still works. This arm is also the VACUITY GATE for every
# "-> ABSENT" arm below: a subject that answers ABSENT to everything (which is
# precisely what the argv defect produced) would satisfy all of them while
# proving nothing. If A9a does not hold, the negative arms are NOT_EXECUTED.
a9a_ok=0
got="$(probe_membership "$SEM" "10.0.0.12")" || true
if [[ "$got" == "FOUND" ]]; then
  a9a_ok=1; ok "A9a exact element 10.0.0.12 -> FOUND (vacuity gate for the ABSENT arms)"
else
  no "A9a exact element 10.0.0.12 -> $got (expected FOUND)"
fi

# Assert a negative membership arm, but only where a positive lookup is known to
# work; otherwise say so instead of banking a meaningless pass.
neg_arm() {  # $1 label, $2 fixture, $3 needle
  local label="$1" fixture="$2" needle="$3" r
  if [[ "$a9a_ok" -ne 1 ]]; then
    nx "$label" "VACUOUS_NEGATIVE: the subject answered ABSENT to a known member (A9a failed), so an ABSENT answer here proves nothing"
    return 0
  fi
  r="$(probe_membership "$fixture" "$needle")" || true
  # ABSENT is also what an unserved fixture produces. A9a gates the SYSTEMATIC
  # case (a subject that answers ABSENT to everything); this gates the PER-PROBE
  # case, where this particular child was handed nothing.
  if ! probe_served; then
    nx "$label" "FIXTURE_NOT_SERVED: the subject's own read returned '$(probe_setbytes)' bytes (child rc=$(probe_childrc)); an ABSENT answer over nothing proves nothing"
    return 0
  fi
  [[ "$r" == "ABSENT" ]] && ok "$label" || no "$label -- got $r, expected ABSENT"
}

# A9b CONTAINMENT IS NOT MEMBERSHIP. 10.0.0.1 is a prefix-sharing DIFFERENT
# address; the set holds only 10.0.0.12. A substring search says "member".
neg_arm "A9b 10.0.0.1 -> ABSENT (set holds 10.0.0.12) -- containment no longer reported as membership" \
        "$SEM" "10.0.0.1"
inv="$(probe_membership "$SEM" "10.0.0.1" "$INVERT_MEMBERSHIP")" || true
inv_arm "A9b-INV old shape reported 10.0.0.1 FOUND -- the false positive was real, and is now closed" \
        "A9b-INV old shape" "$inv"

# A9c the other direction: a LONGER address that merely contains a member.
neg_arm "A9c 192.168.10.55 -> ABSENT (set holds 192.168.10.5)" "$SEM" "192.168.10.55"

# A9d `.` MUST NOT ACT AS A WILDCARD. 10x0y0z12 is not an address in the set,
# but it is matched by the BRE `10.0.0.12`.
DOTF="$tmp/dot.nft"
{
  printf 'table ip nftban {\n\tset http_bot_suspect {\n\t\ttype ipv4_addr\n'
  printf '\t\tcomment "10x0y0z12 seen"\n\t\telements = {'
  printf '\n\t\t\t     192.168.10.5 timeout 1h }\n\t}\n}\n'
} > "$DOTF"
neg_arm "A9d 10.0.0.12 -> ABSENT though the rendered set contains 10x0y0z12 -- '.' is no longer a wildcard" \
        "$DOTF" "10.0.0.12"
inv="$(probe_membership "$DOTF" "10.0.0.12" "$INVERT_MEMBERSHIP")" || true
inv_arm "A9d-INV old shape matched 10x0y0z12 via '.' as a wildcard -- regex interpretation was real" \
        "A9d-INV old shape" "$inv"

# A9e A NEEDLE CARRYING METACHARACTERS IS DATA, NOT A PATTERN. `.*` and `[0-9]`
# must be compared literally and must match nothing here.
for meta in '.*' '10.0.0.[0-9]' '.*timeout.*'; do
  neg_arm "A9e needle '$meta' -> ABSENT -- treated as a literal string, not a pattern" "$SEM" "$meta"
done
# NOTE the asymmetry with A9b-INV: the needle `.*` matches the EMPTY STRING, so
# under the pre-fix shape this arm reports FOUND even for an empty read. It is
# therefore the one inversion arm that CANNOT distinguish "served" from "not
# served" by its own verdict, which is exactly why the witness is consulted here
# too rather than trusting the FOUND.
inv="$(probe_membership "$SEM" '.*' "$INVERT_MEMBERSHIP")" || true
if ! probe_served; then
  nx "A9e-INV old shape" "FIXTURE_NOT_SERVED: the subject's own read returned '$(probe_setbytes)' bytes (child rc=$(probe_childrc)); '.*' matches the empty string, so a FOUND here would have been vacuous"
elif [[ "$inv" == "FOUND" ]]; then
  ok "A9e-INV old shape let the needle '.*' match the whole set -- pattern injection was real"
else
  no "A9e-INV old shape reported '$inv', expected FOUND -- control is inert (subject read $(probe_setbytes) bytes, so it WAS served)"
fi

# A9f MATCHING IS CONFINED TO THE ELEMENTS BLOCK. `65535` appears in the set's
# `size` header; it is not an element and must never be reported as a member.
neg_arm "A9f header text '65535' (the set's size) -> ABSENT -- non-element text is not membership" \
        "$SEM" "65535"

echo
printf 'PASS=%s FAIL=%s NOT_EXECUTED=%s\n' "$PASS" "$FAIL" "$NOTEXEC"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'FAILED ARMS:\n'
  for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
