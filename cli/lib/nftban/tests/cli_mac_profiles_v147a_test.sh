#!/usr/bin/env bash
# =============================================================================
# NFTBan - MAC profiles test (v1.147-A: AppArmor + SELinux)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_mac_profiles_v147a_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-03"
# meta:description="v1.147-A — asserts the MAC profile shipment. SELinux: nftban.te policy_module 1.2.0, nftban.if exists, nftban.fc labels /usr/lib/nftban/bin/nftband as nftband_exec_t, .te carries the netlink/capability allows, build path ships+compiles nftban.pp, RPM %post has a selinuxenabled-guarded semodule -i, RPM %postun has a selinuxenabled-guarded semodule -r on final erase, no permissive nftband_t, no unconfined workaround. AppArmor: profile exists in complain+attach_disconnected mode with net_admin/dac_override/netlink-raw + the nftband.service ReadWritePaths, DEB postinst has an AppArmor-guarded apparmor_parser -r, DEB postrm has an AppArmor-guarded apparmor_parser -R. Guards spelled 'selinuxenabled' (not the plan typo). No polkit-as-SELinux-fix; no Go/daemon/core/schema change. Hermetic — static assertions on repo files, no host contact."
# meta:input="install/selinux/*, install/apparmor/*, packaging/build_nftban.sh, packaging/deb/postinst, packaging/deb/postrm"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk"
# meta:inventory.files="install/selinux/nftban.te,install/selinux/nftban.if,install/selinux/nftban.fc,install/apparmor/usr.lib.nftban.bin.nftband,packaging/build_nftban.sh,packaging/deb/postinst,packaging/deb/postrm"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_mac_profiles_v147a_test"
# meta:ta.owner="security"
# meta:ta.module="mac-profiles"
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
PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

TE="$REPO/install/selinux/nftban.te"
IF="$REPO/install/selinux/nftban.if"
FC="$REPO/install/selinux/nftban.fc"
AA="$REPO/install/apparmor/usr.lib.nftban.bin.nftband"
BUILD="$REPO/packaging/build_nftban.sh"
POSTINST="$REPO/packaging/deb/postinst"
POSTRM="$REPO/packaging/deb/postrm"

