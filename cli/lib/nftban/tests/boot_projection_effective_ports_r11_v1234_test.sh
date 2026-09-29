#!/usr/bin/env bash
# =============================================================================
# NFTBan - R-11: the boot projection carries the complete effective ports
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="boot_projection_effective_ports_r11_v1234_test"
# meta:type="test"
# meta:version="1.234.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-29"
# meta:description="R-11 BUG-BOOT-PROJECTION-CARRIES-ONLY-TEMPLATE-PORTS. Scenario: SSH on 55000, port 22 absent everywhere, 80/443 removed by the administrator (NFTBAN_BASELINE_TCP_IN=none, emulated by the effective-port stand-in; the Go resolution is covered by internal/ports). B1 `firewall render-boot` publishes the effective ports (55000 + ports.d 18765) and NONE of 22/80/443, in both families. B2 the rebuild's refresh step republishes the projection from the exact ruleset the rebuild loaded (new configured port 9090 appears); B2b it never creates a projection the installer did not; B2c a publication failure is reported as failed and the previous projection survives. B3 the SSH-access safeguard is intact: ssh_ports = {55000}, tcp_ports_in carries 55000, the set-driven SSH rule is present, and the render refuses without an SSH-port authority. B4 wiring: the rebuild calls the refresh after the atomic load and cannot report success when it failed. On v1.233.1 the projection held the template ports {SSH, 80, 443} and the rebuild never refreshed it, so B1, B2 and B4 fail there."
# meta:input="cli/lib/nftban/cli/cmd_firewall.sh, cli/lib/nftban/lib/boot_projection.sh, install/nftables/nftables.conf.tpl"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,nft,mktemp,sha256sum,awk"
# meta:ta.id="boot_projection_effective_ports_r11_v1234_test"
# meta:ta.owner="firewall"
# meta:ta.module="boot-projection"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,nft,mktemp,sha256sum,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CMD="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib/lib" "$SB/lib/templates" "$SB/lib/bin" "$SB/conf/ports.d"
cp "$ROOT/cli/lib/nftban/lib/boot_projection.sh" "$SB/lib/lib/"
cp "$ROOT/install/nftables/nftables.conf.tpl"    "$SB/lib/templates/"
TPL="$SB/lib/templates/nftables.conf.tpl"

# The administrator's configuration: SSH on 55000 only (no 22), one custom port.
printf '55000/T/I\n' > "$SB/conf/ports.d/00-ssh.conf"
printf '18765/T/I\n' > "$SB/conf/ports.d/90-custom.conf"

# Stand-in for `nftban-core ports render-effective` with NFTBAN_BASELINE_TCP_IN=none:
# tcp_in = SSH safeguard + ports.d inbound TCP, nothing else (no 80/443 floor).
cat > "$SB/lib/bin/nftban-core" <<'CORE'
#!/usr/bin/env bash
[[ "$1 $2" == "ports render-effective" ]] || exit 2
[[ -n "${NFTBAN_EFFECTIVE_SSH_PORTS:-}" ]] || exit 1
tin=$( { tr ',' '\n' <<<"$NFTBAN_EFFECTIVE_SSH_PORTS"
         cat "$NFTBAN_CONFIG_DIR"/ports.d/*.conf 2>/dev/null | grep -oE '^[0-9]+/T(/I)?$' | cut -d/ -f1; } \
       | tr -d ' ' | grep -E '^[0-9]+$' | sort -n -u | paste -sd, | sed 's/,/, /g')
echo "NFTBAN_SVC_TCP_IN=$tin"
echo "NFTBAN_SVC_TCP_OUT=53, 80, 443"
echo "NFTBAN_SVC_UDP_IN="
echo "NFTBAN_SVC_UDP_OUT=53, 123"
CORE
chmod +x "$SB/lib/bin/nftban-core"

export NFTBAN_LIB_DIR="$SB/lib" NFTBAN_CONFIG_DIR="$SB/conf"
# shellcheck source=/dev/null
source "$CMD"
set +e   # the subject enables errexit; every arm below checks its own rc

# Same validity probe as the other boot-projection tests: stub nft -c only where
# validity cannot be established at all (the stub proves the contract, not syntax).
_pf="$(mktemp)"; printf 'table ip nftban_probe {\n}\n' > "$_pf"; _can=0
if command -v nft >/dev/null 2>&1; then
    if nft -c -f "$_pf" >/dev/null 2>&1; then _can=1
    elif command -v unshare >/dev/null 2>&1 && unshare -rn nft -c -f "$_pf" >/dev/null 2>&1; then _can=1; fi
fi
rm -f "$_pf"
if [[ "$_can" -eq 0 ]]; then
    nft() {
        local a prev="" f=""
        for a in "$@"; do [[ "$prev" == "-f" ]] && f="$a"; prev="$a"; done
        case " $* " in *" -c "*) [[ -n "$f" && -f "$f" ]] || return 1
            grep -qE 'NOT_NFT_SYNTAX|__[A-Z0-9_]+__' "$f" && return 1; return 0 ;; esac
        return 0
    }
fi

TARGET="$SB/conf/generated/nftban-boot.nft"
# set_elems <file> <table-family> <set>: the elements of one set in one table block.
set_elems(){
    awk -v fam="$2" -v set="$3" '
        $0 ~ "^table "fam" nftban \\{$" {t=1} t && /^}/ {t=0}
        t && $0 ~ "set "set" \\{" {s=1} s && /elements = \{/ {sub(/.*elements = \{ */,""); sub(/ *\}.*/,""); print; s=0} s && /^[[:space:]]*}/ {s=0}
    ' "$1" | tr -d ' '
}
has(){ [[ ",$1," == *",$2,"* ]]; }

