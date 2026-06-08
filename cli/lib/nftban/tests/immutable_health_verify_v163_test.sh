#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.163: SEC-IMMUT immutable-flag HEALTH VERIFICATION (advisory)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="immutable_health_verify_v163_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Locks the v1.163 SEC-IMMUT advisory health check nftban_health_check_immutable_flags in cli/lib/nftban/core/nftban_health_checks_security.sh. The installer applies chattr +i to security-critical files (internal/installer/validate/authority.go SetImmutableFlags); this health check READS state with lsattr and reports drift as an advisory WARNING only — it never re-applies the flag. Asserts: (1) both pinned files present WITH the immutable 'i' bit -> no warning, status OK; (2) a file present WITHOUT 'i' -> exactly one advisory WARNING appended to NFTBAN_HEALTH_WARNINGS with a remediation hint, and the health status is NOT escalated to error/issue (NFTBAN_HEALTH_ERRORS untouched); (3) file absent -> silent skip, no warning; (4) lsattr missing from PATH -> graceful skip, no warning, no crash; (5) non-root/unreadable-attrs simulation (lsattr exits non-zero) -> graceful skip, no warning. Every case asserts the function NEVER invokes chattr (a chattr mock records calls; any call fails the test). Hermetic: a TMPDIR sandbox stands in for the pinned file paths via the NFTBAN_IMMUT_FILES env override; lsattr/chattr are PATH shims; no host mutation, no real chattr, no systemd."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_health_checks_security.sh,cli/lib/nftban/core/nftban_health.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_IMMUT_FILES"
# meta:inventory.config_files="/etc/nftban/nftban.conf,/usr/lib/nftban/lib/nft_schema.sh"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SEC_LIB="$REPO_ROOT/cli/lib/nftban/core/nftban_health_checks_security.sh"
HEALTH_LIB="$REPO_ROOT/cli/lib/nftban/core/nftban_health.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$SEC_LIB" ]] || { echo "lib not found: $SEC_LIB"; exit 1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# --- Health level constants (mirror nftban_health.sh; the lib uses these) ----
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2; HEALTH_CRITICAL=3
export HEALTH_OK HEALTH_WARNING HEALTH_ERROR HEALTH_CRITICAL

# --- PATH shims: a fake lsattr whose output we control, and a chattr that ----
# --- records every invocation so we can prove the check NEVER writes. ----------
BIN="$SB/bin"; mkdir -p "$BIN"
CHATTR_LOG="$SB/chattr_calls.log"; : > "$CHATTR_LOG"

# lsattr behaviour is driven by per-file marker files in $SB/attr/<basename>:
#   content "i"   -> attr string contains the immutable bit
#   content "noi" -> attr string lacks the immutable bit
#   content "err" -> exit non-zero (simulates EPERM/non-root/unsupported fs)
mkdir -p "$SB/attr"
cat > "$BIN/lsattr" <<EOF
#!/usr/bin/env bash
# mock lsattr: emulates 'lsattr -d <file>'
target=""
for a in "\$@"; do case "\$a" in -*) ;; *) target="\$a";; esac; done
base="\$(basename "\$target")"
marker="$SB/attr/\$base"
state="noi"
[[ -f "\$marker" ]] && state="\$(cat "\$marker")"
case "\$state" in
  i)   printf '%s %s\n' "----i---------e-----" "\$target";;
  noi) printf '%s %s\n' "--------------e-----" "\$target";;
  err) exit 1;;
  *)   exit 1;;
esac
EOF
chmod +x "$BIN/lsattr"

cat > "$BIN/chattr" <<EOF
#!/usr/bin/env bash
# mock chattr: record any invocation — the health check must NEVER call this.
echo "chattr \$*" >> "$CHATTR_LOG"
exit 0
EOF
chmod +x "$BIN/chattr"

# --- Sandbox stand-ins for the two pinned files ------------------------------
F_CONF="$SB/nftban.conf"
F_SCHEMA="$SB/nft_schema.sh"
: > "$F_CONF"
: > "$F_SCHEMA"

