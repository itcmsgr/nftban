#!/usr/bin/env bash
# =============================================================================
# NFTBan - update/repair/rollback filesystem-restriction preflight (v1.234)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="update_fs_restriction_preflight_v1234_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-30"
# meta:description="v1.234 BUG-UPDATE-STRIPS-ADMIN-IMMUTABLE-FLAGS / BUG-UPDATE-OWNED-FLAGS-NOT-RELOCKED / BUG-DEB-POSTINST-YQ-LINK-FATAL-ON-RESTRICTED-USRBIN. Measured on deb-clean (Ubuntu 24.04) with real packages: `nftban update github`, `update repair` and (v1.233.1) `update github|force|repair --help` ran chattr -i on every file under /usr/lib/nftban, /etc/nftban and /usr/sbin/nftban, silently removing administrator-set +i, and never re-applied NFTBan's own +i when no package transaction ran; an immutable /usr/bin made the DEB postinst die on the optional /usr/bin/yq link (package iF, installer never ran). This test drives the real _remove_immutable_flags / _restore_owned_immutable_flags from cmd_update_helpers.sh against stub lsattr/chattr/findmnt/dpkg-query over a sandbox tree (hermetic; the stub attribute DB is the subject's only view of flags, so root cannot defeat it), and executes the real _nftban_link_yq bodies from the DEB postinst and the RPM %post under set -e with a failing ln. FAILS on v1.233.1, PASSES on the fix."
# meta:input="cli/lib/nftban/cli/cmd_update_helpers.sh, packaging/deb/postinst, packaging/build_nftban.sh, build/+i-lifecycle-matrix.yaml"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh,packaging/deb/postinst,packaging/build_nftban.sh,build/+i-lifecycle-matrix.yaml"
# meta:inventory.binaries="bash,awk,grep,sed,mktemp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,UPDATE_LOG_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="update_fs_restriction_preflight_v1234_test"
# meta:ta.owner="update"
# meta:ta.module="immutable-lifecycle"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
HELPERS="$REPO/cli/lib/nftban/cli/cmd_update_helpers.sh"
POSTINST="$REPO/packaging/deb/postinst"
BUILD_SH="$REPO/packaging/build_nftban.sh"
MATRIX="$REPO/build/+i-lifecycle-matrix.yaml"
for f in "$HELPERS" "$POSTINST" "$BUILD_SH" "$MATRIX"; do
    [[ -f "$f" ]] || { echo "NOT_EXECUTED: missing $f" >&2; exit 1; }
done

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# Stub toolchain. ATTRDB holds "<attrs> <path>" lines: the subject's only view
# of attribute flags. chattr edits it and logs every call; findmnt reports the
# mount options in MOUNTDB; dpkg-query serves the sandbox manifest.
# -----------------------------------------------------------------------------
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/lsattr" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-d" ]] && shift; [[ "${1:-}" == "--" ]] && shift
for p in "$@"; do
  if [[ -n "${STUB_LSATTR_UNSUPPORTED:-}" && "$p" == "$STUB_LSATTR_UNSUPPORTED"* ]]; then
    echo "lsattr: Operation not supported While reading flags on $p" >&2; continue; fi
  a=$(awk -v p="$p" '$2==p{print $1}' "$ATTRDB" | tail -1)
  printf '%s %s\n' "${a:---------------e-------}" "$p"
done
EOF
cat > "$STUB/chattr" <<'EOF'
#!/usr/bin/env bash
echo "chattr $*" >> "$CHATTR_LOG"
op=$1; shift; [[ "${1:-}" == "--" ]] && shift
for p in "$@"; do
  cur=$(awk -v p="$p" '$2==p{print $1}' "$ATTRDB" | tail -1); cur=${cur:---------------e-------}
  case "$op" in -i) new="${cur:0:4}-${cur:5}";; +i) new="${cur:0:4}i${cur:5}";; *) exit 2;; esac
  grep -v " $p\$" "$ATTRDB" > "$ATTRDB.t" || true; mv "$ATTRDB.t" "$ATTRDB"; echo "$new $p" >> "$ATTRDB"
