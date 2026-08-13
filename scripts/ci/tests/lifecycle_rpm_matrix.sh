#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.228.0 Item 2 — RPM package-native lifecycle matrix (EL9).
# Runs AS ROOT on a DISPOSABLE, snapshot-backed AlmaLinux 9 VM. Destructive.
#   R1  fresh install        R2  same-version reinstall
#   R3  upgrade from the PUBLISHED prior rpm
#   R4  package-level T8 (lock contention over a same-version prior COMMITTED)
#   R7  erase               R8  reinstall after erase
#   R11 no-installer path, using the %post AS SHIPPED IN THE PACKAGE
# Any SKIP forces INCOMPLETE. A skipped case is never a pass.
# =============================================================================
set -Eeuo pipefail
CAND="${1:?usage: lifecycle_rpm_matrix.sh <candidate.rpm> <prior.rpm>}"
PRIOR="${2:-}"

# UNINSTALL-PR3 SCOPE SELECTION (mirrors the DEB matrix NFTBAN_LIFECYCLE_CASES).
# The REQUIRED closure gate proves package-native REMOVE/PURGE, which needs only
# the candidate. Upgrade arms need a PUBLISHED prior rpm; binding the merge
# decision to an external release download would make the gate fail for reasons
# unrelated to the change under test.
#
#   NOT_IN_SCOPE  = deliberately not selected for this run (declared, not hidden)
#   SKIP          = selected but could not run  -> INCOMPLETE, never a pass
#
# Those are DIFFERENT verdicts on purpose: silently dropping a case and being
# unable to run one must not look alike.
# ONE canonical case list: the default scope AND the scope validator below both
# derive from it, so a case added/renamed here cannot drift from either.
ALL_CASES="R1 R2 R3 R4 R7 R8 R11"
CASES="${NFTBAN_RPM_CASES:-$ALL_CASES}"
want() { [[ " $CASES " == *" $1 "* ]]; }
PKG=nftban-core
STATE_DIR=/var/lib/nftban/state
STATE="$STATE_DIR/install_state"
LOCK="$STATE_DIR/installer.lock"
W="$(mktemp -d)"; LOCK_PID=""
P=0; F=0; B=0; declare -A R
# Sentinel for "observation authority unavailable" (see A2 probes below).
BLOCKED_TOKEN="BLOCKED_ENVIRONMENT"
ok(){ echo "[PASS] ${CASE:-PRE}  $1"; P=$((P+1)); }
bad(){ echo "[FAIL] ${CASE:-PRE}  $1"; F=$((F+1)); R[$CASE]=FAIL; }
skip(){ echo "[SKIP] ${CASE:-PRE}  $1"; R[$CASE]=SKIP; }
hdr(){ CASE="$1"; R[$1]="${R[$1]:-PASS}"; printf '\n========== CASE %s: %s ==========\n' "$1" "$2"; }
# A3 (UNINSTALL-PR3): a BLOCKED_ENVIRONMENT observation entering the comparator
# must never compare as an ordinary string. It is neither a pass (nothing was
# observed) nor a product FAIL (the product was not the thing that failed).
blocked(){ echo "[BLOCKED] ${CASE:-PRE}  $1"; B=$((B+1)); R[$CASE]=BLOCKED_ENVIRONMENT; }
eq(){
    if [[ "$2" == "$BLOCKED_TOKEN" ]]; then
        blocked "$3 — observation authority unavailable (wanted '$1'); NOT a product verdict"
        return 0
    fi
    [[ "$2" == "$1" ]] && ok "$3 (= $1)" || bad "$3 — got '$2', want '$1'"
}
# LAYER A/B SPLIT (UNINSTALL-PR3). Scope selection is per-CASE, but VM-only
# assertions live INSIDE container-valid cases. In a container those would go
# BLOCKED_ENVIRONMENT and make every run permanently INCOMPLETE, which creates
# pressure to weaken them. Instead Layer A DECLARES them out of scope:
#   Layer A (container): NFTBAN_MATRIX_VM_ASSERTIONS=0 -> NOT_IN_SCOPE by design
#   Layer B (systemd VM): default 1 -> in scope; missing authority => BLOCKED
# Nothing is deleted or weakened — it is scoped, and the scope is printed.
VM_ASSERTIONS="${NFTBAN_MATRIX_VM_ASSERTIONS:-1}"
VMNS=0
eq_vm(){ # want got description   — VM-only (systemd / kernel nftables) assertion
    if [[ "$VM_ASSERTIONS" != "1" ]]; then
        echo "[NOT_IN_SCOPE] ${CASE:-PRE}  $3 — VM-only assertion; this environment cannot observe it"
        VMNS=$((VMNS+1)); return 0
    fi
    eq "$1" "$2" "$3"
}
tok(){ grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
sfield(){ [[ -f "$STATE" ]] && (grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-) || true; }
ver(){ rpm -q --qf '%{VERSION}' "$PKG" 2>/dev/null || true; }
installed(){ rpm -q "$PKG" >/dev/null 2>&1; }
# A2 (UNINSTALL-PR3) TRUTHFUL PROBES.
#   systemctl unavailable != inactive       nft unavailable != absent
# These previously collapsed MISSING OBSERVATION AUTHORITY into the negative
# security state. Removal cases assert `inactive`/`absent`, so in an environment
# with no systemd or no nft they PASSED having observed nothing. The sentinel
# below mirrors the DEB nft_table_state() 'nft-absent' template already in-repo.
#   OBSERVATION_FAILURE MUST NEVER BECOME SECURITY_STATE_EMPTY
unit_state(){
    command -v systemctl >/dev/null 2>&1 || { printf '%s' "$BLOCKED_TOKEN"; return 0; }
    local s; s="$(systemctl is-active "$1" 2>/dev/null | head -1 || true)"
    # An unreachable manager (no PID1 systemd) is NOT evidence a unit is stopped.
    if [[ -z "$s" ]]; then
        systemctl is-system-running >/dev/null 2>&1 || { printf '%s' "$BLOCKED_TOKEN"; return 0; }
        s=inactive
    fi
    printf '%s' "$s"
}
fw(){
    command -v nft >/dev/null 2>&1 || { printf '%s' "$BLOCKED_TOKEN"; return 0; }
    nft list table ip nftban >/dev/null 2>&1 && echo present || echo absent
}
release_lock(){ if [[ -n "$LOCK_PID" ]]; then kill -TERM -"$LOCK_PID" 2>/dev/null || kill -TERM "$LOCK_PID" 2>/dev/null || true
    wait "$LOCK_PID" 2>/dev/null || true; kill -KILL -"$LOCK_PID" 2>/dev/null || true; LOCK_PID=""
    if [[ -e "$LOCK" ]]; then for _ in $(seq 1 20); do flock -n -x "$LOCK" -c true 2>/dev/null && return 0; sleep 1; done
        echo "WARNING: $LOCK still held"; fi; fi; }
# A4 (UNINSTALL-PR3) DURABLE F4 CLOSURE. The trap was cleanup-only, so a mid-run
# `set -e` abort exited with the failing command's rc — 1 or 2 — and printed NO
# SUMMARY, making a harness crash indistinguishable from a legitimate FAIL or
# INCOMPLETE. Fixing the single stray `return 0` in R11 closed one instance, not
# the class. The harness must now PROVE it reached its verdict path.
VERDICT_EMITTED=0
cleanup(){
    local rc=$?
    release_lock; rm -rf "$W"
    if [[ "$VERDICT_EMITTED" -ne 1 ]]; then
        echo "NFTBAN_RPM_MATRIX_VERDICT=HARNESS_FAILURE"
        echo "NFTBAN_RPM_MATRIX_HARNESS_NOTE=aborted before emitting a verdict (rc=${rc}); this run proves NOTHING"
        exit 3
    fi
}
trap cleanup EXIT

erase_all(){ dnf -y remove "$PKG" >/dev/null 2>&1 || rpm -e --nodeps "$PKG" >/dev/null 2>&1 || true
    rm -rf /etc/nftban /var/lib/nftban /usr/lib/nftban /var/log/nftban /var/cache/nftban /run/nftban 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true; systemctl reset-failed >/dev/null 2>&1 || true; }
inst(){ local rpmf="$1" out="$2" rc=0; dnf -y install "$rpmf" >"$out" 2>&1 || rc=$?; echo "$rc"; }
reinst(){ local rpmf="$1" out="$2" rc=0; dnf -y reinstall "$rpmf" >"$out" 2>&1 || rc=$?; echo "$rc"; }
upg(){ local rpmf="$1" out="$2" rc=0; dnf -y upgrade "$rpmf" >"$out" 2>&1 || rc=$?; echo "$rc"; }

assert_healthy_install(){ # outfile expected_version
    local out="$1" want="$2"
    eq 0 "$(tok "$out" NFTBAN_PACKAGE_INSTALLER_EXIT)" "NFTBAN_PACKAGE_INSTALLER_EXIT"
    eq 0 "$(tok "$out" NFTBAN_PACKAGE_VERIFY_EXIT)"    "NFTBAN_PACKAGE_VERIFY_EXIT"
    eq YES "$(tok "$out" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" "POSTINSTALL_VERIFIED"
    eq CURRENT_COMMITTED "$(tok "$out" NFTBAN_INSTALL_ATTEMPT_VERDICT)" "verdict"
    eq YES "$(tok "$out" NFTBAN_INSTALL_VERIFIED)" "INSTALL_VERIFIED"
    eq COMMITTED "$(sfield INSTALL_STATE)" "persisted INSTALL_STATE"
    eq "$want" "$(sfield INSTALL_VERSION)" "persisted INSTALL_VERSION"
    eq "$want" "$(ver)" "rpm database version"
    eq_vm active "$(unit_state nftband.service)" "nftband.service"
    eq_vm active "$(unit_state nftban-maintenance.timer)" "critical timer"
    eq_vm present "$(fw)" "nftables table ip nftban"
    # A8: this probe was the one survivor of the BLOCKED_ENVIRONMENT conversion —
    # the three lines above use eq_vm, this used bare `eq`. Four traps stacked:
    # a missing systemctl yields empty output, 2>/dev/null hides the very failure
    # that is the subject, `grep -c` returns 0 for no-match which IS the pass
    # value, and it was not VM-scoped. In an environment without systemd it
    # PASSED having observed nothing, and counted into ASSERTIONS_PASS.
    local failed
    if ! command -v systemctl >/dev/null 2>&1; then
        failed="$BLOCKED_TOKEN"
    else
        failed="$(systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c nftban || true)"
        [[ -n "$failed" ]] || failed=0
    fi
    eq_vm 0 "${failed}" "failed NFTBan units"
}

CAND_VER="$(rpm -qp --qf '%{VERSION}' "$CAND" 2>/dev/null)"
PRIOR_VER=""
[[ -n "$PRIOR" ]] && PRIOR_VER="$(rpm -qp --qf '%{VERSION}' "$PRIOR" 2>/dev/null)"
echo "===== RPM lifecycle matrix ====="
echo "candidate : $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$CAND")"
[[ -n "$PRIOR" ]] && echo "prior     : $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$PRIOR")" \
              || echo "prior     : (none supplied — upgrade arms out of scope)"