# Helper: run the check in a clean subshell with a controlled environment and
# capture warnings/errors/status. Echoes "RC|nwarn|nerr" and dumps warnings.
run_check() {
    local files="$1" path_extra="${2:-$BIN}" path_mode="${3:-prepend}"
    (
        set +e
        if [[ "$path_mode" == "replace" ]]; then
            # Fully replace PATH so the real /usr/bin/lsattr is NOT reachable
            # (simulates lsattr genuinely absent). The function under test needs
            # no external binary other than lsattr, so an empty PATH is enough.
            export PATH="$path_extra"
        else
            export PATH="$path_extra:$PATH"
        fi
        export NFTBAN_IMMUT_FILES="$files"
        # shellcheck disable=SC2034  # set to satisfy the sourced health function's globals; not read by the test
        declare -gA NFTBAN_HEALTH_RESULTS=() NFTBAN_HEALTH_ISSUES=()
        NFTBAN_HEALTH_WARNINGS=(); NFTBAN_HEALTH_ERRORS=()
        # Source ONLY the security lib (self-contained; uses HEALTH_* env vars).
        # NB: the lib re-enables 'set -Eeuo pipefail' on source, so disable
        # errexit AFTER sourcing — otherwise the function's non-zero advisory
        # return would abort this subshell before we can report it.
        # shellcheck disable=SC1090  # intentional non-constant source of the security lib under test
        source "$SEC_LIB" >/dev/null 2>&1
        set +e
        nftban_health_check_immutable_flags
        rc=$?
        printf 'RC=%s\n' "$rc"
        printf 'NWARN=%s\n' "${#NFTBAN_HEALTH_WARNINGS[@]}"
        printf 'NERR=%s\n' "${#NFTBAN_HEALTH_ERRORS[@]}"
        local w
        for w in "${NFTBAN_HEALTH_WARNINGS[@]:-}"; do printf 'WARN=%s\n' "$w"; done
    )
}

set_attr(){ printf '%s' "$2" > "$SB/attr/$(basename "$1")"; }

echo "=== sanity: function exists and is exported ==="
grep -q 'nftban_health_check_immutable_flags()' "$SEC_LIB" \
  && ok "function defined in security lib" || no "function not defined"
grep -q 'export -f nftban_health_check_immutable_flags' "$SEC_LIB" \
  && ok "function exported" || no "function not exported"
grep -q 'nftban_health_check_immutable_flags || ' "$HEALTH_LIB" \
  && ok "registered/invoked in nftban_health.sh (advisory: warnings++)" \
  || no "not invoked in nftban_health.sh"
# Pin comment to authority.go must be present (anti-drift).
grep -q 'authority.go' "$SEC_LIB" \
  && ok "file list pinned to authority.go via comment" || no "missing authority.go pin comment"

echo "=== (1) both files present WITH 'i' => no warning, status OK ==="
: > "$CHATTR_LOG"
set_attr "$F_CONF" i; set_attr "$F_SCHEMA" i
out="$(run_check "$F_CONF $F_SCHEMA")"
rc=$(sed -n 's/^RC=//p' <<<"$out"); nwarn=$(sed -n 's/^NWARN=//p' <<<"$out")
[[ "$rc" == "0" ]] && ok "status OK (rc=0)" || no "expected rc=0, got $rc"
[[ "$nwarn" == "0" ]] && ok "no warnings emitted" || no "expected 0 warnings, got $nwarn"

echo "=== (2) a file present WITHOUT 'i' => exactly one advisory WARNING + hint, no escalation ==="
: > "$CHATTR_LOG"
set_attr "$F_CONF" noi; set_attr "$F_SCHEMA" i
out="$(run_check "$F_CONF $F_SCHEMA")"
rc=$(sed -n 's/^RC=//p' <<<"$out"); nwarn=$(sed -n 's/^NWARN=//p' <<<"$out")
nerr=$(sed -n 's/^NERR=//p' <<<"$out")
[[ "$nwarn" == "1" ]] && ok "exactly one advisory WARNING" || no "expected 1 warning, got $nwarn"
grep -q "^WARN=.*Immutable flag missing.*nftban.conf" <<<"$out" \
  && ok "warning names the file" || no "warning missing/incorrect file"
