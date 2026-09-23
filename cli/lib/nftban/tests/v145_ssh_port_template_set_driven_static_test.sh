#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - PR-A static regression guard: set-driven SSH rate-limit
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="v145_ssh_port_template_set_driven_static_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="V1.145 PR-A static guard. Asserts the SSH brute-force ct-count rule is set-driven (tcp dport @ssh_ports ct count) in every shipped nftables template, that a `set ssh_ports` block exists, that the retired __SSH_PORTS_LIST__ placeholder is gone, that no literal `tcp dport __SSH_PORT__ ... ct count` rule survives, and that no operator-specific SSH port (e.g. 55000) is hardcoded in shipped templates/schema/renderer (allowed only in tests and comments). Closes Gap 2 from SSH_PORT_CHANGE_FLEET_AUDIT_AND_GAP_STACK.md."
# meta:input="None (reads repo source files read-only)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v145_ssh_port_template_set_driven_static_test"
# meta:ta.owner="firewall"
# meta:ta.module="nftables-ssh-templates"
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

# Resolve repo root from this script's location (.../cli/lib/nftban/tests/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

TPL_DIR="install/nftables"
TEMPLATES=(
    "$TPL_DIR/nftables.conf.tpl"
    "$TPL_DIR/nftables-safe.conf"
    "$TPL_DIR/nftables-ipv4.conf.tmpl"
)
RENDERER="internal/installer/render/nftables.go"
SCHEMA_SRC="cli/lib/nftban/lib/nft_schema.sh"
SCHEMA_GEN="internal/validator/schema_generated.go"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== v1.145 PR-A set-driven SSH rate-limit — static guard =="

# 1. No literal `tcp dport __SSH_PORT__ ... ct count` rule in any template.
for f in "${TEMPLATES[@]}"; do
    if grep -Eq 'tcp dport __SSH_PORT__[^\n]*ct count' "$f"; then
        bad "$f still has literal 'tcp dport __SSH_PORT__ ... ct count'"
    else
        ok "$f: no literal __SSH_PORT__ ct-count rule"
    fi
done

# 2. The retired __SSH_PORTS_LIST__ placeholder must not appear anywhere
#    in shipped templates or the renderer.
if grep -rIlq "__SSH_PORTS_LIST__" "${TEMPLATES[@]}" "$RENDERER"; then
    bad "retired __SSH_PORTS_LIST__ placeholder still present"
    grep -rIn "__SSH_PORTS_LIST__" "${TEMPLATES[@]}" "$RENDERER" | sed 's/^/        /'
else
    ok "no retired __SSH_PORTS_LIST__ placeholder remains"
fi

# 3. Each template declares a `set ssh_ports` block.
for f in "${TEMPLATES[@]}"; do
    if grep -Eq '^[[:space:]]*set ssh_ports \{' "$f"; then
        ok "$f: declares 'set ssh_ports'"
    else
        bad "$f: missing 'set ssh_ports' block"
    fi
done

# 4. Each template's SSH ct-count rule is set-driven via @ssh_ports.
# v1.231.0 P12-A02: `@ssh_ports` and `ct count` are no longer ADJACENT — the
# per-source set insertion (`add @connlimit_ssh_v4 { ip saddr ...`) now sits
# between them. The invariant this guard exists for is unchanged: the SSH cap
# reads its ports from the set and never from a hardcoded literal. Matching on
# adjacency was incidental to the old rule shape, so the pattern is widened to
# the invariant — and a keying assertion is added, which this guard could not
# make before the rules were keyed.
for f in "${TEMPLATES[@]}"; do
    if grep -Eq 'tcp dport @ssh_ports .*ct count over' "$f"; then
        ok "$f: SSH ct-count uses @ssh_ports"
    else
        bad "$f: SSH ct-count rule does not use @ssh_ports"
    fi
    # P12-A02 keying applies to the artifacts that actually REACH A HOST.
    # packaging/build_nftban.sh installs exactly two of these three, in both the
    # RPM (:580,:583) and DEB (:2559,:2562) paths: nftables.conf and
    # nftables.conf.tpl. nftables-safe.conf and nftables-ipv4.conf.tmpl are
    # repo-only today, so asserting keying on them would fail the gate over
    # artifacts no host can receive. Their disposition is tracked separately —
    # see A02-SAFE-CONF-UNCONVERTED / A02-IPV4-TMPL-DEAD-AUTHORITY.
    case "$(basename "$f")" in
        nftables.conf|nftables.conf.tpl)
            if grep -Eq 'tcp dport @ssh_ports .*ip6?[[:space:]]+saddr[[:space:]]+ct count over' "$f"; then
                ok "$f: SSH ct-count is keyed per source"
            else
                bad "$f: SSH ct-count rule is not keyed by source address"
            fi
            ;;
        *)
            ok "$f: not packaged — keying assertion out of scope (see A02 disposition)"
            ;;
    esac
done

# 5. ssh_ports must be in the generated validator inventory (required + all).
if grep -q '"ssh_ports"' "$SCHEMA_GEN"; then
    ok "$SCHEMA_GEN: ssh_ports present in generated inventory"
else
    bad "$SCHEMA_GEN: ssh_ports missing — re-run scripts/generate-go-schema.sh"
fi
if grep -q '\["ssh_ports"\]' "$SCHEMA_SRC"; then
    ok "$SCHEMA_SRC: ssh_ports present in canonical source"
else
    bad "$SCHEMA_SRC: ssh_ports missing from canonical nft_schema.sh"
fi

# 6. No operator-specific SSH port hardcoded in shipped templates/schema.
#    Templates + schema source must be completely free of 55000.
for f in "${TEMPLATES[@]}" "$SCHEMA_SRC" "$SCHEMA_GEN"; do
    if grep -q "55000" "$f"; then
        bad "$f: hardcoded 55000 found (must come from detection, not be baked in)"
        grep -n "55000" "$f" | sed 's/^/        /'
    else
        ok "$f: no hardcoded 55000"
    fi
done

# 7. In the renderer, 55000 may appear ONLY in comments (// …), never in code.
if grep -n "55000" "$RENDERER" | grep -vE ':[[:space:]]*//' | grep -q .; then
    bad "$RENDERER: 55000 used outside a comment (must not be hardcoded in logic)"
    grep -n "55000" "$RENDERER" | grep -vE ':[[:space:]]*//' | sed 's/^/        /'
else
    ok "$RENDERER: 55000 only in comments (if present)"
fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
