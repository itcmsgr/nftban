#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.219.1 RBL enable-prereq IFS-safety + dns_utils package key
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_prereq_ifs_dns_utils_v219_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-10"
# meta:description="v1.219.1 PR-A: nftban_prereq_require_any_cmd must be safe when sourced by strict-mode callers (cmd_rbl.sh sets IFS=\$'\\n\\t'). Before the fix, 'for bin in \$binaries_str' + 'read -a' did not split the space-separated 'host dig nslookup' under IFS=\$'\\n\\t', so it checked one literal binary 'host dig nslookup' → false-MISSING even when a tool existed (the RBL enable hard-block since 2025-12-31). Asserts: (1) under IFS=\$'\\n\\t' the helper returns 0 when at least one tool exists; (2) when none exist, the missing HINT lists each split option (host/dig/nslookup) separately, not one joined string; (3) the RBL prereq uses the valid 'dns_utils' package key (never the unmapped 'bind_utils'); (4) the central per-distro maps resolve dns_utils to bind9-dnsutils on apt distros and bind-utils on dnf distros, on every distro conf. Shell/config/tests only; daemon byte-identical; no scan-behavior change; RBL not enabled."
# meta:input="None (extracts + stubs the prereq helper; greps the lib + distro confs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/lib/nftban_prereq.sh,etc/nftban/distros/*.conf"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="IFS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rbl_prereq_ifs_dns_utils_v219_1_test"
# meta:ta.owner="rbl"
# meta:ta.module="rbl-enable-prereq"
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
LIB="$REPO/cli/lib/nftban/lib/nftban_prereq.sh"
DISTROS="$REPO/etc/nftban/distros"

PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== v1.219.1 RBL enable-prereq IFS-safety + dns_utils ==="

# Harness: extract the helper, run under strict IFS with stubbed have_cmd + arrays.
run_prereq(){ # run_prereq <have:present|absent>  → prints "RC=<rc>|HINT=<suggestion>"
  local mode="$1"
  bash -c '
    set +e
    IFS=$'"'"'\n\t'"'"'                      # strict mode, exactly like cmd_rbl.sh
    MODE="'"$mode"'"
    nftban_have_cmd(){ [ "$MODE" = present ] && [ "$1" = dig ] && return 0; return 1; }
    _nftban_prereq_install_cmd(){ echo "apt-get install -y"; }
    NFTBAN_PREREQ_MISSING=(); NFTBAN_PREREQ_HINTS=()
    '"$(awk '/^nftban_prereq_require_any_cmd\(\)/,/^}/' "$LIB")"'
    nftban_prereq_require_any_cmd "host dig nslookup" "dns_utils dns_utils dns_utils" "DNS lookup tool"
    rc=$?
    printf "RC=%s|HINT=%s\n" "$rc" "${NFTBAN_PREREQ_HINTS[*]:-}"
  '
}

# (1) positive under strict IFS — a tool exists → returns 0
out=$(run_prereq present)
[[ "$out" == RC=0\|* ]] && ok "strict IFS + tool present → returns 0 (enable gate not false-blocked)" || no "strict-IFS positive ($out)"

# (2) negative — no tools → returns 1 AND the hint lists each option split (not one joined string)
out=$(run_prereq absent)
[[ "$out" == RC=1\|* ]] && ok "no tool → returns 1 (honest missing)" || no "negative rc ($out)"
# split correctness: the hint must mention host, dig AND nslookup as separate options,
# and must NOT contain the joined 'host dig nslookup (' token (the pre-fix bug shape).
if [[ "$out" == *"host ("* && "$out" == *"dig ("* && "$out" == *"nslookup ("* ]]; then
  ok "missing hint lists all 3 options split (host/dig/nslookup)"
else no "hint not split correctly ($out)"; fi
[[ "$out" != *"host dig nslookup ("* ]] && ok "hint is NOT one joined 'host dig nslookup (…)' string" || no "hint joined (pre-fix bug)"

# (3) the IFS contract fix is present in the lib
grep -q "local IFS=\$' \\\\t\\\\n'" "$LIB" && ok "require_any_cmd resets IFS locally (contract)" || no "no local IFS reset in lib"

# (4) RBL prereq uses dns_utils, never bind_utils
grep -A6 'nftban_prereq_check_rbl' "$LIB" | grep -q 'dns_utils dns_utils dns_utils' && ok "RBL prereq uses dns_utils key" || no "RBL prereq not dns_utils"
grep -q 'bind_utils' "$LIB" && no "invalid 'bind_utils' still present in lib" || ok "no 'bind_utils' anywhere in lib"

# (5) per-distro central maps: dns_utils present in every conf, correct pkg per package-manager
missing=0; wrong=0; total=0
for f in "$DISTROS"/*.conf; do
  total=$((total+1))
  line=$(grep -E '^[[:space:]]*dns_utils[[:space:]]*=' "$f" | head -1)
  [[ -z "$line" ]] && { missing=$((missing+1)); continue; }
  # EXACT value after '=' (parser does NOT strip inline comments → an inline # would corrupt it)
  val="${line#*=}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  t=$(grep -m1 '^type = ' "$f" | awk '{print $3}')
  case "$t" in
    apt)     [[ "$val" == "bind9-dnsutils" ]] || { wrong=$((wrong+1)); echo "        apt conf wrong: $(basename "$f"): [$val]"; } ;;
    dnf|yum) [[ "$val" == "bind-utils" ]]     || { wrong=$((wrong+1)); echo "        dnf conf wrong: $(basename "$f"): [$val]"; } ;;
  esac
done
[[ $missing -eq 0 ]] && ok "dns_utils present in ALL $total distro confs" || no "$missing distro confs missing dns_utils"
[[ $wrong -eq 0 ]] && ok "dns_utils resolves correctly per distro (apt→bind9-dnsutils, dnf→bind-utils)" || no "$wrong confs wrong pkg"
grep -rl 'bind_utils' "$DISTROS" 2>/dev/null | grep -q . && no "invalid 'bind_utils' in a distro conf" || ok "no 'bind_utils' in any distro conf"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
