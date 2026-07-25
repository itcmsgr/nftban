#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="package_postinstall_verify_test"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Package-level T8 + DEB/RPM parity for the post-install verification gate. Extracts the REAL Item 2 block from packaging/deb/postinst and the generated RPM %post and runs it against a lock-contention installer stub. Tier 1/2 need no toolchain; tier 3 asserts the real verifier's verdict and needs NFTBAN_INSTALLER_BIN."
# meta:inventory.files="packaging/deb/postinst, packaging/build_nftban.sh"
# meta:inventory.binaries="bash, sh, sed, awk, grep, date, mktemp"
# meta:inventory.env_vars="NFTBAN_INSTALLER_BIN, NFTBAN_REQUIRE_REAL"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
#
# WHY THIS EXISTS
#
# The unit fixtures (internal/installer/postinstall) prove the VERIFIER is
# correct. They cannot prove the thing the defect is actually about: that the
# package scriptlet boundary now tells the truth. apt/dnf report success when
# the payload unpacks, and the original defect is that a firewall-less host was
# indistinguishable from a healthy one at exactly that boundary.
#
# So this extracts the REAL block from the REAL packaging files, never a
# transcription. A copied approximation would keep passing while the shipped
# scriptlet drifted away from it.
#
# THREE TIERS, because the dev box carries source only and the packages are
# built on lab2 (DEB) and lab4 (RPM):
#
#   1 STATIC        the shipped text's structural contract          no toolchain
#   2 CONTROL-FLOW  the block survives its interpreter and emits    no toolchain
#                   tokens when the installer fails (stubbed verifier
#                   — proves plumbing, NOT the verdict)
#   3 REAL T8       the real verifier's verdict over a same-version   needs the
#                   stale COMMITTED state                            built binary
#
# Tier 3 SKIPS when no binary is given, and says so loudly. Set
# NFTBAN_REQUIRE_REAL=1 (lab2/lab4, CI) to turn that skip into a failure, so a
# green run can never be mistaken for package-level proof.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "$ROOT"

