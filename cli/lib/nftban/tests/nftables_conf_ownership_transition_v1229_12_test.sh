#!/usr/bin/env bash
# =============================================================================
# NFTBan — v1.229.12: /etc/nftban/nftables.conf ownership transition
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftables-conf-ownership-transition-v1229-12-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-31"
# meta:description="Regression authority for the v1.229.12 nftables.conf ownership transition. THE DEFECT: /etc/nftban/nftables.conf was declared a dpkg conffile (and RPM %config(noreplace)) while the runtime treats it as a GENERATED artifact republished by firewall reload/rebuild via a bare mv. An NFTBan-rendered file therefore reads as locally modified, so a .11 -> .12 upgrade whose payload also changed reached dpkg conffile arbitration: MEASURED APT_RC=100, dpkg status iU, postinst NEVER REACHED, IPv6 ND correction never delivered - on a stock unattended host with no operator edit. Locks: (a) the real generated DEB conffiles list excludes nftables.conf while still enrolling ordinary operator configs; (b) the generated RPM spec no longer marks it %config(noreplace); (c) the shipped preinst transition classifies package-payload / NFTBan-rendered (defaults AND non-default SSH+CT) / unknown, preserves unknown content with a VERIFIED backup before displacement, ABORTS when preservation cannot be proven, is gated on live dpkg conffile registration so it cannot repeat, and classifies against the INSTALLED pre-upgrade template."
# meta:inventory.files="packaging/build_nftban.sh,packaging/deb/preinst,install/nftables/nftables.conf.tpl"
# meta:inventory.privileges="none"
# meta:ta.id="nftables_conf_ownership_transition_v1229_12_test"
# meta:ta.owner="packaging"
# meta:ta.module="packaging-ownership"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# SCOPE OF THIS FILE. It is HERMETIC: it drives the REAL generator block and the
# REAL shipped preinst function inside a sandbox. It is therefore regression
# authority for the ownership MODEL and the transition CONTRACT.
#
# ⛔ IT IS NOT PACKAGE-NATIVE PROOF. It does not run dpkg or rpm. The
#    package-native evidence (real .11 -> .12 DEB upgrade arms, and the RPM
#    %config(noreplace) -> ordinary-file arms showing rc=0, %post reached and
#    modified content preserved as .rpmsave) is recorded in the PR. Do not cite
#    a green run of this file as proof that a real upgrade succeeds.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BUILD="$REPO_ROOT/packaging/build_nftban.sh"
PREINST="$REPO_ROOT/packaging/deb/preinst"
TPL="$REPO_ROOT/install/nftables/nftables.conf.tpl"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; FAIL=$((FAIL+1)); }

W=$(mktemp -d)
_owner=$$
trap '[ "$$" = "$_owner" ] && rm -rf "$W"' EXIT

for f in "$BUILD" "$PREINST" "$TPL"; do
    [ -f "$f" ] || { echo "  FAIL  missing subject: $f"; echo "== RESULT: PASS=0 FAIL=1 =="; exit 1; }
done

# =============================================================================
# PART 1 — THE OWNERSHIP MODEL (the generator is the subject, not its comments)
# =============================================================================
echo "-- T1  real conffiles generator, driven over a synthetic staged tree ----"

# Extract the REAL conffiles-generation block from the REAL build script.
awk '/v1\.227 MAIL-F8: GENERATE the DEB conffiles/{n=1}
     n{print}
     n && /DEBIAN\/conffiles"$/{exit}' "$BUILD" > "$W/genconf.sh"

if [ ! -s "$W/genconf.sh" ] || ! grep -q 'DEBIAN/conffiles' "$W/genconf.sh"; then
    no "could not extract the conffiles generator — every arm below would be vacuous" ""
    echo "== RESULT: PASS=$PASS FAIL=$FAIL =="; exit 1
fi
ok "extracted the live conffiles generator ($(wc -l < "$W/genconf.sh") lines)"