echo "selinux   : $(getenforce 2>/dev/null || echo UNKNOWN)"
# These are ENVIRONMENT preconditions, not harness bugs: emit the canonical
# verdict so the EXIT trap does not reclassify them as HARNESS_FAILURE.
blocked_exit(){ # reason
    echo "NFTBAN_RPM_MATRIX_VERDICT=INCOMPLETE"
    echo "NFTBAN_RPM_MATRIX_INCOMPLETE_REASON=BLOCKED_ENVIRONMENT"
    echo "NFTBAN_RPM_MATRIX_BLOCKED_PRECONDITION=$1"
    VERDICT_EMITTED=1
    exit 2
}
[[ "$(id -u)" -eq 0 ]] || blocked_exit "must run as root"
# /var/lock is absent from some minimal container images, and the redirect then
# aborts the run under set -e BEFORE any verdict — correctly reported as
# HARNESS_FAILURE, but the harness should simply work. Fall back to a writable
# location rather than skipping the single-instance guard, which is load-bearing:
# two concurrent destructive runs mutate the same host and every assertion from
# both becomes void while still printing PASS.
NFTBAN_RPM_LOCK=/var/lock/nftban-rpm-matrix.lock
mkdir -p /var/lock 2>/dev/null || NFTBAN_RPM_LOCK="${TMPDIR:-/tmp}/nftban-rpm-matrix.lock"
exec 9>"$NFTBAN_RPM_LOCK" 2>/dev/null || {
    NFTBAN_RPM_LOCK="${TMPDIR:-/tmp}/nftban-rpm-matrix.lock"
    exec 9>"$NFTBAN_RPM_LOCK"
}
echo "lockfile  : $NFTBAN_RPM_LOCK"
flock -n 9 || blocked_exit "another RPM matrix run holds the lock"
eq nftban-core "$(rpm -qp --qf '%{NAME}' "$CAND")" "candidate package name"
# Only meaningful when a prior was supplied. With PRIOR empty this compared
# "$CAND_VER" against "" and emitted a PASS reading "differs from prior " —
# a green line asserting nothing.
if [[ -z "$PRIOR" ]]; then
    echo "[INFO] PRE   no prior rpm supplied — upgrade comparison not applicable"