echo "== B1  render-boot: effective ports, admin removals honoured (both families) =="
if _firewall_render_boot --quiet 2>"$SB/b1.err"; then ok "render-boot published"
else no "render-boot failed:"; sed 's/^/        /' "$SB/b1.err" | tail -4; fi
for fam in ip ip6; do
    tin=$(set_elems "$TARGET" "$fam" tcp_ports_in 2>/dev/null)
    bad=""; for p in 22 80 443; do has "$tin" "$p" && bad+="$p "; done
    miss=""; for p in 55000 18765; do has "$tin" "$p" || miss+="$p "; done
    if [[ -n "$tin" && -z "$bad" && -z "$miss" ]]; then
        ok "$fam tcp_ports_in = {$tin}: configured ports present, no 22/80/443"
    else
        no "$fam tcp_ports_in = {${tin:-<none>}} (unauthorized: ${bad:-none}; missing: ${miss:-none})"
    fi
done

echo "== B3  SSH-access safeguard intact =="
for fam in ip ip6; do
    sp=$(set_elems "$TARGET" "$fam" ssh_ports 2>/dev/null)
    [[ "$sp" == "55000" ]] && ok "$fam ssh_ports = {55000}" || no "$fam ssh_ports = {${sp:-<none>}}, expected {55000}"
done
n=$(grep -c 'tcp dport @ssh_ports' "$TARGET" 2>/dev/null) || true
[[ "${n:-0}" -ge 2 ]] && ok "set-driven SSH rule present in both families ($n)" || no "set-driven SSH rule missing (${n:-0})"
GOOD_SUM=$(sha256sum "$TARGET" 2>/dev/null | cut -d' ' -f1)
mv "$SB/conf/ports.d/00-ssh.conf" "$SB/00-ssh.off"
( nftban_detect_ssh_ports(){ return 1; }; nftban_detect_ssh_primary_port(){ return 1; }
  _firewall_render_boot --quiet >/dev/null 2>&1 ) \
    && no "published a projection with NO SSH-port authority (lockout)" \
    || ok "refuses to render without an SSH-port authority (lockout guard)"
[[ "$(sha256sum "$TARGET" | cut -d' ' -f1)" == "$GOOD_SUM" ]] \
    && ok "previous projection intact after the refusal" || no "projection changed by a refused render"
mv "$SB/00-ssh.off" "$SB/conf/ports.d/00-ssh.conf"

echo "== B2  rebuild refresh republishes the ruleset the rebuild loaded =="
if ! declare -F _firewall_rebuild_refresh_boot_projection >/dev/null 2>&1; then
    no "SUBJECT_NOT_FOUND: the rebuild has no boot-projection refresh step"
