#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="lifecycle_deb_matrix"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.228.0 Item 2 DEB post-install lifecycle matrix (L1-L10). Runs AS ROOT on a disposable Ubuntu 24.04 VM. Asserts the post-install outcome-truth contract across fresh install, same-version reinstall, real-package upgrade, package-level T8 (lock contention), terminal-failure classes, uninstall, reinstall-after-uninstall, purge and interrupted-uninstall protection."
# meta:input="argv1 = candidate .deb (v1.228.0), argv2 = prior published .deb (v1.227.0)"
# meta:output="PASS/FAIL assertion lines + machine-readable RESULT_* summary"
# meta:depends="dpkg, dpkg-deb, dpkg-query, apt-get, systemctl, nft, flock, chattr, lsattr, date"
# meta:inventory.files="/var/lib/nftban/state/install_state, /var/lib/nftban/state/installer.lock, /usr/lib/nftban/VERSION"
# meta:inventory.binaries="/usr/lib/nftban/bin/nftban-installer, /usr/sbin/nftban"
# meta:inventory.env_vars="NFTBAN_LIFECYCLE_KEEP_GOING, NFTBAN_LIFECYCLE_CASES"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftband.service, nftband.socket, nftban-maintenance.timer, nftables.service, ufw.service"
# meta:inventory.network="none"
# meta:inventory.privileges="root"
# =============================================================================
#
# DESTRUCTIVE. This harness installs, reinstalls, upgrades, removes and PURGES
# nftban-core, masks nftables.service, masks nftban-maintenance.timer, starts
# ufw.service, and sets the immutable flag on package-owned files. Run it ONLY
# on a disposable VM you are willing to throw away.
#
# -----------------------------------------------------------------------------
# WHERE EVERY CONSTANT COMES FROM (repo @ feat/v1.228.0-item2-postinstall-outcome-truth)
# -----------------------------------------------------------------------------
#   package name              packaging/deb/control:13, packaging/build_nftban.sh:1896
#   deb filename convention   packaging/build_nftban.sh:2358
#   installer binary path     packaging/deb/postinst:32
#   expected-version source   packaging/deb/postinst:381 (/usr/lib/nftban/VERSION)
#                             staged by packaging/build_nftban.sh:2133-2137
#   Item 2 package tokens     packaging/deb/postinst:391-397
#   verifier invocation       packaging/deb/postinst:383-387
#   installer/verify exits    internal/installer/state/machine.go:215-229,
#                             cmd/nftban-installer/verify_mode.go:96-117
#   verdict vocabulary        internal/installer/postinstall/verify.go:69-95
#   verifier token names      internal/installer/postinstall/verify.go:265-274
#   state file path + schema  internal/installer/state/file.go:31,34,54-71,248-282
#   state timestamp format    internal/installer/state/file.go:252 (time.RFC3339 -> SECONDS)
#   terminal state vocabulary internal/installer/state/machine.go:24-36
#   lock file / exit 75       internal/installer/state/file.go:39,45-50;
#                             cmd/nftban-installer/main.go:107-115
#   FAILED_NO_FIREWALL path   cmd/nftban-installer/phases.go:474-477 via
#                             internal/installer/switchop/enable.go:41-46
#   FAILED_AUTHORITY_ABORT    cmd/nftban-installer/phases.go:244-247 via
#                             internal/installer/authority/classify.go:157-164 and
#                             internal/installer/extfw/detect.go:178-184 (ufw.service active)
#   DEGRADED path             cmd/nftban-installer/phases.go:718-736 via
#                             internal/installer/validate/timers.go:68-80 +
#                             internal/installer/services/timers.go:98-100
#   core timers               internal/installer/services/timers.go:29-38
#   critical core timer       internal/installer/services/timers.go:98-100
#   daemon units              internal/installer/services/daemon.go:65-91
#   nft tables                packaging/deb/postrm:108-111,215-217
#   emergency table name      internal/installer/switchop/sshguard.go:30
#   remove-vs-purge policy    packaging/deb/postrm:41-186 (purge) / 188-242 (remove)
#   prerm stop list           packaging/deb/prerm:51-125
#   nftban validate exits     cli/lib/nftban/cli/cmd_validate.sh:147-151
#
# -----------------------------------------------------------------------------
# CASES THAT ARE DELIBERATELY NOT FAKED
# -----------------------------------------------------------------------------
#   L5 (package form of T9, controlled pre-Transition termination) has NO shipped
#   controlled injection hook. cmd/nftban-installer/inject.go:32-45 is an
#   unexported, Go-test-only DATA carrier — it is not reachable from a flag or an
#   environment variable, and the installer exposes no abort/inject env var
#   (only NFTBAN_TAKEOVER / NFTBAN_INSTALLER_LOG / NFTBAN_PANEL_AUTO_TAKEOVER /
#   NFTBAN_LIFECYCLE / NFTBAN_SOURCE_DIR / NFTBAN_RUN_ID). The harness therefore
#   uses the ONE controlled, reversible, non-kill mechanism that provably keeps
#   the persisted state historical: the immutable flag on install_state, which
#   makes StateFile.WriteAtomic's rename fail (internal/installer/state/file.go:294)
#   so no Transition can land on disk. That mechanism is INFERRED, not measured,
#   so L5 self-checks it first: if the state file changed at all, L5 reports FAIL
#   ("injection did not take effect"), never PASS. A kill -9 / panic of a live
#   transaction is explicitly refused.
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# derived constants
# -----------------------------------------------------------------------------
readonly PKG="nftban-core"
readonly INSTALLER="/usr/lib/nftban/bin/nftban-installer"
readonly PKG_VERSION_FILE="/usr/lib/nftban/VERSION"
readonly STATE_DIR="/var/lib/nftban/state"
readonly STATE_FILE="${STATE_DIR}/install_state"
readonly LOCK_FILE="${STATE_DIR}/installer.lock"
readonly NFTBAN_CLI="/usr/sbin/nftban"
readonly CONF_MAIN="/etc/nftban/nftban.conf"
readonly CONF_LOCAL_MARKER="/etc/nftban/conf.d/zz-lifecycle-harness.conf.local"
readonly EMERGENCY_TABLE="nftban_install_emergency"

# internal/installer/services/timers.go:29-38
readonly CORE_TIMERS=(
    "nftban-maintenance.timer"
    "nftban-health.timer"
    "nftban-unified-exporter.timer"
    "nftban-core-geoip.timer"
    "nftban-core-feeds.timer"
    "nftban-watchdog.timer"
    "nftban-queue.timer"
    "nftban-update-check.timer"
    "nftban-geoban-refresh.timer"
)
# internal/installer/services/timers.go:98-100
readonly CRITICAL_TIMERS=("nftban-maintenance.timer")
# internal/installer/services/daemon.go:65-91
readonly DAEMON_UNITS=("nftband.socket" "nftband.service")
# packaging/deb/postrm:177-181
readonly PURGE_DIRS=(
    "/etc/nftban" "/var/lib/nftban" "/var/log/nftban"
    "/var/cache/nftban" "/usr/share/nftban"
)

# -----------------------------------------------------------------------------
# bookkeeping
# -----------------------------------------------------------------------------
CANDIDATE_DEB=""
PRIOR_DEB=""
CANDIDATE_VER=""
PRIOR_VER=""
WORKDIR=""
PASS_N=0
FAIL_N=0
CASE_ID="INIT"
declare -A CASE_RESULT=()
declare -A CASE_NOTE=()
CASE_ORDER=(L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11)

# cleanup ledger — every mutation this harness makes to host state
CLEAN_IMMUTABLE=()
CLEAN_MASKED_UNITS=()
# Files whose EXISTING immutable flag this harness cleared and must restore.
# Distinct from CLEAN_IMMUTABLE, which is protection the harness ADDED and must
# remove. Leaving a product-protected config unprotected is a silent failure, so
# the trap restores these even on an interrupted run.
RESTORE_IMMUTABLE=()
LOCK_HOLDER_PID=""

log()  { printf '%s\n' "$*"; }
# A fixture that half-applied is worse than one that stopped: it produces
# assertions about a state nobody established. Fail closed and let the EXIT trap
# put host protection back.
fatal() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }
hdr()  { printf '\n========== %s ==========\n' "$*"; }
sub()  { printf -- '---- %s ----\n' "$*"; }

# assert <ok-bool-as-rc> <description> — the ONLY place PASS/FAIL is emitted.
assert() {
    local rc="$1"; shift
    if [[ "$rc" -eq 0 ]]; then
        printf '[PASS] %-4s %s\n' "$CASE_ID" "$*"
        PASS_N=$((PASS_N + 1))
    else
        printf '[FAIL] %-4s %s\n' "$CASE_ID" "$*"
        FAIL_N=$((FAIL_N + 1))
        CASE_RESULT["$CASE_ID"]="FAIL"
    fi
}

assert_eq() { # want got description
    local want="$1" got="$2"; shift 2
    if [[ "$want" == "$got" ]]; then
        assert 0 "$* (= ${want})"
    else
        assert 1 "$* — got '${got:-<absent>}', want '${want}'"
    fi
}

case_begin() {
    CASE_ID="$1"
    CASE_RESULT["$CASE_ID"]="PASS"
    hdr "CASE ${CASE_ID}: $2"
}

case_skip() { # reason
    CASE_RESULT["$CASE_ID"]="SKIP"
    CASE_NOTE["$CASE_ID"]="$1"
    printf '[SKIP] %-4s %s\n' "$CASE_ID" "$1"
}