elif [[ "$CAND_VER" != "$PRIOR_VER" ]]; then
    ok "candidate $CAND_VER differs from prior $PRIOR_VER"
else
    bad "candidate and prior are both $CAND_VER — R3 would not be an upgrade"
fi

# ---------------------------------------------------------------- R1
if want R1; then
hdr R1 "fresh install (ABSENT -> INSTALL)"
erase_all
installed && bad "precondition: package still installed" || ok "precondition: ABSENT"
o="$W/r1.txt"; rc="$(inst "$CAND" "$o")"
eq 0 "$rc" "dnf transaction rc"
assert_healthy_install "$o" "$CAND_VER"
else
  R[R1]="NOT_IN_SCOPE"
fi

# ---------------------------------------------------------------- R2
if want R2; then
hdr R2 "same-version reinstall ($CAND_VER -> $CAND_VER)"
if ! installed; then skip "R2 needs an installed package"; else
  t_before="$(sfield INSTALL_TIMESTAMP)"; start="$(date -u +%s)"
  o="$W/r2.txt"; rc="$(reinst "$CAND" "$o")"
  eq 0 "$rc" "dnf reinstall rc"
  assert_healthy_install "$o" "$CAND_VER"
  t_after="$(sfield INSTALL_TIMESTAMP)"
  e_after="$(date -u -d "$t_after" +%s 2>/dev/null || echo 0)"
  if [[ "$t_after" != "$t_before" && "$e_after" -ge $((start-1)) ]]; then
      ok "state timestamp advanced into this transaction ($t_after)"
  else
      bad "state timestamp did not advance: before=$t_before after=$t_after"
  fi