else
    printf '9090/T/I\n' > "$SB/conf/ports.d/91-new.conf"      # config changed since boot
    LOADED="$SB/conf/nftables.conf"                              # what rebuild step 2 renders+loads
    _firewall_substitute_placeholders "$TPL" "$LOADED" 2>/dev/null
    _firewall_complete_service_ports "$LOADED" 2>/dev/null
    st=$(_firewall_rebuild_refresh_boot_projection "$TPL" "$LOADED" true 2>"$SB/b2.err")
    tin=$(set_elems "$TARGET" ip tcp_ports_in)
    if [[ "$st" == "refreshed" ]] && has "$tin" 9090 && ! has "$tin" 80 \
       && diff -q <(grep -v '^#' "$LOADED") <(grep -v '^#' "$TARGET") >/dev/null; then
        ok "refreshed: projection == loaded ruleset (tcp_ports_in {$tin}); no second render"
    else
        no "refresh wrong (state=${st:-none}, tcp_ports_in={${tin:-none}})"; sed 's/^/        /' "$SB/b2.err" | tail -3
    fi
    [[ -s "$LOADED" ]] && ok "the rebuild's loaded ruleset is not consumed by the publish" \
                       || no "the loaded ruleset was removed by the publish"

    echo "== B2b refresh never CREATES boot authority =="
    ( export NFTBAN_CONFIG_DIR="$SB/fresh"; mkdir -p "$SB/fresh"
      st=$(_firewall_rebuild_refresh_boot_projection "$TPL" "$LOADED" true 2>/dev/null)
      [[ "$st" == "not-established" && ! -e "$SB/fresh/generated/nftban-boot.nft" ]] ) \
        && ok "no projection -> not-established, nothing created" \
        || no "the rebuild created a boot projection the installer never established"

    echo "== B2c publication failure is reported, previous projection kept =="
    SUM=$(sha256sum "$TARGET" | cut -d' ' -f1)
    printf '9191/T/I\n' > "$SB/conf/ports.d/92-more.conf"
    _firewall_complete_service_ports "$LOADED" 2>/dev/null
    st=$( _firewall_publish_conf(){ return 1; }
          _firewall_rebuild_refresh_boot_projection "$TPL" "$LOADED" true 2>/dev/null )
    [[ "$st" == "failed" && "$(sha256sum "$TARGET" | cut -d' ' -f1)" == "$SUM" ]] \
        && ok "failed publication -> state failed, previous projection intact" \
        || no "publication failure not reported truthfully (state=${st:-none})"
fi

echo "== B4  wiring: rebuild refreshes after the atomic load; failure is never success =="
CORE=$(awk '/^_firewall_rebuild_core\(\) \{/,/^\}/' "$CMD")
# First matching line number, read in full (no early-closing consumer in a pipe).
first_line(){ awk -v re="$1" '$0 ~ re { print NR; exit }' <<<"$CORE"; }
l_load=$(first_line 'if ! nft[[:space:]]+-f "[$]load_conf"')
l_ref=$(first_line '_firewall_rebuild_refresh_boot_projection ')
l_post=$(first_line 'post_state=[$][(]_rebuild_get_validator_state[)]')
l_gate=$(first_line '_boot_proj_state:-}" != "refreshed"')
l_case=$(grep -n 'case "\$post_status" in' <<<"$CORE" | tail -1 | cut -d: -f1)
if [[ -n "$l_load" && -n "$l_ref" && -n "$l_post" && "$l_ref" -gt "$l_load" && "$l_ref" -lt "$l_post" ]]; then
    ok "refresh runs after the atomic load and before post-validation"
else
    no "refresh not wired after the atomic load (load=${l_load:-?} refresh=${l_ref:-none} post=${l_post:-?})"
fi
if [[ -n "$l_gate" && -n "$l_case" && "$l_gate" -lt "$l_case" ]] \
   && [[ "$(sed -n "${l_gate},$((l_gate + 8))p" <<<"$CORE")" == *"return 1"* ]]; then
    ok "a failed refresh returns non-zero before any success branch"
else
    no "a failed refresh can still reach the success branch"
fi

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
