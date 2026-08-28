#!/usr/bin/env bash
# =============================================================================
# NFTBan - falsifiability harness for check-firewall-projection-authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-firewall-projection-authority-falsifiability"
# meta:type="ci-guard-inversion"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-28"
# meta:description="Inverts check-firewall-projection-authority against a hermetic fake repo. A GREEN GUARD OVER AN UNREACHED SUBJECT IS NOT EVIDENCE, so every rule is driven by a fixture that reproduces its MOTIVATING defect: F1 a second placeholder-bearing schema. F2 a reimplemented substitution outside the render authority. F3 enforcement drift of exactly the registered class (a ct-count value differing between boot projection and canonical schema — the 150-vs-200 case that motivated P12-FPA). F4 a NEW unregistered rule-comment drift. F5 a stale registry row with no drift left. F6 a boot projection that fails nft -c. F0 is the positive control: an aligned fixture must PASS. A fixture that fails for the wrong reason is a broken fixture, so each expectation matches the specific rule token."
# meta:input="scripts/ci/check-firewall-projection-authority.sh"
# meta:output="PASS/FAIL per fixture; exit 1 if any fixture fails to behave"
# meta:depends="bash,grep,sed,diff,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,diff,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/scripts/ci/check-firewall-projection-authority.sh"
[[ -x "$GUARD" ]] || { echo "  [FAIL] guard not executable: $GUARD"; exit 1; }

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== check-firewall-projection-authority-falsifiability ==="

# --- hermetic fake repo -----------------------------------------------------
# The guard resolves ROOT from its own location, so the fixture is a real
# directory tree with the guard copied into it. No host repo state is touched.
mk_repo() {
    local d; d=$(mktemp -d) || return 1
    mkdir -p "$d/install/nftables" "$d/cli/lib/nftban/cli" "$d/scripts/ci/data"
    cat > "$d/install/nftables/nftables.conf.tpl" <<'TPL'
#!/usr/sbin/nft -f
table ip nftban {
    set ssh_ports {
        type inet_service
        comment "SSH ports"
        elements = { __SSH_PORT__ }
    }
    chain input {
        type filter hook input priority 0; policy accept;
        ct state new tcp dport @ssh_ports ct count over __CT_LIMIT_SSH__ drop comment "SSH: max __CT_LIMIT_SSH__ (host-wide)"
        ct state new tcp dport { 80, 443 } ct count over __CT_LIMIT_HTTP__ drop comment "HTTP: max __CT_LIMIT_HTTP__ (host-wide)"
        ct state new tcp dport { 25 } ct count over __CT_LIMIT_MAIL__ drop comment "MAIL: max __CT_LIMIT_MAIL__ (host-wide)"
    }
}
TPL
    sed -e 's/__SSH_PORT__/22/g' -e 's/__CT_LIMIT_SSH__/15/g' \
        -e 's/__CT_LIMIT_HTTP__/150/g' -e 's/__CT_LIMIT_MAIL__/150/g' \
        "$d/install/nftables/nftables.conf.tpl" > "$d/install/nftables/nftables.conf"
    cat > "$d/cli/lib/nftban/cli/cmd_firewall.sh" <<'REN'
#!/usr/bin/env bash
_firewall_substitute_placeholders() {
    local _ssh_port=22
    local _ct_ssh=15 _ct_http=150 _ct_mail=150
    sed -e "s/__SSH_PORT__/${_ssh_port}/g" -e "s/__CT_LIMIT_SSH__/${_ct_ssh}/g" \
        -e "s/__CT_LIMIT_HTTP__/${_ct_http}/g" -e "s/__CT_LIMIT_MAIL__/${_ct_mail}/g" "$1" > "$2"
}
REN
    : > "$d/scripts/ci/data/firewall-projection-drift.allow"
    cp "$GUARD" "$d/scripts/ci/"
    printf '%s' "$d"
}

# run <dir> -> captures output; sets RC and OUT
run() { OUT=$("$1/scripts/ci/$(basename "$GUARD")" 2>&1); RC=$?; }