fi
else
  R[R2]="NOT_IN_SCOPE"
fi

# ---------------------------------------------------------------- R3
if want R3; then
hdr R3 "upgrade (published $PRIOR_VER -> candidate $CAND_VER)"
erase_all
o="$W/r3_prior.txt"; rc="$(inst "$PRIOR" "$o")"
if [[ "$rc" -ne 0 ]] || ! installed; then skip "could not install the published prior rpm (rc=$rc)"; else
  eq "$PRIOR_VER" "$(ver)" "prior installed"
  o="$W/r3_upg.txt"; rc="$(upg "$CAND" "$o")"
  eq 0 "$rc" "dnf upgrade rc"
  eq "$CAND_VER" "$(ver)" "rpm database advanced to candidate"
  assert_healthy_install "$o" "$CAND_VER"
fi
else
  R[R3]="NOT_IN_SCOPE"
fi

# ---------------------------------------------------------------- R4  (T8)
if want R4; then
hdr R4 "package-level T8 — lock contention over a same-version prior COMMITTED"
if [[ "$(sfield INSTALL_STATE)" != "COMMITTED" || "$(sfield INSTALL_VERSION)" != "$CAND_VER" ]]; then
  skip "no SAME-VERSION prior COMMITTED (state=$(sfield INSTALL_STATE) version=$(sfield INSTALL_VERSION))"
