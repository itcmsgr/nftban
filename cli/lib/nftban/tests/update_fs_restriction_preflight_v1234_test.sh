#!/usr/bin/env bash
# =============================================================================
# NFTBan - immutable-flag ownership + filesystem-restriction preflight (v1.234)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="update_fs_restriction_preflight_v1234_test"
# meta:type="test"
# meta:version="2.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-30"
# meta:description="v1.234 PR #1439 acceptance. Drives the REAL cli/lib/nftban/lib/nftban_immutable_owned.sh (through the real CLI helpers in cmd_update_helpers.sh, through the RPM preun/posttrans text in packaging/build_nftban.sh, and through the generated DEB copies) against stub lsattr/chattr/findmnt/dpkg-query/test over a sandbox tree. Pins: (1) NFTBan removes or restores only flags whose ownership is PROVEN by the record (inode+ctime) or the pre-v1.234 installer.log line - a candidate PATH alone is never proof; (2) every blocked destination is refused before any chattr, with its cause - IMMUTABLE, APPEND-ONLY, READ-ONLY, WRITE-DENIED (permission/MAC never reported as immutable) - and an immutable directory blocks its own entries only, not the tree; inspection that cannot run is UNMEASURED; (3) the optional /usr/bin/yq link never aborts a maintainer script, never replaces an existing yq, and internal callers use the bundled yq; (4) the RPM preun strips only on erase, the RPM posttrans restores only flags NFTBan set in this transaction. FAILS on v1.233.1, PASSES on the fix."
# meta:input="cli/lib/nftban/lib/nftban_immutable_owned.sh, cli/lib/nftban/cli/cmd_update_helpers.sh, packaging/deb/postinst, packaging/deb/preinst, packaging/build_nftban.sh, build/+i-lifecycle-matrix.yaml, build/generate-immutable-owned-blocks.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,mktemp,stat,date"
# meta:inventory.files="cli/lib/nftban/lib/nftban_immutable_owned.sh,cli/lib/nftban/cli/cmd_update_helpers.sh,packaging/deb/postinst,packaging/deb/preinst,packaging/build_nftban.sh,build/+i-lifecycle-matrix.yaml"
# meta:inventory.binaries="bash,awk,grep,sed,mktemp,stat,date"
# meta:inventory.env_vars="NFTBAN_IMMUT_RECORD,NFTBAN_IMMUT_INSTALLER_LOG,NFTBAN_IMMUT_CANDIDATES,NFTBAN_IMMUT_FIXED_DIRS,NFTBAN_IMMUT_TEST_BIN,UPDATE_LOG_FILE"
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
LIB="$REPO/cli/lib/nftban/lib/nftban_immutable_owned.sh"
HELPERS="$REPO/cli/lib/nftban/cli/cmd_update_helpers.sh"
POSTINST="$REPO/packaging/deb/postinst"
BUILD_SH="$REPO/packaging/build_nftban.sh"
MATRIX="$REPO/build/+i-lifecycle-matrix.yaml"
GEN="$REPO/build/generate-immutable-owned-blocks.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
for f in "$HELPERS" "$POSTINST" "$BUILD_SH" "$MATRIX"; do
    [[ -f "$f" ]] || { echo "NOT_EXECUTED: missing $f" >&2; exit 1; }
done
[[ -f "$LIB" ]] || no "L0 shared library cli/lib/nftban/lib/nftban_immutable_owned.sh exists" "absent (path-based ownership)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- stub toolchain: ATTRDB is the only view of attribute flags; MOUNTDB of mounts ----
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/lsattr" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-d" ]] && shift; [[ "${1:-}" == "--" ]] && shift
rc=0
for p in "$@"; do
  if [[ -n "${STUB_LSATTR_UNSUPPORTED:-}" && "$p" == "$STUB_LSATTR_UNSUPPORTED"* ]]; then
    echo "lsattr: Operation not supported While reading flags on $p" >&2; rc=1; continue; fi
  a=$(awk -v p="$p" '$2==p{print $1}' "$ATTRDB" | tail -1)
  printf '%s %s\n' "${a:---------------e-------}" "$p"