# ── executable-policy extraction ───────────────────────────────────────────
# v1.228.5. These assertions are about POLICY, but they were reading raw source
# TEXT, which is not the same thing. Both failure directions were then observed on
# one branch:
#
#   FALSE FAIL  S9 forbids 'unconfined_t'. nftban.te documents the GeoIP denial's
#               discriminator, which necessarily NAMES unconfined_t ("an interactive
#               run in unconfined_t succeeds, the service domain nftband_t does
#               not"). Prose tripped a guard about rules.
#   FALSE PASS  the sibling v1930 guard was satisfied by a comment quoting the very
#               call it existed to verify — it reported PASS while the call had
#               moved. That is strictly worse than the visible failure, because a
#               green check manufactures confidence.
#
# Strip trailing comments and blank lines, then assert against statements. Applied
# to .te/.if/.fc only. Shell scripts are NOT run through this wholesale: build_nftban.sh
# contains heredocs that EMIT policy text, where '#' is generated content rather
# than a comment, so those assertions keep their existing extraction boundary.
policy_code(){ sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$@" 2>/dev/null; }
TE_CODE="$(policy_code "$TE")"
IF_CODE="$(policy_code "$IF")"
FC_CODE="$(policy_code "$FC")"

# ── SELinux ────────────────────────────────────────────────────────────────
[[ -f "$TE" ]] && grep -qE 'policy_module\(nftban, 1\.2\.0\)' <<<"$TE_CODE" \
  && ok "S1 nftban.te policy_module is 1.2.0" || no "S1 nftban.te policy_module is 1.2.0" "missing/old"
[[ -f "$IF" ]] && grep -q 'nftban_domtrans' <<<"$IF_CODE" \
  && ok "S2 nftban.if exists with interfaces" || no "S2 nftban.if exists" "missing"
[[ -f "$FC" ]] && grep -Eq '/usr/lib/nftban/bin/nftband[[:space:]].*nftband_exec_t' <<<"$FC_CODE" \
  && ok "S3 nftban.fc labels the daemon binary nftband_exec_t" || no "S3 .fc labels daemon binary" "missing"
if grep -q 'netlink_netfilter_socket' <<<"$TE_CODE" && grep -q 'netlink_route_socket' <<<"$TE_CODE" \
   && grep -Eq 'self:capability \{[^}]*\bnet_admin\b[^}]*\bnet_raw\b' <<<"$TE_CODE"; then
  ok "S4 nftban.te carries netlink + net_admin/net_raw allows"
else no "S4 .te netlink/capability allows" "missing"; fi
if grep -qE 'make -f /usr/share/selinux/devel/Makefile nftban\.pp' "$BUILD" \
   && grep -qE 'install .*nftban\.pp .*selinux/nftban\.pp' "$BUILD" \
   && grep -q 'BuildRequires:  selinux-policy-devel' "$BUILD"; then
  ok "S5 build compiles nftban.pp via refpolicy devel Makefile + ships it (BuildRequires set)"
else no "S5 build ships nftban.pp" "compile/install/BuildRequires missing"; fi
# RPM %post: selinuxenabled-guarded semodule -i (here-strings avoid pipefail SIGPIPE)
_post_sec=$(awk '/^%post/{p=1} /^%preun|^%postun/{p=0} p' "$BUILD")
if grep -q 'selinuxenabled' <<<"$_post_sec" && grep -q 'semodule -i' <<<"$_post_sec"; then
  ok "S6 RPM %post has selinuxenabled-guarded semodule -i"
else no "S6 RPM %post semodule -i" "missing/unguarded"; fi
# RPM %postun: selinuxenabled-guarded semodule -r on final erase ($1 -eq 0)
_postun_sec=$(awk '/^%postun/{p=1} p' "$BUILD")
if grep -q 'semodule -r nftban' <<<"$_postun_sec" && grep -q 'selinuxenabled' <<<"$_postun_sec"; then
  ok "S7 RPM %postun has selinuxenabled-guarded semodule -r"
else no "S7 RPM %postun semodule -r" "missing/unguarded"; fi
# enforcing domain only — NO permissive, NO unconfined workaround
if ! grep -qE 'permissive[[:space:]]+nftband_t' <<<"$TE_CODE"; then
  ok "S8 no 'permissive nftband_t' (enforcing domain)"
else no "S8 no permissive nftband_t" "permissive present"; fi
if ! grep -qiE 'unconfined_domain|unconfined_t' <<<"$TE_CODE$IF_CODE"; then
  ok "S9 no unconfined workaround in policy"
else no "S9 no unconfined workaround" "unconfined present"; fi
# ── S9-CONTROLS: prove the guard discriminates statement from prose ────────
# Without these, S9 is unfalsifiable: it would pass identically if policy_code
# silently returned nothing, which is the failure mode that produced the vacuous
# PASS elsewhere on this branch. Injection into a THROWAWAY copy, never the shipped
# policy — the real .te is not written to at any point.
_ctl_dir="$(mktemp -d)"; trap 'rm -rf "$_ctl_dir"' EXIT
_ctl="$_ctl_dir/ctl.te"

# CONTROL A (negative): a real, executable unconfined grant MUST be caught.
{ cat "$TE"; echo 'allow nftband_t unconfined_t:file read;'; } > "$_ctl"
if grep -qiE 'unconfined_domain|unconfined_t' <<<"$(policy_code "$_ctl")"; then
  ok "S9-A injected EXECUTABLE unconfined grant is DETECTED"
else no "S9-A injected executable unconfined grant" "guard blind to a real violation"; fi

# CONTROL B (positive): the same token in a COMMENT must NOT trip it.
{ grep -viE 'unconfined_domain|unconfined_t' "$TE"
  echo '# discriminator: an interactive run in unconfined_t succeeds'; } > "$_ctl"
if grep -qiE 'unconfined_domain|unconfined_t' <<<"$(policy_code "$_ctl")"; then
  no "S9-B comment-only mention" "prose still trips the guard — parser not comment-blind"
else ok "S9-B comment-only 'unconfined_t' correctly IGNORED"; fi

# CONTROL C: policy_code must not be vacuous — an empty extraction would make every
# forbidden-token check pass for the wrong reason.
if [[ "$(wc -l <<<"$TE_CODE")" -gt 20 ]] && grep -q 'policy_module' <<<"$TE_CODE"; then
  ok "S9-C policy_code extraction is non-empty and retains statements"
else no "S9-C policy_code non-vacuous" "extraction empty/degenerate — forbidden checks would false-pass"; fi

# guard typo check: must be selinuxenabled, never selinunenabled
if ! grep -rq 'selinunenabled' "$BUILD" "$POSTINST" "$POSTRM"; then
  ok "S10 guard spelled 'selinuxenabled' (no 'selinunenabled' typo)"
else no "S10 selinuxenabled typo" "found selinunenabled"; fi

# ── AppArmor ───────────────────────────────────────────────────────────────
[[ -f "$AA" ]] && grep -qE 'profile nftband /usr/lib/nftban/bin/nftband flags=\(complain attach_disconnected\)' "$AA" \
  && ok "A1 AppArmor profile exists in complain+attach_disconnected mode" || no "A1 AppArmor profile complain+attach_disconnected" "missing/not-complain"
if grep -q 'capability net_admin,' "$AA" && grep -q 'capability dac_override,' "$AA" \
   && grep -q 'network netlink raw,' "$AA"; then
  ok "A2 profile has net_admin + dac_override + netlink raw"
else no "A2 profile caps/netlink" "missing"; fi
aa_paths=1
for p in '/var/lib/nftban/' '/var/log/nftban/' '/run/nftban/' '/var/cache/nftban/' '/etc/nftban/blacklist.d/' '/etc/nftban/rules.d/'; do
  grep -q "$p" "$AA" || aa_paths=0
done
[[ $aa_paths -eq 1 ]] && ok "A3 profile rw-covers the nftband.service ReadWritePaths" || no "A3 profile ReadWritePaths" "a path missing"
# DEB postinst: AppArmor-guarded apparmor_parser -r
if grep -q 'apparmor_parser -r' "$POSTINST" && grep -qE 'sys/kernel/security/apparmor|command -v apparmor_parser' "$POSTINST"; then
  ok "A4 DEB postinst has AppArmor-guarded apparmor_parser -r"
else no "A4 postinst apparmor_parser -r" "missing/unguarded"; fi
# DEB postrm: AppArmor-guarded apparmor_parser -R
if grep -q 'apparmor_parser -R' "$POSTRM" && grep -q 'command -v apparmor_parser' "$POSTRM"; then
  ok "A5 DEB postrm has AppArmor-guarded apparmor_parser -R"
else no "A5 postrm apparmor_parser -R" "missing/unguarded"; fi
# DEB build ships the profile under /etc/apparmor.d/ (install spans 2 lines)
if grep -q 'install/apparmor/usr.lib.nftban.bin.nftband' "$BUILD" \
   && grep -q 'etc/apparmor.d/usr.lib.nftban.bin.nftband' "$BUILD"; then
  ok "A6 DEB build ships the profile under /etc/apparmor.d/"
else no "A6 DEB ships apparmor profile" "install missing"; fi

# ── Non-goals (147-A is policy-only) ────────────────────────────────────────
# no polkit-as-SELinux-fix: the MAC files must not introduce polkit
if ! grep -riq 'polkit' "$TE" "$IF" "$AA"; then
  ok "N1 no polkit referenced in MAC policy files"
else no "N1 no polkit in MAC files" "polkit present"; fi

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
