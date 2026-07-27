#!/usr/bin/env bash
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
PRIOR="${2:?}"
PKG=nftban-core
STATE_DIR=/var/lib/nftban/state
STATE="$STATE_DIR/install_state"
LOCK="$STATE_DIR/installer.lock"
W="$(mktemp -d)"; LOCK_PID=""
P=0; F=0; declare -A R
ok(){ echo "[PASS] ${CASE:-PRE}  $1"; P=$((P+1)); }
bad(){ echo "[FAIL] ${CASE:-PRE}  $1"; F=$((F+1)); R[$CASE]=FAIL; }
skip(){ echo "[SKIP] ${CASE:-PRE}  $1"; R[$CASE]=SKIP; }
hdr(){ CASE="$1"; R[$1]="${R[$1]:-PASS}"; printf '\n========== CASE %s: %s ==========\n' "$1" "$2"; }
eq(){ [[ "$2" == "$1" ]] && ok "$3 (= $1)" || bad "$3 — got '$2', want '$1'"; }
tok(){ grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
sfield(){ [[ -f "$STATE" ]] && (grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-) || true; }
ver(){ rpm -q --qf '%{VERSION}' "$PKG" 2>/dev/null || true; }
installed(){ rpm -q "$PKG" >/dev/null 2>&1; }
unit_state(){ local s; s="$(systemctl is-active "$1" 2>/dev/null | head -1 || true)"; [[ -n "$s" ]] || s=inactive; printf '%s' "$s"; }
fw(){ nft list table ip nftban >/dev/null 2>&1 && echo present || echo absent; }
release_lock(){ if [[ -n "$LOCK_PID" ]]; then kill -TERM -"$LOCK_PID" 2>/dev/null || kill -TERM "$LOCK_PID" 2>/dev/null || true
    wait "$LOCK_PID" 2>/dev/null || true; kill -KILL -"$LOCK_PID" 2>/dev/null || true; LOCK_PID=""
    if [[ -e "$LOCK" ]]; then for _ in $(seq 1 20); do flock -n -x "$LOCK" -c true 2>/dev/null && return 0; sleep 1; done
        echo "WARNING: $LOCK still held"; fi; fi; }
cleanup(){ release_lock; rm -rf "$W"; }
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
    eq active "$(unit_state nftband.service)" "nftband.service"
    eq active "$(unit_state nftban-maintenance.timer)" "critical timer"
    eq present "$(fw)" "nftables table ip nftban"
    local failed; failed="$(systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c nftban || true)"
    eq 0 "${failed:-0}" "failed NFTBan units"
}

CAND_VER="$(rpm -qp --qf '%{VERSION}' "$CAND" 2>/dev/null)"
PRIOR_VER="$(rpm -qp --qf '%{VERSION}' "$PRIOR" 2>/dev/null)"
echo "===== RPM lifecycle matrix ====="
echo "candidate : $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$CAND")"
echo "prior     : $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$PRIOR")"
echo "selinux   : $(getenforce)"
[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 2; }
exec 9>/var/lock/nftban-rpm-matrix.lock
flock -n 9 || { echo "another RPM matrix run holds the lock — refusing"; exit 2; }
eq nftban-core "$(rpm -qp --qf '%{NAME}' "$CAND")" "candidate package name"
[[ "$CAND_VER" != "$PRIOR_VER" ]] && ok "candidate $CAND_VER differs from prior $PRIOR_VER" \
                                  || bad "candidate and prior are both $CAND_VER — R3 would not be an upgrade"

# ---------------------------------------------------------------- R1
hdr R1 "fresh install (ABSENT -> INSTALL)"
erase_all
installed && bad "precondition: package still installed" || ok "precondition: ABSENT"
o="$W/r1.txt"; rc="$(inst "$CAND" "$o")"
eq 0 "$rc" "dnf transaction rc"
assert_healthy_install "$o" "$CAND_VER"

# ---------------------------------------------------------------- R2
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

# ---------------------------------------------------------------- R3
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

# ---------------------------------------------------------------- R4  (T8)
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

# ---------------------------------------------------------------- R7
hdr R7 "erase"
if ! installed; then
  erase_all; o="$W/r7_pre.txt"; inst "$CAND" "$o" >/dev/null
fi
if ! installed; then skip "R7 needs an installed package"; else
  o="$W/r7.txt"; rc=0; dnf -y remove "$PKG" >"$o" 2>&1 || rc=$?
  eq 0 "$rc" "dnf remove rc"
  installed && bad "package still in the rpm database after erase" || ok "package removed from the rpm database"
  eq inactive "$(unit_state nftband.service)" "nftband.service after erase"
  eq inactive "$(unit_state nftban-maintenance.timer)" "critical timer after erase"
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
fi

# ---------------------------------------------------------------- R8
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

# ---------------------------------------------------------------- R11
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
  if grep -q '^NFTBAN_INSTALLER="/nonexistent/nftban-installer"' "$scr"; then
      ok "injection: extracted %post now points at a nonexistent installer"
  else
      skip "could not redirect NFTBAN_INSTALLER in the extracted %post"
      return 0
  fi
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

echo
echo "===== SUMMARY ====="
skipped=0; failed=0
for c in R1 R2 R3 R4 R7 R8 R11; do
  v="${R[$c]:-SKIP}"; echo "NFTBAN_RPM_MATRIX_RESULT_${c}=${v}"
  [[ "$v" == SKIP ]] && skipped=$((skipped+1)); [[ "$v" == FAIL ]] && failed=$((failed+1))
done
echo "NFTBAN_RPM_MATRIX_ASSERTIONS_PASS=$P"
echo "NFTBAN_RPM_MATRIX_ASSERTIONS_FAIL=$F"
echo "NFTBAN_RPM_MATRIX_ENVIRONMENT=STOCK_ENFORCING_$(getenforce)"
if [[ "$failed" -gt 0 ]]; then echo "NFTBAN_RPM_MATRIX_VERDICT=FAIL"; exit 1; fi
if [[ "$skipped" -gt 0 ]]; then echo "NFTBAN_RPM_MATRIX_VERDICT=INCOMPLETE"; exit 2; fi
echo "NFTBAN_RPM_MATRIX_VERDICT=PASS"; exit 0
