#!/usr/bin/env bash
# =============================================================================
# NFTBan - nft parser compatibility & failure-truth (v1.228.8 PR1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_parser_compat_v1228_8_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="PR1 consumer-level bad controls for the nft parser contract. Drives nftban_health_check_limiter_capacity against AUTHENTIC per-version nft JSON captured from seven production hosts (nft 1.0.2/1.0.9/1.1.1/1.1.5/1.1.6) and proves: (A) a saturated limiter is detected on EVERY version including 1.0.2, which omits the 'dynamic' flag from -j output and made the old token-gated check blind to 13 real limiters; (B) a healthy limiter is not falsely flagged on any version; (C) a FAILED nft command, MALFORMED JSON, and TRUNCATED JSON each yield UNKNOWN and a non-OK status, never the old silent HEALTHY; (D) an EMPTY-but-successful dump is classified per contract; (E) the discrimination control - the pre-fix token-gated logic - is proven to MISS the 1.0.2 saturation this test catches, so the test cannot pass vacuously."
# meta:ta.id="nft_parser_compat_v1228_8_test"
# meta:ta.owner="health"
# meta:ta.module="nft-parser-contract"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="fixtures/nft-versions/sets-*.json"
# meta:inventory.binaries="bash,python3"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
# The health module enables `set -e`; a check returning CRITICAL(2) must not abort us.
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
FIXDIR="$SCRIPT_DIR/fixtures/nft-versions"
VERSIONS=(1.0.2 1.0.9 1.1.1 1.1.5 1.1.6)

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- health-check harness -----------------------------------------------------
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_CRITICAL=2
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES
NFTBAN_HEALTH_ERRORS=(); NFTBAN_HEALTH_WARNINGS=()

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_health_checks_security.sh" 2>/dev/null || {
    echo "FAIL: cannot source nftban_health_checks_security.sh"; exit 1; }

# Fake nft. MODE drives what the "kernel" returns, so each control exercises the
# REAL consumer (nftban_health_check_limiter_capacity) rather than a re-implementation.
#   ok:<file>   successful dump of a fixture
#   fail        non-zero exit, no output   (command failure)
#   malformed   rc=0 with non-JSON output  (unparseable)
#   truncated   rc=0 with a cut-off JSON document
#   empty       rc=0 with zero bytes
make_nft() {
    cat > "$WORK/nft" <<'EOS'
#!/usr/bin/env bash
case "$NFT_FAKE_MODE" in
    ok:*)      cat "${NFT_FAKE_MODE#ok:}"; exit 0 ;;
    fail)      echo "Error: Could not receive from netlink: No such file or directory" >&2; exit 1 ;;
    malformed) echo 'this is not json at all {{{'; exit 0 ;;
    truncated) head -c 60 "$NFT_FAKE_TRUNC_SRC"; exit 0 ;;
    empty)     exit 0 ;;
esac
EOS
    chmod +x "$WORK/nft"
}
make_nft
export PATH="$WORK:$PATH"

# Build a dump whose FIRST limiter is at a chosen occupancy, preserving the
# authentic per-version representation (flags/size/timeout come from the fixture).
occupy() { # $1=fixture $2=count -> path
    python3 - "$1" "$2" "$WORK/dump.json" <<'PY'
import json,sys
src,count,dst=sys.argv[1],int(sys.argv[2]),sys.argv[3]
doc=json.load(open(src))
done=False
for o in doc["nftables"]:
    s=o.get("set")
    if s and (s.get("size") or 0)>0 and not done:
        s["elem"]=[{"elem":{"val":"10.%d.%d.%d"%(i>>16&255,i>>8&255,i&255)}} for i in range(count)]
        done=True
json.dump(doc,open(dst,"w"))
PY
    printf '%s\n' "$WORK/dump.json"
}

# Runs the REAL consumer in THIS shell (never a subshell: the health arrays are
# the observable under test and a $(...) capture would discard them).
ST=""; ISS=""
run_check() {
    NFTBAN_HEALTH_RESULTS=(); NFTBAN_HEALTH_ISSUES=()
    NFTBAN_HEALTH_ERRORS=(); NFTBAN_HEALTH_WARNINGS=()
    # rc is the health STATUS (2=CRITICAL), not a failure: never let it abort the run.
    nftban_health_check_limiter_capacity >/dev/null 2>&1 || true
    ST="${NFTBAN_HEALTH_RESULTS[limiter_capacity]:-MISSING}"
    ISS="${NFTBAN_HEALTH_ISSUES[limiter_capacity]:-}"
}

echo "=== A. SATURATION DETECTED ON EVERY nft VERSION (authentic captures) ==="
for v in "${VERSIONS[@]}"; do
    f="$FIXDIR/sets-$v.json"
    [[ -f "$f" ]] || { bad "$v fixture missing"; continue; }
    NFT_FAKE_MODE="ok:$(occupy "$f" 65000)"; export NFT_FAKE_MODE
    run_check
    st="$ST"; issues="$ISS"
    if [[ "$st" == "$HEALTH_CRITICAL" && "$issues" == *CRITICAL:*SATURATED* ]]; then
        ok "nft $v: 65000/65535 -> CRITICAL saturation reported"
    else
        bad "nft $v: saturation NOT reported (status=$st issues=${issues:0:90})"
    fi
