#!/usr/bin/env bash
# =============================================================================
# NFTBan - PRO export profile is a deny-by-default data-release authority (v1.229.11)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="pro_export_profile_authority_v1229_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="metrics"
# meta:ta.id="pro_export_profile_authority_v1229_11_test"
# meta:ta.owner="metrics"
# meta:ta.module="pro-export-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.229.11. Locks the PRO export profile as a DATA-RELEASE AUTHORITY: deny-by-default, explicit producers, no transport. Asserts the exact permitted field set so a change is a deliberate reviewed act rather than a drift; asserts every profile entry has a declared producer (an entry without one is a silent contract failure, the same declared-but-unconsumed class as DDOS_HYBRID_CLASSIC_LAYER0 and NFTBAN_PRO_REMOTE_WRITE_URL); asserts the privacy-sensitive and inventory fields carried by the export_portal() stub are NOT inherited (serial_number, mac_address, networks, subnet_mask, location, cpu/memory/disk/vendor/model) -- AN EXISTING FIELD SET IS A PROPOSAL, NOT A CONTRACT; asserts the file performs no network I/O and contains no transport logic, since PROFILE decides WHAT may leave and TRANSPORT decides HOW with zero discretion to add fields; and asserts the builder cannot be widened by a caller."
# meta:inventory.files="cli/lib/nftban/exporters/nftban_export_profile_pro.sh"
# meta:inventory.binaries="bash,grep,jq"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$SD/../exporters/nftban_export_profile_pro.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE — the file documents excluded fields by name, on purpose.
code(){ grep -vE '^[[:space:]]*#' "$P" || true; }

echo "=== PRO export profile: deny-by-default data-release authority (v1.229.11) ==="
echo ""

# shellcheck source=/dev/null
source "$P" 2>/dev/null || { echo "cannot source profile"; exit 1; }

# --- P1 THE EXACT PERMITTED SET ------------------------------------------------
# Pinned deliberately: changing what may leave a customer host must be a reviewed
# act, never a silent drift.
#   THE EXPORT SURFACE IS PINNED, NOT DISCOVERED.
expected="blacklist_feeds_state blacklist_geoban_state blacklist_manual_entries blacklist_manual_state consistency_status hostname module_botguard_config module_ddos_config module_ddos_structural module_loginmon_config module_loginmon_effective module_loginmon_runtime module_loginmon_structural module_portscan_config module_portscan_effective module_portscan_structural nftban_version observed_at overall_status schema_version server_id service_state"
actual="$(nftban_pro_profile_fields | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$actual" == "$expected" ]]; then
    ok "P1 permitted set is EXACTLY the reviewed 22 fields"
else
    no "P1 permitted set changed — review required"
    echo "      expected: $expected"
    echo "      actual  : $actual"
fi

# --- P2 EVERY ENTRY HAS A DECLARED PRODUCER ------------------------------------
#   A PROFILE ENTRY WITHOUT A PRODUCER IS A CONTRACT FAILURE.
missing=0
while IFS= read -r f; do
    prod="$(nftban_pro_profile_producer "$f" 2>/dev/null)" || { missing=$((missing+1)); continue; }
    [[ "$prod" =~ ^(validator|local): ]] || { no "P2 '$f' producer is not validator:/local: -> '$prod'"; missing=$((missing+1)); }
done < <(nftban_pro_profile_fields)
[[ "$missing" -eq 0 ]] && ok "P2 every permitted field declares a real producer" \
                       || no "P2 $missing field(s) lack a usable producer"

# --- P3 DENY BY DEFAULT --------------------------------------------------------
for f in totally_unknown_field nftban_secret_key ""; do
    nftban_pro_profile_permits "$f" && { no "P3 unknown field '$f' was PERMITTED"; break; }
done
nftban_pro_profile_permits totally_unknown_field || ok "P3 an unknown field is DENIED (deny-by-default)"

# --- P4 THE export_portal() STUB'S FIELDS ARE NOT INHERITED --------------------
#   AN EXISTING FIELD SET IS A PROPOSAL, NOT A CONTRACT.
leaked=0
for f in serial_number mac_address networks subnet_mask location \
         cpu_cores cpu_model memory_total_bytes disk_total_bytes vendor model \
         os_name os_release kernel_version arch server_type panel; do
    nftban_pro_profile_permits "$f" && { no "P4 inventory/privacy field '$f' is PERMITTED"; leaked=$((leaked+1)); }
done
[[ "$leaked" -eq 0 ]] && ok "P4 no inventory/privacy field inherited from the export_portal() stub" || true

# --- P5 SPECIFICALLY: the privacy-sensitive four --------------------------------
priv=0
for f in serial_number mac_address networks location; do
    nftban_pro_profile_permits "$f" && priv=$((priv+1))
done
[[ "$priv" -eq 0 ]] && ok "P5 serial_number / mac_address / networks / location all DENIED" \
                    || no "P5 $priv privacy-sensitive field(s) permitted"

# --- N1 THE PROFILE PERFORMS NO NETWORK I/O ------------------------------------
#   PROFILE decides WHAT may leave. TRANSPORT decides HOW.
if code | grep -qE '\bcurl\b|\bwget\b|\bnc\b|\bncat\b|/dev/tcp|--connect-timeout'; then
    no "N1 the profile contains transport code — the authority boundary is blurred"
else
    ok "N1 the profile performs NO network I/O (no transport logic)"
fi
if code | grep -qiE 'retry|backoff|Authorization|Bearer'; then
    no "N1b the profile contains auth/retry logic — that belongs to TRANSPORT"
else
    ok "N1b no auth/retry/backoff logic in the profile"
fi

# --- N2 THE BUILDER CANNOT BE WIDENED BY A CALLER ------------------------------
# It takes at most a validator document; there is no extra-fields parameter and
# no merge with an external object.
if code | grep -qE 'nftban_pro_profile_build\(\)'; then
    body="$(awk '/^nftban_pro_profile_build\(\)/,/^}/' "$P" | grep -vE '^[[:space:]]*#')"
    if grep -qE '\$\{?[2-9]\}?|"\$@"' <<<"$body"; then
        no "N2 the builder accepts extra arguments — a caller could widen the export surface"
    else
        ok "N2 the builder takes only a validator document (surface cannot be widened by a caller)"
    fi
else
    no "N2 builder not found"
fi

# --- N3 NEGATIVE CONTROL --------------------------------------------------------
# If permits() returned true for everything, P3/P4/P5 would be vacuous.
if nftban_pro_profile_permits overall_status; then
    ok "N3 negative control: a KNOWN field IS permitted (the deny assertions are meaningful)"
else
    no "N3 negative control failed — permits() denies everything, so P3/P4/P5 prove nothing"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PRO export profile authority PASSED"