done
exit $rc
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
cat > "$STUB/test" <<'EOF'
#!/usr/bin/env bash
# write-access stub: paths listed in $DENYDB are not writable (permission/MAC)
[[ "$1" == "-w" ]] || exec /usr/bin/test "$@"
grep -qxF -- "$2" "$DENYDB" && exit 1
exit 0
EOF
chmod +x "$STUB"/*

S="$WORK/root"
CONF="$S/etc/nftban/nftban.conf"; SCHEMA="$S/usr/lib/nftban/lib/nft_schema.sh"; BIN="$S/usr/lib/nftban/bin/nftband"
mk_tree() {
    rm -rf "$S"; mkdir -p "$S/usr/lib/nftban/bin" "$S/usr/lib/nftban/lib" "$S/usr/lib/nftban/data" "$S/etc/nftban/whitelist.d" "$S/usr/sbin" "$S/etc/sysctl.d"
    : > "$BIN"; : > "$SCHEMA"; : > "$S/usr/sbin/nftban"; : > "$CONF"; : > "$S/usr/lib/nftban/data/x.json"
    : > "$S/etc/nftban/whitelist.d/99-manual.conf"; : > "$S/etc/sysctl.d/90-nftban.conf"
    printf '%s\n' "$S/usr/lib/nftban/bin" "$BIN" "$S/usr/lib/nftban/lib" "$SCHEMA" "$S/usr/sbin/nftban" \
        "$S/etc/nftban" "$CONF" "$S/etc/sysctl.d/90-nftban.conf" > "$WORK/manifest"
    printf '%s\n' "$CONF" "$S/etc/sysctl.d/90-nftban.conf" > "$WORK/conffiles"
    : > "$WORK/attrdb"; : > "$WORK/chattr.log"; : > "$WORK/deny"; : > "$WORK/record"; : > "$WORK/installer.log"
    echo "/ rw,relatime" > "$WORK/mountdb"
}
setattr(){ echo "$1 $2" >> "$WORK/attrdb"; }
attr_of(){ awk -v p="$1" '$2==p{print $1}' "$WORK/attrdb" | tail -1; }
record(){  # PATH STATE [WRITTEN_AT] — an entry for the file's CURRENT inode+ctime
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$(stat -c %i "$1")" "$(stat -c %Z "$1")" "$2" "${3:-1}" >> "$WORK/record"
}
ENVV=(HOME="$WORK" PATH="$STUB:/usr/bin:/bin" ATTRDB="$WORK/attrdb" CHATTR_LOG="$WORK/chattr.log"
      MOUNTDB="$WORK/mountdb" MANIFEST="$WORK/manifest" CONFFILES="$WORK/conffiles" DENYDB="$WORK/deny"
      NFTBAN_IMMUT_RECORD="$WORK/record" NFTBAN_IMMUT_INSTALLER_LOG="$WORK/installer.log"
      NFTBAN_IMMUT_CANDIDATES="$CONF $SCHEMA" NFTBAN_IMMUT_FIXED_DIRS="$S/usr/sbin $S/usr/lib/nftban"
      NFTBAN_IMMUT_TEST_BIN="$STUB/test" NFTBAN_CONFIG_DIR="$S/etc/nftban" NFTBAN_LIB_DIR="$S/usr/lib/nftban"
      UPDATE_LOG_FILE="$WORK/update.log")
run_subject() {  # $1 = snippet run after sourcing the real CLI helpers
    env -i "${ENVV[@]}" STUB_LSATTR_UNSUPPORTED="${STUB_LSATTR_UNSUPPORTED:-}" \
        bash -c 'set -Eeuo pipefail; source "$1"; shift; eval "$1"' _ "$HELPERS" "$1" > "$WORK/out" 2>&1
}

echo "=========================================================="
echo "v1.234 PR #1439: proven immutable ownership + restriction preflight"
echo "=========================================================="

# T1 — administrator +i on a payload file: refused, nothing changed.
mk_tree; setattr "----i---------e-------" "$BIN"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 && ! -s "$WORK/chattr.log" && "$(attr_of "$BIN")" == *i* ]] && grep -qF "IMMUTABLE file $BIN" "$WORK/out"; then
    ok "T1 admin +i on nftband: refused before any chattr, path and cause named"
else no "T1 admin +i refused" "rc=$rc chattr=$(tr '\n' ';' < "$WORK/chattr.log") out=$(head -c 300 "$WORK/out")"; fi

# T2 — acceptance 1: a candidate PATH is not proof. +i on nft_schema.sh with NO record and
# NO installer.log proof is administrator-owned: refused, never cleared.
mk_tree; setattr "----i---------e-------" "$SCHEMA"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 && ! -s "$WORK/chattr.log" ]] && grep -qF "IMMUTABLE file $SCHEMA" "$WORK/out"; then
    ok "T2 unproven flag on a candidate path (nft_schema.sh): refused, not cleared"
else no "T2 path alone is not ownership" "rc=$rc chattr=$(tr '\n' ';' < "$WORK/chattr.log")"; fi

# T3 — proven by the record: unlocked during the operation, restored exactly after.
mk_tree; setattr "----i---------e-------" "$CONF"; setattr "----i---------e-------" "$SCHEMA"
record "$CONF" locked; record "$SCHEMA" locked
rc=0; run_subject '_remove_immutable_flags; echo "MID=$(lsattr -d "$NFTBAN_CONFIG_DIR/nftban.conf")"; _restore_owned_immutable_flags' || rc=$?
bad=$(grep -E '^chattr -i' "$WORK/chattr.log" | grep -vF -e "$CONF" -e "$SCHEMA" || true)
if [[ $rc -eq 0 && -z "$bad" ]] && grep -q 'MID=----------' "$WORK/out" && [[ "$(attr_of "$CONF")" == *i* && "$(attr_of "$SCHEMA")" == *i* ]]; then
    ok "T3 record-proven flags: unlocked during the operation, restored after"
else no "T3 proven unlock/relock" "rc=$rc bad=$bad out=$(head -c 300 "$WORK/out")"; fi

# T4 — record entry no longer matches (attributes changed since: ctime moved): not proven.
mk_tree; setattr "----i---------e-------" "$SCHEMA"
printf '%s\t%s\t%s\tlocked\t1\n' "$SCHEMA" "$(stat -c %i "$SCHEMA")" "$(( $(stat -c %Z "$SCHEMA") - 100 ))" >> "$WORK/record"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 && ! -s "$WORK/chattr.log" ]]; then ok "T4 stale record entry (ctime differs) is not proof"; else no "T4 stale record" "rc=$rc"; fi

# T5 — pre-v1.234 flag: proven only by an installer.log line at the file's ctime.
mk_tree; setattr "----i---------e-------" "$SCHEMA"
echo "$(date -u -d "@$(stat -c %Z "$SCHEMA")" +%Y-%m-%dT%H:%M:%SZ) [DEBUG] set immutable: $SCHEMA" > "$WORK/installer.log"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -eq 0 ]] && grep -q "^chattr -i -- $SCHEMA" "$WORK/chattr.log"; then
    ok "T5 pre-v1.234 flag adopted only with installer.log proof at its ctime"
else no "T5 legacy proof" "rc=$rc out=$(head -c 300 "$WORK/out")"; fi

# T5b — owner direction: a historical installer.log line proves a historical action,
# not ownership of TODAY's flag. Every negative case must be REFUSED (no chattr).
legacy_neg() {  # LABEL — expects refusal with the current tree/log/record
    local rc=0; run_subject '_remove_immutable_flags' || rc=$?
    if [[ $rc -ne 0 && ! -s "$WORK/chattr.log" ]]; then ok "$1"; else no "$1" "rc=$rc chattr=$(tr '\n' ';' < "$WORK/chattr.log")"; fi
}
ts_of(){ date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
mk_tree; setattr "----i---------e-------" "$SCHEMA"; ct=$(stat -c %Z "$SCHEMA")
echo "$(ts_of $((ct - 5))) [DEBUG] set immutable: $SCHEMA" > "$WORK/installer.log"
legacy_neg "T5b-a NFTBan set it earlier, admin removed and re-set it (same inode, ctime moved): refused"
mk_tree; setattr "----i---------e-------" "$SCHEMA"; ct=$(stat -c %Z "$SCHEMA")
echo "$(ts_of $((ct + 1))) [DEBUG] set immutable: $SCHEMA" > "$WORK/installer.log"
legacy_neg "T5b-a2 log line one second off the ctime: refused (no tolerance window)"
mk_tree; setattr "----i---------e-------" "$SCHEMA"; ct=$(stat -c %Z "$SCHEMA")
{ echo "$(ts_of "$ct") [DEBUG] set immutable: $SCHEMA"; echo "$(ts_of $((ct + 60))) [DEBUG] set immutable: $SCHEMA"; } > "$WORK/installer.log"
legacy_neg "T5b-c matching line is not the LAST one for the path: refused"
mk_tree; setattr "----i---------e-------" "$SCHEMA"; ct=$(stat -c %Z "$SCHEMA")
echo "$(ts_of "$ct") [DEBUG] set immutable: $SCHEMA.bak" > "$WORK/installer.log"
legacy_neg "T5b-c2 line for another path with the same prefix: refused"
mk_tree; old_ino=$(stat -c %i "$SCHEMA"); old_ct=$(stat -c %Z "$SCHEMA")
printf '%s\t%s\t%s\tlocked\t1\n' "$SCHEMA" "$old_ino" "$old_ct" > "$WORK/record"
sleep 1; cp "$SCHEMA" "$SCHEMA.new"; mv -f "$SCHEMA.new" "$SCHEMA"; setattr "----i---------e-------" "$SCHEMA"
echo "$(ts_of "$(stat -c %Z "$SCHEMA")") [DEBUG] set immutable: $SCHEMA" > "$WORK/installer.log"
legacy_neg "T5b-b admin replaced the file (new inode) and set +i; the record knows the path: refused even with a same-second log line"
if grep -q 'deliberate removal of one specific protection' "$WORK/out" && ! grep -qi 'clear it with chattr -i and retry' "$WORK/out"; then
    ok "T5c refusal guidance: a conscious administrator decision on a named path, not a repair step"
else no "T5c guidance wording" "$(grep -m3 -iE 'chattr|deliberate' "$WORK/out" | tr '\n' ';')"; fi

# T5d — re-lock is checked: a failing chattr +i or a changed file is REPORTED, never silent.
mk_tree; setattr "----i---------e-------" "$CONF"; record "$CONF" locked
cat > "$WORK/chattr_fail_plus" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == "+i" ]] && { echo "chattr $*" >> "$CHATTR_LOG"; exit 1; }
exec "$(dirname "$0")/chattr.real" "$@"
EOF2
cp "$STUB/chattr" "$STUB/chattr.real"; cp "$WORK/chattr_fail_plus" "$STUB/chattr"; chmod +x "$STUB/chattr"
rc=0; run_subject '_remove_immutable_flags; _restore_owned_immutable_flags' || rc=$?
if [[ $rc -ne 0 ]] && grep -q 'Could NOT re-apply' "$WORK/out"; then ok "T5d re-lock failure reported with the path (rc!=0)"; else no "T5d relock failure" "rc=$rc $(tail -c 300 "$WORK/out")"; fi
cp "$STUB/chattr.real" "$STUB/chattr"; rm -f "$STUB/chattr.real"
mk_tree; setattr "----i---------e-------" "$CONF"; record "$CONF" locked
rc=0; run_subject '_remove_immutable_flags; cp "$NFTBAN_CONFIG_DIR/nftban.conf" /tmp/x.$$ 2>/dev/null; rm -f "$NFTBAN_CONFIG_DIR/nftban.conf"; mv /tmp/x.$$ "$NFTBAN_CONFIG_DIR/nftban.conf"; _restore_owned_immutable_flags' || rc=$?
if grep -q 'changed since; protection not re-applied' "$WORK/out"; then ok "T5e file changed after NFTBan unlocked it: not re-locked blindly, reported"; else no "T5e NOT_RELOCKED" "rc=$rc $(tail -c 300 "$WORK/out")"; fi

# T6 — distinct causes; an immutable directory blocks its own entries, not the tree.
mk_tree; setattr "----i------I--e-------" "$S/usr/lib/nftban/bin"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 && ! -s "$WORK/chattr.log" ]] && grep -qF "IMMUTABLE dir $S/usr/lib/nftban/bin " "$WORK/out"; then
    ok "T6a immutable destination directory refused"; else no "T6a immutable dir" "rc=$rc"; fi
mk_tree; echo "$S/usr/lib/nftban ro,relatime" >> "$WORK/mountdb"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 ]] && grep -q "READ-ONLY dir $S/usr/lib/nftban" "$WORK/out" && ! grep -qE 'IMMUTABLE (file|dir) ' "$WORK/out"; then
    ok "T6b read-only mount refused as READ-ONLY (not immutable)"; else no "T6b read-only" "rc=$rc"; fi
mk_tree; echo "$S/usr/sbin" > "$WORK/deny"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -ne 0 ]] && grep -q "WRITE-DENIED dir $S/usr/sbin" "$WORK/out" && ! grep -qE 'IMMUTABLE (file|dir) ' "$WORK/out"; then
    ok "T6c permission/MAC denial refused as WRITE-DENIED (not immutable)"; else no "T6c write-denied" "rc=$rc out=$(head -c 300 "$WORK/out")"; fi
mk_tree; setattr "----i------I--e-------" "$S/usr/lib/nftban/data"
rc=0; run_subject '_remove_immutable_flags' || rc=$?
if [[ $rc -eq 0 ]]; then ok "T6d immutable dir holding no payload entry does not block (not recursive)"; else no "T6d not recursive" "rc=$rc out=$(head -c 300 "$WORK/out")"; fi

# T7 — unsupported attribute inspection: UNMEASURED, never "no restriction".
mk_tree
rc=0; STUB_LSATTR_UNSUPPORTED="$S/usr/lib/nftban/bin" run_subject '_update_fs_restriction_preflight' || rc=$?
if grep -q 'UNMEASURED' "$WORK/out"; then ok "T7 unsupported attribute read reported UNMEASURED"; else no "T7 UNMEASURED" "$(head -c 300 "$WORK/out")"; fi

# T8 — unchanged-conffile flag (dpkg leaves it) warns; operator file outside payload untouched.
mk_tree; setattr "----i---------e-------" "$S/etc/sysctl.d/90-nftban.conf"; setattr "----i---------e-------" "$S/etc/nftban/whitelist.d/99-manual.conf"
rc=0; run_subject '_remove_immutable_flags; _restore_owned_immutable_flags' || rc=$?
if [[ $rc -eq 0 && ! -s "$WORK/chattr.log" ]] && grep -q 'conffile' "$WORK/out"; then
    ok "T8 conffile flag warned; operator-owned flag outside the payload untouched"
else no "T8 conffile/operator" "rc=$rc log=$(tr '\n' ';' < "$WORK/chattr.log")"; fi

# T9 — library candidates == +i matrix protected_files (drift guard).
yaml=$(awk '/^protected_files:/{p=1} p && /- path:/{print $3}' "$MATRIX" | sort)
cand=$(env -i PATH=/usr/bin:/bin sh -c '. "$1"; _nftban_immut_candidates' _ "$LIB" 2>/dev/null | sort || true)
if [[ -n "$yaml" && "$yaml" == "$cand" ]]; then ok "T9 library candidates == +i matrix protected_files"; else no "T9 candidates" "yaml=[$yaml] lib=[$cand]"; fi

# T10 — generated DEB copies are byte-identical to the library.
if [[ -f "$GEN" ]] && bash "$GEN" --check >/dev/null 2>&1; then ok "T10 DEB maintainer-script copies of the library are current"
else no "T10 generated copies current" "build/generate-immutable-owned-blocks.sh --check failed or missing"; fi

# T11 — RPM scriptlets (real spec text, library substituted as the build does).
libtxt=$(bash "$GEN" --body 2>/dev/null || true)
if [[ -n "$libtxt" ]] && ! grep -qE 'SPDX-|Copyright|meta:' <<< "$libtxt" && ! grep -qE 'SPDX-|Copyright|meta:' < <(awk '/# == BEGIN GENERATED immutable-owned lib ==/{p=1;next} /# == END GENERATED immutable-owned lib ==/{p=0} p' "$REPO/packaging/deb/preinst" "$REPO/packaging/deb/prerm" "$POSTINST"); then
    ok "T10b injected library copies (DEB regions, RPM body) carry no SPDX/copyright/meta line"
else no "T10b no legal header in injected copies" "legal lines present or body empty"; fi
spec_section() { awk -v s="$1" '$0==s {p=1; next} p && /^%[a-z]+( |$)/ {exit} p' "$BUILD_SH" | sed -e 's/\\\$/$/g'; }
# The replacement is QUOTED: under bash >= 5.2 (patsub_replacement) an unquoted
# replacement turns every '&' of the library into the matched pattern, the scriptlet
# no longer parses, and the "removes nothing" arms pass on a script that never ran.
preun=$(spec_section '%preun'); preun=${preun%%# MFST-C3*}; preun=${preun//'${rpm_immut_lib}'/"$libtxt"}
post=$(spec_section '%posttrans'); post=${post//'${rpm_immut_lib}'/"$libtxt"}
for _sc in preun post; do
    if [[ -n "${!_sc}" ]] && sh -n -c "${!_sc}" 2>/dev/null; then ok "T11-pre RPM $_sc scriptlet (library substituted) parses"
    else no "T11-pre RPM $_sc scriptlet parses" "$(sh -n -c "${!_sc}" 2>&1 | head -c 300)"; fi
done
run_spec() { env -i "${ENVV[@]}" sh -c "$1" _ "$2" >/dev/null 2>&1 || true; }
mk_tree; setattr "----i---------e-------" "$CONF"; record "$CONF" locked
run_spec "$preun" 1
if [[ ! -s "$WORK/chattr.log" ]]; then ok "T11a RPM preun on upgrade (\$1=1) removes nothing"; else no "T11a preun upgrade" "$(tr '\n' ';' < "$WORK/chattr.log")"; fi
run_spec "$preun" 0
if grep -q "chattr -i -- $CONF" "$WORK/chattr.log"; then ok "T11b RPM preun on erase removes the PROVEN flag"; else no "T11b preun erase proven" "$(tr '\n' ';' < "$WORK/chattr.log")"; fi
mk_tree; setattr "----i---------e-------" "$CONF"
run_spec "$preun" 0
if [[ ! -s "$WORK/chattr.log" ]]; then ok "T11c RPM preun on erase leaves an unproven flag"; else no "T11c preun erase unproven" "$(tr '\n' ';' < "$WORK/chattr.log")"; fi
if [[ -n "$post" ]] && grep -q 'nftban_immut_txn_restore' <<< "$post"; then
    post_t=${post//\/run\/nftban-rpm-txn-start/$WORK\/txn}
    mk_tree; record "$CONF" locked 2000; record "$SCHEMA" locked 500; echo 1000 > "$WORK/txn"
    run_spec "$post_t" 0
    if [[ "$(attr_of "$CONF")" == *i* && "$(attr_of "$SCHEMA")" != *i* ]]; then
        ok "T11d RPM posttrans restores only flags NFTBan set in this transaction"
    else no "T11d posttrans restore" "conf=$(attr_of "$CONF") schema=$(attr_of "$SCHEMA")"; fi
else
    no "T11d RPM posttrans transition restore present" "no posttrans with nftban_immut_txn_restore"
fi
pretrans=$(awk '/^%pretrans -p <lua>$/{p=1;next} p && /^%pre$/{exit} p' "$BUILD_SH")
if ! grep -qE 'chattr -i -R|chattr -R -i' <<< "$pretrans" && grep -q 'nftban_immut_pkg_preflight rpm' <<< "$pretrans"; then
    ok "T11e RPM pretrans: shared preflight, no recursive unlock"
else no "T11e pretrans shape" "recursive unlock present or shared preflight missing"; fi

# T13 — failure exits re-lock what was unlocked: DEB preinst EXIT trap, DEB postrm and
# postinst abort branches, RPM pre EXIT trap (shape; behaviour is package-native).
pre_src=$(cat "$REPO/packaging/deb/preinst")
rpm_pre=$(awk '$0=="%pre" {p=1; next} p && /^%[a-z]+( |$)/ {exit} p' "$BUILD_SH")
if grep -q "trap '_nftban_rc=\$?; if \[ \"\$_nftban_rc\" -ne 0 \]; then nftban_immut_relock_owned" <<< "$pre_src" \
   && awk 'index($0, "abort-install|abort-upgrade)") {n=5} n-- > 0 && /nftban_immut_relock_owned/ {f=1} END {exit f ? 0 : 1}' "$REPO/packaging/deb/postrm" \
   && awk 'index($0, "abort-upgrade|abort-remove|abort-deconfigure)") {n=4} n-- > 0 && /nftban_immut_relock_owned/ {f=1} END {exit f ? 0 : 1}' "$POSTINST" \
   && grep -q 'nftban_immut_relock_owned' <<< "$rpm_pre" && grep -q 'trap ' <<< "$rpm_pre"; then
    ok "T13 every failure exit after an unlock re-applies it (DEB preinst trap, postrm/postinst abort, RPM pre trap)"
else no "T13 failure-path relock" "missing trap/abort relock"; fi

# T14 — unlock-authority gate: source tree clean, and it catches a planted unchecked unlock.
GATE="$REPO/scripts/ci/check-immutable-unlock-authority.sh"
if [[ -f "$GATE" ]] && bash "$GATE" >/dev/null 2>&1; then ok "T14a no chattr -i/-R outside the proven-ownership implementation (source)"; else no "T14a unlock gate on source" "gate missing or FAIL"; fi
if [[ -f "$GATE" ]]; then
    F="$WORK/fx"; mkdir -p "$F/scripts/ci" "$F/packaging/deb" "$F/cli" "$F/internal" "$F/cmd"
    cp "$GATE" "$F/scripts/ci/"; for x in preinst postinst prerm postrm; do echo '#!/bin/sh' > "$F/packaging/deb/$x"; done
    printf '#!/bin/sh\nchattr -i /etc/nftban/nftban.conf\n' > "$F/packaging/deb/preinst"; : > "$F/packaging/build_nftban.sh"
    rc=0; bash "$F/scripts/ci/check-immutable-unlock-authority.sh" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 1 ]]; then ok "T14b gate FAILS on a planted unchecked chattr -i (negative control)"; else no "T14b gate negative control" "rc=$rc"; fi
fi

# T12 — /usr/bin/yq: optional, never fatal, never replaces an existing yq; internal callers bundled.
extract_fn() { awk -v n="$2" '!p && index($0, n "() {") { p=1; match($0,/^[ \t]*/); pad=substr($0,1,RLENGTH); print; next }
        p { print; sub(/[ \t]+$/,""); if ($0 == pad "}") exit }' "$1"; }
