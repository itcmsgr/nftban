#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - the CLI surface parity guard reads the dispatcher
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="cli_surface_parity_dispatcher_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="GATE-CLI-SURFACE-PARITY-CHECKER-READS-NO-DISPATCHER (v1.235). scripts/ci/check-cli-surface-parity.sh named cli/sbin/nftban as its authority and was passed its path, but never opened it: a command present in the registry and in bash completion with NO handler passed as parity clean. Runs the REAL checker in a sandbox copy of its inputs (registry, completion, dispatcher, cli/cmd_*.sh). Arms: C0 the unmodified copy passes (control); N1 a command planted in registry + completion with no cmd_<cmd>.sh, no special case and no case arm FAILS with UNREACHABLE_IN_DISPATCHER; P1 the same command with a cmd_<cmd>.sh passes; P2 the same command handled by a dispatcher case arm passes. Set PARITY_SUBJECT_ROOT to an older tree (e.g. e79a1173): N1 must FAIL there (the old checker reports clean)."
# meta:inventory.files="cli_surface_parity_dispatcher_v1235_test.sh"
# meta:inventory.binaries="bash,python3,cp,mktemp"
# meta:inventory.env_vars="PARITY_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="cli_surface_parity_dispatcher_v1235_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-semantic-parity"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${PARITY_SUBJECT_ROOT:-$REPO}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: CLI surface parity guard reads the dispatcher ==="
command -v python3 >/dev/null 2>&1 || { echo "  NOT_EXECUTED: python3 missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
for f in scripts/ci/check-cli-surface-parity.sh commands.registry.yml install/bash-completion/nftban cli/sbin/nftban; do
    [[ -f "$ROOT/$f" ]] || { echo "  NOT_EXECUTED: $f missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }
done

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
# sandbox <name> -> a copy of exactly what the checker reads
sandbox(){
    local d="$W/$1"
    mkdir -p "$d/scripts/ci" "$d/install/bash-completion" "$d/cli/sbin" "$d/cli/lib/nftban/cli"
    cp "$ROOT/scripts/ci/check-cli-surface-parity.sh" "$d/scripts/ci/"
    cp "$ROOT/commands.registry.yml" "$d/"
    cp "$ROOT/install/bash-completion/nftban" "$d/install/bash-completion/"
    cp "$ROOT/cli/sbin/nftban" "$d/cli/sbin/"
    cp "$ROOT"/cli/lib/nftban/cli/cmd_*.sh "$d/cli/lib/nftban/cli/"
    printf '%s' "$d"
}
# plant <dir>: a registry command + completion entry named zzghost
plant(){
    printf '\nzzghost:\n  description: "planted by the v1.235 parity test"\n' >> "$1/commands.registry.yml"
    sed -i 's/local commands="/local commands="zzghost /' "$1/install/bash-completion/nftban"
}
run(){ ( cd "$1" && bash scripts/ci/check-cli-surface-parity.sh ) > "$1.out" 2>&1; }

d="$(sandbox c0)"; rc=0; run "$d" || rc=$?
[[ "$rc" -eq 0 ]] && ok "C0 unmodified copy passes (control)" || no "C0 unmodified copy failed" "rc=$rc $(tail -3 "$d.out" | tr '\n' ' ')"

d="$(sandbox n1)"; plant "$d"; rc=0; run "$d" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'UNREACHABLE_IN_DISPATCHER: zzghost' "$d.out"; then
    ok "N1 registry+completion command with no handler FAILS (UNREACHABLE_IN_DISPATCHER)"
else
    no "N1 handler-less command was not caught" "rc=$rc $(grep -m1 RESULT "$d.out" || true)"
fi

d="$(sandbox p1)"; plant "$d"; printf '#!/usr/bin/env bash\n' > "$d/cli/lib/nftban/cli/cmd_zzghost.sh"; rc=0; run "$d" || rc=$?
[[ "$rc" -eq 0 ]] && ok "P1 a cmd_<cmd>.sh makes it reachable" || no "P1 file-backed command reported unreachable" "rc=$rc"

d="$(sandbox p2)"; plant "$d"; printf '\n_zz(){ case "$1" in\n            zzghost)\n                :\n                ;;\n    esac; }\n' >> "$d/cli/sbin/nftban"; rc=0; run "$d" || rc=$?
[[ "$rc" -eq 0 ]] && ok "P2 a dispatcher case arm makes it reachable" || no "P2 case-arm command reported unreachable" "rc=$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