grep -qE "^WARN=.*chattr \+i.*nftban.conf|^WARN=.*update --repair" <<<"$out" \
  && ok "remediation hint present (chattr +i / update --repair)" || no "no remediation hint"
# Advisory only: status == WARNING (1), NOT error(2)/critical(3); errors untouched.
[[ "$rc" == "1" ]] && ok "status is WARNING (rc=1), not escalated to error/critical" \
  || no "expected rc=1 (WARNING), got $rc"
[[ "$nerr" == "0" ]] && ok "NFTBAN_HEALTH_ERRORS untouched (no exit-code escalation)" \
  || no "errors array touched ($nerr), escalation leaked"

echo "=== (3) file absent => silent skip, no warning ==="
: > "$CHATTR_LOG"
ABSENT="$SB/does_not_exist.conf"
out="$(run_check "$ABSENT")"
rc=$(sed -n 's/^RC=//p' <<<"$out"); nwarn=$(sed -n 's/^NWARN=//p' <<<"$out")
[[ "$rc" == "0" && "$nwarn" == "0" ]] && ok "absent file silently skipped (rc=0, 0 warnings)" \
  || no "absent file not skipped (rc=$rc, warnings=$nwarn)"

echo "=== (4) lsattr MISSING from PATH => graceful skip, no warning, no crash ==="
: > "$CHATTR_LOG"
# Provide an empty PATH dir (no lsattr, no chattr) but keep coreutils via a
# minimal real PATH so 'command' works; the lib must not crash under set -u.
EMPTY="$SB/empty"; mkdir -p "$EMPTY"
set_attr "$F_CONF" noi   # would warn IF lsattr were present
out="$(run_check "$F_CONF $F_SCHEMA" "$EMPTY" replace)"
rc=$(sed -n 's/^RC=//p' <<<"$out"); nwarn=$(sed -n 's/^NWARN=//p' <<<"$out")
[[ "$rc" == "0" ]] && ok "graceful skip when lsattr absent (rc=0)" || no "expected rc=0, got $rc"
[[ "$nwarn" == "0" ]] && ok "no warning when lsattr absent" || no "expected 0 warnings, got $nwarn"

echo "=== (5) non-root / unreadable attrs (lsattr exits non-zero) => graceful skip ==="
: > "$CHATTR_LOG"
set_attr "$F_CONF" err; set_attr "$F_SCHEMA" err
out="$(run_check "$F_CONF $F_SCHEMA")"
rc=$(sed -n 's/^RC=//p' <<<"$out"); nwarn=$(sed -n 's/^NWARN=//p' <<<"$out")
[[ "$rc" == "0" && "$nwarn" == "0" ]] \
  && ok "lsattr-error files skipped without warning (rc=0, 0 warnings)" \
  || no "lsattr-error not skipped (rc=$rc, warnings=$nwarn)"

echo "=== INVARIANT: chattr NEVER invoked across ALL cases ==="
# Re-run every case once more under a single chattr log to be thorough.
: > "$CHATTR_LOG"
set_attr "$F_CONF" i;   set_attr "$F_SCHEMA" i;   run_check "$F_CONF $F_SCHEMA"   >/dev/null
set_attr "$F_CONF" noi; set_attr "$F_SCHEMA" i;   run_check "$F_CONF $F_SCHEMA"   >/dev/null
run_check "$SB/does_not_exist.conf"                                                >/dev/null
run_check "$F_CONF $F_SCHEMA" "$SB/empty"                                          >/dev/null
set_attr "$F_CONF" err; set_attr "$F_SCHEMA" err; run_check "$F_CONF $F_SCHEMA"   >/dev/null
if [[ -s "$CHATTR_LOG" ]]; then
    no "chattr WAS invoked (read-only contract violated)" "$(cat "$CHATTR_LOG")"
else
    ok "chattr never invoked (read-only / no flag re-application)"
fi

echo "================================================================"
echo "immutable_health_verify_v163: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
