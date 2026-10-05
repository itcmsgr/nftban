#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - package removal retires install_state (no stale COMMITTED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="remove_retires_install_state_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="BUG-INSTALL-STATE-SAYS-COMMITTED-AFTER-PACKAGE-REMOVE (v1.235 K1). DEB postrm remove and RPM %postun ($1 -eq 0) preserve /var/lib/nftban but never touched install_state, so a removed host kept claiming INSTALL_STATE=COMMITTED. Locks: R0 the RPM spec is rendered from the REAL generator (packaging/build_nftban.sh) and the heredoc executes nothing; D1 DRIFT: _nftban_retire_install_state is present exactly once and byte-identical in packaging/deb/postrm and the rendered %postun; P1 PLACEMENT: DEB remove arm calls it, the upgrade/failed-upgrade/disappear arm and the abort arm do not; RPM calls it inside `if [ $1 -eq 0 ]` and not in the upgrade block; F1-F3 FUNCTIONAL for EACH copy under sh -e: a COMMITTED install_state is moved to install_state.removed-<UTC> byte-for-byte with rc 0 and nothing left claiming the install; no state file => rc 0, no-op; an unmovable file (read-only dir, non-root) => WARN on stderr, rc 0, removal not aborted. Set K1_SUBJECT_ROOT to an older tree (e.g. e79a1173): D1/P1/F1 must FAIL there."
# meta:inventory.files="remove_retires_install_state_v1235_test.sh"
# meta:inventory.binaries="bash,sh,awk,cmp,mktemp,chmod,id"
# meta:inventory.env_vars="K1_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="remove_retires_install_state_v1235_test"
# meta:ta.owner="packaging"
# meta:ta.module="package-remove-state"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${K1_SUBJECT_ROOT:-$REPO}"
POSTRM="$ROOT/packaging/deb/postrm"
BUILD="$ROOT/packaging/build_nftban.sh"
FN="_nftban_retire_install_state"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 K1: package removal retires install_state ==="
for b in awk sh cmp; do
    command -v "$b" >/dev/null 2>&1 || { echo "  NOT_EXECUTED: '$b' missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
done
[[ -f "$POSTRM" && -f "$BUILD" ]] || { echo "  NOT_EXECUTED: subject files missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }

W="$(mktemp -d)"
cleanup(){ chmod -R u+w "$W" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT

# ---- R0 · render the REAL RPM spec from the REAL generator -------------------------
awk '/^create_rpm_spec_nftban_core\(\) *\{/{n=1}
     n && /<<EOF$/{h=1}
     n && h && /^EOF$/{h=0; print; next}
     n{print}
     n && !h && /^\}$/{exit}' "$BUILD" > "$W/gen.sh"
mkdir -p "$W/SPECS"
(
    set +e
    export BUILD_DIR="$W" PROJECT_ROOT="$ROOT"
    export PKG_VERSION="0.0.0-test" PKG_RELEASE="1" PKG_VERSION_DATE="2026-01-01"
    log_info(){ :; }; log_error(){ :; }; log_warn(){ :; }; log_success(){ :; }
    # shellcheck disable=SC1091
    . "$W/gen.sh"
    create_rpm_spec_nftban_core
) >"$W/gen.out" 2>"$W/gen.err"
SPEC="$W/SPECS/nftban-core.spec"
if [[ -s "$SPEC" ]]; then
    ok "R0 RPM spec rendered from packaging/build_nftban.sh"
else
    no "R0 RPM spec generation failed — every RPM arm would be vacuous"
    echo "Results: $PASS passed, $FAIL failed"; echo "RESULT: FAIL"; exit 1
fi
GENERR=$(grep -vF 'log_success' "$W/gen.err" | grep -v '^[[:space:]]*$' || true)
[[ -z "$GENERR" ]] && ok "R0b spec generation executed nothing (heredoc inert)" \
                   || no "R0b spec generation executed something — unescaped \$( ) in the heredoc" "$GENERR"
POSTUN="$W/postun.sh"
awk '/^%postun$/{n=1;next} n && /^%[a-z]+$/{exit} n{print}' "$SPEC" > "$POSTUN"

# ---- D1 · one function, two byte-identical copies ---------------------------------
extract_fn(){ awk '/^# >>> NFTBAN_INSTALL_STATE_RETIRE_BEGIN >>>$/{f=1} f{print} /^# <<< NFTBAN_INSTALL_STATE_RETIRE_END <<<$/{f=0}' "$1"; }
extract_fn "$POSTRM" > "$W/fn.deb"
extract_fn "$POSTUN" > "$W/fn.rpm"
for c in deb rpm; do
    n=$(grep -c "^${FN}() {" "$W/fn.$c" || true)
    [[ "$n" == 1 ]] && ok "D1 $c copy present exactly once" || no "D1 $c copy count=$n (want 1)"
done
if [[ -s "$W/fn.deb" ]] && cmp -s "$W/fn.deb" "$W/fn.rpm"; then
    ok "D1 DEB postrm and rendered RPM %postun copies are byte-identical"
else
    d1diff="$(diff "$W/fn.deb" "$W/fn.rpm" 2>&1 || true)"
    no "D1 copies differ or are missing" "${d1diff:0:400}"
fi

# ---- P1 · placement ------------------------------------------------------------------
arm(){ awk -v lbl="$1" '$0 == lbl {f=1; next} f && /^        ;;$/ {exit} f {print}' "$POSTRM"; }
calls(){ local n; n=$(grep -cE "^[[:space:]]*${FN}[[:space:]]*\$" <<<"$1" || true); printf '%s' "$n"; }
a_remove="$(arm '    remove)')"
a_upgrade="$(arm '    upgrade|failed-upgrade|disappear)')"
a_abort="$(arm '    abort-install|abort-upgrade)')"
[[ -n "$a_remove" && -n "$a_upgrade" && -n "$a_abort" ]] || no "P1 DEB postrm arm not found — arm checks would be vacuous"
[[ "$(calls "$a_remove")" == 1 ]] && ok "P1 DEB postrm remove arm calls $FN" || no "P1 DEB remove arm does not call $FN"
[[ "$(calls "$a_upgrade")" == 0 && "$(calls "$a_abort")" == 0 ]] && ok "P1 DEB upgrade/abort arms do not call it" || no "P1 DEB upgrade/abort arm calls it"
blk0="$(awk '/^if \[ \$1 -eq 0 \]; then$/{i=1;next} i && /^fi$/{exit} i{print}' "$POSTUN")"
blk1="$(awk '/^if \[ \$1 -ge 1 \]; then$/{i=1;next} i && /^fi$/{exit} i{print}' "$POSTUN")"
[[ -n "$blk0" && "$(calls "$blk0")" == 1 ]] && ok "P1 RPM %postun (\$1 -eq 0) calls $FN" || no "P1 RPM complete-removal block does not call $FN"
[[ "$(calls "$blk1")" == 0 ]] && ok "P1 RPM upgrade block (\$1 -ge 1) does not call it" || no "P1 RPM upgrade block calls it"

# ---- F1-F3 · functional, each copy, under sh -e ----------------------------------
run_copy(){ # <copy> <statedir> -> rc, stdout, stderr files
    env NFTBAN_INSTALL_STATE_DIR="$2" sh -e -c '. "$1"; '"$FN" _ "$W/fn.$1" >"$W/$1.out" 2>"$W/$1.err"
}
for c in deb rpm; do
    [[ -s "$W/fn.$c" ]] || { no "F1 $c copy missing — functional arms not run"; continue; }
    D="$W/state_$c"; mkdir -p "$D"
    printf 'INSTALL_STATE=COMMITTED\nVERSION=1.234.0\n' > "$D/install_state"
    cp "$D/install_state" "$W/orig_state"
    rc=0; run_copy "$c" "$D" || rc=$?
    moved=""
    for f in "$D"/install_state.removed-*; do [[ -e "$f" ]] && moved="$f"; done
    if [[ "$rc" -eq 0 && ! -e "$D/install_state" && -n "$moved" ]] && cmp -s "$W/orig_state" "$moved"; then
        ok "F1 $c: COMMITTED state moved aside byte-for-byte; no install_state left (rc=0)"
    else
        no "F1 $c: state not retired" "rc=$rc left=$( [[ -e "$D/install_state" ]] && echo yes || echo no ) moved=${moved:-none}"
    fi
    D2="$W/empty_$c"; mkdir -p "$D2"
    rc=0; run_copy "$c" "$D2" || rc=$?
    n_files=0; for f in "$D2"/*; do [[ -e "$f" ]] && n_files=$((n_files+1)); done
    [[ "$rc" -eq 0 && "$n_files" -eq 0 ]] && ok "F2 $c: no state file => no-op, rc=0" || no "F2 $c: no-op case wrong" "rc=$rc files=$n_files"
    if [[ "$(id -u)" -ne 0 ]]; then
        D3="$W/ro_$c"; mkdir -p "$D3"; printf 'INSTALL_STATE=COMMITTED\n' > "$D3/install_state"; chmod 0555 "$D3"
        rc=0; run_copy "$c" "$D3" || rc=$?
        if [[ "$rc" -eq 0 && -e "$D3/install_state" ]] && grep -q 'WARN: could not retire' "$W/$c.err"; then
            ok "F3 $c: unmovable state => WARN on stderr, rc=0 (removal not aborted)"
        else
            no "F3 $c: unmovable state handled wrongly" "rc=$rc"
        fi
        chmod 0755 "$D3"
    else
        echo "  - F3 $c not asserted as root (root ignores directory permissions)"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