cat > "$STUB/ln" <<'EOF'
#!/usr/bin/env bash
echo "ln: failed to create symbolic link '${@: -1}': Operation not permitted" >&2; exit 1
EOF
chmod +x "$STUB/ln"; mkdir -p "$WORK/usrbin"; : > "$WORK/yq"; chmod +x "$WORK/yq"
for pair in "DEB postinst:$POSTINST" "RPM post:$BUILD_SH"; do
    label=${pair%%:*}; file=${pair#*:}
    fn=$(extract_fn "$file" _nftban_link_yq | sed 's/\\\$/$/g')
    if [[ -z "$fn" ]]; then no "T12 $label: guarded _nftban_link_yq" "absent"; continue; fi
    body=${fn//\/usr\/lib\/nftban\/bin\/yq/$WORK\/yq}; body=${body//\/usr\/bin\/yq/$WORK\/usrbin\/yq}
    rm -f "$WORK/usrbin/yq"
    rc=0; out=$(env -i PATH="$STUB" /bin/bash -c 'set -Eeuo pipefail; log_info(){ echo "[I] $*"; }; log_warn(){ echo "[W] $*"; }; eval "$1"; _nftban_link_yq; echo REACHED' _ "$body" 2>&1) || rc=$?
    if [[ $rc -eq 0 && "$out" == *REACHED* && "$out" == *"lsattr -d /usr/bin"* ]]; then ok "T12a $label: refused link is reported, not fatal"; else no "T12a $label" "rc=$rc $out"; fi
    echo "system-yq" > "$WORK/usrbin/yq"
    env -i PATH="/usr/bin:/bin" bash -c 'set -Eeuo pipefail; log_info(){ :; }; log_warn(){ :; }; eval "$1"; _nftban_link_yq' _ "$body" >/dev/null 2>&1 || true
    if [[ ! -L "$WORK/usrbin/yq" && "$(cat "$WORK/usrbin/yq")" == system-yq ]]; then ok "T12b $label: existing /usr/bin/yq never replaced"; else no "T12b $label" "replaced"; fi
done
bare=$(grep -nE '(^|[^_A-Za-z/"$-])yq +-r' "$REPO/cli/lib/nftban/core/nftban_health_checks_config.sh" "$REPO/cli/lib/nftban/core/nftban_health_fixes.sh" \
       "$REPO/scripts/generate-help.sh" "$REPO/scripts/generate-wiki-auditor.sh" "$REPO/scripts/generate-wiki-operator.sh" || true)
if [[ -z "$bare" ]]; then ok "T12c internal yq callers use the bundled binary (no PATH yq dependency)"; else no "T12c bundled yq" "$bare"; fi

echo "----------------------------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf '  failed: %s\n' "${FAILED[@]}"; exit 1; fi
(( PASS > 0 )) || { echo "NOT_EXECUTED: zero assertions"; exit 1; }
exit 0