# -----------------------------------------------------------------------------
# token extraction — anchored so NFTBAN_INSTALLER_EXIT never matches inside
# NFTBAN_PACKAGE_INSTALLER_EXIT (postinst:391 vs verify.go:273)
# -----------------------------------------------------------------------------
tok() { # file key
    local f="$1" k="$2" line
    [[ -f "$f" ]] || { printf ''; return 0; }
    line="$(grep -aoE "(^|[^A-Za-z0-9_])${k}=[^[:space:]]*" "$f" | head -1 || true)"
    [[ -n "$line" ]] || { printf ''; return 0; }
    printf '%s' "${line#*"${k}"=}"
}

# state file field reader (internal/installer/state/file.go:317-387)
statefield() { # key
    [[ -f "$STATE_FILE" ]] || { printf ''; return 0; }
    grep -aE "^$1=" "$STATE_FILE" | head -1 | cut -d= -f2- || true
}

epoch_of() { # RFC3339 -> epoch seconds; empty on failure
    local ts="$1"
    [[ -n "$ts" ]] || { printf ''; return 0; }
    date -u -d "$ts" +%s 2>/dev/null || printf ''
}

# -----------------------------------------------------------------------------
# package-transaction runners (Dpkg::Use-Pty=0 keeps postinst stdout unmangled)
# -----------------------------------------------------------------------------
APT_OPTS=(-y -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold
          -o Dpkg::Options::=--force-confdef --allow-downgrades
          # Cloud images run apt-daily/unattended-upgrades on boot and hold the
          # dpkg frontend lock. Without this wait every pkg_* call fails on the
          # ENVIRONMENT and the whole matrix reports product failures that are
          # nothing of the kind.
          -o DPkg::Lock::Timeout=300)

