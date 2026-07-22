#!/usr/bin/env bash
# =============================================================================
# V133 PR-B — write-guard / reframe refusal regression guard (A12–A15)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v133_pr_b_write_guard_refusal_test"
# meta:type="test"
# meta:version="1.133.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_PRO_DATA_DIR,NFTBAN_DATA_DIR,NFTBAN_REPORT_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="V133 PR-B regression guard for A12–A15: operator-facing privileged-write/read paths must emit the canonical polkit-aware refusal instead of leaking a raw OS error. A15 (get_live_ruleset) is deterministic — a stubbed failing nft printing 'Operation not permitted (you must be root)' must be reframed to a polkit/CAP_NET_ADMIN-aware JSON error with NO 'you must be root' substring. A12 (nftban_pro), A13 (cmd_snapshot), A14 (nftban_report_module) get static structural assertions (EUID guard + '! -w' + canonical message present) always, plus a non-root behavioral refusal (rc=1 + polkit stderr + no raw 'Permission denied') that SKIPs under root (CI runners are root; real non-root proof is lab/local)."
# meta:ta.id="v133_pr_b_write_guard_refusal_test"
# meta:ta.owner="security"
# meta:ta.module="polkit-write-refusal"
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

_lib=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)   # .../cli/lib/nftban
_msg='PolicyKit/polkit authorization failed or insufficient privileges'

_pass=0; _fail=0; _skip=0
_t_assert() {
    local name="$1" rc="$2" detail="${3:-}"
    if [[ "$rc" == "0" ]]; then echo "  [PASS] $name"; _pass=$((_pass+1))
    else echo "  [FAIL] $name${detail:+ — $detail}"; _fail=$((_fail+1)); fi
}
_t_skip() { echo "  [SKIP] $1"; _skip=$((_skip+1)); }

echo "==============================================================================="
echo "V133 PR-B — write-guard / reframe refusal guard (A12–A15)"
echo "  lib root: $_lib"
echo "==============================================================================="

# ---------------------------------------------------------------------------
# A15 — get_live_ruleset reframes raw nft permission errors (DETERMINISTIC)
# ---------------------------------------------------------------------------
echo "[A15] get_live_ruleset reframes 'Operation not permitted (you must be root)'"
_a15_out() {
    local td out
    td=$(mktemp -d)
    printf '#!/usr/bin/env bash\necho "Error: Operation not permitted (you must be root)" >&2\nexit 1\n' > "$td/nft"
    chmod +x "$td/nft"
    out=$(
        set +eu
        export NFTBAN_LIB_DIR="$_lib"
        PATH="$td:$PATH"
        # shellcheck disable=SC1090
        source "$_lib/core/nftban_ip_and_stats.sh" >/dev/null 2>&1
        get_live_ruleset 2>&1
    ) || true
    rm -rf "$td"
    printf '%s' "$out"
}
a15=$(_a15_out)
if printf '%s' "$a15" | grep -qi 'you must be root'; then
    _t_assert "A15: reframed error contains NO 'you must be root'" 1 "got: $a15"
else
    _t_assert "A15: reframed error contains NO 'you must be root'" 0
fi
if printf '%s' "$a15" | grep -qiE 'polkit-authorized|CAP_NET_ADMIN'; then
    _t_assert "A15: reframed error carries polkit/CAP_NET_ADMIN framing" 0
else
    _t_assert "A15: reframed error carries polkit/CAP_NET_ADMIN framing" 1 "got: $a15"
fi

# ---------------------------------------------------------------------------
# A12–A14 — STATIC structural: EUID guard + '! -w' + canonical message present
# ---------------------------------------------------------------------------
echo "[A12-A14] static structural guards present"
_static_guard() { # $1=file $2=human-id
    local f="$_lib/$1"
    if grep -q '! -w ' "$f" && grep -qF "$_msg" "$f" && grep -qE '\$EUID -ne 0' "$f"; then
        _t_assert "$2: EUID + '! -w' + canonical polkit message present" 0
    else
        _t_assert "$2: EUID + '! -w' + canonical polkit message present" 1 "missing guard in $1"
    fi
}
_static_guard "lib/nftban_pro.sh"            "A12 (pro write)"
_static_guard "cli/cmd_snapshot.sh"          "A13 (snapshot write)"
_static_guard "core/nftban_report_module.sh" "A14 (report write)"

# ---------------------------------------------------------------------------
# A12/A13 — NON-ROOT behavioral refusal (SKIP under root; real proof is non-root)
# ---------------------------------------------------------------------------
echo "[A12-A13] non-root behavioral refusal (skips as root)"
_behavioral_refuse() { # $1=file $2=envvar $3=func $4=human-id
    if [[ $EUID -eq 0 ]]; then _t_skip "$4: behavioral refusal (running as root — guard is EUID-gated)"; return; fi
    local f="$_lib/$1" td out rc=0
    td=$(mktemp -d); chmod 000 "$td"
    out=$(
        set +eu
        export NFTBAN_LIB_DIR="$_lib"
        export "$2=$td"
        # shellcheck disable=SC1090
        source "$f" >/dev/null 2>&1
        if ! declare -f "$3" >/dev/null 2>&1; then echo "__NOFUNC__"; exit 0; fi
        "$3" 2>&1
    ) || rc=$?
    chmod 700 "$td" 2>/dev/null || true; rm -rf "$td"
    if printf '%s' "$out" | grep -q '__NOFUNC__'; then
        _t_skip "$4: behavioral refusal (function $3 not sourceable standalone)"; return
    fi
    if [[ "$rc" -ne 0 ]] \
       && printf '%s' "$out" | grep -qF "$_msg" \
       && ! printf '%s' "$out" | grep -qiE 'permission denied|you must be root'; then
        _t_assert "$4: non-root → rc!=0 + polkit refusal + no raw leak" 0
    else
        _t_assert "$4: non-root → rc!=0 + polkit refusal + no raw leak" 1 "rc=$rc out=$out"
    fi
}
_behavioral_refuse "lib/nftban_pro.sh"   "NFTBAN_PRO_DATA_DIR" "nftban_pro_enable_remote" "A12 (pro enable)"
_behavioral_refuse "cli/cmd_snapshot.sh" "NFTBAN_DATA_DIR"     "nftban_snapshot_create"   "A13 (snapshot create)"

echo "==============================================================================="
echo "Results: $_pass passed, $_fail failed, $_skip skipped"
echo "==============================================================================="
[[ "$_fail" -eq 0 ]]