done

echo "=== B. HEALTHY LIMITER NOT FALSELY FLAGGED (no false positives) ==="
for v in "${VERSIONS[@]}"; do
    NFT_FAKE_MODE="ok:$(occupy "$FIXDIR/sets-$v.json" 10)"; export NFT_FAKE_MODE
    run_check; st="$ST"
    if [[ "$st" == "$HEALTH_OK" ]]; then
        ok "nft $v: 10/65535 -> OK"
    else
        bad "nft $v: healthy limiter flagged (status=$st $ISS)"
    fi
done

echo "=== C. FAILED / MALFORMED / TRUNCATED OBSERVATION -> UNKNOWN, NEVER HEALTHY ==="
NFT_FAKE_MODE=fail; export NFT_FAKE_MODE
run_check; st="$ST"; iss="$ISS"
[[ "$st" != "$HEALTH_OK" && "$iss" == *UNKNOWN:* ]] &&
    ok "nft command failure -> UNKNOWN + non-OK status" ||
    bad "nft command failure reported as OK/no-UNKNOWN (status=$st issues=${iss:0:80})"

NFT_FAKE_MODE=malformed; export NFT_FAKE_MODE
run_check; st="$ST"; iss="$ISS"
[[ "$st" != "$HEALTH_OK" && "$iss" == *UNKNOWN:* ]] &&
    ok "unparseable JSON -> UNKNOWN + non-OK status" ||
    bad "unparseable JSON reported as OK (status=$st issues=${iss:0:80})"

NFT_FAKE_TRUNC_SRC="$(occupy "$FIXDIR/sets-1.0.2.json" 65000)"; export NFT_FAKE_TRUNC_SRC
NFT_FAKE_MODE=truncated; export NFT_FAKE_MODE
run_check; st="$ST"; iss="$ISS"
[[ "$st" != "$HEALTH_OK" && "$iss" == *UNKNOWN:* ]] &&
    ok "truncated JSON -> UNKNOWN + non-OK status" ||
    bad "truncated JSON reported as OK (status=$st issues=${iss:0:80})"

echo "=== D. EMPTY-BUT-SUCCESSFUL DUMP CLASSIFIED PER CONTRACT ==="
NFT_FAKE_MODE=empty; export NFT_FAKE_MODE
run_check; st="$ST"; iss="$ISS"
# rc=0 with zero bytes is not a readable ruleset: it must be UNKNOWN, not OK.
[[ "$st" != "$HEALTH_OK" && "$iss" == *UNKNOWN:* ]] &&
    ok "empty-but-rc0 dump -> UNKNOWN (an empty read is not a measurement)" ||
    bad "empty-but-rc0 dump treated as healthy (status=$st issues=${iss:0:80})"

echo "=== E. DISCRIMINATION CONTROL — the pre-fix logic MUST miss 1.0.2 ==="
# If this control ever passes with the old logic, the test is vacuous: it would
# mean the fixtures no longer carry the version divergence that caused the bug.
old_seen=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for o in d["nftables"] if o.get("set") and "dynamic" in (o["set"].get("flags") or [])))' "$FIXDIR/sets-1.0.2.json")
new_seen=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
n=0
for o in d["nftables"]:
    s=o.get("set")
    if not s: continue
    fl=s.get("flags") or []; sz=s.get("size") or 0
    ht=bool(s.get("timeout")) or "timeout" in fl
    if "dynamic" in fl or (sz and ht): n+=1
print(n)' "$FIXDIR/sets-1.0.2.json")
if [[ "$old_seen" -eq 0 && "$new_seen" -gt 0 ]]; then
    ok "1.0.2 fixture is discriminating: token-gated logic sees $old_seen limiters, semantic logic sees $new_seen"
else
    bad "1.0.2 fixture no longer discriminates (old=$old_seen new=$new_seen) — the test would pass vacuously"
fi

# Authentic-representation assertion: 1.0.2 really does omit the flag, and the
# modern versions really do carry it. Guards against a fixture regenerated from
# the wrong host silently removing the whole point of the corpus.
python3 - "$FIXDIR" <<'PY' && ok "fixtures preserve the authentic per-version flag divergence" || bad "fixture divergence lost"
import json,sys,os
d=sys.argv[1]
def flags(v):
    doc=json.load(open(os.path.join(d,f"sets-{v}.json")))
    for o in doc["nftables"]:
        s=o.get("set")
        if s and (s.get("size") or 0)>0: return s.get("flags") or []
    return []
assert "dynamic" not in flags("1.0.2"), "1.0.2 fixture unexpectedly carries 'dynamic'"
for v in ("1.0.9","1.1.1","1.1.5","1.1.6"):
    assert "dynamic" in flags(v), f"{v} fixture unexpectedly LACKS 'dynamic'"
PY

echo
echo "=== nft_parser_compat_v1228_8: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