stage_tree() {
    local root="$1"
    rm -rf "$root"; mkdir -p "$root/deb/DEBIAN" "$root/deb/etc/nftban/conf.d" "$root/deb/etc/sysctl.d"
    : > "$root/deb/etc/nftban/nftables.conf"      # the subject
    : > "$root/deb/etc/nftban/nftban.conf"        # ordinary operator config
    : > "$root/deb/etc/nftban/conf.d/feeds.conf"  # ordinary operator config
    : > "$root/deb/etc/nftban/nftban.conf.local"  # operator override, never a conffile
    : > "$root/deb/etc/nftban/mail.conf.default"  # shipped reference
    : > "$root/deb/etc/sysctl.d/90-nftban.conf"
}
run_gen() {  # $1=generator script  $2=staged root -> prints the generated list
    local g="$1" root="$2"
    # shellcheck disable=SC1090  # sourcing the extracted generator IS the test
    ( set +u; BUILD_DIR="$root"; export BUILD_DIR; . "$g" ) >/dev/null 2>&1
    cat "$root/deb/DEBIAN/conffiles" 2>/dev/null
}

stage_tree "$W/s1"
LIST="$(run_gen "$W/genconf.sh" "$W/s1")"

if [ -z "$LIST" ]; then
    no "generator produced an EMPTY list — arms would be vacuously green" ""
    echo "== RESULT: PASS=$PASS FAIL=$FAIL =="; exit 1
fi

# The fix.
if printf '%s\n' "$LIST" | grep -qx '/etc/nftban/nftables.conf'; then
    no "nftables.conf is STILL a generated DEB conffile — the .11->.12 upgrade blocker is back" \
       "dpkg would arbitrate an NFTBan-rendered file: APT_RC=100, iU, postinst not reached"
else
    ok "nftables.conf is NOT a DEB conffile (generated-runtime ownership)"
fi

# The fix must be surgical, not a gutted generator.
printf '%s\n' "$LIST" | grep -qx '/etc/nftban/nftban.conf' \
    && ok "ordinary operator config nftban.conf IS still protected" \
    || no "generator no longer protects nftban.conf — change was over-broad" "$LIST"
printf '%s\n' "$LIST" | grep -qx '/etc/nftban/conf.d/feeds.conf' \
    && ok "conf.d/feeds.conf IS still protected" \
    || no "generator no longer protects conf.d configs — change was over-broad" "$LIST"
printf '%s\n' "$LIST" | grep -qx '/etc/sysctl.d/90-nftban.conf' \
    && ok "sysctl drop-in IS still protected" \
    || no "generator no longer protects the sysctl drop-in" "$LIST"
for excl in '/etc/nftban/nftban.conf.local' '/etc/nftban/mail.conf.default'; do
    printf '%s\n' "$LIST" | grep -qx "$excl" \
        && no "$excl must never be a conffile" "$LIST" \
        || ok "$excl correctly excluded"
done

echo "-- T2  PRE-FIX REPRODUCER: restore the old shape, defect must return ---"
# Remove ONLY the load-bearing exclusion. If nftables.conf then reappears, the
# T1 assertion is non-vacuous AND the exclusion is proven load-bearing.
sed "/! -name 'nftables.conf'/d" "$W/genconf.sh" > "$W/genconf_prefix.sh"
if cmp -s "$W/genconf.sh" "$W/genconf_prefix.sh"; then
    no "could not construct the pre-fix generator — T1 is unproven" \
       "the exclusion line was not found; T1 may be passing for the wrong reason"
else
    stage_tree "$W/s2"
    PRELIST="$(run_gen "$W/genconf_prefix.sh" "$W/s2")"
    if printf '%s\n' "$PRELIST" | grep -qx '/etc/nftban/nftables.conf'; then
        ok "pre-fix generator DOES enroll nftables.conf — T1 detects the real defect"
    else
        no "pre-fix generator did not reproduce the defect — T1 proves nothing" "$PRELIST"
    fi
fi

