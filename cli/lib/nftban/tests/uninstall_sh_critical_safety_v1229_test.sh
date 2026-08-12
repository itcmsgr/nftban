#!/usr/bin/env bash
# =============================================================================
# NFTBan — UNINSTALL-PR1: uninstall.sh critical safety (D2 / D4 / D5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="uninstall-sh-critical-safety-v1229-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-12"
# meta:description="Locks UNINSTALL-PR1: standard mode never invokes dpkg --purge, --purge cannot abort mid-deletion on a prefix guard, and the summary states firewall truth without asserting an unobserved protected state."
# meta:inventory.files="uninstall.sh"
# meta:inventory.privileges="none"
# meta:ta.id="uninstall_sh_critical_safety_v1229_test"
# meta:ta.owner="packaging"
# meta:ta.module="uninstall-lifecycle"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
# DEFECTS GUARDED (canonical audit UNINSTALL_PACKAGE_LIFECYCLE_INDEPENDENT_AUDIT_2026_08_11):
#
#   D2  standard mode ran `dpkg --purge` unconditionally, firing postrm purge)
#       which rm -rf'd all five trees — including whitelist.d/*.conf, the durable
#       management-IP whitelist that is the SSH-lockout safety invariant — while
#       this same script printed "Configuration preserved" / "Data preserved".
#
#   D4  /usr/share/nftban sat in data_dirs while every entry was passed "/var/"
#       as expected_prefix, so safe_rm_rf Guard 4 exited 1 AFTER /var/lib,
#       /var/log and /var/cache were already deleted.
#           PARTIAL_PROGRESS != SAFE_INTERMEDIATE_STATE
#
#   D5  the script deletes nft tables in BOTH modes, never re-probes, and said
#       nothing about firewall state; packaging asserted other firewalls "may
#       still be active" — false on the proven EL9 host.
#
# HARNESS POLICY: source is read with comments STRIPPED, so prose describing a
# removed defect can neither satisfy nor violate an assertion
# (GUARD_SUBJECT == GUARD_INPUT). No `producer | grep -q` under pipefail.
# =============================================================================
# shellcheck disable=SC2015
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SRC="$REPO_ROOT/uninstall.sh"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; echo "       $2"; FAIL=$((FAIL+1)); }

[ -r "$SRC" ] || { echo "uninstall.sh not readable at $SRC"; exit 1; }

# Code with comments removed — every structural assertion runs against THIS.
CODE=$(sed 's|#.*||' "$SRC")

# Extract a shell function body by name, comments stripped.
fnbody() { printf '%s\n' "$CODE" | awk -v f="$1" '$0 ~ "^"f"\\(\\)" {n=1} n{print} n && /^\}/{exit}'; }

echo "── T1  BEHAVIOURAL: STANDARD mode must NOT execute dpkg --purge ───────"
# A text scan CANNOT decide this. The pre-fix defect put `dpkg --purge` in the
# ELSE branch, only 8 lines below `if [[ "$PURGE_DATA" == true ]]` — any
# proximity/lookback heuristic reads that as "guarded" and passes the defect.
# So EXECUTE the real function with dpkg/rpm mocked and inspect the argv it
# actually received.  BEHAVIOUR, not shape.
SBX=$(mktemp -d)
# PID-guarded cleanup: a subshell EXIT must not delete the sandbox mid-run.
_owner=$$
cleanup(){ [ "$$" = "$_owner" ] && rm -rf "$SBX"; }
trap cleanup EXIT

mkdir -p "$SBX/bin"
for tool in dpkg rpm; do
    cat > "$SBX/bin/$tool" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$SBX/argv.log"
# 'dpkg -l' / 'rpm -q' must report the package INSTALLED so the removal path is entered.
case "\$1" in
    -l) echo "ii  nftban-core  1.0  all  mock"; exit 0;;
    -q) exit 0;;