else
  t_before="$(sfield INSTALL_TIMESTAMP)"
  ok "precondition: SAME-VERSION prior COMMITTED at $t_before"
  mkdir -p "$STATE_DIR"
  setsid bash -c 'flock -x 9; sleep 900' 9>"$LOCK" & LOCK_PID=$!
  sleep 2
  if ! kill -0 "$LOCK_PID" 2>/dev/null; then skip "could not hold $LOCK"; else
    ok "controlled injection: exclusive flock held on $LOCK"
    o="$W/r4.txt"; rc="$(reinst "$CAND" "$o")"
    release_lock
    eq 0 "$rc" "dnf reports success (mechanical completion)"
    eq 75 "$(tok "$o" NFTBAN_PACKAGE_INSTALLER_EXIT)" "NFTBAN_PACKAGE_INSTALLER_EXIT"
    eq 2  "$(tok "$o" NFTBAN_PACKAGE_VERIFY_EXIT)"    "NFTBAN_PACKAGE_VERIFY_EXIT"
    eq NO "$(tok "$o" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" "POSTINSTALL_VERIFIED"
    eq STALE_STATE "$(tok "$o" NFTBAN_INSTALL_ATTEMPT_VERDICT)" "verdict"
    eq NO "$(tok "$o" NFTBAN_INSTALL_VERIFIED)" "INSTALL_VERIFIED"
    eq COMMITTED "$(tok "$o" NFTBAN_PERSISTED_INSTALL_STATE)" "persisted state still historical"
    eq "$t_before" "$(sfield INSTALL_TIMESTAMP)" "install_state untouched by a transaction that never began"
  fi
fi
else
  R[R4]="NOT_IN_SCOPE"
fi

# ---------------------------------------------------------------- R7
if want R7; then
hdr R7 "erase"
if ! installed; then
  erase_all; o="$W/r7_pre.txt"; inst "$CAND" "$o" >/dev/null