echo "-- T3  dpkg arbitration predicate, driven by the generated lists -------"
# dpkg reaches conffile arbitration iff the path is a REGISTERED conffile AND the
# on-disk bytes differ from the recorded md5 AND the incoming payload differs.
# The NFTBan-rendered state satisfies the last two by construction, so
# registration is the only remaining input — which is exactly what .12 changes.
arbitrates() { # $1=list  -> ARBITRATION | NO_ARBITRATION
    printf '%s\n' "$1" | grep -qx '/etc/nftban/nftables.conf' \
        && echo ARBITRATION || echo NO_ARBITRATION
}
[ "$(arbitrates "$LIST")" = "NO_ARBITRATION" ] \
    && ok "post-fix: rendered nftables.conf cannot reach dpkg conffile arbitration" \
    || no "post-fix still arbitrates — upgrade would stop before postinst" ""
if [ -n "${PRELIST:-}" ]; then
    [ "$(arbitrates "$PRELIST")" = "ARBITRATION" ] \
        && ok "pre-fix: rendered nftables.conf DOES reach arbitration (the shipped defect)" \
        || no "pre-fix predicate did not reproduce arbitration" ""
fi

echo "-- T4  generated RPM spec no longer marks it %config(noreplace) --------"
awk '/^create_rpm_spec_nftban_core\(\) *\{/{n=1}
     n && /<<EOF$/{h=1}
     n && h && /^EOF$/{h=0; print; next}
     n{print}
     n && !h && /^\}$/{exit}' "$BUILD" > "$W/genspec.sh"
mkdir -p "$W/SPECS"
(
    set +eu
    export BUILD_DIR="$W" PROJECT_ROOT="$REPO_ROOT"
    export PKG_VERSION="0.0.0-test" PKG_RELEASE="1" PKG_VERSION_DATE="2026-01-01"
    log_info(){ :; }; log_error(){ :; }; log_warn(){ :; }; log_success(){ :; }
    # shellcheck disable=SC1090
    . "$W/genspec.sh"
    create_rpm_spec_nftban_core
) >"$W/spec.out" 2>"$W/spec.err"
SPEC="$W/SPECS/nftban-core.spec"
if [ -s "$SPEC" ]; then
    ok "generated the real RPM spec ($(wc -l < "$SPEC") lines)"
    # ⛔ THE SUBJECT IS THE %files SECTION. An earlier revision of this test matched
    #    the %install line ("install -D -m 0644 ... %{buildroot}/etc/nftban/nftables.conf"),
    #    which can never carry %config and so passed vacuously. File DISPOSITION is
    #    declared in %files and nowhere else.
    FILES=$(awk '/^%files/{n=1;next} n && /^%[a-z]+$/{exit} n{print}' "$SPEC")
    NFTLINE=$(printf '%s\n' "$FILES" | grep -E '(^|[[:space:]])/etc/nftban/nftables\.conf[[:space:]]*$' | head -1)
    if [ -z "$NFTLINE" ]; then
        no "nftables.conf absent from the generated %files — spec would not ship it" \
           "assertion cannot be evaluated; treat as failure, not as pass"
    elif printf '%s' "$NFTLINE" | grep -q '%config'; then
        no "RPM still declares nftables.conf %config(noreplace)" "$NFTLINE"
    else
        ok "RPM %files declares nftables.conf as an ordinary generated file"
        ok "  %files entry: $(printf '%s' "$NFTLINE" | sed 's/^[[:space:]]*//')"
    fi

    # NEGATIVE CONTROL: the detector must actually see the pre-fix shape.
    PREFIX_LINE="%config(noreplace) %attr(640,root,nftban) /etc/nftban/nftables.conf"
    if printf '%s' "$PREFIX_LINE" | grep -q '%config'; then
        ok "detector DOES flag the pre-fix %config(noreplace) shape — T4 non-vacuous"
    else
        no "detector blind to %config(noreplace)" "T4 proves nothing"
    fi
    # And it must still be reachable by the same %files extraction.
    printf '%s\n' "$PREFIX_LINE" | grep -qE '(^|[[:space:]])/etc/nftban/nftables\.conf[[:space:]]*$' \
        && ok "pre-fix line is matched by the same extractor T4 uses" \
        || no "extractor would miss the pre-fix line" "$PREFIX_LINE"

    # Parity: the two families must agree on ownership.
    printf '%s\n' "$FILES" | grep -E '%config' | grep -q '/etc/nftban/nftables.conf' \
        && no "DEB/RPM ownership parity broken" "" \
        || ok "DEB and RPM agree: nftables.conf is generated, not operator-owned"