PASS=0; FAIL=0; SKIP=0
ok(){   echo "[PASS] $1"; PASS=$((PASS+1)); }
bad(){  echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
skip(){ echo "[SKIP] $1"; SKIP=$((SKIP+1)); }

WORK="$(mktemp -d)"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

REQUIRE_REAL="${NFTBAN_REQUIRE_REAL:-0}"
BIN="${NFTBAN_INSTALLER_BIN:-}"

# =============================================================================
# extract the REAL Item 2 blocks
# =============================================================================
# DEB: verbatim between the markers.
awk '/# --- v1\.228\.0 Item 2: post-install outcome truth/,/# --- end Item 2/' \
    packaging/deb/postinst | sed 's/^[[:space:]]*//' > "$WORK/deb_block.sh"

# RPM: the same markers inside the generated %post, with the spec heredoc's
# escaping removed (\$ -> $) so it runs as the shell it becomes on the target.
awk '/# --- v1\.228\.0 Item 2: post-install outcome truth/,/# --- end Item 2/' \
    packaging/build_nftban.sh | sed 's/^[[:space:]]*//; s/\\\$/$/g' > "$WORK/rpm_block.sh"

FAMILIES=(deb rpm)
extract_ok=1
for f in "${FAMILIES[@]}"; do
    if [[ ! -s "$WORK/${f}_block.sh" ]]; then
        bad "extract: ${f} Item 2 block is empty — markers moved or the plumbing was removed"
        extract_ok=0
    elif ! grep -q -- '--verify-install-state' "$WORK/${f}_block.sh"; then
        bad "extract: ${f} block does not invoke --verify-install-state"
        extract_ok=0
    else
        ok "extract: ${f} Item 2 block found and invokes the verifier"
    fi
done
if [[ "$extract_ok" -ne 1 ]]; then
    echo "----------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    echo "RESULT: EXTRACTION FAILED — nothing downstream could be asserted"
    exit 1
fi

# leftover escaping would silently change what the RPM block executes
if grep -q '\\\$' "$WORK/rpm_block.sh"; then
    bad "extract: rpm block still carries spec escaping (\\\$) after unescaping"
else
    ok "extract: rpm block unescapes cleanly to executable shell"
fi

# =============================================================================
# TIER 1 — static contract of the shipped text
# =============================================================================
echo "=== tier 1: static contract ==="

# The three structural predicates are defined ONCE and used twice: to assert the
# shipped blocks, and — at the end of this tier — to assert that a deliberately
# broken block makes each of them fail. A predicate that cannot fail is not a
# check, and this suite has already shipped one of those.

# 1a. The mutating installer's exit must be captured in a CONDITION context.
#     A bare call followed by INSTALLER_EXIT=$? aborts under an errexit
#     interpreter before the verifier runs — which removes the gate in exactly
#     the failing transaction it exists for. DEB sets its own flags
#     (set -Eeuo pipefail); RPM's are supplied by rpm and are not ours to
#     assume, so both must use the safe form.
pred_errexit_safe() { # file family
    grep -Eq '^"\$NFTBAN_INSTALLER" --'"$2"' --mode="\$INSTALL_MODE" \|\| INSTALLER_EXIT=\$\?' "$1"
}

# 1b. The verifier must be invoked UNCONDITIONALLY. Guarding it on installer
#     failure misses a stale COMMITTED after exit 75; guarding it on success
#     misses the case the gate exists for.
pred_unconditional() { # file family
    local mut ver
    mut="$(grep -n -- "--${2} --mode=" "$1" | head -1 | cut -d: -f1)"
    ver="$(grep -n -- '--verify-install-state' "$1" | head -1 | cut -d: -f1)"
    [[ -n "$mut" && -n "$ver" && "$ver" -gt "$mut" ]] || return 1
    ! sed -n "$((mut+1)),$((ver))p" "$1" | grep -Eq '^(if|case|while|until) |&&'
}

# 1c. The verification invocation must be family-independent. The family flag
#     belongs to the mutating call only; a --deb/--rpm on the verify call would
#     mean two divergent verification contracts.
pred_family_independent() { # file _family
    local ver
    ver="$(grep -n -- '--verify-install-state' "$1" | head -1 | cut -d: -f1)"
    [[ -n "$ver" ]] || return 1
    # the invocation spans the backslash continuations that follow it
    ! sed -n "$((ver-1)),$((ver+5))p" "$1" | grep -Eq -- '--(deb|rpm)\b'
}

for f in "${FAMILIES[@]}"; do
    b="$WORK/${f}_block.sh"
    pred_errexit_safe "$b" "$f" \
        && ok  "static/${f}: mutating installer exit captured errexit-safely (|| INSTALLER_EXIT=\$?)" \
        || bad "static/${f}: mutating call is not errexit-safe — under 'sh -e' the scriptlet aborts before the verifier"
    pred_unconditional "$b" "$f" \
        && ok  "static/${f}: verifier invoked unconditionally after the installer" \
        || bad "static/${f}: verifier is reached through a conditional — it must run after EVERY installer outcome"
    pred_family_independent "$b" "$f" \
        && ok  "static/${f}: verification invocation is family-independent" \
        || bad "static/${f}: a family flag leaked into the VERIFICATION invocation"
done

# 1d. Both families must emit the same package-context keys in the same order.
pkg_keys(){ grep -oE 'NFTBAN_PACKAGE_[A-Z_]+=' "$1" | sed 's/=$//' | awk '!seen[$0]++'; }
if diff -u <(pkg_keys "$WORK/deb_block.sh") <(pkg_keys "$WORK/rpm_block.sh") > "$WORK/keydiff" 2>&1; then
    ok "static/parity: DEB and RPM emit identical package-context keys in identical order"
else
    bad "static/parity: package-context keys differ between DEB and RPM"
    sed 's/^/    /' "$WORK/keydiff"
fi

# 1e. The scriptlet must not duplicate the installer's state vocabulary. The
#     eight canonical tokens are the installer's to emit; a shell copy is a
#     second authority that drifts.
for f in "${FAMILIES[@]}"; do
    if grep -Eq 'echo "NFTBAN_(PERSISTED|EXPECTED|NOT_BEFORE|INSTALL_ATTEMPT|INSTALL_VERIFIED)' "$WORK/${f}_block.sh"; then
        bad "static/${f}: scriptlet re-emits a canonical installer token — duplicate authority"
    else
        ok "static/${f}: scriptlet emits execution context only, never the installer's state tokens"
    fi
done

# 1f. NEGATIVE CONTROLS. Each predicate is run against a block mutated to
#     reintroduce exactly the defect it exists to catch. If a mutant still
#     passes, the corresponding assertion above is decorative.
mutate(){ sed "$1" "$WORK/deb_block.sh" > "$WORK/mutant.sh"; }

# revert the errexit-safe capture to the bare-call form
mutate 's#^"\$NFTBAN_INSTALLER" --deb --mode="\$INSTALL_MODE" || INSTALLER_EXIT=\$?#"$NFTBAN_INSTALLER" --deb --mode="$INSTALL_MODE"\nINSTALLER_EXIT=$?#'
pred_errexit_safe "$WORK/mutant.sh" deb \
    && bad "negative-control: bare-call mutant PASSED the errexit-safety check — the check is decorative" \
    || ok  "negative-control: bare-call mutant correctly fails the errexit-safety check"

# guard the verifier behind the installer's success
mutate 's#^NFTBAN_PKG_VERSION=#if [ "${INSTALLER_EXIT}" -eq 0 ]; then\nNFTBAN_PKG_VERSION=#'
pred_unconditional "$WORK/mutant.sh" deb \
    && bad "negative-control: conditional-verifier mutant PASSED the unconditional check — the check is decorative" \
    || ok  "negative-control: conditional-verifier mutant correctly fails the unconditional check"

# leak a family flag into the verification invocation
mutate 's#^--verify-install-state#--verify-install-state --deb#'
pred_family_independent "$WORK/mutant.sh" deb \
    && bad "negative-control: family-flag mutant PASSED the family-independence check — the check is decorative" \
    || ok  "negative-control: family-flag mutant correctly fails the family-independence check"

# =============================================================================
# TIER 2 — control flow under the interpreters the block actually meets
# =============================================================================
# The stub stands in for BOTH invocations: the mutating one exits 75 having
# written nothing (lock contention — a transaction that never began), and the
# verification one prints the canonical token set for a STALE_STATE verdict and
# exits 2. This proves the plumbing survives and the tokens reach stdout. It
# does NOT prove the verdict — that is tier 3, and only tier 3.
echo "=== tier 2: control flow (stubbed verifier — plumbing only) ==="

STUB_FAKE="$WORK/installer-stub-fake"
cat >"$STUB_FAKE" <<'STUBEOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "--verify-install-state" ]; then
        echo "NFTBAN_PERSISTED_INSTALL_STATE=COMMITTED"
        echo "NFTBAN_PERSISTED_STATE_VERSION=1.228.0"
        echo "NFTBAN_PERSISTED_STATE_TIMESTAMP=2026-07-25T00:00:00Z"
        echo "NFTBAN_EXPECTED_VERSION=1.228.0"
        echo "NFTBAN_NOT_BEFORE=2026-07-25T01:00:00Z"
        echo "NFTBAN_INSTALL_ATTEMPT_VERDICT=STALE_STATE"
        echo "NFTBAN_INSTALL_VERIFIED=NO"
        echo "NFTBAN_INSTALLER_EXIT=-1"
        exit 2
    fi
done
echo "ERROR: another nftban-installer holds the lock" >&2
exit 75
STUBEOF
chmod +x "$STUB_FAKE"

# Interpreters: DEB's own declared flags, plus both readings of the RPM
# scriptlet interpreter (rpm supplies the flags; we do not assume which).
run_block() {
    local block="$1" interp="$2" stub="$3" vdir="$4" sdir="$5" out="$6"
    local run="${block%.sh}_run.sh"
    # Redirect the block's absolute paths into the fixture WITHOUT editing the
    # logic: the text under test stays the text that ships.
    sed -e "s#/usr/lib/nftban/VERSION#${vdir}/VERSION#" \
        -e "s#/var/lib/nftban/state#${sdir}#" "$block" > "$run"
    local rc=0
    env NFTBAN_INSTALLER="$stub" INSTALL_MODE=install \
        $interp "$run" >"$out" 2>&1 || rc=$?
    echo "$rc"
}

declare -A INTERP=( [deb]="bash -Eeuo pipefail" [rpm]="sh -e" )
mkdir -p "$WORK/t2_v" "$WORK/t2_s"; echo "1.228.0" > "$WORK/t2_v/VERSION"

for f in "${FAMILIES[@]}"; do
    interps=("${INTERP[$f]}")
    [[ "$f" == "rpm" ]] && interps+=("sh")   # rpm's flags are not ours to assume
    for it in "${interps[@]}"; do
        out="$WORK/t2_${f}_$(tr -d ' -' <<<"$it").txt"
        rc="$(run_block "$WORK/${f}_block.sh" "$it" "$STUB_FAKE" "$WORK/t2_v" "$WORK/t2_s" "$out")"
        label="control-flow/${f} under '${it}'"
        if [[ "$rc" != "0" ]]; then
            bad "$label: block aborted rc=$rc — the verifier's output never reached the boundary"
            sed 's/^/    /' "$out" | tail -5
            continue
        fi
        missing=""
        for k in NFTBAN_PACKAGE_INSTALLER_EXIT NFTBAN_PACKAGE_VERIFY_EXIT \
                 NFTBAN_PACKAGE_POSTINSTALL_VERIFIED NFTBAN_INSTALL_ATTEMPT_VERDICT; do
            grep -q "^${k}=" "$out" || missing="$missing $k"
        done
        if [[ -n "$missing" ]]; then
            bad "$label: tokens missing:$missing"
        elif [[ "$(grep -m1 '^NFTBAN_PACKAGE_INSTALLER_EXIT=' "$out" | cut -d= -f2)" != "75" ]]; then
            bad "$label: installer exit not propagated as 75"
        elif [[ "$(grep -m1 '^NFTBAN_PACKAGE_POSTINSTALL_VERIFIED=' "$out" | cut -d= -f2)" != "NO" ]]; then
            bad "$label: VERIFIED must be NO when the verifier exits non-zero"
        else
            ok "$label: survives, propagates installer exit 75, reports VERIFIED=NO"
        fi
    done
done

# 2b. NEGATIVE CONTROL. VERIFIED=NO must be derived from the verifier's exit,
#     not printed unconditionally. With a verifier that exits 0 the same block
#     must say YES — otherwise the tier-2 assertions above would pass against a
#     hardcoded string.
STUB_OK="$WORK/installer-stub-ok"
sed 's/^        exit 2$/        exit 0/; s/^exit 75$/exit 0/' "$STUB_FAKE" > "$STUB_OK"
chmod +x "$STUB_OK"
out="$WORK/t2_control_yes.txt"
rc="$(run_block "$WORK/deb_block.sh" "${INTERP[deb]}" "$STUB_OK" "$WORK/t2_v" "$WORK/t2_s" "$out")"
got="$(grep -m1 '^NFTBAN_PACKAGE_POSTINSTALL_VERIFIED=' "$out" | cut -d= -f2- || true)"
if [[ "$rc" == "0" && "$got" == "YES" ]]; then
    ok "negative-control: VERIFIED tracks the verifier's exit (0 -> YES), not a hardcoded NO"
else
    bad "negative-control: verifier exit 0 gave VERIFIED=${got:-<absent>} rc=$rc — VERIFIED is not derived from the verifier"
fi

# 2c. NEGATIVE CONTROL, and the empirical basis for check 1a. Whether rpm runs
#     scriptlets with -e is rpm's business, not ours; what IS measurable here is
#     that under an errexit interpreter the bare-call-then-$? form loses the
#     entire token set. This runs that mutant and proves the loss, so 1a rests
#     on a measurement rather than on a belief about the interpreter.
mutate 's#^"\$NFTBAN_INSTALLER" --deb --mode="\$INSTALL_MODE" || INSTALLER_EXIT=\$?#"$NFTBAN_INSTALLER" --deb --mode="$INSTALL_MODE"\nINSTALLER_EXIT=$?#'
cp "$WORK/mutant.sh" "$WORK/bare_mutant.sh"
out="$WORK/t2_bare_mutant.txt"
rc="$(run_block "$WORK/bare_mutant.sh" "sh -e" "$STUB_FAKE" "$WORK/t2_v" "$WORK/t2_s" "$out")"
if [[ "$rc" != "0" ]] && ! grep -q '^NFTBAN_PACKAGE_' "$out"; then
    ok "negative-control: bare-call mutant under 'sh -e' aborts (rc=$rc) and emits NO tokens — 1a is load-bearing"
else
    bad "negative-control: bare-call mutant under 'sh -e' survived (rc=$rc) — check 1a rests on an unmeasured assumption"
fi

# =============================================================================
# TIER 3 — package-level T8 against the REAL verifier
# =============================================================================
# T8: a SAME-VERSION prior COMMITTED state, stale, under a mutating installer
# that exits 75 without writing. The package must report STALE_STATE while the
# scriptlet itself still exits 0 — apt/dnf keep succeeding, the tokens carry the
# truth. Same version is mandatory: with a differing version this passes on
# VERSION_MISMATCH and proves nothing about freshness.
echo "=== tier 3: package-level T8 (real verifier) ==="

if [[ -z "$BIN" ]]; then
    if [[ "$REQUIRE_REAL" == "1" ]]; then
        bad "T8: NFTBAN_INSTALLER_BIN unset and NFTBAN_REQUIRE_REAL=1 — package-level T8 must run here"
    else
        skip "T8: no verifier binary (set NFTBAN_INSTALLER_BIN=/path/to/nftban-installer on lab2/lab4)"
        skip "T8: DEB/RPM verdict parity — depends on T8"
    fi
elif [[ ! -x "$BIN" ]]; then
    bad "T8: NFTBAN_INSTALLER_BIN=$BIN is not executable"
else
    STUB_REAL="$WORK/installer-stub-real"
    cat >"$STUB_REAL" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "--verify-install-state" ]; then
        exec "$BIN" "\$@"
    fi