fi
if ! installed; then skip "R7 needs an installed package"; else
  o="$W/r7.txt"; rc=0; dnf -y remove "$PKG" >"$o" 2>&1 || rc=$?
  eq 0 "$rc" "dnf remove rc"
  installed && bad "package still in the rpm database after erase" || ok "package removed from the rpm database"
  eq_vm inactive "$(unit_state nftband.service)" "nftband.service after erase"
  eq_vm inactive "$(unit_state nftban-maintenance.timer)" "critical timer after erase"
  # Item 2 must not leak install-verification tokens into a removal.
  if grep -qE 'NFTBAN_(PACKAGE_POSTINSTALL_VERIFIED|INSTALL_ATTEMPT_VERDICT|PACKAGE_INSTALLER_EXIT)=' "$o"; then
      bad "removal emitted install-verification tokens — a removal is not an install outcome"
  else
      ok "removal emitted no install-verification tokens"
  fi
  if grep -qE 'CURRENT_COMMITTED' "$o"; then
      bad "removal output claims CURRENT_COMMITTED"
  else
      ok "removal makes no CURRENT_COMMITTED claim"
  fi

  # ---- D1 (UNINSTALL-PR2) PACKAGE-NATIVE PROOF -----------------------------
  # `dnf remove` IS the $1 -eq 0 path (rpm has no purge verb), so this is the
  # STANDARD remove. It must preserve operator state, matching DEB `remove)`.
  # Until PR3 wired this matrix into CI, D1 was only SOURCE_PROVEN.
  for _d in /etc/nftban /var/lib/nftban /var/log/nftban; do
      [[ -d "$_d" ]] && ok "D1: $_d PRESERVED by standard remove" \
                     || bad "D1: $_d DESTROYED by standard remove — remove is not purge"
  done

  # ---- D3 PACKAGE-NATIVE PROOF: preserved must also be LOADER-VISIBLE ------
  # BYTES_PRESERVED != FUNCTIONAL_STATE_PRESERVED. Every loader globs
  # whitelist.d/*.conf, so a file rpm renamed to .rpmsave is present but dead.
  for _l in whitelist blacklist; do
      _f="/etc/nftban/${_l}.d/99-manual.conf"
      if [[ -f "$_f" ]]; then
          ok "D3: ${_l}.d/99-manual.conf survives erase under its LOADED name"
      else
          # `|| true` is load-bearing: find exits non-zero when the directory is
          # absent, and under `set -Eeuo pipefail` the ASSIGNMENT inherits that
          # status and aborts the whole matrix mid-case — reported (correctly) as
          # HARNESS_FAILURE, but the arm never runs. A missing directory is a
          # legitimate observation here, not a harness error.
          _side="$(find "/etc/nftban/${_l}.d" -maxdepth 1 -name '99-manual.conf.*' 2>/dev/null | head -1 || true)"
          if [[ -n "$_side" ]]; then
              bad "D3: operator config survives only as ${_side} — present but INVISIBLE to the *.conf loader"
          else
              bad "D3: ${_l}.d/99-manual.conf absent after erase"
          fi
      fi
  done
  # No package-manager sidecar may be produced for operator state at all.
  # SCOPE OF THIS ASSERTION. D3's contract is that OPERATOR STATE must not be
  # package-owned. It does NOT forbid rpm's normal handling of genuinely
  # package-owned config: /etc/nftban/nftables.conf is %config(noreplace)
  # (build_nftban.sh) — a rendered template the package replaces on reinstall —
  # so a .rpmsave for it on erase is CORRECT rpm behaviour, not a D3 violation.
  # A blanket "no .rpmsave anywhere" arm asserted something D3 never claimed and
  # failed on standard packaging semantics. Narrowed to the operator-state dirs,
  # where a sidecar WOULD prove the package owns operator state.
  _opsides="$(find /etc/nftban/whitelist.d /etc/nftban/blacklist.d \
                   \( -name '*.rpmsave' -o -name '*.rpmnew' \) 2>/dev/null | head -5 || true)"
  [[ -z "$_opsides" ]] && ok "D3: no .rpmsave/.rpmnew in the operator-state dirs (whitelist.d/blacklist.d)" \
                       || bad "D3: package manager still owns OPERATOR state — sidecars: ${_opsides//$'\n'/ }"
  # Package-owned config sidecars are reported, never failed: visibility without
  # a false verdict.
  _pkgsides="$(find /etc/nftban -maxdepth 1 \( -name '*.rpmsave' -o -name '*.rpmnew' \) 2>/dev/null | head -5 || true)"
  [[ -n "$_pkgsides" ]] && echo "[INFO] $CASE  package-owned config sidecars (expected rpm semantics): ${_pkgsides//$'\n'/ }"

  # ---- D5 PACKAGE-NATIVE PROOF: disclosure, and no unobserved claim --------
  grep -qF 'no longer protects this host' "$o" \
      && ok "D5: removal states NFTBan no longer protects this host" \
      || bad "D5: removal did not disclose loss of protection"
  grep -qF 'were NOT modified and may still be active' "$o" \
      && bad "D5: removal asserts an UNOBSERVED other-firewall state" \
      || ok "D5: removal makes no unobserved other-firewall claim"
fi
else
  R[R7]="NOT_IN_SCOPE"
fi

# ---------------------------------------------------------------- R8
if want R8; then
hdr R8 "reinstall after erase"
if installed; then skip "R8 needs the package erased first"; else
  before_state="$(sfield INSTALL_STATE)"; before_ts="$(sfield INSTALL_TIMESTAMP)"
  [[ -n "$before_state" ]] && echo "[INFO] R8  residual state survived erase: $before_state @ $before_ts"
  start="$(date -u +%s)"
  o="$W/r8.txt"; rc="$(inst "$CAND" "$o")"
  eq 0 "$rc" "dnf install rc"
  assert_healthy_install "$o" "$CAND_VER"
  t_after="$(sfield INSTALL_TIMESTAMP)"
  e_after="$(date -u -d "$t_after" +%s 2>/dev/null || echo 0)"
  if [[ "$e_after" -ge $((start-1)) ]]; then
      ok "new transaction timestamp — residual state did not answer for this install"
  else
      bad "state timestamp $t_after predates this transaction — stale state reused"
  fi