else
    no "RPM spec generation failed — T4 vacuous" "$(head -3 "$W/spec.err")"
fi

# =============================================================================
# PART 2 — THE TRANSITION CONTRACT (the shipped preinst function is the subject)
# =============================================================================
echo "-- T5  extract the shipped transition function into a sandbox ----------"
awk '/^_nftban_nftables_conf_ownership_transition\(\) *\{/{n=1}
     n{print}
     n && /^\}$/{exit}' "$PREINST" > "$W/fn_raw.sh"
if [ ! -s "$W/fn_raw.sh" ] || ! grep -q 'ownership_transition' "$W/fn_raw.sh"; then
    no "could not extract the transition function — PART 2 vacuous" ""
    echo "== RESULT: PASS=$PASS FAIL=$FAIL =="; exit 1
fi

SB="$W/root"
# Rewrite ONLY absolute system path prefixes so the shipped logic runs contained.
sed -E "s#(/etc/nftban|/usr/lib/nftban|/var/lib/nftban|/var/log/nftban)#${SB}\1#g" \
    "$W/fn_raw.sh" > "$W/fn.sh"
# CONTAINMENT + COMPLETENESS: if any real absolute path survived the rewrite the
# test is either dangerous or vacuous. This also fails loudly when a future edit
# adds a path this harness does not know about.
ESCAPED=$(grep -nE '(^|[^A-Za-z0-9_/.])/(etc|usr|var)/' "$W/fn.sh" | grep -v "$SB" || true)
[ -z "$ESCAPED" ] \
    && ok "all system paths rewritten into the sandbox (contained + complete)" \
    || no "an absolute path escaped the sandbox rewrite" "$ESCAPED"

# OLD-TEMPLATE RULE: classification must use the INSTALLED pre-upgrade template.
grep -q 'usr/lib/nftban/templates/nftables.conf.tpl' "$W/fn_raw.sh" \
    && ok "classifies against the INSTALLED template path" \
    || no "transition no longer reads the installed template" ""
grep -qE '\.dpkg-new|DPKG_ROOT' "$W/fn_raw.sh" \
    && no "transition reads an INCOMING template — changes the verifier's subject" \
          "installed template answers 'could the installed version have produced this?'" \
    || ok "transition does not reach for an incoming template"

# ---- sandbox harness --------------------------------------------------------
mkdir -p "$SB/bin"
CONF="$SB/etc/nftban/nftables.conf"
BDIR="$SB/var/lib/nftban/update-backups"
ILOG="$SB/var/log/nftban/installer.log"

render() { # $1=out  $2=ssh  $3=ct_ssh  $4=ct_http  $5=ct_mail
    sed -e "s/__SSH_PORT__/$2/g" -e "s/__CT_LIMIT_SSH__/$3/g" \
        -e "s/__CT_LIMIT_HTTP__/$4/g" -e "s/__CT_LIMIT_MAIL__/$5/g" "$TPL" > "$1"
}
setup() { # $1=registered(yes/no)  $2=recorded-md5-source(file|none)
    rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/etc/nftban" \
        "$SB/usr/lib/nftban/templates" "$SB/var/lib/nftban" "$SB/var/log/nftban"
    cp "$TPL" "$SB/usr/lib/nftban/templates/nftables.conf.tpl"
}
mk_dpkg_query() { # $1=registered md5 or empty
    if [ -n "$1" ]; then
        printf '#!/bin/sh\nprintf "\\n%s %s\\n"\n' "$CONF" "$1" > "$SB/bin/dpkg-query"
    else
        printf '#!/bin/sh\nprintf "\\n"\n' > "$SB/bin/dpkg-query"
    fi
    chmod +x "$SB/bin/dpkg-query"
}
run_fn() { ( PATH="$SB/bin:$PATH"; set +u; . "$W/fn.sh"; \
              _nftban_nftables_conf_ownership_transition ) >"$W/out" 2>"$W/err"; echo $?; }