done
echo "ERROR: another nftban-installer holds the lock" >&2
exit 75
STUBEOF
    chmod +x "$STUB_REAL"

    STALE_TS="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"

    for f in "${FAMILIES[@]}"; do
        vd="$WORK/t3_${f}_v"; sd="$WORK/t3_${f}_s"
        rm -rf "$vd" "$sd"; mkdir -p "$vd" "$sd"
        echo "1.228.0" > "$vd/VERSION"
        {
            echo "INSTALL_STATE=COMMITTED"
            echo "INSTALL_VERSION=1.228.0"
            echo "INSTALL_TIMESTAMP=${STALE_TS}"
        } > "$sd/install_state"

        out="$WORK/t3_${f}.txt"
        rc="$(run_block "$WORK/${f}_block.sh" "${INTERP[$f]}" "$STUB_REAL" "$vd" "$sd" "$out")"
        label="T8/${f}"

        if [[ "$rc" == "0" ]]; then
            ok "$label: scriptlet exits 0 — the package transaction still succeeds"
        else
            bad "$label: scriptlet rc=$rc (want 0)"
        fi

        for wp in "NFTBAN_PACKAGE_INSTALLER_EXIT=75" \
                  "NFTBAN_PACKAGE_VERIFY_EXIT=2" \
                  "NFTBAN_PACKAGE_POSTINSTALL_VERIFIED=NO" \
                  "NFTBAN_INSTALL_ATTEMPT_VERDICT=STALE_STATE" \
                  "NFTBAN_INSTALL_VERIFIED=NO"; do
            k="${wp%%=*}"; want="${wp#*=}"
            got="$(grep -m1 "^${k}=" "$out" | cut -d= -f2- || true)"
            if [[ "$got" == "$want" ]]; then ok "$label: $k=$want"
            else bad "$label: $k=${got:-<absent>} (want $want)"; fi
        done

        # The verifier must not claim to know the installer's exit. It is
        # invoked without one and prints the -1 sentinel; the authoritative
        # value is the package's own NFTBAN_PACKAGE_INSTALLER_EXIT.
        got="$(grep -m1 '^NFTBAN_INSTALLER_EXIT=' "$out" | cut -d= -f2- || true)"
        if [[ "$got" == "-1" ]]; then
            ok "$label: verifier reports the -1 not-supplied sentinel, not a fabricated 0"
        else
            bad "$label: NFTBAN_INSTALLER_EXIT=${got:-<absent>} (want -1 sentinel)"
        fi

        # If the precondition decayed, the assertions above stop being a
        # freshness test even while they pass.
        ps="$(grep -m1 '^NFTBAN_PERSISTED_INSTALL_STATE=' "$out" | cut -d= -f2- || true)"
        pv="$(grep -m1 '^NFTBAN_PERSISTED_STATE_VERSION=' "$out" | cut -d= -f2- || true)"
        if [[ "$ps" == "COMMITTED" && "$pv" == "1.228.0" ]]; then
            ok "$label: precondition intact — SAME-VERSION prior COMMITTED"
        else
            bad "$label: precondition broken — state=${ps:-?} version=${pv:-?}; not a freshness test"
        fi
    done

    # semantic parity: identical verdict fields from both families
    parity_fail=0
    for k in NFTBAN_PACKAGE_VERIFY_EXIT NFTBAN_PACKAGE_POSTINSTALL_VERIFIED \
             NFTBAN_PERSISTED_INSTALL_STATE NFTBAN_PERSISTED_STATE_VERSION \
             NFTBAN_EXPECTED_VERSION NFTBAN_INSTALL_ATTEMPT_VERDICT NFTBAN_INSTALL_VERIFIED; do
        d="$(grep -m1 "^${k}=" "$WORK/t3_deb.txt" | cut -d= -f2- || true)"
        r="$(grep -m1 "^${k}=" "$WORK/t3_rpm.txt" | cut -d= -f2- || true)"
        if [[ -z "$d$r" ]]; then bad "parity: $k absent from both families"; parity_fail=1
        elif [[ "$d" != "$r" ]]; then bad "parity: $k deb=$d rpm=$r"; parity_fail=1; fi
    done
    [[ "$parity_fail" -eq 0 ]] && ok "parity: verdict fields identical across DEB and RPM"
fi

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ "$FAIL" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
if [[ "$SKIP" -ne 0 ]]; then
    echo "RESULT: STATIC_AND_CONTROL_FLOW_ONLY — package-level T8 did NOT run."
    echo "        Run on lab2/lab4 with NFTBAN_INSTALLER_BIN set and NFTBAN_REQUIRE_REAL=1."
    exit 0
fi
echo "RESULT: PASS (package-level T8 executed against the real verifier)"
exit 0