fi
else
  R[R8]="NOT_IN_SCOPE"
fi

# ---------------------------------------------------------------- R11
if want R11; then
hdr R11 "no-installer path — %post AS SHIPPED, installer missing"
scr="$W/post.sh"
rpm -qp --scripts "$CAND" 2>/dev/null | awk '/^postinstall scriptlet/{f=1;next} /^post(un|trans)/{f=0} f' > "$scr" || true
if [[ ! -s "$scr" ]]; then skip "could not extract %post from the package"; else
  ok "extracted %post as shipped in the package ($(wc -l <"$scr") lines)"
  # The scriptlet HARDCODES NFTBAN_INSTALLER (build_nftban.sh:1107), so an
  # environment override does nothing -- the first attempt silently ran the REAL
  # installer and "passed" for entirely the wrong reason. Rewrite the assignment
  # in the extracted text instead, exactly as the DEB harness rewrites paths.
  sed -i 's#^NFTBAN_INSTALLER=.*#NFTBAN_INSTALLER="/nonexistent/nftban-installer"#' "$scr"
  # F4 (UNINSTALL-PR3): this branch used to `return 0` at TOP LEVEL. bash rejects
  # that outside a function ("can only 'return' from a function or sourced
  # script") and under `set -Eeuo pipefail` the script ABORTS with rc=2 — which
  # is this matrix's own INCOMPLETE code, so a harness crash was indistinguishable
  # from a legitimate INCOMPLETE verdict, with no SUMMARY block printed at all.
  # Restructured so the rest of R11 is genuinely conditional instead.
  if ! grep -q '^NFTBAN_INSTALLER="/nonexistent/nftban-installer"' "$scr"; then
      skip "could not redirect NFTBAN_INSTALLER in the extracted %post"
  else
      ok "injection: extracted %post now points at a nonexistent installer"
      o="$W/r11.txt"
      ( set +e; INSTALL_MODE=install sh -e "$scr" 1 >"$o" 2>&1; echo "rc=$?" >>"$o" ) || true
      eq 127 "$(tok "$o" NFTBAN_PACKAGE_INSTALLER_EXIT)" "NFTBAN_PACKAGE_INSTALLER_EXIT"
      eq 127 "$(tok "$o" NFTBAN_PACKAGE_VERIFY_EXIT)"    "NFTBAN_PACKAGE_VERIFY_EXIT"
      eq NO  "$(tok "$o" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" "POSTINSTALL_VERIFIED"
      if grep -qE 'NFTBAN_INSTALL_ATTEMPT_VERDICT=' "$o"; then
          bad "canonical state token emitted though the verifier never ran"
      else
          ok "no canonical state token — the installer never ran, so no state was interpreted"
      fi
  fi
fi

echo
else
  R[R11]="NOT_IN_SCOPE"
fi

echo "===== SUMMARY ====="
# A1 (UNINSTALL-PR3) CLOSED-SET AGGREGATION. This loop previously counted only
# SKIP and FAIL; every other value fell through and the run reached PASS. A new
# verdict state would therefore have been counted as NOTHING. There is no
# default-success path any more: an unrecognised verdict is a HARNESS_FAILURE.
skipped=0; failed=0; blocked=0; unknown=0
for c in R1 R2 R3 R4 R7 R8 R11; do
  v="${R[$c]:-SKIP}"; echo "NFTBAN_RPM_MATRIX_RESULT_${c}=${v}"
  case "$v" in
    PASS)                ;;
    FAIL)                failed=$((failed+1)) ;;
    SKIP)                skipped=$((skipped+1)) ;;
    BLOCKED_ENVIRONMENT) blocked=$((blocked+1)) ;;
    NOT_IN_SCOPE)        ;;   # declared exclusion — not a claim, not a gap
    *)                   unknown=$((unknown+1))
                         echo "NFTBAN_RPM_MATRIX_UNKNOWN_VERDICT_${c}=${v}" ;;
  esac
