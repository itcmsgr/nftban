#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - shipped configs must load on a host with no nftban tables
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="nft-shipped-conf-cold-load-idiom-test"
# meta:type="test"
# meta:header="Shipped Config Cold-Load Idiom"
# meta:version="1.229.11"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Static regression for SAFE-CONF-COLD-LOAD: every shipped nftables config that issues 'delete table ip{,6} nftban' MUST first declare the empty table ('table ip nftban { }') so the delete is idempotent. nft applies a file as ONE transaction and 'delete table' on a missing table is a hard error, so without the create-first idiom the whole config fails to load on any host with no nftban tables - fresh install, post-flush, post-uninstall, recovery. MEASURED on nftables-safe.conf before the fix: real 'nft -f' returned rc=1 and installed NO firewall, while the identical file loaded rc=0 when the tables already existed. That is inverted for a safe fallback, whose entire purpose is the recovery case. Asserts per file and per family: the 'table <fam> nftban { }' declaration precedes the matching 'delete table <fam> nftban'. Hermetic: reads repo source files read-only; no nft, no host, no root."
# meta:inventory.files="install/nftables/nftables.conf.tpl,install/nftables/nftables.conf,install/nftables/nftables-safe.conf"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-08-29"
# meta:updated_date="2026-08-29"
# meta:ta.id="nft_shipped_conf_cold_load_idiom_test"
# meta:ta.owner="firewall"
# meta:ta.module="nft-schema-load-idiom"
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
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cd "$SD/../../../.." && pwd)
P=0; F=0
ok(){ echo "PASS $1"; P=$((P+1)); }
no(){ echo "FAIL $1 ${2:-}"; F=$((F+1)); }

# Rule lines only - a commented-out example must never satisfy the assertion.
rules_only(){ grep -vE '^[0-9]+:[[:space:]]*#'; }

check_file() {
    local f="$1" label="$2"
    [[ -r "$f" ]] || { no "$label: unreadable ($f)"; return; }
    local fam
    for fam in ip ip6; do
        local del cre
        del=$(grep -nE "^[[:space:]]*delete table ${fam} nftban[[:space:]]*$" "$f" \
              | rules_only | grep -oE '^[0-9]+' | head -1 || true)
        if [[ -z "$del" ]]; then
            ok "$label/$fam: no 'delete table' (idiom not required)"
            continue
        fi
        cre=$(grep -nE "^[[:space:]]*table ${fam} nftban \{[[:space:]]*\}[[:space:]]*$" "$f" \
              | rules_only | grep -oE '^[0-9]+' | head -1 || true)
        if [[ -z "$cre" ]]; then
            no "$label/$fam: 'delete table' at line $del with NO preceding 'table ${fam} nftban { }'" \
               "(cold load on a host without nftban tables fails the whole transaction)"
        elif [[ "$cre" -lt "$del" ]]; then
            ok "$label/$fam: create($cre) precedes delete($del)"
        else
            no "$label/$fam: create($cre) does NOT precede delete($del)"
        fi
    done
}

echo "== every shipped config makes its table deletion idempotent =="
check_file "$ROOT/install/nftables/nftables.conf.tpl"  "TPL"
check_file "$ROOT/install/nftables/nftables.conf"      "CONF"
check_file "$ROOT/install/nftables/nftables-safe.conf" "SAFE"

echo ""
echo "=== nft_shipped_conf_cold_load_idiom: PASS=$P FAIL=$F ==="
[[ "$F" -eq 0 ]]
