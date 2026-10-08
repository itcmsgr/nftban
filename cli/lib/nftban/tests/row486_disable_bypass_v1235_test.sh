#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.235 row 486: disable/enable contract + emergency boot bypass
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="row486_disable_bypass_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="BEHAVIORAL regression for v1.235 row 486 (contract NFTBAN_ROADMAP/CLI_AUDIT_V1235/ROW486_BEHAVIOUR_CONTRACT_V1235.md sections 2-3). Drives the REAL install/helpers/nftban-boot-early.sh (bypass / bypass-guard / normal modes), the REAL lib/boot_projection.sh state reader and inert body, and the REAL lib/service_control.sh nftban_disable_all / nftban_enable_all with stubbed systemctl, nft, nftban, mount, restorecon and ss on PATH in a sandbox. Asserts: the bypass makes the projection inert before nftables.service by bind mount, rename-swap or create, and the backstop deletes ONLY ip/ip6 nftban and reports it as a divergence; a disabled NFTBan never loads at boot (normal mode); disable writes the unit record once, does not stop nftban-firewall-init.service (its ExecStop deletes the tables; C7b, audit H5), never touches nftables.service or suricata.service, never unmasks, keeps the boot guards armed, publishes the inert projection and with --flush-rules DELETES (never flush-only) only the NFTBan tables; enable switches the stored choice ON before the rebuild, never enables nftables.service, keeps operator choices (module switched off, core unit recorded disabled, masked unit), forces no GeoIP setting, never calls `nftban login enable`, refuses under the bypass and under a failed commit-confirm rollback while enabled, and clears that state when NFTBan was disabled for recovery. Static census: every NFTBan unit carries both the bypass and the failed-rollback conditions; the early units add no ordering to nftables.service; every firewall dispatcher verb that loads or replaces rules (aliases included) calls both guards (E5, audit H4); the upgrade scriptlet reload is gated by the master switch (E6, audit H3); both scriptlet switch lines are executed for on / off / unreadable (E7); no operator text advises `nft flush ruleset` (E8, audit K14). K2 (owner 2026-10-08): one NFTBAN_ENABLED contract: both shell readers answer the shared case table (E9) with byte-identical code (E10); INVALID refuses disable/enable before any change (E11/E12) and is null in status JSON (E13); at boot INVALID leaves the last published projection, off is understood, and the bypass is never blocked (K2a-c)."
# meta:input="None (self-contained sandbox; stubbed system tools)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,mktemp,cmp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,grep,sed,mktemp,cmp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="row486_disable_bypass_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="lifecycle"
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
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIBDIR="$REPO_ROOT/cli/lib/nftban"
EARLY="$REPO_ROOT/install/helpers/nftban-boot-early.sh"
BOOTPROJ="$LIBDIR/lib/boot_projection.sh"
SVC="$LIBDIR/lib/service_control.sh"
INERT_SHIPPED="$LIBDIR/data/nftban-boot-inert.nft"
UNITDIR="$REPO_ROOT/install/systemd"
MARKER='# NFTBAN-PROJECTION-STATE: inert'

pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
ko(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
absent(){ echo "  [FAIL] $1 (FAIL-BY-ABSENCE: $2)"; fail=$((fail+1)); }
has_line(){ grep -qxF -- "$2" "$1" 2>/dev/null; }
has(){ grep -qF -- "$2" "$1" 2>/dev/null; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
STUB="$SB/bin"; mkdir -p "$STUB"

# ---------------------------------------------------------------------------
# Stubs. Every call is logged to $SB/calls.log as "<tool> <args>".
# ---------------------------------------------------------------------------
cat > "$STUB/mount" <<'EOF'
#!/usr/bin/env bash
echo "mount $*" >> "$SBX/calls.log"
[[ -f "$SBX/mount_fail" ]] && exit 32
exit 0
EOF
cat > "$STUB/restorecon" <<'EOF'
#!/usr/bin/env bash
echo "restorecon $*" >> "$SBX/calls.log"; exit 0
EOF
cat > "$STUB/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# nft: list tables from $SBX/nft_tables; delete table removes the line; list ruleset
# prints a minimal ruleset; -c always ok; -f logs and returns $SBX/nft_f_rc.
cat > "$STUB/nft" <<'EOF'
#!/usr/bin/env bash
echo "nft $*" >> "$SBX/calls.log"
case "$*" in
    "list tables")   [[ -f "$SBX/nft_list_fail" ]] && { echo "netlink: Operation not permitted" >&2; exit 1; }
                     cat "$SBX/nft_tables" 2>/dev/null; exit 0 ;;
    "delete table "*) [[ -f "$SBX/nft_delete_fail" ]] && exit 1
                     a="$*"; t="table ${a#delete table }"
                     grep -vxF -- "$t" "$SBX/nft_tables" > "$SBX/nft_tables.n" 2>/dev/null || true
                     mv -f "$SBX/nft_tables.n" "$SBX/nft_tables"; exit 0 ;;
    "list ruleset")  printf 'table ip nftban {\n\tchain input {\n\t\ttype filter hook input priority 0; policy drop;\n\t}\n}\n'; exit 0 ;;
    "-c -f "*)       exit 0 ;;
    *)               exit 0 ;;
esac
EOF
# nftban CLI: log; record the stored switch at the moment of a rebuild.
cat > "$STUB/nftban" <<'EOF'
#!/usr/bin/env bash
echo "nftban $*" >> "$SBX/calls.log"
if [[ "$*" == "firewall rebuild"* ]]; then
    v=$(sed -n 's/^NFTBAN_ENABLED=//p' "$SBX/etc/conf.d/services.conf.local" 2>/dev/null)
    echo "rebuild-saw-switch ${v//\"/}" >> "$SBX/calls.log"