nbackups() { find "$BDIR" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ---- ROW 1: pristine package payload ---------------------------------------
echo "-- ROW 1  pristine package payload -> KNOWN_PACKAGE_PAYLOAD ------------"
setup; render "$CONF" 22 12 60 30
mk_dpkg_query "$(md5sum "$CONF" | cut -d' ' -f1)"
RC=$(run_fn)
[ "$RC" = "0" ] && ok "rc=0 (upgrade proceeds)" || no "rc=$RC" "$(cat "$W/err")"
grep -q 'KNOWN_PACKAGE_PAYLOAD' "$W/out" && ok "classified KNOWN_PACKAGE_PAYLOAD" \
    || no "not classified as package payload" "$(cat "$W/out")"
[ "$(nbackups)" = "0" ] && ok "no backup cut for known payload" || no "spurious backup" ""

# ---- ROW 2: NFTBan-rendered, packaged DEFAULTS ------------------------------
echo "-- ROW 2  NFTBan-rendered at defaults -> KNOWN_NFTBAN_RENDERED_FORM ----"
setup; render "$CONF" 22 12 60 30
mk_dpkg_query "00000000000000000000000000000000"   # differs => 'locally modified'
RC=$(run_fn)
[ "$RC" = "0" ] && ok "rc=0" || no "rc=$RC" "$(cat "$W/err")"
grep -q 'KNOWN_NFTBAN_RENDERED_FORM' "$W/out" && ok "classified KNOWN_NFTBAN_RENDERED_FORM" \
    || no "rendered-at-defaults misclassified" "$(cat "$W/out")"
[ "$(nbackups)" = "0" ] && ok "no backup for recognised generated form" || no "spurious backup" ""

# ---- ROW 3: NFTBan-rendered, NON-DEFAULT SSH + CT (mandatory) ---------------
echo "-- ROW 3  rendered with NON-DEFAULT SSH 2222 / CT 9,77,88 --------------"
# A host that merely runs SSH on 2222 must not be told its config is unknown.
setup; render "$CONF" 2222 9 77 88
mk_dpkg_query "00000000000000000000000000000000"
RC=$(run_fn)
[ "$RC" = "0" ] && ok "rc=0" || no "rc=$RC" "$(cat "$W/err")"
grep -q 'KNOWN_NFTBAN_RENDERED_FORM' "$W/out" \
    && ok "non-default rendered form still recognised as generated" \
    || no "NON-DEFAULT host misclassified as UNKNOWN" "$(cat "$W/out")"
[ "$(nbackups)" = "0" ] && ok "no backup for non-default generated form" || no "spurious backup" ""

# ---- ROW 4: unknown operator content ---------------------------------------
echo "-- ROW 4  unknown content -> preserve, verify, record, continue --------"
setup
printf '# OPERATOR CUSTOM POLICY\ntable inet operator_custom { }\n' > "$CONF"
SRC_SHA=$(sha256sum "$CONF" | cut -d' ' -f1)
mk_dpkg_query "00000000000000000000000000000000"
RC=$(run_fn)
[ "$RC" = "0" ] && ok "rc=0 (preserved, then continues)" || no "rc=$RC" "$(cat "$W/err")"
[ "$(nbackups)" = "1" ] && ok "exactly one backup created" || no "backups=$(nbackups)" ""
BAK=$(find "$BDIR" -type f 2>/dev/null | head -1)
if [ -n "$BAK" ]; then
    [ "$(sha256sum "$BAK" | cut -d' ' -f1)" = "$SRC_SHA" ] \
        && ok "backup is byte-identical to the displaced content" \
        || no "backup does not match the original" ""
    [ "$(stat -c '%a' "$BAK")" = "600" ] && ok "backup mode 0600" \
        || no "backup mode $(stat -c '%a' "$BAK")" ""
    case "$BAK" in *ownership-transition*) ok "backup name identifies the migration" ;;
                   *) no "backup name is not self-describing" "$BAK" ;; esac