pkg_install() { # deb-path outfile ; echoes rc
    local deb="$1" out="$2" rc=0
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install "$deb" \
        >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

pkg_reinstall() { # deb-path outfile ; --reinstall keeps the same version
    local deb="$1" out="$2" rc=0
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install --reinstall "$deb" \
        >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

pkg_remove() { # outfile
    local out="$1" rc=0
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" remove "$PKG" \
        >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

pkg_purge() { # outfile
    local out="$1" rc=0
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" purge "$PKG" \
        >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

dpkg_status() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$PKG" 2>/dev/null | tr -d ' \n' || printf 'absent'
}

dpkg_version() {
    dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || printf ''
}

# -----------------------------------------------------------------------------
# cross-lifecycle invariant snapshot — printed for EVERY case
# -----------------------------------------------------------------------------
snapshot() { # label
    sub "INVARIANT SNAPSHOT: $1"
    printf '  dpkg.status              = %s\n' "$(dpkg_status)"
    printf '  dpkg.version             = %s\n' "$(dpkg_version)"
    printf '  dpkg.owned_files         = %s\n' \
        "$(dpkg -L "$PKG" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ -f "$STATE_FILE" ]]; then
        printf '  state.file               = present\n'
        printf '  state.INSTALL_STATE      = %s\n' "$(statefield INSTALL_STATE)"
        printf '  state.INSTALL_MODE       = %s\n' "$(statefield INSTALL_MODE)"
        printf '  state.INSTALL_VERSION    = %s\n' "$(statefield INSTALL_VERSION)"
        printf '  state.INSTALL_TIMESTAMP  = %s\n' "$(statefield INSTALL_TIMESTAMP)"
        printf '  state.PHASE_REACHED      = %s\n' "$(statefield PHASE_REACHED)"
        printf '  state.FAILURE_REASON     = %s\n' "$(statefield FAILURE_REASON)"
        printf '  state.SERVICES_FAILED    = %s\n' "$(statefield SERVICES_FAILED)"
    else
        printf '  state.file               = ABSENT\n'
    fi
    printf '  pkg.VERSION file         = %s\n' \
        "$(cat "$PKG_VERSION_FILE" 2>/dev/null || echo absent)"
    local u
    for u in "${DAEMON_UNITS[@]}"; do
        printf '  systemd.%-24s active=%s enabled=%s\n' "$u" \
            "$(systemctl is-active "$u" 2>/dev/null || true)" \
            "$(systemctl is-enabled "$u" 2>/dev/null || true)"
    done
    for u in "${CORE_TIMERS[@]}"; do
        printf '  systemd.%-32s active=%s enabled=%s\n' "$u" \
            "$(systemctl is-active "$u" 2>/dev/null || true)" \
            "$(systemctl is-enabled "$u" 2>/dev/null || true)"
    done
    printf '  systemd.failed_nftban    = %s\n' "$(failed_nftban_units | tr '\n' ' ')"
    printf '  nft.ip_nftban            = %s\n' "$(nft_table_state ip nftban)"
    printf '  nft.ip6_nftban           = %s\n' "$(nft_table_state ip6 nftban)"
    printf '  nft.emergency            = %s\n' "$(nft_table_state inet "$EMERGENCY_TABLE")"
    printf '  config./etc/nftban       = %s\n' \
        "$([[ -d /etc/nftban ]] && echo present || echo absent)"
    printf '  config.nftban.conf       = %s\n' \
        "$([[ -f "$CONF_MAIN" ]] && echo present || echo absent)"
    printf '  config.dpkg_sidecars     = %s\n' \
        "$(find /etc/nftban -name '*.dpkg-dist' -o -name '*.dpkg-new' 2>/dev/null | wc -l | tr -d ' ')"
    printf '  ufw.service              = %s\n' "$(systemctl is-active ufw.service 2>/dev/null || true)"
    printf '  nftables.service         = %s\n' "$(systemctl is-active nftables.service 2>/dev/null || true)"
}

nft_table_state() { # family name
    if ! command -v nft >/dev/null 2>&1; then printf 'nft-absent'; return 0; fi
    if nft list table "$1" "$2" >/dev/null 2>&1; then printf 'present'; else printf 'absent'; fi
}

failed_nftban_units() {
    systemctl list-units --state=failed --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | grep -E '^(nftban|nftband)' || true
}

# -----------------------------------------------------------------------------
# shared assertion bundles
# -----------------------------------------------------------------------------

# The five Item 2 package-boundary + verifier tokens for a HEALTHY transaction.
assert_verified_tokens() { # outfile expected_version
    local out="$1" ver="$2"
    assert_eq "0"                "$(tok "$out" NFTBAN_PACKAGE_INSTALLER_EXIT)" \
        "NFTBAN_PACKAGE_INSTALLER_EXIT"
    assert_eq "0"                "$(tok "$out" NFTBAN_PACKAGE_VERIFY_EXIT)" \
        "NFTBAN_PACKAGE_VERIFY_EXIT"
    assert_eq "YES"              "$(tok "$out" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" \
        "NFTBAN_PACKAGE_POSTINSTALL_VERIFIED"
    assert_eq "CURRENT_COMMITTED" "$(tok "$out" NFTBAN_INSTALL_ATTEMPT_VERDICT)" \
        "NFTBAN_INSTALL_ATTEMPT_VERDICT"
    assert_eq "YES"              "$(tok "$out" NFTBAN_INSTALL_VERIFIED)" \
        "NFTBAN_INSTALL_VERIFIED"
    assert_eq "COMMITTED"        "$(tok "$out" NFTBAN_PERSISTED_INSTALL_STATE)" \
        "NFTBAN_PERSISTED_INSTALL_STATE"
    assert_eq "$ver"             "$(tok "$out" NFTBAN_PERSISTED_STATE_VERSION)" \
        "NFTBAN_PERSISTED_STATE_VERSION"
    assert_eq "$ver"             "$(tok "$out" NFTBAN_EXPECTED_VERSION)" \
        "NFTBAN_EXPECTED_VERSION"
    # verify_mode.go:150 passes installerExit=-1 — the verifier must not fabricate 0
    assert_eq "-1"               "$(tok "$out" NFTBAN_INSTALLER_EXIT)" \
        "verifier NFTBAN_INSTALLER_EXIT sentinel"
}

assert_state_version_and_window() { # expected_version tx_start_epoch tx_end_epoch
    local ver="$1" t0="$2" t1="$3" ts e
    assert_eq "$ver" "$(statefield INSTALL_VERSION)" "state INSTALL_VERSION == package version"
    ts="$(statefield INSTALL_TIMESTAMP)"
    e="$(epoch_of "$ts")"
    if [[ -z "$e" ]]; then
        assert 1 "state INSTALL_TIMESTAMP parseable (got '${ts:-<absent>}')"
        return 0
    fi
    # file.go:252 formats with time.RFC3339 (second precision) — the persisted
    # value is TRUNCATED downward, so allow exactly one second of slack at the
    # lower bound and nothing more.
    if [[ "$e" -ge $((t0 - 1)) && "$e" -le $((t1 + 1)) ]]; then
        assert 0 "state INSTALL_TIMESTAMP inside the transaction window (${ts})"
    else
        assert 1 "state INSTALL_TIMESTAMP ${ts} (epoch ${e}) outside window [${t0},${t1}]"
    fi
}

assert_runtime_healthy() {
    local u active enabled
    for u in "${DAEMON_UNITS[@]}"; do
        active="$(systemctl is-active "$u" 2>/dev/null || true)"
        assert_eq "active" "$active" "systemd ${u} is-active"
    done
    for u in "${CORE_TIMERS[@]}"; do
        active="$(systemctl is-active "$u" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$u" 2>/dev/null || true)"
        assert_eq "active"  "$active"  "core timer ${u} is-active"
        assert_eq "enabled" "$enabled" "core timer ${u} is-enabled"
    done
    for u in "${CRITICAL_TIMERS[@]}"; do
        assert_eq "active" "$(systemctl is-active "$u" 2>/dev/null || true)" \
            "CRITICAL timer ${u} active (drives DEGRADED per timers.go:68-80)"
    done
    assert_eq "present" "$(nft_table_state ip nftban)"  "nft table ip nftban loaded"
    assert_eq "present" "$(nft_table_state ip6 nftban)" "nft table ip6 nftban loaded"
    assert_eq "absent"  "$(nft_table_state inet "$EMERGENCY_TABLE")" \
        "emergency SSH table removed (assertions.go:279 no_emergency_table)"
    local failed
    failed="$(failed_nftban_units | tr '\n' ' ' | sed 's/ *$//')"
    assert_eq "" "$failed" "zero failed NFTBan systemd units"
}

assert_validate_ok() {
    local rc=0 out="${WORKDIR}/validate_${CASE_ID}.txt"
    if [[ ! -x "$NFTBAN_CLI" ]]; then
        assert 1 "nftban CLI present at ${NFTBAN_CLI}"
        return 0
    fi
    "$NFTBAN_CLI" validate >"$out" 2>&1 || rc=$?
    # cmd_validate.sh:147-151 — 0 PROTECTED/IDLE, 1 DEGRADED, 2 DOWN, 3 crash
    assert_eq "0" "$rc" "nftban validate exit (0=PROTECTED/IDLE per cmd_validate.sh:148)"
    if [[ "$rc" -ne 0 ]]; then
        sed 's/^/      | /' "$out" | tail -25
    fi
}

assert_dpkg_installed() {
    local st; st="$(dpkg_status)"
    assert_eq "ii" "$st" "dpkg database status"
}

# operator-override fixtures (conffiles: build_nftban.sh:2024-2048; *.local excluded)
OPERATOR_MARK="# NFTBAN-LIFECYCLE-HARNESS-OPERATOR-MARK"
is_immutable() { # file -> 0 if the immutable flag is set
    lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

plant_operator_config() {
    [[ -f "$CONF_MAIN" ]] || return 0
    # NFTBan protects nftban.conf with the immutable flag; preinst clears it for
    # its own transaction (preinst:78-89). A real controlled operator edit must
    # therefore clear the flag and put it back -- appending blind fails with
    # "Operation not permitted" and aborts the run before any case completes.
    #
    # Every step below is fail-closed. A silent `|| true` here would either leave
    # the fixture unplanted (so the preservation assertions prove nothing) or
    # leave a product-protected config permanently unprotected.
    local was_immutable=0
    if is_immutable "$CONF_MAIN"; then
        was_immutable=1
        RESTORE_IMMUTABLE+=("$CONF_MAIN")   # trap safety net for an interrupted run
        chattr -i "$CONF_MAIN" || fatal "cannot clear immutable flag on ${CONF_MAIN}"
        if is_immutable "$CONF_MAIN"; then
            fatal "immutable flag still set on ${CONF_MAIN} after chattr -i"
        fi
    fi

    if ! grep -q "$OPERATOR_MARK" "$CONF_MAIN" 2>/dev/null; then
        printf '%s\n' "$OPERATOR_MARK" >>"$CONF_MAIN" \
            || fatal "cannot write the operator marker to ${CONF_MAIN}"
    fi
    grep -q "$OPERATOR_MARK" "$CONF_MAIN" \
        || fatal "operator marker not present in ${CONF_MAIN} after writing it"

    if [[ "$was_immutable" -eq 1 ]]; then
        chattr +i "$CONF_MAIN" || fatal "cannot restore immutable flag on ${CONF_MAIN}"
        is_immutable "$CONF_MAIN" \
            || fatal "immutable flag NOT restored on ${CONF_MAIN} -- refusing to continue with the product config left unprotected"
        # restored: drop it from the trap ledger
        local keep=() f
        for f in "${RESTORE_IMMUTABLE[@]:-}"; do
            [[ "$f" == "$CONF_MAIN" ]] || keep+=("$f")
        done
        RESTORE_IMMUTABLE=("${keep[@]:-}")
    fi

    mkdir -p "$(dirname "$CONF_LOCAL_MARKER")"
    printf '%s\n' "$OPERATOR_MARK" >"$CONF_LOCAL_MARKER" \
        || fatal "cannot write ${CONF_LOCAL_MARKER}"
}

assert_operator_config_preserved() {
    if grep -q "$OPERATOR_MARK" "$CONF_MAIN" 2>/dev/null; then
        assert 0 "operator edit preserved in ${CONF_MAIN} (conffile)"
    else
        assert 1 "operator edit LOST from ${CONF_MAIN}"
    fi
    if [[ -f "$CONF_LOCAL_MARKER" ]] && grep -q "$OPERATOR_MARK" "$CONF_LOCAL_MARKER"; then
        assert 0 "operator override preserved at ${CONF_LOCAL_MARKER} (*.local, never a conffile)"
    else
        assert 1 "operator override LOST at ${CONF_LOCAL_MARKER}"
    fi
}

# -----------------------------------------------------------------------------
# host mutation helpers, all reversible and all recorded in the cleanup ledger
# -----------------------------------------------------------------------------
mark_immutable() { # path
    chattr +i "$1" 2>/dev/null || return 1
    CLEAN_IMMUTABLE+=("$1")
    return 0
}

unmark_immutable() { # path
    chattr -i "$1" 2>/dev/null || true
}

mask_unit() { # unit
    systemctl mask "$1" >/dev/null 2>&1 || return 1
    CLEAN_MASKED_UNITS+=("$1")
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

unmask_unit() { # unit
    systemctl unmask "$1" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

drop_emergency_table() {
    command -v nft >/dev/null 2>&1 || return 0
    nft delete table inet "$EMERGENCY_TABLE" >/dev/null 2>&1 || true
}

release_lock_holder() {
    if [[ -n "$LOCK_HOLDER_PID" ]] && kill -0 "$LOCK_HOLDER_PID" 2>/dev/null; then
        kill "$LOCK_HOLDER_PID" 2>/dev/null || true
        wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    fi
    LOCK_HOLDER_PID=""
}

# Full teardown to a known-clean ABSENT baseline. Idempotent.
reset_to_absent() {
    sub "reset host to ABSENT baseline"
    release_lock_holder
    local p u
    for p in "${CLEAN_IMMUTABLE[@]:-}"; do
        if [[ -n "$p" ]]; then unmark_immutable "$p"; fi
    done
    CLEAN_IMMUTABLE=()
    for u in "${CLEAN_MASKED_UNITS[@]:-}"; do
        if [[ -n "$u" ]]; then unmask_unit "$u"; fi
    done
    CLEAN_MASKED_UNITS=()
    unmark_immutable "$STATE_FILE"
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all "$PKG" >/dev/null 2>&1 || true
    drop_emergency_table
    rm -rf "${PURGE_DIRS[@]}" /run/nftban >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
}

on_exit() {
    local rc=$?
    sub "cleanup"
    release_lock_holder
    local p u
    for p in "${CLEAN_IMMUTABLE[@]:-}"; do
        if [[ -n "$p" ]]; then unmark_immutable "$p"; fi
    done
    for u in "${CLEAN_MASKED_UNITS[@]:-}"; do
        if [[ -n "$u" ]]; then unmask_unit "$u"; fi
    done
    unmark_immutable "$STATE_FILE"
    unmask_unit nftables.service
    # Put back any product protection this run cleared. Loud on failure: a host
    # left with an unprotected nftban.conf must never be silent.
    for p in "${RESTORE_IMMUTABLE[@]:-}"; do
        if [[ -n "$p" && -f "$p" ]]; then
            if chattr +i "$p" 2>/dev/null; then
                log "cleanup: restored immutable flag on ${p}"
            else
                log "cleanup: WARNING — could NOT restore immutable flag on ${p}"
            fi
        fi
    done
    log "cleanup done (harness exit rc=${rc}); artifacts under ${WORKDIR:-<none>}"
}

# =============================================================================
# CASES
# =============================================================================

case_L1() {
    case_begin L1 "fresh install (ABSENT -> INSTALL)"
    reset_to_absent
    snapshot "L1 pre (must be ABSENT)"
    assert_eq "absent" "$(dpkg_status)" "precondition: package absent"
    assert_eq "ABSENT" "$([[ -f "$STATE_FILE" ]] && echo PRESENT || echo ABSENT)" \
        "precondition: no persisted install_state"

    local out="${WORKDIR}/L1_install.txt" t0 t1 rc
    t0="$(date -u +%s)"
    rc="$(pkg_install "$CANDIDATE_DEB" "$out")"
    t1="$(date -u +%s)"
    snapshot "L1 post"

    assert_eq "0" "$rc" "apt-get install exit"
    assert_dpkg_installed
    assert_eq "$CANDIDATE_VER" "$(dpkg_version)" "dpkg records the candidate version"
    assert_eq "install" "$(statefield INSTALL_MODE)" "installer selected INSTALL mode (postinst:303-307)"
    if grep -aq 'Running nftban-installer --deb (mode=install)' "$out"; then
        assert 0 "postinst announced mode=install (postinst:349)"
    else
        assert 1 "postinst did NOT announce mode=install"
    fi
    assert_eq "COMMITTED" "$(statefield INSTALL_STATE)" "persisted terminal state"
    assert_verified_tokens "$out" "$CANDIDATE_VER"
    assert_state_version_and_window "$CANDIDATE_VER" "$t0" "$t1"
    assert_runtime_healthy
    assert_validate_ok
    plant_operator_config
}

case_L2() {
    case_begin L2 "same-version reinstall (${CANDIDATE_VER} -> ${CANDIDATE_VER})"
    if [[ "$(dpkg_status)" != "ii" ]]; then
        case_skip "L2 requires a healthy L1 install; dpkg status is $(dpkg_status)"
        return 0
    fi
    plant_operator_config
    local ts_before files_before out="${WORKDIR}/L2_reinstall.txt" t0 t1 rc e_before e_after
    ts_before="$(statefield INSTALL_TIMESTAMP)"
    e_before="$(epoch_of "$ts_before")"
    files_before="$(dpkg -L "$PKG" 2>/dev/null | LC_ALL=C sort -u | wc -l | tr -d ' ')"
    snapshot "L2 pre"

    t0="$(date -u +%s)"
    rc="$(pkg_reinstall "$CANDIDATE_DEB" "$out")"
    t1="$(date -u +%s)"
    snapshot "L2 post"

    assert_eq "0" "$rc" "apt-get install --reinstall exit"
    assert_dpkg_installed
    assert_verified_tokens "$out" "$CANDIDATE_VER"
    assert_eq "COMMITTED" "$(statefield INSTALL_STATE)" "persisted terminal state"
    assert_state_version_and_window "$CANDIDATE_VER" "$t0" "$t1"

    e_after="$(epoch_of "$(statefield INSTALL_TIMESTAMP)")"
    if [[ -n "$e_before" && -n "$e_after" && "$e_after" -ge $((t0 - 1)) && "$e_after" -ge "$e_before" ]]; then
        assert 0 "state timestamp advanced to this reinstall (${ts_before} -> $(statefield INSTALL_TIMESTAMP))"
    else
        assert 1 "state timestamp did not advance (before=${ts_before} after=$(statefield INSTALL_TIMESTAMP))"
    fi

    assert_operator_config_preserved
    assert_runtime_healthy
    assert_validate_ok

    # no duplicates: owned-file set, state keys, unit instances
    local files_after dupes state_dupes
    files_after="$(dpkg -L "$PKG" 2>/dev/null | LC_ALL=C sort -u | wc -l | tr -d ' ')"
    assert_eq "$files_before" "$files_after" "package-owned file inventory unchanged by reinstall"
    dupes="$(dpkg -L "$PKG" 2>/dev/null | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
    assert_eq "0" "$dupes" "no duplicate entries in the dpkg file list"
    state_dupes="$(grep -aoE '^[A-Z_]+=' "$STATE_FILE" 2>/dev/null | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
    assert_eq "0" "$state_dupes" "no duplicate keys in install_state"
    local unit_dupes
    unit_dupes="$(systemctl list-unit-files --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | grep -E '^(nftban|nftband)' | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
    assert_eq "0" "$unit_dupes" "no duplicate nftban unit files registered"
    local sidecars
    sidecars="$(find /etc/nftban \( -name '*.dpkg-dist' -o -name '*.dpkg-new' \) 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "0" "$sidecars" "no config sidecars left in /etc/nftban (postinst:518-544 quarantine)"
}

case_L3() {
    case_begin L3 "upgrade (published ${PRIOR_VER} -> candidate ${CANDIDATE_VER})"
    if [[ "$PRIOR_VER" == "$CANDIDATE_VER" ]]; then
        case_skip "prior deb version (${PRIOR_VER}) equals candidate (${CANDIDATE_VER}) — this is NOT an upgrade. Rebuild the candidate with a bumped VERSION file (repo VERSION is currently the source of PKG_VERSION, build_nftban.sh:46)."
        return 0
    fi
    reset_to_absent

    local out0="${WORKDIR}/L3_prior_install.txt" rc0
    rc0="$(pkg_install "$PRIOR_DEB" "$out0")"
    assert_eq "0" "$rc0" "prior published ${PRIOR_VER} installs (REAL earlier package, never a VERSION edit)"
    assert_eq "$PRIOR_VER" "$(dpkg_version)" "dpkg records the prior version before upgrade"
    assert_eq "$PRIOR_VER" "$(statefield INSTALL_VERSION)" "state records the prior version before upgrade"
    plant_operator_config
    snapshot "L3 pre (prior version installed)"

    local out="${WORKDIR}/L3_upgrade.txt" t0 t1 rc
    t0="$(date -u +%s)"
    rc="$(pkg_install "$CANDIDATE_DEB" "$out")"
    t1="$(date -u +%s)"
    snapshot "L3 post (candidate installed)"

    assert_eq "0" "$rc" "apt-get install (upgrade) exit"
    assert_dpkg_installed
    assert_eq "$CANDIDATE_VER" "$(dpkg_version)" "dpkg advanced to the candidate version"
    assert_eq "upgrade" "$(statefield INSTALL_MODE)" "installer selected UPGRADE mode (postinst:303-307)"
    if grep -aq 'Running nftban-installer --deb (mode=upgrade)' "$out"; then
        assert 0 "postinst announced mode=upgrade (postinst:349)"
    else
        assert 1 "postinst did NOT announce mode=upgrade"
    fi
    assert_eq "COMMITTED" "$(statefield INSTALL_STATE)" "persisted terminal state"
    assert_verified_tokens "$out" "$CANDIDATE_VER"
    assert_state_version_and_window "$CANDIDATE_VER" "$t0" "$t1"
    assert_operator_config_preserved
    local sidecars
    sidecars="$(find /etc/nftban \( -name '*.dpkg-dist' -o -name '*.dpkg-new' \) 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "0" "$sidecars" "config migration left no un-quarantined sidecars"
    assert_runtime_healthy
    assert_validate_ok
}

case_L4() {
    case_begin L4 "package-level T8 — prior same-version COMMITTED + lock contention"
    # Precondition: a healthy same-version COMMITTED already on disk.
    if [[ "$(dpkg_status)" != "ii" || "$(dpkg_version)" != "$CANDIDATE_VER" ]]; then
        reset_to_absent
        local pre="${WORKDIR}/L4_pre_install.txt"
        pkg_install "$CANDIDATE_DEB" "$pre" >/dev/null
    fi
    if [[ "$(statefield INSTALL_STATE)" != "COMMITTED" || "$(statefield INSTALL_VERSION)" != "$CANDIDATE_VER" ]]; then
        case_skip "no SAME-VERSION prior COMMITTED to make stale — precondition unmet (state=$(statefield INSTALL_STATE) version=$(statefield INSTALL_VERSION))"
        return 0
    fi

    local ts_before e_before
    ts_before="$(statefield INSTALL_TIMESTAMP)"
    e_before="$(epoch_of "$ts_before")"
    assert 0 "precondition: SAME-VERSION prior COMMITTED at ${ts_before}"
    snapshot "L4 pre"

    # Controlled injection: hold the installer's own flock so the mutating run
    # exits 75 BEFORE any StateFile write (main.go:107-115). No kill, no panic.
    mkdir -p "$STATE_DIR"
    flock -x "$LOCK_FILE" -c 'sleep 900' &
    LOCK_HOLDER_PID=$!
    sleep 2
    if ! kill -0 "$LOCK_HOLDER_PID" 2>/dev/null; then
        case_skip "could not hold ${LOCK_FILE} — flock injection unavailable"
        return 0
    fi
    assert 0 "controlled injection: exclusive flock held on ${LOCK_FILE} (pid ${LOCK_HOLDER_PID})"

    local out="${WORKDIR}/L4_reinstall_locked.txt" rc
    rc="$(pkg_reinstall "$CANDIDATE_DEB" "$out")"
    release_lock_holder
    snapshot "L4 post"

    # 1. The package manager reports mechanical completion ...
    assert_eq "0" "$rc" "apt-get reports success (mechanical completion)"
    assert_dpkg_installed
    # ... 2. while the machine-readable result does NOT claim verified success.
    assert_eq "75"           "$(tok "$out" NFTBAN_PACKAGE_INSTALLER_EXIT)"     "NFTBAN_PACKAGE_INSTALLER_EXIT"
    assert_eq "2"            "$(tok "$out" NFTBAN_PACKAGE_VERIFY_EXIT)"        "NFTBAN_PACKAGE_VERIFY_EXIT"
    assert_eq "NO"           "$(tok "$out" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" "NFTBAN_PACKAGE_POSTINSTALL_VERIFIED"
    assert_eq "STALE_STATE"  "$(tok "$out" NFTBAN_INSTALL_ATTEMPT_VERDICT)"    "NFTBAN_INSTALL_ATTEMPT_VERDICT"
    assert_eq "NO"           "$(tok "$out" NFTBAN_INSTALL_VERIFIED)"           "NFTBAN_INSTALL_VERIFIED"
    assert_eq "COMMITTED"    "$(tok "$out" NFTBAN_PERSISTED_INSTALL_STATE)"    "persisted state still the historical COMMITTED"
    assert_eq "$CANDIDATE_VER" "$(tok "$out" NFTBAN_PERSISTED_STATE_VERSION)"  "persisted version is SAME-VERSION (freshness, not version, is under test)"

    # 3. State stayed historical.
    local e_after
    e_after="$(epoch_of "$(statefield INSTALL_TIMESTAMP)")"
    if [[ -n "$e_before" && "$e_before" == "$e_after" ]]; then
        assert 0 "install_state unchanged — timestamp still ${ts_before}"
    else
        assert 1 "install_state MUTATED during a transaction that never began (${ts_before} -> $(statefield INSTALL_TIMESTAMP))"
    fi
    # 4. Scriptlet rc=0 is what makes the defect invisible to apt — assert it explicitly.
    if grep -aqE 'dpkg: error processing package nftban-core' "$out"; then
        assert 1 "postinst scriptlet reported an error to dpkg (want a clean rc=0 scriptlet)"
    else
        assert 0 "postinst scriptlet exited 0 — apt stays green, only the tokens carry the truth"
    fi
}

case_L5() {
    case_begin L5 "controlled pre-Transition termination (package form of T9)"
    # There is NO shipped controlled injection hook for the T9 class other than
    # lock contention (already L4). inject.go:32-45 is Go-test-only and
    # unexported; no abort/inject env var exists. A panic or kill -9 of a live
    # transaction is explicitly REFUSED by this harness.
    #
    # The mechanism used here is controlled, reversible and non-kill: the
    # immutable flag on install_state makes StateFile.WriteAtomic's final
    # os.Rename fail (file.go:294), so NO Transition can land on disk and the
    # historical state is what the verifier sees — the T9 observable.
    #
    # This is INFERRED from the code path, not previously measured. The case
    # therefore SELF-CHECKS the injection: if the state file changed at all, L5
    # FAILS with "injection did not take effect" rather than reporting a pass.
    if [[ "$(dpkg_status)" != "ii" || "$(statefield INSTALL_STATE)" != "COMMITTED" ]]; then
        case_skip "L5 needs a healthy prior COMMITTED install"
        return 0
    fi
    if ! command -v chattr >/dev/null 2>&1 || ! command -v lsattr >/dev/null 2>&1; then
        case_skip "chattr/lsattr unavailable — the only controlled non-kill pre-Transition injection cannot be applied; NOT_YET_VERIFIED"
        return 0
    fi

    local ts_before sum_before out="${WORKDIR}/L5_reinstall_immutable_state.txt" rc
    ts_before="$(statefield INSTALL_TIMESTAMP)"
    sum_before="$(md5sum "$STATE_FILE" | awk '{print $1}')"
    if ! mark_immutable "$STATE_FILE"; then
        case_skip "chattr +i on ${STATE_FILE} refused (filesystem may not support immutability) — NOT_YET_VERIFIED"
        return 0
    fi
    if ! lsattr "$STATE_FILE" 2>/dev/null | grep -q -- '-i-'; then
        unmark_immutable "$STATE_FILE"
        case_skip "immutable flag not observable on ${STATE_FILE} — injection unverifiable, NOT_YET_VERIFIED"
        return 0
    fi
    assert 0 "controlled injection: install_state is immutable — no Transition can persist (file.go:294)"
    snapshot "L5 pre"

    rc="$(pkg_reinstall "$CANDIDATE_DEB" "$out")"
    unmark_immutable "$STATE_FILE"
    snapshot "L5 post"

    local sum_after
    sum_after="$(md5sum "$STATE_FILE" 2>/dev/null | awk '{print $1}')"
    if [[ "$sum_before" != "$sum_after" ]]; then
        assert 1 "INJECTION DID NOT TAKE EFFECT — install_state changed despite +i; the T9 class was NOT reproduced (treat as NOT_YET_VERIFIED, not a product defect)"
        CASE_RESULT["$CASE_ID"]="FAIL"
        return 0
    fi
    assert 0 "historical install_state byte-identical after the transaction (${ts_before})"

    assert_eq "0" "$rc" "apt-get exit — the package transaction still completes mechanically"
    assert_dpkg_installed
    assert_eq "STALE_STATE" "$(tok "$out" NFTBAN_INSTALL_ATTEMPT_VERDICT)" "NFTBAN_INSTALL_ATTEMPT_VERDICT"
    assert_eq "NO"          "$(tok "$out" NFTBAN_INSTALL_VERIFIED)"        "NFTBAN_INSTALL_VERIFIED"
    assert_eq "NO"          "$(tok "$out" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" "NFTBAN_PACKAGE_POSTINSTALL_VERIFIED"
    assert_eq "2"           "$(tok "$out" NFTBAN_PACKAGE_VERIFY_EXIT)"     "NFTBAN_PACKAGE_VERIFY_EXIT"
    # Distinguish L5 from L4: this must NOT be lock contention.
    local iexit; iexit="$(tok "$out" NFTBAN_PACKAGE_INSTALLER_EXIT)"
    if [[ "$iexit" == "75" ]]; then
        assert 1 "installer exited 75 — this reproduced L4's lock contention, not the T9 class"
    else
        assert 0 "installer exit ${iexit:-<absent>} is not 75 — a distinct mechanism from L4"
    fi
    if grep -aqE 'dpkg: error processing package nftban-core' "$out"; then
        assert 1 "postinst scriptlet reported an error to dpkg (want rc=0)"
    else
        assert 0 "postinst scriptlet exited 0"
    fi
    # leave the host clean for the next case
    reset_to_absent
    pkg_install "$CANDIDATE_DEB" "${WORKDIR}/L5_restore_install.txt" >/dev/null
}

# --- L6 helpers -------------------------------------------------------------
# Each terminal state gets: clean baseline -> inject -> install -> assert -> revert.
l6_expect_terminal() { # outfile expected_state expected_verdict label
    local out="$1" want_state="$2" want_verdict="$3" label="$4"
    assert_eq "$want_state" "$(statefield INSTALL_STATE)" \
        "${label}: persisted INSTALL_STATE names the failure class"
    assert_eq "$want_state" "$(tok "$out" NFTBAN_PERSISTED_INSTALL_STATE)" \
        "${label}: NFTBAN_PERSISTED_INSTALL_STATE"
    assert_eq "$want_verdict" "$(tok "$out" NFTBAN_INSTALL_ATTEMPT_VERDICT)" \
        "${label}: NFTBAN_INSTALL_ATTEMPT_VERDICT"
    assert_eq "NO" "$(tok "$out" NFTBAN_INSTALL_VERIFIED)" \
        "${label}: NFTBAN_INSTALL_VERIFIED"
    assert_eq "NO" "$(tok "$out" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" \
        "${label}: NFTBAN_PACKAGE_POSTINSTALL_VERIFIED"
    assert_eq "2"  "$(tok "$out" NFTBAN_PACKAGE_VERIFY_EXIT)" \
        "${label}: NFTBAN_PACKAGE_VERIFY_EXIT (ExitFailed, verify_mode.go:117)"
}

l6_expect_current_not_stale() { # t0 t1 label
    local t0="$1" t1="$2" label="$3" e ts
    ts="$(statefield INSTALL_TIMESTAMP)"
    e="$(epoch_of "$ts")"
    if [[ -n "$e" && "$e" -ge $((t0 - 1)) && "$e" -le $((t1 + 1)) ]]; then
        assert 0 "${label}: persisted state is CURRENT (written in this transaction, ${ts})"
    else
        assert 1 "${label}: persisted state is not current — ${ts} outside [${t0},${t1}]"
    fi
}

case_L6() {
    case_begin L6 "terminal states FAILED_NO_FIREWALL / FAILED_AUTHORITY_ABORT / DEGRADED"

    # ---- 6a FAILED_NO_FIREWALL ------------------------------------------
    # switchop.EnableNftables returns an error when `systemctl start nftables`
    # fails (enable.go:41-43) -> phases.go:476 Transition(StateFailedNoFirewall).
    sub "6a FAILED_NO_FIREWALL (nftables.service masked)"
    reset_to_absent
    if mask_unit nftables.service; then
        assert 0 "6a injection: nftables.service masked (reversible)"
        local out6a="${WORKDIR}/L6a_failed_no_firewall.txt" t0 t1 rc
        t0="$(date -u +%s)"
        rc="$(pkg_install "$CANDIDATE_DEB" "$out6a")"
        t1="$(date -u +%s)"
        snapshot "6a post"
        assert_eq "0" "$rc" "6a: apt-get still reports success (the whole point of Item 2)"
        l6_expect_terminal "$out6a" "FAILED_NO_FIREWALL" "INSTALL_FAILED" "6a"
        l6_expect_current_not_stale "$t0" "$t1" "6a"
        unmask_unit nftables.service
        drop_emergency_table
    else
        assert 1 "6a injection: could not mask nftables.service"
    fi

    # ---- 6b FAILED_AUTHORITY_ABORT --------------------------------------
    # extfw.Detect flags UFW when ufw.service is active (detect.go:178-184);
    # with no takeover approval authority.Classify returns Abort
    # (classify.go:157-164) -> phases.go:245 Transition(StateFailedAbort).
    sub "6b FAILED_AUTHORITY_ABORT (ufw.service active, no NFTBAN_TAKEOVER)"
    reset_to_absent
    systemctl start ufw.service >/dev/null 2>&1 || true
    if [[ "$(systemctl is-active ufw.service 2>/dev/null || true)" == "active" ]]; then
        assert 0 "6b injection: ufw.service is active (conflict signal, detect.go:178)"
        local out6b="${WORKDIR}/L6b_failed_authority_abort.txt" t0b t1b rcb
        t0b="$(date -u +%s)"
        rcb="$(pkg_install "$CANDIDATE_DEB" "$out6b")"
        t1b="$(date -u +%s)"
        snapshot "6b post"
        if grep -aq "Conflicting populated 'inet filter' table detected" "$out6b"; then
            assert 1 "6b: postinst aborted at the CVE inet-filter guard (postinst:99-103) before the installer ran — precondition invalid"
        else
            assert 0 "6b: CVE inet-filter guard did not pre-empt the installer"
            assert_eq "0" "$rcb" "6b: apt-get still reports success"
            assert_eq "3" "$(tok "$out6b" NFTBAN_PACKAGE_INSTALLER_EXIT)" \
                "6b: NFTBAN_PACKAGE_INSTALLER_EXIT (ExitAborted, machine.go:219)"
            l6_expect_terminal "$out6b" "FAILED_AUTHORITY_ABORT" "INSTALL_FAILED" "6b"
            l6_expect_current_not_stale "$t0b" "$t1b" "6b"
        fi
        systemctl stop ufw.service >/dev/null 2>&1 || true
    else
        assert 1 "6b injection: ufw.service could not be made active — FAILED_AUTHORITY_ABORT not induced"
    fi

    # ---- 6c DEGRADED -----------------------------------------------------
    # The critical core timer must be enabled AND active or the install
    # DEGRADEs (timers.go:68-80 + services/timers.go:98-100 + phases.go:736).
    sub "6c DEGRADED (critical core timer masked)"
    reset_to_absent
    # unit files must exist before masking is meaningful, so install first
    pkg_install "$CANDIDATE_DEB" "${WORKDIR}/L6c_base_install.txt" >/dev/null
    if [[ "$(statefield INSTALL_STATE)" != "COMMITTED" ]]; then
        assert 1 "6c: baseline install did not reach COMMITTED — cannot isolate DEGRADED"
    elif mask_unit "${CRITICAL_TIMERS[0]}"; then
        systemctl stop "${CRITICAL_TIMERS[0]}" >/dev/null 2>&1 || true
        assert 0 "6c injection: ${CRITICAL_TIMERS[0]} masked (reversible)"
        local out6c="${WORKDIR}/L6c_degraded.txt" t0c t1c rcc
        t0c="$(date -u +%s)"
        rcc="$(pkg_reinstall "$CANDIDATE_DEB" "$out6c")"
        t1c="$(date -u +%s)"
        snapshot "6c post"
        assert_eq "0" "$rcc" "6c: apt-get still reports success"
        assert_eq "1" "$(tok "$out6c" NFTBAN_PACKAGE_INSTALLER_EXIT)" \
            "6c: NFTBAN_PACKAGE_INSTALLER_EXIT (ExitDegraded, machine.go:217)"
        l6_expect_terminal "$out6c" "DEGRADED" "INSTALL_DEGRADED" "6c"
        l6_expect_current_not_stale "$t0c" "$t1c" "6c"
        # Informational only — the contract does not require the timer name in
        # FAILURE_REASON, so this is printed, never counted as an assertion.
        printf '  6c FAILURE_REASON = %s\n' "$(statefield FAILURE_REASON)"
        unmask_unit "${CRITICAL_TIMERS[0]}"
    else
        assert 1 "6c injection: could not mask ${CRITICAL_TIMERS[0]}"
    fi

    # restore a healthy baseline for L7
    reset_to_absent
    pkg_install "$CANDIDATE_DEB" "${WORKDIR}/L6_restore_install.txt" >/dev/null
    plant_operator_config
    assert_eq "COMMITTED" "$(statefield INSTALL_STATE)" "L6 teardown: healthy baseline restored for L7"
}

case_L7() {
    case_begin L7 "uninstall (apt-get remove — config preserved by policy)"
    if [[ "$(dpkg_status)" != "ii" ]]; then
        case_skip "L7 needs an installed package; dpkg status is $(dpkg_status)"
        return 0
    fi
    # Package-owned inventory + the maintainer scripts as shipped. The verifier
    # binary is preserved BEFORE removal so the post-removal stale-claim probe
    # can still run the shipped read-only mode.
    local inv="${WORKDIR}/L7_owned_files.txt" s
    dpkg -L "$PKG" 2>/dev/null | LC_ALL=C sort -u >"$inv"
    if [[ -x "$INSTALLER" ]]; then cp -f "$INSTALLER" "${WORKDIR}/nftban-installer.copy"; fi
    local scripts="${WORKDIR}/L7_scripts"
    rm -rf "$scripts"; mkdir -p "$scripts"
    dpkg-deb -e "$CANDIDATE_DEB" "$scripts" >/dev/null 2>&1 || true
    snapshot "L7 pre"

    local out="${WORKDIR}/L7_remove.txt" rc t0
    t0="$(date -u +%s)"
    rc="$(pkg_remove "$out")"
    snapshot "L7 post"

    assert_eq "0" "$rc" "apt-get remove exit"
    local st; st="$(dpkg_status)"
    if [[ "$st" == "rc" || "$st" == "absent" ]]; then
        assert 0 "dpkg status after remove = ${st} (config-files retained per policy)"
    else
        assert 1 "dpkg status after remove = ${st} (want 'rc')"
    fi

    # services stopped (prerm:51-106 stops; deprecated units also disabled 109-125)
    local u
    for u in "${DAEMON_UNITS[@]}"; do
        assert_eq "inactive" "$(systemctl is-active "$u" 2>/dev/null || echo inactive)" \
            "after remove: ${u} not active (prerm:105 deb-systemd-invoke stop)"
    done
    for u in "${CORE_TIMERS[@]}"; do
        assert_eq "inactive" "$(systemctl is-active "$u" 2>/dev/null || echo inactive)" \
            "after remove: ${u} not active"
    done
    # unit FILES removed with the payload (raw dpkg-deb build: no debhelper
    # enable/disable, build_nftban.sh:2372)
    local leftover_units
    leftover_units="$(find /usr/lib/systemd/system /lib/systemd/system -maxdepth 1 \
        \( -name 'nftban-*' -o -name 'nftband.*' \) 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "0" "$leftover_units" "after remove: no nftban unit files left under /usr/lib/systemd/system"

    # nftables tables deleted, NOT left as an empty drop-policy chain (postrm:215-217)
    assert_eq "absent" "$(nft_table_state ip nftban)"  "after remove: ip nftban table deleted (no drop-policy blackhole)"
    assert_eq "absent" "$(nft_table_state ip6 nftban)" "after remove: ip6 nftban table deleted"
    if grep -aq 'no longer protecting this system' "$out"; then
        assert 0 "postrm disclosed the documented uninstall firewall consequence (postrm:219-222)"
    else
        assert 1 "postrm did not print the documented uninstall firewall consequence"
    fi

    # runtime files per policy: /run/nftban removed only on purge (postrm:64),
    # so on remove /var/lib and /etc are RETAINED by design.
    assert_eq "present" "$([[ -d /etc/nftban ]] && echo present || echo absent)" \
        "after remove: /etc/nftban retained by policy (postrm:223)"
    assert_operator_config_preserved
    assert_eq "present" "$([[ -f "$STATE_FILE" ]] && echo present || echo absent)" \
        "after remove: install_state retained (postrm 'remove' branch never touches /var/lib/nftban)"

    # Item 2 must not run on the removal path.
    if grep -aqE 'NFTBAN_PACKAGE_(INSTALLER_EXIT|VERIFY_EXIT|POSTINSTALL_VERIFIED)=' "$out"; then
        assert 1 "removal transaction emitted Item 2 package tokens — verification interfered with uninstall"
    else
        assert 0 "removal transaction emitted NO Item 2 tokens — verification does not run on this path"
    fi
    for s in prerm postrm; do
        if [[ -f "${scripts}/${s}" ]] && grep -q -- '--verify-install-state' "${scripts}/${s}"; then
            assert 1 "${s} invokes --verify-install-state (must not: --not-before has no meaning on removal)"
        else
            assert 0 "${s} does not invoke --verify-install-state / --not-before"
        fi
    done
    # No stale postinstall verification presented as current: re-run the shipped
    # verifier read-only with this removal as the transaction start.
    assert_no_stale_success_claim "$t0" "L7"
    printf '  (owned-file inventory captured: %s entries -> %s)\n' \
        "$(wc -l <"$inv" | tr -d ' ')" "$inv"
}

# Runs the shipped verifier read-only against a NEW transaction start. A
# previously COMMITTED state must resolve to STALE_STATE, never to success.
assert_no_stale_success_claim() { # not_before_epoch label
    local t0="$1" label="$2" bin="${WORKDIR}/nftban-installer.copy"
    local nb out rc=0
    # Both early exits are INFORMATIONAL — they must never be counted as passes.
    if [[ ! -x "$bin" ]]; then
        printf '  %s: no preserved verifier binary — stale-claim probe not run\n' "$label"
        return 0
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        printf '  %s: no persisted state to misread — stale-claim probe not run\n' "$label"
        return 0
    fi
    nb="$(date -u -d "@${t0}" +'%Y-%m-%dT%H:%M:%S.000000000Z')"
    out="${WORKDIR}/${label}_stale_probe.txt"
    "$bin" --verify-install-state \
        --expected-version "$(cat "$PKG_VERSION_FILE" 2>/dev/null || echo "$CANDIDATE_VER")" \
        --not-before "$nb" --state-dir "$STATE_DIR" >"$out" 2>&1 || rc=$?
    local verdict verified
    verdict="$(tok "$out" NFTBAN_INSTALL_ATTEMPT_VERDICT)"
    verified="$(tok "$out" NFTBAN_INSTALL_VERIFIED)"
    assert_eq "NO" "$verified" "${label}: a prior COMMITTED is NOT readable as success for a later transaction"
    if [[ "$verdict" == "CURRENT_COMMITTED" ]]; then
        assert 1 "${label}: verdict CURRENT_COMMITTED against a later transaction start — stale state claimed as current"
    else
        assert 0 "${label}: verdict ${verdict:-<absent>} (non-success), verifier rc=${rc}"
    fi
}

case_L8() {
    case_begin L8 "reinstall after uninstall — preserved config must not look historically committed"
    if [[ "$(dpkg_status)" != "rc" ]]; then
        case_skip "L8 needs the 'rc' (removed, config-files) state left by L7; dpkg status is $(dpkg_status)"
        return 0
    fi
    local ts_before e_before
    ts_before="$(statefield INSTALL_TIMESTAMP)"
    e_before="$(epoch_of "$ts_before")"
    assert_eq "present" "$([[ -f "$STATE_FILE" ]] && echo present || echo absent)" \
        "precondition: a stale install_state survived the removal"
    snapshot "L8 pre"

    local out="${WORKDIR}/L8_reinstall_after_remove.txt" t0 t1 rc
    t0="$(date -u +%s)"
    rc="$(pkg_install "$CANDIDATE_DEB" "$out")"
    t1="$(date -u +%s)"
    snapshot "L8 post"

    assert_eq "0" "$rc" "apt-get install after remove exit"
    assert_dpkg_installed
    assert_verified_tokens "$out" "$CANDIDATE_VER"
    assert_eq "COMMITTED" "$(statefield INSTALL_STATE)" "persisted terminal state"
    assert_state_version_and_window "$CANDIDATE_VER" "$t0" "$t1"
    local e_after
    e_after="$(epoch_of "$(statefield INSTALL_TIMESTAMP)")"
    if [[ -n "$e_before" && -n "$e_after" && "$e_after" -gt "$e_before" ]]; then
        assert 0 "state timestamp is NEW (${ts_before} -> $(statefield INSTALL_TIMESTAMP)) — no stale reuse"
    else
        assert 1 "state timestamp not advanced past the pre-removal value (${ts_before} -> $(statefield INSTALL_TIMESTAMP))"
    fi
    assert_operator_config_preserved
    assert_runtime_healthy
    assert_validate_ok
}

case_L9() {
    case_begin L9 "purge — owned config/state/units removed, then clean install"
    if [[ "$(dpkg_status)" != "ii" && "$(dpkg_status)" != "rc" ]]; then
        case_skip "L9 needs an installed or removed-with-config package; dpkg status is $(dpkg_status)"
        return 0
    fi
    local inv="${WORKDIR}/L9_owned_files.txt"
    dpkg -L "$PKG" 2>/dev/null | LC_ALL=C sort -u >"$inv" || true
    # preserve the shipped verifier so L10's stale-claim probe can still run
    if [[ -x "$INSTALLER" ]]; then cp -f "$INSTALLER" "${WORKDIR}/nftban-installer.copy"; fi
    snapshot "L9 pre"

    local out="${WORKDIR}/L9_purge.txt" rc
    rc="$(pkg_purge "$out")"
    snapshot "L9 post-purge"

    assert_eq "0" "$rc" "apt-get purge exit"
    assert_eq "absent" "$(dpkg_status)" "dpkg database no longer knows the package"

    local d
    for d in "${PURGE_DIRS[@]}"; do
        assert_eq "absent" "$([[ -e "$d" ]] && echo present || echo absent)" \
            "purge removed ${d} (postrm:177-181)"
    done
    assert_eq "absent" "$([[ -f "$STATE_FILE" ]] && echo present || echo absent)" \
        "purge removed the persisted install_state"

    # units absent
    local leftover_units
    leftover_units="$(systemctl list-unit-files --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | grep -cE '^(nftban|nftband)' || true)"
    assert_eq "0" "$leftover_units" "no nftban unit files known to systemd after purge"

    # no orphan package-owned files (only nftban-scoped paths are asserted; shared
    # system directories such as /usr/lib are not owned exclusively by this package)
    local orphans=0 p
    while IFS= read -r p; do
        case "$p" in
            *nftban*)
                if [[ -e "$p" ]]; then
                    orphans=$((orphans + 1))
                    printf '      orphan: %s\n' "$p"
                fi
                ;;
            *) : ;;
        esac
    done <"$inv"
    assert_eq "0" "$orphans" "no orphan nftban-scoped package-owned files after purge"

    # postrm STEP 1 backup is a documented purge side effect — record it
    local backups
    backups="$(find /var/tmp -maxdepth 1 -name 'nftban-config-backup-*' 2>/dev/null | wc -l | tr -d ' ')"
    printf '  purge config backups under /var/tmp: %s (documented, postrm:50-59)\n' "$backups"

    # fresh install after purge must reach a clean CURRENT_COMMITTED
    local out2="${WORKDIR}/L9_fresh_after_purge.txt" t0 t1 rc2
    t0="$(date -u +%s)"
    rc2="$(pkg_install "$CANDIDATE_DEB" "$out2")"
    t1="$(date -u +%s)"
    snapshot "L9 post-fresh-install"
    assert_eq "0" "$rc2" "fresh install after purge exit"
    assert_dpkg_installed
    assert_verified_tokens "$out2" "$CANDIDATE_VER"
    assert_eq "COMMITTED" "$(statefield INSTALL_STATE)" "post-purge fresh install persisted state"
    assert_eq "install" "$(statefield INSTALL_MODE)" "post-purge install is mode=install, not upgrade"
    assert_state_version_and_window "$CANDIDATE_VER" "$t0" "$t1"
    assert_runtime_healthy
    assert_validate_ok
}

case_L10() {
    case_begin L10 "interrupted/failed uninstall protection"
    if [[ "$(dpkg_status)" != "ii" ]]; then
        case_skip "L10 needs an installed package; dpkg status is $(dpkg_status)"
        return 0
    fi
    if ! command -v chattr >/dev/null 2>&1; then
        case_skip "chattr unavailable — no controlled way to make a removal fail; NOT_YET_VERIFIED"
        return 0
    fi
    # Controlled, reversible failure: an immutable package-owned file makes
    # dpkg's unlink fail during removal. preinst only strips +i from
    # nft_schema.sh and nftban.conf (preinst:78-89), so VERSION_DATE stays
    # immutable through the transaction.
    local victim="/usr/lib/nftban/VERSION_DATE"
    if [[ ! -f "$victim" ]]; then victim="$PKG_VERSION_FILE"; fi
    if [[ ! -f "$victim" ]]; then
        case_skip "no package-owned file available to make immutable"
        return 0
    fi
    if [[ -x "$INSTALLER" ]]; then cp -f "$INSTALLER" "${WORKDIR}/nftban-installer.copy"; fi
    local ts_before
    ts_before="$(statefield INSTALL_TIMESTAMP)"
    if ! mark_immutable "$victim"; then
        case_skip "chattr +i on ${victim} refused — controlled uninstall failure unavailable; NOT_YET_VERIFIED"
        return 0
    fi
    assert 0 "controlled injection: ${victim} made immutable so removal cannot complete"
    snapshot "L10 pre"

    local out="${WORKDIR}/L10_failed_remove.txt" rc t0
    t0="$(date -u +%s)"
    rc="$(pkg_remove "$out")"
    snapshot "L10 post"

    if [[ "$rc" -ne 0 ]] || grep -aqE 'dpkg: error|error processing package' "$out"; then
        assert 0 "removal genuinely failed (apt rc=${rc}) — the interrupted-uninstall condition was reached"
    else
        assert 1 "removal succeeded despite the immutable file — the failure was not induced (assertions below prove nothing)"
    fi

    # 1. No install-verification tokens may be produced by a failing uninstall.
    if grep -aqE 'NFTBAN_PACKAGE_(INSTALLER_EXIT|VERIFY_EXIT|POSTINSTALL_VERIFIED)=|NFTBAN_INSTALL_VERIFIED=' "$out"; then
        assert 1 "failed uninstall emitted install-verification tokens — Item 2 converted an uninstall failure into install truth"
    else
        assert 0 "failed uninstall emitted NO install-verification tokens"
    fi
    # 2. A previous COMMITTED must not read as evidence of removal success.
    assert_no_stale_success_claim "$t0" "L10"
    if [[ -f "$STATE_FILE" ]]; then
        assert_eq "$ts_before" "$(statefield INSTALL_TIMESTAMP)" \
            "install_state untouched by the failed removal"
    else
        assert 0 "install_state absent after the failed removal (recorded)"
    fi

    # recover the host
    unmark_immutable "$victim"
    reset_to_absent
    assert_eq "absent" "$(dpkg_status)" "L10 teardown: host recovered to ABSENT"
}

# =============================================================================
# main
# =============================================================================
usage() {
    cat <<'EOF'
usage: lifecycle_deb_matrix.sh <candidate.deb> <prior-v1.227.0.deb>

  Runs AS ROOT on a DISPOSABLE Ubuntu 24.04 VM. Destructive.

  env:
    NFTBAN_LIFECYCLE_CASES="L1 L4 L7"   run a subset (default: all)
EOF
}

case_L11() {
    case_begin L11 "no-installer path — corrupt package, boundary must still answer"
    # v1.228.0: the whole Item 2 block is nested inside `if [ -x "$NFTBAN_INSTALLER" ]`
    # (postinst:348). Before the fix, the else branch printed human text and emitted NO
    # tokens: apt reports success, the firewall never comes up, and the transaction
    # carries no machine-readable result at all — indistinguishable from a pre-Item-2
    # package. Absence is not a verdict.
    #
    # Controlled injection: repack the SAME candidate .deb with the installer binary
    # non-executable. `[ -x ]` is then false at postinst time. This is a faithful
    # corrupt-package simulation, fully reversible by reinstalling the real package,
    # and it needs no kill and no hand-edited scriptlet.
    if [[ "$(dpkg_status)" != "ii" ]]; then
        reset_to_absent
        local pre="${WORKDIR}/L11_pre_install.txt"
        pkg_install "$CANDIDATE_DEB" "$pre" >/dev/null
    fi
    if [[ "$(dpkg_status)" != "ii" ]]; then
        case_skip "L11 needs a healthy installed package as the prior state"
        return 0
    fi
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        case_skip "dpkg-deb unavailable — cannot repack a corrupt candidate; NOT_YET_VERIFIED"
        return 0
    fi

    local ts_before state_before
    ts_before="$(statefield INSTALL_TIMESTAMP)"
    state_before="$(statefield INSTALL_STATE)"
    snapshot "L11 pre"

    local ext="${WORKDIR}/L11_extract" bad="${WORKDIR}/L11_noexec.deb"
    rm -rf "$ext"; mkdir -p "$ext"
    if ! dpkg-deb -R "$CANDIDATE_DEB" "$ext" >/dev/null 2>&1; then
        case_skip "dpkg-deb -R failed on the candidate — cannot build the corrupt variant"
        return 0
    fi
    if [[ ! -e "${ext}${INSTALLER}" ]]; then
        assert 1 "candidate package does not ship ${INSTALLER} — the guard this case tests cannot be reached"
        return 0
    fi
    chmod 0644 "${ext}${INSTALLER}"
    if [[ -x "${ext}${INSTALLER}" ]]; then
        case_skip "could not make the payload installer non-executable"
        return 0
    fi
    assert 0 "controlled injection: candidate repacked with a non-executable ${INSTALLER}"
    if ! dpkg-deb -b "$ext" "$bad" >/dev/null 2>&1; then
        case_skip "dpkg-deb -b failed — corrupt variant unavailable"
        return 0
    fi

    local out="${WORKDIR}/L11_corrupt_install.txt" rc
    rc="$(pkg_reinstall "$bad" "$out")"
    snapshot "L11 post"

    # The package manager still reports mechanical completion ...
    assert_eq "0" "$rc" "apt-get reports success (mechanical completion over a firewall-less host)"
    # ... and the installer genuinely never ran.
    if [[ -x "$INSTALLER" ]]; then
        assert 1 "installer is still executable — the injection did not take, assertions below prove nothing"
    else
        assert 0 "installer on disk is non-executable — the else branch was genuinely reached"
    fi

    # THE POINT: the boundary answers instead of staying silent.
    assert_eq "127" "$(tok "$out" NFTBAN_PACKAGE_INSTALLER_EXIT)"       "NFTBAN_PACKAGE_INSTALLER_EXIT"
    assert_eq "127" "$(tok "$out" NFTBAN_PACKAGE_VERIFY_EXIT)"          "NFTBAN_PACKAGE_VERIFY_EXIT"
    assert_eq "NO"  "$(tok "$out" NFTBAN_PACKAGE_POSTINSTALL_VERIFIED)" "NFTBAN_PACKAGE_POSTINSTALL_VERIFIED"

    # No canonical state token may appear: the verifier never ran, so there is no
    # state interpretation to report. Emitting one here would be a bash-side verdict.
    local leaked=""
    local k
    for k in NFTBAN_INSTALL_ATTEMPT_VERDICT NFTBAN_INSTALL_VERIFIED NFTBAN_PERSISTED_INSTALL_STATE; do
        [[ -n "$(tok "$out" "$k")" ]] && leaked="${leaked} ${k}"
    done
    if [[ -n "$leaked" ]]; then
        assert 1 "canonical state token(s) emitted with no verifier run:${leaked}"
    else
        assert 0 "no canonical state token emitted — the installer never ran, so no state was interpreted"
    fi

    # Historical state must be untouched by a transaction that never began.
    if [[ "$(statefield INSTALL_TIMESTAMP)" == "$ts_before" && "$(statefield INSTALL_STATE)" == "$state_before" ]]; then
        assert 0 "install_state untouched — still ${state_before} at ${ts_before}"
    else
        assert 1 "install_state mutated by a transaction whose installer never executed"
    fi

    # Restore a healthy host so this case cannot poison anything downstream.
    local fix="${WORKDIR}/L11_restore.txt"
    pkg_reinstall "$CANDIDATE_DEB" "$fix" >/dev/null
    if [[ -x "$INSTALLER" ]]; then
        assert 0 "host restored — real candidate reinstalled, installer executable again"
    else
        assert 1 "host NOT restored — installer still non-executable after reinstall"
    fi
}

main() {
    if [[ $# -lt 2 ]]; then usage; exit 2; fi
    CANDIDATE_DEB="$(readlink -f "$1")"
    PRIOR_DEB="$(readlink -f "$2")"

    if [[ "$(id -u)" -ne 0 ]]; then
        log "ERROR: must run as root"; exit 2
    fi

    # SINGLE INSTANCE, enforced rather than assumed. This harness purges,
    # reinstalls and masks units; two concurrent runs mutate the same host and
    # interleave into the same log, so every assertion from both becomes void
    # while still printing as PASS. That has already happened once: a name-based
    # kill silently matched nothing (the script name exceeds pgrep's 15-char
    # comm limit) and a second run was started over the first.
    exec 9>"/var/lock/nftban-lifecycle-matrix.lock"
    if ! flock -n 9; then
        log "ERROR: another lifecycle matrix run holds /var/lock/nftban-lifecycle-matrix.lock."
        log "       This harness is destructive; refusing to run a second copy against the same host."
        exit 2
    fi
    local missing=() b
    for b in dpkg dpkg-deb dpkg-query apt-get systemctl nft flock date find awk grep sed; do
        command -v "$b" >/dev/null 2>&1 || missing+=("$b")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log "ERROR: missing required binaries: ${missing[*]}"; exit 2
    fi
    for b in "$CANDIDATE_DEB" "$PRIOR_DEB"; do
        [[ -f "$b" ]] || { log "ERROR: not a file: $b"; exit 2; }
    done

    WORKDIR="$(mktemp -d /var/tmp/nftban-lifecycle-XXXXXX)"
    trap on_exit EXIT

    CANDIDATE_VER="$(dpkg-deb -f "$CANDIDATE_DEB" Version)"
    PRIOR_VER="$(dpkg-deb -f "$PRIOR_DEB" Version)"
    local cand_pkg prior_pkg
    cand_pkg="$(dpkg-deb -f "$CANDIDATE_DEB" Package)"
    prior_pkg="$(dpkg-deb -f "$PRIOR_DEB" Package)"

    hdr "NFTBan v1.228.0 Item 2 — DEB lifecycle matrix"
    log "candidate : ${CANDIDATE_DEB} (${cand_pkg} ${CANDIDATE_VER})"
    log "prior     : ${PRIOR_DEB} (${prior_pkg} ${PRIOR_VER})"
    log "host      : $( (. /etc/os-release && printf '%s %s' "${ID:-?}" "${VERSION_ID:-?}") 2>/dev/null || echo unknown)"
    log "kernel    : $(uname -r)"
    log "workdir   : ${WORKDIR}"

    CASE_ID="PRE"
    CASE_RESULT["PRE"]="PASS"
    assert_eq "$PKG" "$cand_pkg"  "candidate package name (control:13)"
    assert_eq "$PKG" "$prior_pkg" "prior package name"
    if [[ "$CANDIDATE_VER" == "$PRIOR_VER" ]]; then
        assert 1 "candidate and prior versions differ (both ${CANDIDATE_VER}) — L3 cannot be a real upgrade"
    else
        assert 0 "candidate ${CANDIDATE_VER} differs from prior ${PRIOR_VER}"
    fi

    # Baseline: UFW must be inactive or every install would classify as ABORT
    # (extfw/detect.go:178-184 + authority/classify.go:157-164). Recorded, not hidden.
    local ufw0
    ufw0="$(systemctl is-active ufw.service 2>/dev/null || true)"
    log "baseline ufw.service = ${ufw0}"
    if [[ "$ufw0" == "active" ]]; then
        log "baseline: stopping+disabling ufw.service so the happy-path cases are not pre-aborted"
        systemctl stop ufw.service >/dev/null 2>&1 || true
        systemctl disable ufw.service >/dev/null 2>&1 || true
    fi
    local ufw_now
    # `systemctl is-active` exits 3 when inactive, so a `|| echo inactive` fallback
    # fires IN ADDITION to the command's own output and the comparison sees two
    # lines. Take the first line and treat empty (unit absent) as inactive.
    # `|| true` is load-bearing: is-active exits 3 when inactive and this script
    # runs under `set -o pipefail`, so without it the assignment aborts the run.
    ufw_now="$(systemctl is-active ufw.service 2>/dev/null | head -1 || true)"
    [[ -n "$ufw_now" ]] || ufw_now="inactive"
    assert_eq "inactive" "$ufw_now" "baseline: ufw.service inactive"

    local selected="${NFTBAN_LIFECYCLE_CASES:-}"
    local c
    for c in "${CASE_ORDER[@]}"; do
        if [[ -n "$selected" ]] && [[ " $selected " != *" $c "* ]]; then
            CASE_ID="$c"; CASE_RESULT["$c"]="SKIP"
            CASE_NOTE["$c"]="not selected via NFTBAN_LIFECYCLE_CASES"
            continue
        fi
        "case_${c}"
    done

    # -------------------------------------------------------------------------
    hdr "MACHINE-READABLE SUMMARY"
    local skipped=0 failed=0
    printf 'NFTBAN_MATRIX_CANDIDATE_VERSION=%s\n' "$CANDIDATE_VER"
    printf 'NFTBAN_MATRIX_PRIOR_VERSION=%s\n' "$PRIOR_VER"
    for c in "${CASE_ORDER[@]}"; do
        local r="${CASE_RESULT[$c]:-SKIP}"
        printf 'NFTBAN_MATRIX_RESULT_%s=%s\n' "$c" "$r"
        if [[ -n "${CASE_NOTE[$c]:-}" ]]; then
            printf 'NFTBAN_MATRIX_NOTE_%s=%s\n' "$c" "${CASE_NOTE[$c]}"
        fi
        if [[ "$r" == "SKIP" ]]; then skipped=$((skipped + 1)); fi
        if [[ "$r" == "FAIL" ]]; then failed=$((failed + 1)); fi
    done
    printf 'NFTBAN_MATRIX_ASSERTIONS_PASS=%d\n' "$PASS_N"
    printf 'NFTBAN_MATRIX_ASSERTIONS_FAIL=%d\n' "$FAIL_N"
    printf 'NFTBAN_MATRIX_CASES_FAILED=%d\n'   "$failed"
    printf 'NFTBAN_MATRIX_CASES_SKIPPED=%d\n'  "$skipped"
    printf 'NFTBAN_MATRIX_ARTIFACTS=%s\n'      "$WORKDIR"

    if [[ "$FAIL_N" -ne 0 || "$failed" -ne 0 ]]; then
        printf 'NFTBAN_MATRIX_VERDICT=FAIL\n'
        log "RESULT: FAIL — ${FAIL_N} failed assertions across ${failed} case(s)."
        return 1
    fi
    if [[ "$skipped" -ne 0 ]]; then
        # A skipped case is NOT a pass. Refuse to report success.
        printf 'NFTBAN_MATRIX_VERDICT=INCOMPLETE\n'
        log "RESULT: INCOMPLETE — ${skipped} case(s) were skipped; this run does NOT establish"
        log "        the v1.228.0 Item 2 DEB lifecycle contract. Resolve every SKIP and re-run."
        return 2
    fi
    printf 'NFTBAN_MATRIX_VERDICT=PASS\n'
    log "RESULT: PASS — all ${#CASE_ORDER[@]} cases executed, ${PASS_N} assertions passed."
    return 0
}

main "$@"