fi
# K5 arm: a render-boot refused by the D10 guard (as the real dispatcher does).
if [[ "$*" == "firewall render-boot"* && -e "$SBX/refuse_render" ]]; then
    echo "REFUSED: firewall render-boot: a commit-confirm rollback FAILED (D10 hold)" >&2
    exit 1
fi
exit 0
EOF
# systemctl: unit states in $SBX/units ("<unit> <is-enabled>"), active set in $SBX/active.
cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SBX/calls.log"
args=(); for a in "$@"; do case "$a" in --*) ;; *) args+=("$a") ;; esac; done
verb="${args[0]:-}"; u="${args[1]:-}"
state_of(){ awk -v u="$1" '$1==u{print $2; f=1} END{if(!f) exit 1}' "$SBX/units"; }
set_state(){ awk -v u="$1" -v s="$2" '$1==u{$2=s} {print}' "$SBX/units" > "$SBX/units.n" && mv -f "$SBX/units.n" "$SBX/units"; }
case "$verb" in
    list-unit-files)
        # Filter like systemd: each remaining arg is an exact name or a glob pattern.
        pats=("${args[@]:1}")
        if [[ ${#pats[@]} -eq 0 ]]; then cat "$SBX/units"; else
            while read -r n s; do
                for p in "${pats[@]}"; do
                    # shellcheck disable=SC2053
                    if [[ "$n" == $p ]]; then echo "$n $s"; break; fi
                done
            done < "$SBX/units"
        fi ;;
    is-enabled) s=$(state_of "$u") || { echo "not-found"; exit 4; }; echo "$s"; [[ "$s" == enabled ]] ;;
    is-active)  if grep -qxF -- "$u" "$SBX/active" 2>/dev/null; then echo active; exit 0; fi; echo inactive; exit 3 ;;
    enable)  s=$(state_of "$u") || exit 1; [[ "$s" == masked ]] && exit 1; set_state "$u" enabled ;;
    disable) s=$(state_of "$u") || exit 1; [[ "$s" == masked ]] || set_state "$u" disabled ;;
    start)   grep -qxF -- "$u" "$SBX/active" 2>/dev/null || echo "$u" >> "$SBX/active" ;;
    stop)    grep -vxF -- "$u" "$SBX/active" > "$SBX/active.n" 2>/dev/null || true; mv -f "$SBX/active.n" "$SBX/active" ;;
    list-timers) echo "Mon 2026-10-06 nftban-maintenance.timer nftban-maintenance.service" ;;