fi
if [ -f "$ILOG" ]; then
    MISS=""
    for k in MIGRATION= CLASSIFICATION= SOURCE_PATH= BACKUP_PATH= BACKUP_SHA256= RESULT=; do
        grep -q "^$k" "$ILOG" || MISS="$MISS $k"
    done
    [ -z "$MISS" ] && ok "durable record carries every recovery field" \
                   || no "durable record missing:$MISS" "$(cat "$ILOG")"
    grep -q "BACKUP_SHA256=$SRC_SHA" "$ILOG" \
        && ok "recorded sha256 matches the preserved bytes" \
        || no "recorded sha256 does not match" ""
    grep -qi 'table inet operator_custom' "$ILOG" \
        && no "durable record leaked file CONTENT" "records reference content, never embed it" \
        || ok "durable record references content without embedding it"
else
    no "no durable record written" ""
fi

# ---- ROW 5: preservation failure MUST abort --------------------------------
echo "-- ROW 5  backup impossible -> ABORT before displacement ---------------"
setup
printf '# OPERATOR CUSTOM POLICY\ntable inet operator_custom { }\n' > "$CONF"
BEFORE=$(sha256sum "$CONF" | cut -d' ' -f1)
mkdir -p "$(dirname "$BDIR")"
: > "$BDIR"          # a FILE where the backup dir must be => mkdir -p fails
mk_dpkg_query "00000000000000000000000000000000"
RC=$(run_fn)
[ "$RC" != "0" ] && ok "rc=$RC (non-zero: preinst fails, dpkg does not unpack)" \
                 || no "rc=0 — unknown content would be displaced unpreserved" ""
grep -qi 'refusing to continue' "$W/err" && ok "operator told why it stopped" \
    || no "abort reason not surfaced on stderr" "$(cat "$W/err")"
[ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$BEFORE" ] \
    && ok "original file untouched by the failed transition" \
    || no "original mutated despite abort" ""

# ---- ROW 6: idempotence -----------------------------------------------------
echo "-- ROW 6  rerun after transition -> no second backup -------------------"
setup
printf '# OPERATOR CUSTOM POLICY\ntable inet operator_custom { }\n' > "$CONF"
mk_dpkg_query "00000000000000000000000000000000"
RC=$(run_fn); N1=$(nbackups)
# After the transition dpkg no longer records it as a conffile.
mk_dpkg_query ""
RC2=$(run_fn); N2=$(nbackups)
[ "$N1" = "1" ] && ok "first run preserved once" || no "first run backups=$N1" ""
[ "$RC2" = "0" ] && ok "rerun rc=0" || no "rerun rc=$RC2" ""
[ "$N2" = "1" ] && ok "rerun cut NO second backup (idempotent)" \
                || no "rerun created another backup (backups=$N2)" ""

# ---- ROW 7: applicability gate ---------------------------------------------
echo "-- ROW 7  not a registered conffile -> transition does not apply -------"
# Proves the gate is dpkg STATE, not a private marker we could write ourselves.
setup
printf '# OPERATOR CUSTOM POLICY\ntable inet operator_custom { }\n' > "$CONF"
mk_dpkg_query ""
RC=$(run_fn)
[ "$RC" = "0" ] && ok "rc=0 (no-op)" || no "rc=$RC" "$(cat "$W/err")"
[ "$(nbackups)" = "0" ] \
    && ok "no backup when the old ownership model is already gone" \
    || no "transition ran outside its applicability window" ""
[ ! -s "$W/out" ] && ok "silent when not applicable" || ok "output: $(head -1 "$W/out")"

echo
echo "== RESULT: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
