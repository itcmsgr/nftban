#!/usr/bin/env bash
# =============================================================================
# NFTBan - deprecated-unit cleanup leaves package-owned unit files to rpm
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="deprecated_unit_owned_file_v1236_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-17"
# meta:description="v1.235.1 rollout finding (el10 host, upgrade from v1.234.0): rpm printed 'warning: file /usr/lib/systemd/system/nftban-rollback.timer: remove failed: No such file or directory' (and .service). The new package's %pre deprecated-unit cleanup (remove_unit_file_if_exists) deleted unit files that the installed v1.234.0 nftban-core still owned, so rpm's own erase of the old package found them gone. The helper must leave a file owned by the installed nftban-core to the package manager and still remove an unowned leftover, clear a /dev/null mask and reset the failed latch. Runs the helper body exactly as the generator emits it, with paths rebased into a temp dir and stub rpm/systemctl; never touches the host's systemd or package database."
# meta:input="build/generate-systemd-maintainer-scripts.sh, install/packaging/{deb,rpm}/*.inc, packaging/deb/{preinst,prerm}"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed,readlink,mktemp"
# meta:inventory.files="build/generate-systemd-maintainer-scripts.sh"
# meta:inventory.binaries="bash,grep,sed,readlink,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="units listed in build/deprecated-units.yaml (names only; stubbed)"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="deprecated_unit_owned_file_v1236_test"
# meta:ta.owner="packaging"
# meta:ta.module="systemd-maintainer-scripts"
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
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
GEN="$REPO/build/generate-systemd-maintainer-scripts.sh"
[[ -f "$GEN" ]] || { echo "FAIL: cannot find $GEN" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
UNIT=nftban-rollback.timer

# The helper exactly as emitted, with its absolute paths rebased into $T.
body=$(sed -n '/^remove_unit_file_if_exists() {/,/^}/p' "$GEN")
[[ -n "$body" ]] || { echo "FAIL: remove_unit_file_if_exists not found in $GEN" >&2; exit 1; }
printf '%s\n' "$body" | sed -e "s#/usr/lib/systemd/system#$T/root/usr/lib/systemd/system#g" \
    -e "s#\"/lib/systemd/system#\"$T/root/lib/systemd/system#g" \
    -e "s#/etc/systemd/system#$T/root/etc/systemd/system#g" > "$T/helper.sh"

# Tool dirs: "rpm" has a stub rpm that owns the paths listed in $T/owned; "deb" has no rpm.
for d in rpm deb; do
    mkdir -p "$T/bin_$d"
    for t in readlink grep rm; do ln -s "$(command -v "$t")" "$T/bin_$d/$t"; done
    printf '#!/bin/sh\necho "systemctl $*" >> "%s/systemctl.log"\n' "$T" > "$T/bin_$d/systemctl"
    chmod 755 "$T/bin_$d/systemctl"
done
cat > "$T/bin_rpm/rpm" <<EOF
#!/bin/sh
# stub: rpm -qf --qf '%{NAME}\n' <path>
f=\$4; grep -qxF "\$f" "$T/owned" 2>/dev/null && { echo nftban-core; exit 0; }
echo "file \$f is not owned by any package"; exit 1
EOF
chmod 755 "$T/bin_rpm/rpm"

# fresh <merged_usr:0|1>: an empty fake root; with merged /usr, lib -> usr/lib.
fresh(){
    rm -rf "$T/root" "$T/owned" "$T/systemctl.log"; mkdir -p "$T/root/usr/lib/systemd/system" "$T/root/etc/systemd/system"
    if [[ "$1" == 1 ]]; then ln -s usr/lib "$T/root/lib"; else mkdir -p "$T/root/lib/systemd/system"; fi
    : > "$T/owned"
}
run(){ PATH="$T/bin_$1" /bin/bash -c ". '$T/helper.sh'; remove_unit_file_if_exists '$UNIT'"; }
U="$T/root/usr/lib/systemd/system/$UNIT"

echo "=== A. RPM host: a file owned by the installed nftban-core is left to rpm ==="
fresh 0; echo x > "$U"; readlink -f "$U" > "$T/owned"
run rpm && [[ -e "$U" ]] && ok "A1 owned file kept (rpm's erase removes it)" || no "A1 owned file kept" "the helper deleted a file rpm still owns: rpm will warn 'remove failed'"
grep -q "reset-failed $UNIT" "$T/systemctl.log" 2>/dev/null && ok "A2 failed latch still reset" || no "A2 failed latch still reset" "no reset-failed call"

echo "=== B. merged /usr: /lib/systemd/system is the same file and is not deleted through it ==="
fresh 1; echo x > "$U"; readlink -f "$U" > "$T/owned"
run rpm && [[ -e "$U" ]] && ok "B1 owned file kept via the /lib alias" || no "B1 owned file kept via the /lib alias" "deleted through /lib/systemd/system"

echo "=== C. RPM host: an unowned leftover is removed, and a /dev/null mask cleared ==="
fresh 0; echo x > "$U"; ln -s /dev/null "$T/root/etc/systemd/system/$UNIT"
run rpm && [[ ! -e "$U" ]] && ok "C1 unowned leftover removed" || no "C1 unowned leftover removed" "file still present"
[[ ! -L "$T/root/etc/systemd/system/$UNIT" ]] && ok "C2 /dev/null mask cleared" || no "C2 /dev/null mask cleared" "mask still present"

echo "=== D. DEB host (no rpm): behaviour unchanged, file removed ==="
fresh 0; echo x > "$U"; readlink -f "$U" > "$T/owned"
run deb && [[ ! -e "$U" ]] && ok "D1 removed without rpm" || no "D1 removed without rpm" "file still present"

echo "=== E. absent file: no error ==="
fresh 0
run rpm && ok "E1 absent file is a no-op (rc 0)" || no "E1 absent file is a no-op" "non-zero exit"

echo "=== F. every generated artifact carries the ownership guard ==="
for rel in install/packaging/deb/nftban-preinst-deprecated-cleanup.inc install/packaging/deb/nftban-prerm-systemd-cleanup.inc \
           install/packaging/rpm/nftban-pre-deprecated-cleanup.inc install/packaging/rpm/nftban-preun-systemd-cleanup.inc \
           packaging/deb/preinst packaging/deb/prerm; do
    if grep -qF "grep -qx 'nftban-core'" "$REPO/$rel" 2>/dev/null; then ok "F1 $rel"; else
        no "F1 $rel" "guard missing - run: bash build/generate-systemd-maintainer-scripts.sh"; fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