esac
exit 0
EOF
chmod +x "$STUB"/*

fresh(){  # new sandbox state
    rm -rf "${SB:?}/etc" "${SB:?}/data" "${SB:?}/run" "${SB:?}/calls.log" "${SB:?}"/mount_fail "${SB:?}"/nft_* "${SB:?}/units" "${SB:?}/active"
    mkdir -p "$SB/etc/conf.d" "$SB/etc/generated" "$SB/etc/ports.d" "$SB/data/state" "$SB/data/geoip" "$SB/run"
    : > "$SB/calls.log"; : > "$SB/active"
    printf 'table ip nftban\ntable ip6 nftban\ntable inet labforeign\n' > "$SB/nft_tables"
    echo "22/T/I" > "$SB/etc/ports.d/00-ssh.conf"
    : > "$SB/data/geoip/dbip-country-lite.mmdb"
    : > "$SB/etc/nftban.conf"
}
ACTIVE_PROJ=$'#!/usr/sbin/nft -f\n# NFTBAN GENERATED BOOT PROJECTION\ntable ip nftban {\n}\n'

# ===========================================================================
echo "==============================================="
echo "v1.235 row 486: disable/enable contract + emergency bypass"
echo "==============================================="

# ---------------------------------------------------------------- A. early boot helper
echo "[A] nftban-boot-early.sh"
if [[ ! -f "$EARLY" ]]; then
    absent "A0 early-boot helper" "install/helpers/nftban-boot-early.sh missing"
else
    early(){  # mode
        local rc=0
        env -i PATH="$STUB:/usr/bin:/bin" SBX="$SB" \
            NFTBAN_BOOT_PROJECTION="$SB/etc/generated/nftban-boot.nft" \
            NFTBAN_BOOT_INERT="${INERT_SRC:-$INERT_SHIPPED}" \
            NFTBAN_BOOT_STATE_DIR="$SB/run" \
            NFTBAN_SERVICES_CONF="$SB/etc/conf.d/services.conf" \
            bash "$EARLY" "$1" > "$SB/early.out" 2>&1 || rc=$?
        return "$rc"
    }
    st(){ sed -n "s/^$1=//p" "$SB/run/boot-bypass.state" 2>/dev/null; }
    P="$SB/etc/generated/nftban-boot.nft"

    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"
    early bypass || true
    if [[ "$(st outcome)" == "primary" ]] && has "$SB/calls.log" "mount --bind"; then ok "A1 bypass: bind mount -> outcome=primary"
    else ko "A1 bypass primary (outcome=$(st outcome))"; fi

    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"; : > "$SB/mount_fail"
    early bypass || true
    if [[ "$(st outcome)" == "fallback-rename" ]] && has_line "$P" "$MARKER" && has "$P.bypassed" "table ip nftban"; then
        ok "A2 bind fails -> rename-swap: real projection saved as .bypassed, inert in place"
    else ko "A2 rename-swap fallback (outcome=$(st outcome))"; fi

    fresh; cp "$INERT_SHIPPED" "$P"; : > "$SB/mount_fail"
    early bypass || true
    if [[ "$(st outcome)" == "fallback-rename" ]] && has "$SB/run/boot-bypass.state" "already inert" && [[ ! -e "$P.bypassed" ]]; then
        ok "A3 projection already inert -> guarantee holds, nothing swapped"
    else ko "A3 already-inert path (outcome=$(st outcome))"; fi

    fresh
    early bypass || true
    if [[ "$(st outcome)" == "created-inert" ]] && has_line "$P" "$MARKER"; then ok "A4 projection missing -> inert file created"
    else ko "A4 created-inert (outcome=$(st outcome))"; fi

    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"; : > "$SB/mount_fail"
    INERT_SRC="$SB/does-not-exist.nft" early bypass || true
    if [[ "$(st outcome)" == "fallback-rename" ]] && has_line "$P" "$MARKER" && ! has "$P" "table ip nftban"; then
        ok "A5 shipped inert file missing + bind fails -> built-in inert body still written"
    else ko "A5 built-in inert body (outcome=$(st outcome))"; fi

    fresh
    early bypass-guard || true
    if [[ "$(st outcome)" == "backstop-removed" ]] && has "$SB/calls.log" "nft delete table ip nftban" \
       && has "$SB/calls.log" "nft delete table ip6 nftban" && ! has "$SB/calls.log" "labforeign" \
       && has_line "$SB/nft_tables" "table inet labforeign"; then
        ok "A6 backstop: deletes ONLY ip/ip6 nftban (foreign kept), outcome=backstop-removed"
    else ko "A6 backstop removal (outcome=$(st outcome))"; fi

    fresh; : > "$SB/nft_delete_fail"
    early bypass-guard || true
    [[ "$(st outcome)" == "backstop-failed" ]] && ok "A7 backstop delete fails -> backstop-failed" || ko "A7 backstop-failed (outcome=$(st outcome))"

    fresh; : > "$SB/nft_list_fail"
    early bypass-guard || true
    [[ "$(st outcome)" == "backstop-unknown" ]] && ok "A8 nft list fails -> backstop-unknown" || ko "A8 backstop-unknown (outcome=$(st outcome))"

    fresh; printf 'table inet labforeign\n' > "$SB/nft_tables"
    early bypass-guard || true
    if [[ ! -e "$SB/run/boot-bypass.state" ]] && ! has "$SB/calls.log" "nft delete"; then ok "A9 no NFTBan table -> no state change, nothing deleted"
    else ko "A9 clean bypass-guard"; fi

    fresh; cp "$INERT_SHIPPED" "$P"; printf '%s' "$ACTIVE_PROJ" > "$P.bypassed"
    early normal || true
    if has "$P" "table ip nftban" && [[ ! -e "$P.bypassed" ]]; then ok "A10 normal boot restores the projection saved by a bypass boot"
    else ko "A10 normal restore"; fi

    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"
    echo 'NFTBAN_ENABLED="true"' > "$SB/etc/conf.d/services.conf"
    echo 'NFTBAN_ENABLED="false"' > "$SB/etc/conf.d/services.conf.local"
    early normal || true
    if has_line "$P" "$MARKER"; then ok "A11 normal boot: stored switch OFF (.local wins) -> projection made inert"
    else ko "A11 disabled-at-boot enforcement"; fi

    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"
    echo 'NFTBAN_ENABLED="false"' > "$SB/etc/conf.d/services.conf"
    echo 'NFTBAN_ENABLED=true' > "$SB/etc/conf.d/services.conf.local"
    early normal || true
    if has "$P" "table ip nftban" && ! has_line "$P" "$MARKER"; then ok "A12 normal boot: stored switch ON -> projection untouched"
    else ko "A12 enabled projection untouched"; fi
    # K2 (owner 2026-10-08): ONE NFTBAN_ENABLED contract at boot. INVALID changes nothing (the last
    # published projection loads); "off" (not only "false") is understood; the bypass is never
    # blocked by an invalid value.
    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"; mkdir -p "$SB/etc/conf.d"; printf 'NFTBAN_ENABLED=maybe\n' > "$SB/etc/conf.d/services.conf"
    early normal || true
    if [[ "$(cat "$P")" == "$ACTIVE_PROJ" ]] && has "$SB/early.out" "INVALID"; then ok "K2a boot (normal), NFTBAN_ENABLED=maybe -> projection left as last published, warning logged"
    else ko "K2a boot normal with an invalid value (projection changed or no warning)"; fi
    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"; mkdir -p "$SB/etc/conf.d"; printf 'NFTBAN_ENABLED=off\n' > "$SB/etc/conf.d/services.conf"
    early normal || true
    if has_line "$P" "$MARKER"; then ok "K2b boot (normal), NFTBAN_ENABLED=off -> projection made inert (off is OFF, not only 'false')"
    else ko "K2b boot normal with off (not made inert)"; fi
    fresh; printf '%s' "$ACTIVE_PROJ" > "$P"; mkdir -p "$SB/etc/conf.d"; printf 'NFTBAN_ENABLED=maybe\n' > "$SB/etc/conf.d/services.conf"
    early bypass || true
    if [[ "$(st outcome)" == "primary" ]]; then ok "K2c boot bypass with NFTBAN_ENABLED=maybe -> the bypass still acts (outcome=primary)"
    else ko "K2c bypass blocked by an invalid value (outcome=$(st outcome))"; fi
fi

# ---------------------------------------------------------------- B. projection library
echo "[B] lib/boot_projection.sh"
if ! grep -q '^nftban_boot_projection_state()' "$BOOTPROJ" 2>/dev/null; then
    absent "B0 nftban_boot_projection_state" "function missing"
else
    bp(){ env -i PATH="/usr/bin:/bin" bash -c 'set -Eeuo pipefail; source "$1"; shift; "$@"' _ "$BOOTPROJ" "$@" 2>/dev/null; }
    fresh; P="$SB/etc/generated/nftban-boot.nft"
    printf '%s' "$ACTIVE_PROJ" > "$P"; s1=$(bp nftban_boot_projection_state "$P")
    cp "$INERT_SHIPPED" "$P"; s2=$(bp nftban_boot_projection_state "$P")
    s3=$(bp nftban_boot_projection_state "$SB/nope.nft")
    printf '# only a comment\n' > "$P"; s4=$(bp nftban_boot_projection_state "$P")
    if [[ "$s1/$s2/$s3/$s4" == "active/inert/missing/unknown" ]]; then ok "B1 state reader: active/inert/missing/unknown"
    else ko "B1 state reader ($s1/$s2/$s3/$s4)"; fi
    bp bash -c 'source "$0"; { nftban_boot_projection_inert_body | sed -n 1p; nftban_boot_projection_header; nftban_boot_projection_inert_body | sed -n "2,\$p"; }' "$BOOTPROJ" > "$SB/inert.gen" || true
    if cmp -s "$SB/inert.gen" "$INERT_SHIPPED"; then ok "B2 shipped inert file is byte-identical to the publisher's inert output"
    else ko "B2 shipped inert file differs from the publisher output"; fi
fi

# ---------------------------------------------------------------- C. disable / enable
echo "[C] lib/service_control.sh disable/enable"
UNITS_BASE=$'nftband.service enabled\nnftband.socket enabled\nnftban-maintenance.timer enabled\nnftban-watchdog.timer enabled\nnftban-health.timer enabled\nnftban-core-geoip.timer enabled\nnftban-botscan.timer enabled\nnftban-queue.timer enabled\nnftban-tunnel.timer masked\nnftban-boot-bypass.service enabled\nnftban-boot-bypass-guard.service enabled\nnftban-boot-normal.service enabled\nnftban-commit-confirm-boot.service enabled\nnftables.service enabled\nsuricata.service enabled'
svc(){  # snippet; runs the REAL library in a fresh shell under strict mode
    local rc=0
    env -i PATH="$STUB:/usr/bin:/bin" SBX="$SB" HOME="$SB" \
        NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_DATA_DIR="$SB/data" NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_RUN_DIR="$SB/run" \
        EUID_OVERRIDE=0 \
        bash -c 'set -Eeuo pipefail; source "$1"; shift; eval "$1"' _ "$SVC" "$1" > "$SB/svc.out" 2>&1 || rc=$?
    return "$rc"
}
rec="$SB/data/state/disable-units.state"
# EUID is read-only and the subjects refuse unless root. The runner is unprivileged
# (uid 65534 in the lab, CI user in CI), so ONLY the privilege gate is neutralised:
# both functions are re-declared from their own source with `$EUID -ne 0` -> `0 -ne 0`.
# The subject logic is otherwise byte-for-byte the shipped code.
cat > "$SB/euid_shim.sh" <<'EOF'
for _f in nftban_disable_all nftban_enable_all; do
    eval "$(declare -f "$_f" | sed 's/\[\[ \$EUID -ne 0 \]\]/[[ 0 -ne 0 ]]/')"
done
EOF
svc_root(){ svc "source \"$SB/euid_shim.sh\"; $1"; }

if ! grep -q '^_nftban_record_units()' "$SVC" 2>/dev/null; then
    absent "C0 disable unit record" "_nftban_record_units missing"
fi
fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"; printf 'nftband.service\nnftband.socket\nnftban-maintenance.timer\nnftables.service\nsuricata.service\n' > "$SB/active"
rc=0; svc_root 'nftban_disable_all' || rc=$?
if [[ -f "$rec" ]] && has "$rec" $'nftban-maintenance.timer\tenabled' && has "$rec" "recorded_at="; then ok "C1 disable writes the unit record (is-enabled + is-active per unit)"
else ko "C1 unit record (rc=$rc)"; fi
if ! grep -E 'systemctl (stop|disable|enable|mask|unmask) (nftables|suricata)\.service' "$SB/calls.log" >/dev/null; then ok "C2 nftables.service and suricata.service never stopped/disabled/enabled/masked"
else ko "C2 shared services touched: $(grep -E 'systemctl (stop|disable|enable|mask) (nftables|suricata)' "$SB/calls.log" | tr '\n' ';')"; fi
if ! grep -E 'systemctl (disable|unmask|mask) nftban-tunnel\.timer' "$SB/calls.log" >/dev/null && [[ "$(awk '$1=="nftban-tunnel.timer"{print $2}' "$SB/units")" == masked ]]; then ok "C3 masked unit left masked (never disabled/unmasked)"
else ko "C3 masked unit handling"; fi
if ! grep -E 'systemctl (stop|disable) nftban-(boot-bypass|boot-bypass-guard|boot-normal|commit-confirm-boot)\.service' "$SB/calls.log" >/dev/null; then ok "C4 boot guard units + commit-confirm-boot never stopped/disabled"
else ko "C4 boot guards touched"; fi
if has "$SB/etc/conf.d/services.conf.local" 'NFTBAN_ENABLED="false"' && has "$SB/calls.log" "nftban firewall render-boot --inert"; then ok "C5 stored switch OFF + inert projection published"
else ko "C5 switch/inert publish"; fi
if [[ "$(awk '$1=="nftban-maintenance.timer"{print $2}' "$SB/units")" == disabled ]] && ! grep -qxF "nftban-maintenance.timer" "$SB/active"; then ok "C6 NFTBan units stopped and disabled"
else ko "C6 NFTBan units not stopped/disabled"; fi
if ! grep -E '^nft (delete|flush)' "$SB/calls.log" >/dev/null; then ok "C7 plain disable leaves NFTBan rules in the kernel (no delete/flush)"
else ko "C7 plain disable touched kernel tables"; fi
cp "$rec" "$SB/rec.first" 2>/dev/null || : > "$SB/rec.first"   # base: no record (arm C8 then fails, not the harness)
svc_root 'nftban_disable_all' || true
if cmp -s "$rec" "$SB/rec.first"; then ok "C8 repeated disable never overwrites the original record"
else ko "C8 record overwritten"; fi

# C5b (audit K5, 2026-10-08): when the inert publish is refused (D10 hold), disable must SAY WHY;
# the refusal was hidden (2>/dev/null) and only a generic warning remained.
fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"; : > "$SB/active"; : > "$SB/refuse_render"
rc=0; svc_root 'nftban_disable_all' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/svc.out" "could NOT be published" && has "$SB/svc.out" "cause: REFUSED: firewall render-boot: a commit-confirm rollback FAILED (D10 hold)"; then
    ok "C5b refused inert publish: disable reports the refusal's cause (rc != 0)"
else ko "C5b refused inert publish (rc=$rc cause shown=$(has "$SB/svc.out" "cause: REFUSED" && echo y || echo n))"; fi
rm -f "$SB/refuse_render"

# C7b (audit H5, 2026-10-08): the stub `systemctl stop` runs no ExecStop, so C7 cannot see that a
# real stop of nftban-firewall-init.service runs its ExecStop, which DELETES ip/ip6 nftban at once.
# A plain disable must therefore not stop that unit (it is disabled: not started at the next boot).
_fi_unit="$REPO_ROOT/install/systemd/nftban-firewall-init.service"
fresh; printf '%s\nnftban-firewall-init.service enabled\n' "$UNITS_BASE" > "$SB/units"
printf 'nftband.service\nnftban-firewall-init.service\nnftables.service\n' > "$SB/active"
rc=0; svc_root 'nftban_disable_all' || rc=$?
if grep -qE '^ExecStop=.*nft delete table ip nftban' "$_fi_unit" \
   && ! grep -qxF 'systemctl stop nftban-firewall-init.service' "$SB/calls.log" \
   && [[ "$(awk '$1=="nftban-firewall-init.service"{print $2}' "$SB/units")" == disabled ]]; then
    ok "C7b plain disable does NOT stop nftban-firewall-init.service (its ExecStop deletes the tables); the unit is disabled"
else ko "C7b firewall-init on plain disable (rc=$rc stop=$(grep -cxF 'systemctl stop nftban-firewall-init.service' "$SB/calls.log") state=$(awk '$1=="nftban-firewall-init.service"{print $2}' "$SB/units"))"; fi

fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"
rc=0; svc_root 'nftban_disable_all --flush-rules' || rc=$?
if has "$SB/calls.log" "nft delete table ip nftban" && has "$SB/calls.log" "nft delete table ip6 nftban" \
   && ! grep -E '^nft flush table' "$SB/calls.log" >/dev/null && has_line "$SB/nft_tables" "table inet labforeign" \
   && ! grep -E '^table (ip|ip6) nftban$' "$SB/nft_tables" >/dev/null && has "$SB/svc.out" "Verified: no NFTBan table"; then
    ok "C9 --flush-rules DELETES only ip/ip6 nftban (no flush-only), foreign kept, verified from the kernel"
else ko "C9 --flush-rules (rc=$rc): $(tail -4 "$SB/svc.out" | tr "\n" "|") tables: $(tr "\n" "," < "$SB/nft_tables") nftcalls: $(grep "^nft " "$SB/calls.log" | tr "\n" ";") out: $(grep -E "Removing|STILL|Verified|ERROR|WARNING" "$SB/svc.out" | tr "\n" ";")"; fi

# enable: build a disabled host with a record, then change settings while disabled.
fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"
svc_root 'nftban_disable_all' >/dev/null 2>&1 || true
# operator changes while disabled: a recorded-enabled core unit was recorded disabled for queue
awk -F'\t' 'BEGIN{OFS="\t"} $1=="nftban-queue.timer"{$2="disabled"} {print}' "$rec" > "$rec.n" && mv "$rec.n" "$rec"
mkdir -p "$SB/etc/conf.d/botscan"; echo 'BOTSCAN_ENABLED="false"' > "$SB/etc/conf.d/botscan/main.conf"
echo 'NFTBAN_GEOIP_ENABLED="false"' >> "$SB/etc/nftban.conf"
: > "$SB/calls.log"
rc=0; svc_root 'nftban_emergency_bypass_active(){ return 1; }; nftban_enable_all' || rc=$?
if grep -qxF "rebuild-saw-switch true" "$SB/calls.log"; then ok "C10 enable switches the stored choice ON before the rebuild"
else ko "C10 rebuild ran with switch: $(sed -n 's/^rebuild-saw-switch //p' "$SB/calls.log")"; fi
if ! grep -E 'systemctl (enable|start|unmask) nftables\.service' "$SB/calls.log" >/dev/null && ! grep -E 'systemctl (enable|start) suricata\.service' "$SB/calls.log" >/dev/null; then
    ok "C11 enable never enables/starts nftables.service or suricata.service"
else ko "C11 shared service enabled by enable"; fi
if [[ "$(awk '$1=="nftban-botscan.timer"{print $2}' "$SB/units")" != enabled ]]; then ok "C12 module switched OFF while disabled stays off (recorded enabled)"
else ko "C12 botscan timer re-enabled against the current switch"; fi
if [[ "$(awk '$1=="nftban-queue.timer"{print $2}' "$SB/units")" != enabled ]]; then ok "C13 unit recorded disabled stays disabled"
else ko "C13 recorded-disabled unit enabled"; fi
if [[ "$(awk '$1=="nftban-tunnel.timer"{print $2}' "$SB/units")" == masked ]] && ! grep -E 'systemctl unmask' "$SB/calls.log" >/dev/null; then ok "C14 masked unit stays masked"
else ko "C14 masked unit changed"; fi
if [[ "$(awk '$1=="nftban-maintenance.timer"{print $2}' "$SB/units")" == enabled ]]; then ok "C15 core unit recorded enabled is restored"
else ko "C15 core unit not restored"; fi
if ! has "$SB/etc/conf.d/services.conf.local" 'NFTBAN_GEOIP_ENABLED="true"' && [[ "$(awk '$1=="nftban-core-geoip.timer"{print $2}' "$SB/units")" != enabled ]]; then
    ok "C16 GeoIP switched off stays off (no forced NFTBAN_GEOIP_ENABLED=true)"
else ko "C16 GeoIP forced on"; fi
if ! has "$SB/calls.log" "nftban login enable"; then ok "C17 enable never calls 'nftban login enable' (no settings rewrite)"
else ko "C17 login enable called"; fi
if [[ $rc -eq 0 && ! -f "$rec" ]]; then ok "C18 successful enable removes the record"
else ko "C18 record after enable (rc=$rc, record $( [[ -f "$rec" ]] && echo present || echo absent)); out: $(tail -3 "$SB/svc.out" | tr '\n' '|')"; fi

# enable refuses under the bypass. /proc/cmdline has no test hook: the subject function
# nftban_emergency_bypass_active is stubbed (TESTABILITY GAP, reported).
fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"; : > "$SB/calls.log"
rc=0; svc_root 'nftban_emergency_bypass_active(){ return 0; }; nftban_enable_all' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/svc.out" "EMERGENCY BYPASS ACTIVE" && ! has "$SB/calls.log" "firewall rebuild"; then ok "C19 enable refuses under the emergency bypass (nothing rebuilt)"
else ko "C19 enable under bypass (rc=$rc)"; fi

# D10 with enable
fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"; : > "$SB/data/state/commit-confirm.rollback-failed"
printf 'apply_id=X1\nstatus=rollback-failed\n' > "$SB/data/state/commit-confirm.state"
echo 'NFTBAN_ENABLED="true"' > "$SB/etc/conf.d/services.conf.local"
rc=0; svc_root 'nftban_emergency_bypass_active(){ return 1; }; nftban_enable_all' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/svc.out" "ROLLBACK FAILED" && [[ -e "$SB/data/state/commit-confirm.rollback-failed" ]]; then ok "C20 failed rollback + NFTBan enabled -> enable refuses, state kept"
else ko "C20 enable with failed rollback (rc=$rc)"; fi
echo 'NFTBAN_ENABLED="false"' > "$SB/etc/conf.d/services.conf.local"
rc=0; svc_root 'nftban_emergency_bypass_active(){ return 1; }; nftban_enable_all' || rc=$?
if [[ ! -e "$SB/data/state/commit-confirm.rollback-failed" ]] && has_line "$SB/data/state/commit-confirm.state" "status=abandoned"; then
    ok "C21 NFTBan disabled for recovery -> enable clears the marker, record status=abandoned"
else ko "C21 recovery enable (rc=$rc)"; fi

# ---------------------------------------------------------------- E. unit census
echo "[E] systemd unit census"
shopt -s nullglob
missing_k=""; missing_d=""
for f in "$UNITDIR"/nftban*.service "$UNITDIR"/nftban*.timer "$UNITDIR"/nftban*.socket "$UNITDIR"/nftband.service "$UNITDIR"/nftband.socket; do
    b=$(basename "$f")
    case "$b" in nftban-boot-bypass.service|nftban-boot-bypass-guard.service|nftban-boot-normal.service|nftban-commit-confirm-boot.service) continue ;; esac
    # Read-only diagnosis and failure notification stay available under bypass / D10.
    case "$b" in nftban-firewall-validate.service|nftban-alert@.service) continue ;; esac
    has_line "$f" 'ConditionKernelCommandLine=!nftban=disabled' || missing_k="$missing_k $b"
    has_line "$f" 'ConditionPathExists=!/var/lib/nftban/state/commit-confirm.rollback-failed' || missing_d="$missing_d $b"
done
[[ -z "$missing_k" ]] && ok "E1 every NFTBan unit carries ConditionKernelCommandLine=!nftban=disabled" || ko "E1 missing bypass condition:$missing_k"
[[ -z "$missing_d" ]] && ok "E2 every NFTBan unit carries the failed-rollback condition" || ko "E2 missing D10 condition:$missing_d"
held=""
for b in nftban-firewall-validate.service nftban-alert@.service nftban-commit-confirm-boot.service; do
    f="$UNITDIR/$b"
    [[ -f "$f" ]] || { held="$held $b(absent)"; continue; }
    has_line "$f" 'ConditionPathExists=!/var/lib/nftban/state/commit-confirm.rollback-failed' && held="$held $b(D10)"
    [[ "$b" != nftban-commit-confirm-boot.service ]] && has_line "$f" 'ConditionKernelCommandLine=!nftban=disabled' && held="$held $b(bypass)"
done
[[ -z "$held" ]] && ok "E2b diagnosis/alert/recovery units are NOT held by the bypass / D10 conditions" || ko "E2b held:$held"
bad=""
for b in nftban-boot-bypass.service nftban-boot-bypass-guard.service nftban-boot-normal.service nftban-commit-confirm-boot.service; do
    f="$UNITDIR/$b"
    [[ -f "$f" ]] || { bad="$bad $b(absent)"; continue; }
    has_line "$f" 'DefaultDependencies=no' || bad="$bad $b(DefaultDependencies)"
    if [[ "$b" != nftban-boot-bypass-guard.service ]] && grep -E '^(After|Requires|Wants|BindsTo)=.*nftables\.service' "$f" >/dev/null; then bad="$bad $b(orders-after-nftables)"; fi
done
[[ -z "$bad" ]] && ok "E3 early units: DefaultDependencies=no, no ordering after nftables.service (except the guard)" || ko "E3 early units:$bad"
# E4: the legacy rollback pair is RETIRED: not shipped, and converged away on upgrade.
_dep="$REPO_ROOT/build/deprecated-units.yaml"
if [[ ! -e "$UNITDIR/nftban-rollback.service" && ! -e "$UNITDIR/nftban-rollback.timer" ]] \
   && grep -qxF -- '  - name: nftban-rollback.timer' "$_dep" && grep -qxF -- '  - name: nftban-rollback.service' "$_dep"; then
    ok "E4 legacy nftban-rollback.timer/.service retired (not shipped; registered stop_disable_remove)"
else ko "E4 legacy rollback units still shipped or not registered for upgrade cleanup (registry: $_dep)"; fi

# E5 (audit H4, 2026-10-08): EVERY firewall dispatcher verb that loads or replaces rules carries
# BOTH guards (R-DEC bypass, D10 rollback-failed). Derived from the dispatcher itself, so an alias
# such as `init` (-> firewall_rebuild) cannot bypass them.
_fw="$LIBDIR/cli/cmd_firewall.sh"
_unguarded=$(awk '/^        [a-z|-]+\)$/{v=$1; sub(/\)$/,"",v); blk=""; next}
    v!="" {blk=blk"\n"$0}
    v!="" && /^            ;;$/ {
        if (blk ~ /(firewall_rebuild|firewall_reload|firewall_reset|firewall_restore|firewall_takeover|_firewall_render_boot) "\$@"/ \
            && !(blk ~ /_fw_bypass_guard / && blk ~ /_fw_cc_guard /)) printf "%s ", v
        v="" }' "$_fw")
_loaders=$(grep -cE '^[[:space:]]+(firewall_rebuild|firewall_reload|firewall_reset|firewall_restore|firewall_takeover|_firewall_render_boot) "\$@"' "$_fw" || true)
if [[ "$_loaders" -ge 6 && -z "$_unguarded" ]]; then
    ok "E5 every rule-loading firewall verb ($_loaders call sites) carries the bypass and the rollback-failed guard"
else ko "E5 rule-loading verbs WITHOUT both guards: ${_unguarded:-none} (loader call sites=$_loaders)"; fi

# E6 (audit H3, owner U1, 2026-10-08): an UPGRADE of a disabled host loads no NFTBan rules. The
# DEB postinst and RPM %post scriptlet reload must be gated by the shared switch reader.
_post="$REPO_ROOT/packaging/deb/postinst"; _spec="$REPO_ROOT/packaging/build_nftban.sh"
_h3=0
for _f in "$_post" "$_spec"; do
    _rl=$(grep -n -m1 'nftban firewall reload --quiet' "$_f" | cut -d: -f1 || true)
    _gate=$(grep -n -m1 '_nftban_switch=.*service_control.sh.*nftban_is_enabled' "$_f" | cut -d: -f1 || true)
    _off=$(grep -n -m1 '_nftban_switch" = "off" \]; then' "$_f" | cut -d: -f1 || true)
    [[ -n "$_rl" && -n "$_gate" && -n "$_off" && "$_gate" -lt "$_off" && "$_off" -lt "$_rl" && $((_rl - _gate)) -le 10 ]] \
        || { _h3=1; echo "      $_f: reload line=${_rl:-?} switch read=${_gate:-none} off-branch=${_off:-none}"; }
done
if [[ $_h3 -eq 0 ]]; then ok "E6 DEB postinst and RPM %post upgrade reload are skipped while NFTBan is disabled (shared reader nftban_is_enabled)"
else ko "E6 upgrade reload not gated by the master switch"; fi

# E7 (audit H3 follow-up, 2026-10-08): EXECUTE the exact switch line of both scriptlets (the RPM
# copy unescaped from the heredoc) with the reader pointed at this tree, in a clean environment:
# stored ON -> "on"; the services.conf.local override that `disable all` writes -> "off"; a reader
# that cannot be loaded -> "" (the scriptlet then says "could not be read", never "disabled").
e7(){  # <scriptlet line> <config dir> <lib dir> -> prints the decided value
    env -i PATH="/usr/bin:/bin" HOME="$SB" NFTBAN_CONFIG_DIR="$2" NFTBAN_LIB_DIR="$3" \
        bash -c 'eval "$1"; printf "%s" "${_nftban_switch-UNSET}"' _ "${1//\/usr\/lib\/nftban\/lib\/service_control.sh/$3/lib/service_control.sh}"
}
_e7_ok=1
for _src in deb rpm; do
    if [[ $_src == deb ]]; then _line=$(grep -m1 '^ *_nftban_switch=\$(bash -c' "$REPO_ROOT/packaging/deb/postinst" | sed 's/^ *//')
    else _line=$(grep -m1 '^ *_nftban_switch=\\\$(bash -c' "$REPO_ROOT/packaging/build_nftban.sh" | sed 's/^ *//; s/\\\$/$/g'); fi
    [[ -n "$_line" ]] || { _e7_ok=0; echo "      $_src: switch line not found"; continue; }
    rm -rf "$SB/e7"; mkdir -p "$SB/e7/on/conf.d" "$SB/e7/off/conf.d"
    printf 'NFTBAN_ENABLED="true"\n' > "$SB/e7/on/conf.d/services.conf"
    printf 'NFTBAN_ENABLED="true"\n' > "$SB/e7/off/conf.d/services.conf"
    printf 'NFTBAN_ENABLED="false"\n' > "$SB/e7/off/conf.d/services.conf.local"
    a1=$(e7 "$_line" "$SB/e7/on" "$LIBDIR"); a2=$(e7 "$_line" "$SB/e7/off" "$LIBDIR"); a3=$(e7 "$_line" "$SB/e7/on" "$SB/e7/no-such-lib")
    [[ "$a1" == on && "$a2" == off && -z "$a3" ]] || { _e7_ok=0; echo "      $_src: stored-on=[$a1] local-off=[$a2] unreadable=[$a3] (want on / off / empty)"; }