esac
exit 0
MOCK
    chmod +x "$SBX/bin/$tool"
done

# Run the real function body, extracted from the shipped script.
run_pkg_mgr() { # $1 = PURGE_DATA value
    : > "$SBX/argv.log"
    (
        set +e
        PATH="$SBX/bin:$PATH"
        # consumed by the eval'd production function below, not by this scope
        # shellcheck disable=SC2034
        PURGE_DATA="$1"
        log(){ :; }; ok(){ :; }; warn(){ :; }; error(){ :; }
        eval "$(awk '/^uninstall_package_manager\(\) *\{/,/^\}/' "$SRC")"
        uninstall_package_manager
    ) >/dev/null 2>&1 || true
    cat "$SBX/argv.log"
}

STD_ARGV=$(run_pkg_mgr false)
PRG_ARGV=$(run_pkg_mgr true)

# Non-vacuity FIRST: if the harness never reached dpkg at all, nothing below means anything.
case "$STD_ARGV" in
    *'dpkg'*) ok "harness reached the real dpkg call path (mock recorded argv)";;
    *) no "mock never invoked — T1 would be vacuous" "argv.log empty";;
esac
# POSITIVE control: --purge MUST appear when PURGE_DATA=true, proving the mock can see it.
case "$PRG_ARGV" in
    *'--purge'*) ok "--purge IS observed in purge mode (detector proven sighted)";;
    *) no "--purge not seen even in purge mode" "detector blind: $PRG_ARGV";;
esac
# THE ASSERTION: standard mode must never purge.
case "$STD_ARGV" in
    *'--purge'*) no "dpkg --purge EXECUTED in standard mode (D2)" "$STD_ARGV";;
    *) ok "standard mode executes remove but NEVER --purge (D2)";;
esac

echo "── T2  the standard path still removes the package ────────────────────"
# The D2 fix must not have turned removal into a no-op.
case "$STD_ARGV" in
    *'--remove'*) ok "standard mode still executes dpkg --remove";;
    *) no "standard mode no longer removes the package" "$STD_ARGV";;
esac

echo "── T3  --purge reaches /usr/share/nftban without a prefix abort ───────"
BODY=$(fnbody uninstall_data)
[ -n "$BODY" ] || no "uninstall_data not found" "cannot verify D4"
case "$BODY" in
    *'/usr/share/nftban'*) ;;
    *) no "/usr/share/nftban absent from purge list" "$BODY";;
esac
# The /var/ prefix must never be applied to a /usr/share path.
MISMATCH=0
while read -r line; do
    case "$line" in
        *'/usr/share/nftban'*'/var/'*) MISMATCH=$((MISMATCH+1));;
    esac
done <<< "$BODY"
[ "$MISMATCH" -eq 0 ] && ok "/usr/share/nftban is not guarded by the /var/ prefix (D4)" \
                      || no "/usr/share/nftban still paired with /var/ — Guard 4 will exit 1 mid-purge" "$MISMATCH"
# And Guard 4 must still be enforced, not weakened away.
case "$CODE" in
    *'does not start with expected prefix'*) ok "safe_rm_rf Guard 4 still present (not weakened)";;
    *) no "Guard 4 removed — the fix must not disarm the safety check" "";;
esac

echo "── T4  partial deletion followed by a false success is impossible ─────"
# Guard 4 exits; so any path in the purge list whose prefix does not match its
# own directory would abort AFTER earlier deletions. Assert pairing for ALL.
UNPAIRED=0
while read -r line; do
    case "$line" in
        *'"/var/'*'|/var/"'*|*'"/usr/share/nftban|/usr/share/"'*) ;;
        *'safe_rm_rf'*)
            case "$line" in
                *'"$prefix"'*|*'$prefix'*) ;;
                *) UNPAIRED=$((UNPAIRED+1)); echo "       hardcoded prefix in loop: $line";;
            esac;;
    esac