# expect <label> <dir> <expected-rc> [token-that-must-appear-in-a-FAIL-line]
expect() {
    local label="$1" dir="$2" want="$3" token="${4:-}"
    run "$dir"
    if [[ "$RC" -ne "$want" ]]; then
        bad "$label — expected rc=$want, got rc=$RC"
        sed 's/^/         /' <<<"$OUT" | head -8
    elif [[ -n "$token" ]] && ! grep -q "\[FAIL\].*$token" <<<"$OUT"; then
        bad "$label — rc correct but no [FAIL] line mentions '$token' (fixture may fail for the WRONG reason)"
        sed 's/^/         /' <<<"$OUT" | grep '\[FAIL\]' | head -5
    else
        ok "$label"
    fi
    rm -rf "$dir"
}

# --- F0 positive control ----------------------------------------------------
D=$(mk_repo); expect "F0 aligned fixture PASSES (positive control)" "$D" 0

# --- F1 second placeholder schema ------------------------------------------
D=$(mk_repo)
cp "$D/install/nftables/nftables.conf.tpl" "$D/install/nftables/second-schema.tpl"
expect "F1 a SECOND placeholder-bearing schema is caught" "$D" 1 "P1"

# --- F2 substitution reimplemented outside the render authority -------------
D=$(mk_repo)
printf '%s\n' '#!/usr/bin/env bash' 'sed -e "s/__CT_LIMIT_SSH__/99/g" x > y' > "$D/cli/lib/nftban/cli/rogue_render.sh"
expect "F2 substitution reimplemented elsewhere is caught" "$D" 1 "P2"

# --- F3 ENFORCEMENT drift of the motivating class (ct-count value) ----------
# This is the exact defect P12-FPA exists for: the boot projection enforcing a
# different connection limit than the canonical schema.
D=$(mk_repo)
sed -i 's/ct count over 150 drop comment "HTTP/ct count over 200 drop comment "HTTP/' "$D/install/nftables/nftables.conf"
expect "F3 ct-count ENFORCEMENT drift (150 vs 200) is caught" "$D" 1 "P3"

# --- F4 new unregistered rule-comment drift --------------------------------
D=$(mk_repo)
sed -i 's/comment "MAIL: max 150 (host-wide)"/comment "MAIL: max 150 per IP"/' "$D/install/nftables/nftables.conf"
expect "F4 NEW unregistered rule-comment drift is caught" "$D" 1 "P4"

# --- F5 stale registry row with no drift left ------------------------------
# The registry may only shrink: a row that no longer corresponds to real drift
# must be deleted, not left to quietly pre-approve a future divergence.
D=$(mk_repo)
printf '%s\n' 'comment "SOMETHING THAT NO LONGER DIVERGES"' > "$D/scripts/ci/data/firewall-projection-drift.allow"
expect "F5 stale registry row (no drift remains) is caught" "$D" 1 "P4"

# --- F6 boot projection that cannot parse ----------------------------------
D=$(mk_repo)
sed -i 's/^table ip nftban {/table ip nftban { NOT_NFT_SYNTAX/' "$D/install/nftables/nftables.conf.tpl"
sed -i 's/^table ip nftban {/table ip nftban { NOT_NFT_SYNTAX/' "$D/install/nftables/nftables.conf"
run "$D"
if [[ "$RC" -eq 0 ]]; then
    bad "F6 unparseable projection was NOT caught (rc=0)"
elif grep -q '\[FAIL\].*P5' <<<"$OUT"; then
    ok "F6 unparseable projection is caught by nft -c"
elif grep -q '\[INFO\].*P5 SKIPPED' <<<"$OUT"; then
    bad "F6 INCONCLUSIVE — nft -c could not run here, so P5 is UNPROVEN in this environment (a skip is not a pass)"
else
    ok "F6 unparseable projection is caught (rc=$RC)"
fi
rm -rf "$D"

echo "=== firewall-projection-authority-falsifiability: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