done
if [[ $_e7_ok -eq 1 ]]; then ok "E7 both scriptlet switch lines EXECUTED: stored on -> on; disable's .local override -> off; unloadable reader -> unread (not 'disabled')"
else ko "E7 scriptlet switch decision"; fi

# E8 (audit K14, 2026-10-08): no shipped operator text ADVISES `nft flush ruleset` (it deletes
# every table, Docker's included). Lines that warn against it (NOT / never / do not) are allowed.
_k14=$(grep -rnE '(echo|printf).*nft flush ruleset' "$LIBDIR" --include='*.sh' 2>/dev/null \
       | grep -v '/tests/' | grep -viE 'NOT|never|do not|don.t' || true)
if [[ -z "$_k14" ]]; then ok "E8 no operator text advises 'nft flush ruleset'"
else ko "E8 operator text advises 'nft flush ruleset': ${_k14:0:300}"; fi

# E9 (owner K2): both shell readers answer the SHARED case table exactly like the Go reader
# (configloader.ParseSwitch is held to the same file by master_switch_test.go).
_k2tbl="$REPO_ROOT/scripts/ci/data/master-switch-cases.tsv"; _k2bad=""; _k2n=0
_k2fn_svc=$(awk '/^_nftban_switch_word\(\) \{/{c=1} c{print} c&&/^}/{exit}' "$SVC")
_k2fn_early=$(awk '/^_nftban_switch_word\(\) \{/{c=1} c{print} c&&/^}/{exit}' "$EARLY")
while IFS=$'\t' read -r _k2in _k2want || [[ -n "${_k2in:-}" ]]; do
    [[ -z "$_k2in" || "$_k2in" == \#* ]] && continue
    [[ "$_k2in" == "<EMPTY>" ]] && _k2in=""
    _k2n=$((_k2n+1))
    for _k2fn in "$_k2fn_svc" "$_k2fn_early"; do
        _k2got=$(bash -c "$_k2fn"$'\n''_nftban_switch_word "$1"' _ "$_k2in")
        [[ "$_k2got" == "$_k2want" ]] || _k2bad+=" [$_k2in]=$_k2got(want $_k2want)"
    done
done < "$_k2tbl"
if [[ $_k2n -ge 30 && -z "$_k2bad" ]]; then ok "E9 both shell readers give the shared table's answer for all $_k2n cases"
else ko "E9 switch contract mismatch (cases=$_k2n):${_k2bad}"; fi
# E10: the boot helper's copy is byte-identical to lib/service_control.sh (one rule, two places).
if [[ -n "$_k2fn_svc" && "$_k2fn_svc" == "$_k2fn_early" ]]; then ok "E10 _nftban_switch_word is byte-identical in lib/service_control.sh and the boot helper"
else ko "E10 the two copies of _nftban_switch_word differ"; fi
# E11/E12 (owner K2): an INVALID value refuses enable and disable before any change; status JSON
# reports master_enabled = null (never true/false).
fresh; printf '%s\n' "$UNITS_BASE" > "$SB/units"; : > "$SB/active"; mkdir -p "$SB/etc/conf.d"
printf 'NFTBAN_ENABLED=maybe\n' > "$SB/etc/conf.d/services.conf"; cp "$SB/etc/conf.d/services.conf" "$SB/svc.before"
rc=0; svc_root 'nftban_disable_all' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/svc.out" "master switch is INVALID" && ! grep -qE 'systemctl (stop|disable)' "$SB/calls.log" && cmp -s "$SB/etc/conf.d/services.conf" "$SB/svc.before" && [[ ! -e "$SB/etc/conf.d/services.conf.local" ]]; then
    ok "E11 disable with NFTBAN_ENABLED=maybe -> REFUSED, no unit touched, no setting written"
else ko "E11 disable with an invalid value (rc=$rc)"; fi
rc=0; svc_root 'nftban_enable_all' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/svc.out" "master switch is INVALID" && ! has "$SB/calls.log" "firewall rebuild"; then
    ok "E12 enable with NFTBAN_ENABLED=maybe -> REFUSED, nothing rebuilt"
else ko "E12 enable with an invalid value (rc=$rc)"; fi
rc=0; svc '_nftban_services_status_json' || rc=$?
if has "$SB/svc.out" '"master_enabled": null'; then ok "E13 status JSON with an invalid value -> master_enabled null (not true/false)"
else ko "E13 status JSON master_enabled for an invalid value"; fi

echo ""
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