done
echo "NFTBAN_RPM_MATRIX_SCOPE=${CASES// /,}"
echo "NFTBAN_RPM_MATRIX_ASSERTIONS_PASS=$P"
echo "NFTBAN_RPM_MATRIX_ASSERTIONS_FAIL=$F"
echo "NFTBAN_RPM_MATRIX_ASSERTIONS_BLOCKED=$B"
echo "NFTBAN_RPM_MATRIX_VM_ASSERTIONS_NOT_IN_SCOPE=$VMNS"
# A Layer A PASS must never read as systemd/kernel validation.
if [[ "$VM_ASSERTIONS" == "1" ]]; then
  echo "NFTBAN_RPM_MATRIX_LAYER=B_VM_AUTHORITATIVE"
  echo "NFTBAN_RPM_MATRIX_CLAIMS_SYSTEMD_AUTHORITY=YES"
else
  echo "NFTBAN_RPM_MATRIX_LAYER=A_CONTAINER_PACKAGE_ONLY"
  echo "NFTBAN_RPM_MATRIX_CLAIMS_SYSTEMD_AUTHORITY=NO"
  echo "NFTBAN_RPM_MATRIX_CLAIMS_KERNEL_FIREWALL_AUTHORITY=NO"
fi
echo "NFTBAN_RPM_MATRIX_CASES_BLOCKED=$blocked"
echo "NFTBAN_RPM_MATRIX_ENVIRONMENT=STOCK_ENFORCING_$(getenforce 2>/dev/null || echo UNKNOWN)"
VERDICT_EMITTED=1
# Taxonomy: PASS=0 · TEST_FAILURE=1 · INCOMPLETE=2 · HARNESS_FAILURE=3
# A9 ASSERTION FLOOR. NOT_IN_SCOPE is correctly non-blocking, but nothing
# required that ANY case actually ran. A scope token matching no known case —
# a typo, or a case renamed while the workflow still names the old id — left
# every counter at zero and reached VERDICT=PASS having asserted NOTHING.
#   ZERO ASSERTIONS IS NOT A PASS
# It is a harness failure, not a product verdict: the run could not have
# observed the product either way.
if [[ "$P" -eq 0 && "$F" -eq 0 ]]; then
  echo "NFTBAN_RPM_MATRIX_VERDICT=HARNESS_FAILURE"
  echo "NFTBAN_RPM_MATRIX_HARNESS_NOTE=zero assertions executed (scope='${CASES}'); a requested case may not exist"
  VERDICT_EMITTED=1
  exit 3
fi
# Every requested token must resolve to a real case, or the scope is a typo.
for _want in $CASES; do
  if [[ " $ALL_CASES " != *" $_want "* ]]; then
    echo "NFTBAN_RPM_MATRIX_VERDICT=HARNESS_FAILURE"
    echo "NFTBAN_RPM_MATRIX_HARNESS_NOTE=requested case '${_want}' is not a known case"
    VERDICT_EMITTED=1; exit 3
  fi
done
if [[ "$unknown" -gt 0 ]]; then
  echo "NFTBAN_RPM_MATRIX_VERDICT=HARNESS_FAILURE"
  echo "NFTBAN_RPM_MATRIX_HARNESS_NOTE=${unknown} case(s) carried an unrecognised verdict"
  exit 3
fi
if [[ "$failed" -gt 0 ]]; then echo "NFTBAN_RPM_MATRIX_VERDICT=FAIL"; exit 1; fi
# BLOCKED is closure-blocking exactly like SKIP, but labelled separately: SKIP is
# "known-not-run", BLOCKED is "could-not-observe".
if [[ "$blocked" -gt 0 ]]; then
  echo "NFTBAN_RPM_MATRIX_VERDICT=INCOMPLETE"
  echo "NFTBAN_RPM_MATRIX_INCOMPLETE_REASON=BLOCKED_ENVIRONMENT"
  exit 2
fi
if [[ "$skipped" -gt 0 ]]; then
  echo "NFTBAN_RPM_MATRIX_VERDICT=INCOMPLETE"
  echo "NFTBAN_RPM_MATRIX_INCOMPLETE_REASON=SKIP"
  exit 2
fi
echo "NFTBAN_RPM_MATRIX_VERDICT=PASS"; exit 0