done
EOF
cat > "$STUB/findmnt" <<'EOF'
#!/usr/bin/env bash
t=${@: -1}; best="/"; opts="rw,relatime"
while read -r m o; do [[ "$t" == "$m" || "$t" == "$m"/* ]] && (( ${#m} >= ${#best} )) && { best=$m; opts=$o; }; done < "$MOUNTDB"
printf '%s %s\n' "$best" "$opts"
EOF
cat > "$STUB/dpkg-query" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-W nftban-core") exit 0;;
  "-L nftban-core") cat "$MANIFEST";;
  *Conffiles*) awk '{print " "$0" 0123456789abcdef"}' "$CONFFILES";;
  *) exit 1;;
esac
EOF
chmod +x "$STUB"/*

# Sandbox tree mirroring the package layout.
S="$WORK/root"
mk_tree() {
    rm -rf "$S"; mkdir -p "$S/usr/lib/nftban/bin" "$S/usr/lib/nftban/lib" "$S/etc/nftban/whitelist.d" "$S/usr/sbin" "$S/etc/sysctl.d"
    : > "$S/usr/lib/nftban/bin/nftband"; : > "$S/usr/lib/nftban/lib/nft_schema.sh"; : > "$S/usr/sbin/nftban"
    : > "$S/etc/nftban/nftban.conf"; : > "$S/etc/nftban/whitelist.d/99-manual.conf"; : > "$S/etc/sysctl.d/90-nftban.conf"
    printf '%s\n' "$S/usr/lib/nftban" "$S/usr/lib/nftban/bin" "$S/usr/lib/nftban/bin/nftband" "$S/usr/lib/nftban/lib" \
        "$S/usr/lib/nftban/lib/nft_schema.sh" "$S/usr/sbin/nftban" "$S/etc/nftban" "$S/etc/nftban/nftban.conf" \
        "$S/etc/sysctl.d/90-nftban.conf" > "$WORK/manifest"
    printf '%s\n' "$S/etc/nftban/nftban.conf" "$S/etc/sysctl.d/90-nftban.conf" > "$WORK/conffiles"
    : > "$WORK/attrdb"; : > "$WORK/chattr.log"; echo "/ rw,relatime" > "$WORK/mountdb"
}
setattr(){ echo "$1 $2" >> "$WORK/attrdb"; }
attr_of(){ awk -v p="$1" '$2==p{print $1}' "$WORK/attrdb" | tail -1; }

# Run the REAL helper functions in a child shell: stub PATH first, sandbox dirs.
run_subject() {  # $1 = shell snippet run after sourcing the helpers
    env -i HOME="$WORK" PATH="$STUB:/usr/bin:/bin" ATTRDB="$WORK/attrdb" CHATTR_LOG="$WORK/chattr.log" \
        MOUNTDB="$WORK/mountdb" MANIFEST="$WORK/manifest" CONFFILES="$WORK/conffiles" \
        STUB_LSATTR_UNSUPPORTED="${STUB_LSATTR_UNSUPPORTED:-}" \
        NFTBAN_CONFIG_DIR="$S/etc/nftban" NFTBAN_LIB_DIR="$S/usr/lib/nftban" UPDATE_LOG_FILE="$WORK/update.log" \
        bash -c 'set -Eeuo pipefail; source "$1"; shift; eval "$1"' _ "$HELPERS" "$1" > "$WORK/out" 2>&1
}

echo "=========================================================="
echo "v1.234: update filesystem-restriction preflight + owned-flag relock"
echo "=========================================================="

# T1 — administrator +i on a payload file NFTBan does not own => refuse, mutate NOTHING.
mk_tree
setattr "----i---------e-------" "$S/usr/lib/nftban/bin/nftband"
setattr "----i---------e-------" "$S/etc/nftban/nftban.conf"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 ]]; then ok "T1 admin +i on nftband: refused (rc=$rc)"; else no "T1 admin +i on nftband: refused" "rc=0 — update would proceed"; fi
if [[ ! -s "$WORK/chattr.log" ]]; then ok "T1 no chattr call at all (nothing mutated before refusal)"
else no "T1 no chattr call at all" "$(tr '\n' ';' < "$WORK/chattr.log")"; fi
[[ "$(attr_of "$S/usr/lib/nftban/bin/nftband")" == *i* ]] && ok "T1 admin flag preserved" || no "T1 admin flag preserved" "flag cleared"
grep -qF "$S/usr/lib/nftban/bin/nftband" "$WORK/out" && grep -q 'IMMUTABLE' "$WORK/out" \
    && ok "T1 refusal names the exact blocked path" || no "T1 refusal names the exact blocked path" "$(head -c 300 "$WORK/out")"

# T2 — only NFTBan-owned +i => unlock exactly those; restore puts back exactly that state.
mk_tree
setattr "----i---------e-------" "$S/etc/nftban/nftban.conf"
setattr "----i---------e-------" "$S/usr/lib/nftban/lib/nft_schema.sh"
rc=0; run_subject '_remove_immutable_flags; echo "UNLOCKED=${_NFTBAN_UNLOCKED_OWNED[*]}"; echo "MID_CONF=$(lsattr -d "$NFTBAN_CONFIG_DIR/nftban.conf")"; _restore_owned_immutable_flags' || rc=$?
[[ $rc -eq 0 ]] && ok "T2 owned-only: rc=0" || no "T2 owned-only: rc=0" "rc=$rc $(head -c 300 "$WORK/out")"
grep -q "MID_CONF=----------" "$WORK/out" && ok "T2 owned file unlocked during the operation" || no "T2 owned file unlocked during the operation" "$(grep MID_CONF "$WORK/out" || echo none)"
bad=$(grep -E '^chattr -i' "$WORK/chattr.log" | grep -vF -e "$S/etc/nftban/nftban.conf" -e "$S/usr/lib/nftban/lib/nft_schema.sh" || true)
[[ -z "$bad" ]] && ok "T2 chattr -i only on the owned set" || no "T2 chattr -i only on the owned set" "$bad"
[[ "$(attr_of "$S/etc/nftban/nftban.conf")" == *i* && "$(attr_of "$S/usr/lib/nftban/lib/nft_schema.sh")" == *i* ]] \
    && ok "T2 owned +i restored exactly after a run with no package transaction" || no "T2 owned +i restored" "conf=$(attr_of "$S/etc/nftban/nftban.conf") schema=$(attr_of "$S/usr/lib/nftban/lib/nft_schema.sh")"
grep -qE "^chattr \+i( --)? .*nftband" "$WORK/chattr.log" && no "T2 +i never applied to a file that was not +i before" "nftband locked" || ok "T2 +i never applied to a file that was not +i before"

# T3 — administrator +i on a parent directory of payload files => refuse naming the directory.
mk_tree
setattr "----i------I--e-------" "$S/usr/lib/nftban/bin"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
[[ $rc -ne 0 ]] && grep -qE "IMMUTABLE dir $S/usr/lib/nftban/bin " "$WORK/out" && [[ ! -s "$WORK/chattr.log" ]] \
    && ok "T3 immutable destination directory: refused, named, unmutated" || no "T3 immutable destination directory" "rc=$rc $(head -c 300 "$WORK/out")"

# T4 — read-only mount over a destination => refuse, named as READ-ONLY (distinct from immutable).
mk_tree
echo "$S/usr/lib/nftban ro,relatime" >> "$WORK/mountdb"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
[[ $rc -ne 0 ]] && grep -q "READ-ONLY mount $S/usr/lib/nftban" "$WORK/out" && [[ ! -s "$WORK/chattr.log" ]] \
    && ok "T4 read-only destination: refused as READ-ONLY" || no "T4 read-only destination" "rc=$rc $(head -c 300 "$WORK/out")"

# T5 — attribute inspection unsupported => UNMEASURED, never reported as "no restrictions".
mk_tree
rc=0; STUB_LSATTR_UNSUPPORTED="$S/usr/lib/nftban/bin" run_subject '_update_fs_restriction_preflight' || rc=$?
grep -q 'UNMEASURED' "$WORK/out" && ok "T5 unsupported attribute read reported as UNMEASURED (rc=$rc)" || no "T5 UNMEASURED reported" "$(head -c 300 "$WORK/out")"

# T6 — +i on an UNCHANGED conffile does not block dpkg (measured): warn, do not refuse.
mk_tree
setattr "----i---------e-------" "$S/etc/sysctl.d/90-nftban.conf"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
[[ $rc -eq 0 ]] && grep -q 'conffile' "$WORK/out" && ok "T6 immutable conffile: warned, not refused" || no "T6 immutable conffile" "rc=$rc $(head -c 300 "$WORK/out")"

# T7 — operator file outside the payload keeps its administrator flag and does not block.
mk_tree
setattr "----i---------e-------" "$S/etc/nftban/whitelist.d/99-manual.conf"
rc=0; run_subject '_remove_immutable_flags; _restore_owned_immutable_flags' || rc=$?
[[ $rc -eq 0 && "$(attr_of "$S/etc/nftban/whitelist.d/99-manual.conf")" == *i* ]] && ! grep -q '99-manual' "$WORK/chattr.log" \
    && ok "T7 operator-owned +i outside the payload untouched" || no "T7 operator-owned +i untouched" "rc=$rc log=$(tr '\n' ';' < "$WORK/chattr.log")"

# T8 — the CLI's owned set equals build/+i-lifecycle-matrix.yaml protected_files (drift guard).
yaml=$(awk '/^protected_files:/{p=1} p && /- path:/{print $3}' "$MATRIX" | sort)
cli=$(env -i PATH=/usr/bin:/bin UPDATE_LOG_FILE=/dev/null bash -c 'source "$1"; _nftban_owned_immutable_files' _ "$HELPERS" 2>/dev/null | sort || true)
[[ -n "$yaml" && "$yaml" == "$cli" ]] && ok "T8 owned set == +i matrix protected_files" || no "T8 owned set == +i matrix" "yaml=[$yaml] cli=[$cli]"

# T9/T10 — the optional /usr/bin/yq link must not abort the maintainer script (DEB postinst
# runs under set -Eeuo pipefail). Execute the REAL function bodies with a failing `ln`.
extract_fn() {  # $1 file $2 function name — print the function definition (indent-aware)
    awk -v n="$2" '
        !p && index($0, n "() {") { p=1; match($0,/^[ \t]*/); pad=substr($0,1,RLENGTH); print; next }
        p { print; sub(/[ \t]+$/,""); if ($0 == pad "}") exit }' "$1"
}
cat > "$STUB/ln" <<'EOF'
#!/usr/bin/env bash
echo "ln: failed to create symbolic link '/usr/bin/yq': Operation not permitted" >&2; exit 1
EOF
chmod +x "$STUB/ln"
for pair in "DEB postinst:$POSTINST" "RPM %post:$BUILD_SH"; do
    label=${pair%%:*}; file=${pair#*:}
    fn=$(extract_fn "$file" _nftban_link_yq | sed 's/\\\$/$/g')
    if [[ -z "$fn" ]]; then no "T9 $label: _nftban_link_yq present" "not found — unguarded ln -sf into /usr/bin"; continue; fi
    # Pretend the bundled yq is executable by pointing the test at a temp copy path.
    body=${fn//\/usr\/lib\/nftban\/bin\/yq/$WORK\/yq}
    : > "$WORK/yq"; chmod +x "$WORK/yq"
    rc=0; out=$(env -i PATH="$STUB:/usr/bin:/bin" bash -c 'set -Eeuo pipefail; log_info(){ echo "[I] $*"; }; log_warn(){ echo "[W] $*"; }; eval "$1"; _nftban_link_yq; echo AFTER_LINK_REACHED' _ "$body" 2>&1) || rc=$?
    [[ $rc -eq 0 && "$out" == *AFTER_LINK_REACHED* ]] && ok "T9 $label: failing /usr/bin/yq link does not abort the script" || no "T9 $label: link failure non-fatal" "rc=$rc out=$out"
    [[ "$out" == *"/usr/bin/yq"* && "$out" == *"lsattr -d /usr/bin"* ]] && ok "T10 $label: refusal names /usr/bin/yq with a diagnosis" || no "T10 $label: diagnosis" "$out"
done
unguarded=$(grep -nE '^[[:space:]]*ln -sf /usr/lib/nftban/bin/yq /usr/bin/yq[[:space:]]*$' "$POSTINST" "$BUILD_SH" || true)
[[ -z "$unguarded" ]] && ok "T11 no bare 'ln -sf ... /usr/bin/yq' statement left in the scriptlets" || no "T11 bare ln -sf left" "$unguarded"

# T12 — RPM upgrade ordering: the OLD %preun runs AFTER the NEW %post, so an unconditional
# owned-flag strip there undid the new installer's +i (measured on el9-clean). Execute the
# real %preun strip block with $1=1 (upgrade) and $1=0 (erase) over sandbox copies.
mk_tree
preun=$(awk '/^%preun$/{p=1;next} p && /^# MFST-C3/{exit} p' "$BUILD_SH" | sed -e 's/\\\$/$/g' \
    -e "s#/etc/nftban/nftban.conf#$S/etc/nftban/nftban.conf#g" -e "s#/usr/lib/nftban/lib/nft_schema.sh#$S/usr/lib/nftban/lib/nft_schema.sh#g")
if ! grep -q 'chattr -i' <<< "$preun"; then
    no "T12 %preun strip block found" "no chattr -i in %preun"
else
    : > "$WORK/chattr.log"
    env -i PATH="$STUB:/usr/bin:/bin" ATTRDB="$WORK/attrdb" CHATTR_LOG="$WORK/chattr.log" sh -c "$preun" _ 1 >/dev/null 2>&1 || true
    [[ ! -s "$WORK/chattr.log" ]] && ok "T12 RPM %preun on upgrade (\$1=1) leaves NFTBan-owned +i alone" \
        || no "T12 RPM %preun on upgrade leaves owned +i alone" "$(tr '\n' ';' < "$WORK/chattr.log")"
    : > "$WORK/chattr.log"
    env -i PATH="$STUB:/usr/bin:/bin" ATTRDB="$WORK/attrdb" CHATTR_LOG="$WORK/chattr.log" sh -c "$preun" _ 0 >/dev/null 2>&1 || true
    [[ $(grep -c 'chattr -i' "$WORK/chattr.log") -eq 2 ]] && ok "T12b RPM %preun on erase (\$1=0) still unlocks both owned files" \
        || no "T12b RPM %preun on erase unlocks owned files" "$(tr '\n' ';' < "$WORK/chattr.log")"
fi

# T13 — RPM %pretrans: the pre-v1.234 `chattr -i -R /usr/lib/nftban` sweep removed administrator
# flags on direct dnf upgrade (measured on el9-clean). The %pretrans must refuse (error()) on a
# restriction it does not own and strip only the owned files. Behaviour is proven package-natively
# on el9-clean (FINDINGS.md); this pins the shape so the sweep cannot return.
pretrans=$(awk '/^%pretrans -p <lua>$/{p=1;next} p && /^%pre$/{exit} p' "$BUILD_SH")
if grep -qE 'chattr -i -R|chattr -R -i' <<< "$pretrans"; then no "T13 %pretrans has no recursive chattr -i sweep" "sweep present"
else ok "T13 %pretrans has no recursive chattr -i sweep"; fi
if grep -q 'error("nftban: filesystem restriction preflight refused' <<< "$pretrans" && grep -q 'lsattr -d --' <<< "$pretrans"; then
    ok "T13b %pretrans refuses on restrictions before any file change"
else no "T13b %pretrans refusal present" "no preflight error() in %pretrans"; fi

echo "----------------------------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf '  failed: %s\n' "${FAILED[@]}"; exit 1; fi
(( PASS > 0 )) || { echo "NOT_EXECUTED: zero assertions"; exit 1; }
exit 0
