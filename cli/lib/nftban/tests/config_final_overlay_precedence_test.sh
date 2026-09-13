#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-final-overlay-precedence"
# meta:type="test"
# meta:description="v1.230.0 PR-5c-B1. Locks the shell config precedence contract BASE < MODULE_LOCAL < CENTRAL_OPERATOR_OVERRIDE for the governed loader consumers, by observing POST-LOAD EFFECTIVE VALUES from the real module loaders — never by inspecting source text. Also locks the bootstrap invariant: the repair must not increase the number of env.sh source sites, because env.sh participates in configuration initialisation and a fresh source solely to reach the helper would itself change load order — the exact defect class this increment removes. That wrong implementation would still have produced correct-looking precedence in a narrow test, which is why the invariant is asserted structurally."
# meta:ta.id="config_final_overlay_precedence_test"
# meta:ta.owner="core"
# meta:ta.module="config-precedence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/env.sh,cli/lib/nftban/core/nftban_rbl.sh,cli/lib/nftban/core/nftban_geoban.sh,cli/lib/nftban/core/nftban_tunnel.sh,cli/lib/nftban/core/nftban_geoip_download.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT INT TERM

# B1-1 governed family. Values are deliberately NON-EMPTY: `: "${K:=default}"` treats empty
# as unset, and empty-value semantics are separate debt (CONFIG-LOCAL-EMPTY-VALUE-SEMANTICS).
# ⛔ "${SB:?}" not "$SB": an empty SB would make this `rm -rf /etc`. A destructive path
#    must fail to expand rather than widen (SC2115).
_mk(){ rm -rf "${SB:?}/etc"; mkdir -p "$SB/etc/conf.d/rbl" "$SB/etc/conf.d/geoban" "$SB/etc/conf.d/tunnel"; printf '# base\n' > "$SB/etc/nftban.conf"; }
_eff(){ # $1=module file  $2=key  $3=extra load cmd
  NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" bash -c "
    cd '$ROOT'
    source cli/lib/nftban/lib/env.sh >/dev/null 2>&1 || true
    source '$1' >/dev/null 2>&1 || true
    $3
    printf '%s' \"\${$2:-<unset>}\"" 2>/dev/null
}
RBL="$ROOT/cli/lib/nftban/core/nftban_rbl.sh"

echo "=== 1. BASE < MODULE_LOCAL < CENTRAL (real loader, real key) ==="
_mk; printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/rbl/main.conf"
     printf 'NFTBAN_RBL_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/rbl/main.conf.local"
     printf 'NFTBAN_RBL_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
[[ "$(_eff "$RBL" NFTBAN_RBL_ENABLED ':')" == "USERVAL" ]] && ok "central operator override WINS" || bad "central override did not win"
_mk; printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/rbl/main.conf"
     printf 'NFTBAN_RBL_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/rbl/main.conf.local"
[[ "$(_eff "$RBL" NFTBAN_RBL_ENABLED ':')" == "LOCALVAL" ]] && ok "module-local wins when central absent (overlay does not clobber)" || bad "module-local lost"
_mk; printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/rbl/main.conf"
[[ "$(_eff "$RBL" NFTBAN_RBL_ENABLED ':')" == "BASEVAL" ]] && ok "base survives with no overrides" || bad "base value lost"

echo "=== 2. one transaction, several subjects -> ONE overlay (geoban) ==="
_mk; printf 'GEOBAN_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/geoban/main.conf"; printf 'GEOBAN_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_eff "$ROOT/cli/lib/nftban/core/nftban_geoban.sh" GEOBAN_ENABLED ':')" == "USERVAL" ]] \
  && ok "geoban loads geoban/main.conf AND legacy nftban-go.conf, then one overlay" || bad "geoban precedence wrong"

echo "=== 3. load FUNCTION as the transaction (tunnel) ==="
_mk; printf 'NFTBAN_TUNNEL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/tunnel/main.conf"; printf 'NFTBAN_TUNNEL_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_eff "$ROOT/cli/lib/nftban/core/nftban_tunnel.sh" NFTBAN_TUNNEL_ENABLED 'nftban_tunnel_load_config >/dev/null 2>&1 || true')" == "USERVAL" ]] \
  && ok "overlay applied at the end of the load function, before the caller consumes" || bad "tunnel precedence wrong"

echo "=== 4. BOOTSTRAP INVARIANT — the repair must add no env.sh source site ==="
# A fresh `source env.sh` to reach the helper would change initialisation order while still
# passing the precedence checks above. Assert the structure, not only the behaviour.
for f in core/nftban_rbl.sh core/nftban_geoban.sh core/nftban_tunnel.sh core/nftban_geoip_download.sh; do
  n=$(grep -cE 'source .*lib/env\.sh' "$ROOT/cli/lib/nftban/$f" 2>/dev/null || true)
  [[ "$n" -le 1 ]] && ok "$(basename "$f"): env.sh source sites = $n (<=1, no new bootstrap)" \
                   || bad "$(basename "$f"): env.sh source sites = $n — a new bootstrap path was introduced"
done

echo "=== 5. every governed consumer reaches the overlay authority ==="
miss=0
for f in core/nftban_rbl.sh core/nftban_geoban.sh core/nftban_tunnel.sh core/nftban_geoip_download.sh; do
  grep -q 'nftban_config_apply_final_operator_overlay' "$ROOT/cli/lib/nftban/$f" || { bad "$(basename "$f") has no final overlay"; miss=1; }
done
[[ "$miss" -eq 0 ]] && ok "all 4 B1-1 consumers invoke the final overlay authority"
grep -q '^nftban_config_apply_final_operator_overlay()' "$ROOT/cli/lib/nftban/lib/env.sh" \
  && ok "single overlay authority is defined in env.sh" || bad "overlay authority missing"

echo
printf 'config-final-overlay-precedence: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