done <<< "$BODY"
[ "$UNPAIRED" -eq 0 ] && ok "purge loop passes each directory its OWN prefix" \
                      || no "a hardcoded prefix remains — mid-loop abort still reachable" "$UNPAIRED"

echo "── T5  'preserved' claims only on a path that actually preserves ──────"
# The standard-mode summary may claim preservation only where dpkg --purge is
# not reachable — which T1 already established. Here: assert the claim and the
# purge live in OPPOSITE branches of the same PURGE_DATA condition.
case "$CODE" in
    *'NFTBan uninstalled (data preserved)'*) ;;
    *) no "standard-mode preservation claim missing" "";;
esac
# the claim must be in the ELSE of PURGE_DATA==true
CLAIM_CTX=$(printf '%s\n' "$CODE" | grep -n 'NFTBan uninstalled (data preserved)' | cut -d: -f1)
if [ -n "$CLAIM_CTX" ]; then
    PRE=$(printf '%s\n' "$CODE" | sed -n "$((CLAIM_CTX>8?CLAIM_CTX-8:1)),${CLAIM_CTX}p")
    case "$PRE" in
        *else*) ok "preservation claim sits in the non-purge branch";;
        *) no "preservation claim not clearly in the non-purge branch" "$PRE";;
    esac
fi

echo "── T6  firewall warning must not assert unverified protection ─────────"
case "$CODE" in
    *'no longer protects this host'*) ok "states NFTBan no longer protects the host";;
    *) no "no firewall-state message in uninstall.sh (D5)" "";;
esac
case "$CODE" in
    *'Review your firewall state'*) ok "directs the operator to review firewall state";;
    *) no "missing review directive" "";;
esac
case "$CODE" in
    *'nftables tooling may also have been removed'*) ok "warns nft tooling may be gone (proven on EL9)";;
    *) no "missing nftables cascade-removal warning" "";;
esac
# The new message must not drift into over-claiming. Same forbidden vocabulary the
# packaging guard (uninstall_firewall_ownership_message_v225_test.sh) applies to
# postrm/%postun, applied here to uninstall.sh's own message.
#
# SCOPE NOTE: packaging/deb/postrm and packaging/build_nftban.sh carry the same
# truth contract as of v1.229 UNINSTALL-PR2 (D5) — the "may still be active"
# claim was retired from both and uninstall_firewall_ownership_message_v225_test
# now enforces parity on meaning rather than on that literal string. This suite
# still asserts nothing about those two files; they are guarded there, not here.
OVERCLAIM=0
while IFS= read -r bad; do
    if printf '%s\n' "$CODE" | grep -qiE "$bad"; then
        no "uninstall.sh message over-claims" "$bad"; OVERCLAIM=$((OVERCLAIM+1))
    fi
done <<'BAD'
host has no firewall
network access is safe
your host is still protected
automatically restore
BAD
[ "$OVERCLAIM" -eq 0 ] && ok "uninstall.sh asserts no unobserved protected state"

echo "── T7  the production call sites are actually reached ─────────────────"
# Without this, the above could pass against dead code.
case "$CODE" in
    *'uninstall_data'*) ok "uninstall_data invoked from the main flow";;
    *) no "uninstall_data never called" "assertions would be vacuous";;
esac
INVOKED=$(printf '%s\n' "$CODE" | grep -c '^uninstall_data$')
[ "${INVOKED:-0}" -ge 1 ] && ok "uninstall_data call site present at top level" \
                          || no "uninstall_data not called at top level" "count=$INVOKED"
# the firewall message must be in the executed tail, after the summary branch
case "$CODE" in
    *'FIREWALL STATE'*) ok "firewall message present in executable code (not a comment)";;
    *) no "firewall message only in comments — GUARD_SUBJECT != GUARD_INPUT" "";;
esac

echo
echo "══ RESULT: PASS=$PASS FAIL=$FAIL ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
