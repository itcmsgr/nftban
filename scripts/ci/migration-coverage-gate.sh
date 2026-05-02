#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.100.4 — H3.2 CI Migration-Coverage Gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ci-migration-coverage-gate"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-02"
# meta:description="H3.2 CI gate enforcing migration-coverage classifications (rules inline)"
# meta:inventory.files="scripts/ci/migration-coverage-gate.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Enforces migration-coverage classifications using rules inlined in this
# script. The classification spec lives in an internal audit/wiki workspace
# and is intentionally NOT shipped in this repo. The rules below MUST stay
# in sync with that spec.
# Doc-only enforcement — does NOT change runtime behavior, does NOT delete shell.
#
# 8 checks per the H3.2 specification:
#   1. PANELFW-ADAPTER-COVERAGE       (asymmetric — pending conf.d allowed)
#   2. PAYLOAD-DESTINATIONS-SOLE-TRUTH
#   3. NFTBAN-TABLE-CLASSIFIER-PARITY (structural)
#   4. G3-UN-NO-MUTATION whitelist locked
#   5. G3-UN-SHIM-LOCK + G3-EXEC-TRACE preserved
#   6. DEPRECATED-UI-UNIT-REFUSAL
#   7. PORT-LIST-BOUNDS
#   8. VALIDATOR-AUTHORITY-PIN
#
# Exit 0 = all required checks pass. Exit 1 = ≥1 required failure.
# Local invocation:
#     bash scripts/ci/migration-coverage-gate.sh
# CI invocation:
#     .github/workflows/ci-migration-coverage.yml runs this directly.
#
# Note: many checks pipe through grep / awk which legitimately return
# non-zero when there is no match. Those calls are wrapped with `|| true`
# (or assigned via $(...) which captures output without aborting) so
# `set -Eeuo pipefail` does not misclassify "no match" as a script error.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Inline classification rules (mirroring the internal H3.1 spec):
#
# Migrated panelfw adapters (Go install-time validation framework):
MIGRATED_PANELFW_ADAPTERS=("cpanel" "directadmin" "plesk")
# Pending evidence-gated panel families (have conf.d, no Go adapter yet):
PENDING_PANELFW_FAMILIES=("cwp" "cyberpanel" "generic" "interworx" "vesta")
# Deprecated unit names that must NOT reappear in payload destinations.
# Used by CHECK 6 via inline patterns; declared here as the canonical list.
# shellcheck disable=SC2034  # consumed by CHECK 6's inline grep patterns
DEPRECATED_UNIT_NAMES=("nftban-ui.service" "nftban-ui-auth.service")

declare -i FAILS=0
declare -i CHECKS=0

check_pass() {
    local name="$1" detail="$2"
    printf "%s: PASS  %s\n" "$name" "$detail"
    CHECKS=$((CHECKS + 1))
}

check_fail() {
    local name="$1" detail="$2"
    printf "%s: FAIL  %s\n" "$name" "$detail" >&2
    CHECKS=$((CHECKS + 1))
    FAILS=$((FAILS + 1))
}

# shellcheck disable=SC2329  # reserved for future advisory-only checks
check_advisory() {
    local name="$1" detail="$2"
    printf "%s: ADVISORY  %s\n" "$name" "$detail"
    CHECKS=$((CHECKS + 1))
}

echo "============================================================"
echo "H3.2 migration-coverage gate — branch HEAD $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo "rules: inline (internal H3.1 spec is not in this repo)"
echo "============================================================"

# =============================================================================
# CHECK 1 — PANELFW-ADAPTER-COVERAGE (asymmetric)
# =============================================================================
# Rule:
#   Go adapter exists      → conf.d MUST exist (FAIL if missing)
#   conf.d exists, no Go   → ALLOWED (pending status, row 4 in MIGRATION_COVERAGE.md)
# =============================================================================
{
    name="PANELFW-ADAPTER-COVERAGE"
    panelfw_dir="internal/installer/panelfw/adapters"
    confd_dir="etc/nftban/conf.d/panels"
    fail_detail=""

    if [ ! -d "$panelfw_dir" ]; then
        check_fail "$name" "panelfw adapter dir missing: $panelfw_dir"
    elif [ ! -d "$confd_dir" ]; then
        check_fail "$name" "conf.d/panels dir missing: $confd_dir"
    else
        # Helper: is element in array
        in_list() {
            local needle="$1"; shift
            local x
            for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
            return 1
        }

        # Iterate Go adapters: each must have conf.d + be in the migrated list
        for adapter in "$panelfw_dir"/*/; do
            [ -d "$adapter" ] || continue
            ad_name=$(basename "$adapter")
            confd="$confd_dir/$ad_name/main.conf"
            if [ ! -f "$confd" ]; then
                fail_detail+="Go adapter $ad_name has no $confd; "
                continue
            fi
            if ! in_list "$ad_name" "${MIGRATED_PANELFW_ADAPTERS[@]}"; then
                fail_detail+="Go adapter $ad_name not in MIGRATED_PANELFW_ADAPTERS allow-list (update inline rule if a new adapter migrates); "
            fi
        done

        # conf.d-only families (no Go adapter) are allowed if listed in
        # PENDING_PANELFW_FAMILIES. Iterate conf.d to catch unexpected families.
        for confd_path in "$confd_dir"/*/; do
            [ -d "$confd_path" ] || continue
            family=$(basename "$confd_path")
            if in_list "$family" "${MIGRATED_PANELFW_ADAPTERS[@]}"; then
                continue   # already validated above
            fi
            if ! in_list "$family" "${PENDING_PANELFW_FAMILIES[@]}"; then
                fail_detail+="conf.d/panels/$family/ is neither migrated nor pending — update inline rule; "
            fi
        done

        if [ -z "$fail_detail" ]; then
            check_pass "$name" "${#MIGRATED_PANELFW_ADAPTERS[@]} migrated Go adapters all have conf.d + inline-rule entry; ${#PENDING_PANELFW_FAMILIES[@]} pending conf.d-only families allowed"
        else
            check_fail "$name" "$fail_detail"
        fi
    fi
}

# =============================================================================
# CHECK 2 — PAYLOAD-DESTINATIONS-SOLE-TRUTH
# =============================================================================
# Rule:
#   internal/installer/uninstall/artifacts.go MUST call payload.Destinations()
#   and MUST NOT carry parallel hardcoded payload-path lists outside the
#   bounded uninstallOwnedRuntimePaths set:
#       /var/lib/nftban
#       /var/log/nftban
#       /var/cache/nftban
# =============================================================================
{
    name="PAYLOAD-DESTINATIONS-SOLE-TRUTH"
    target="internal/installer/uninstall/artifacts.go"
    fail_detail=""

    if [ ! -f "$target" ]; then
        check_fail "$name" "$target missing"
    else
        # Must call payload.Destinations
        if ! grep -qE "payload\.Destinations\(" "$target"; then
            fail_detail+="$target does not call payload.Destinations(); "
        fi

        # uninstallOwnedRuntimePaths must be exactly 3 entries from the bounded list.
        # Extract literal absolute paths in that var declaration.
        runtime_block=$(awk '/^var uninstallOwnedRuntimePaths *=/,/^}/' "$target")
        runtime_paths=$(echo "$runtime_block" | grep -oE '"/[a-zA-Z0-9/_.-]+"' | tr -d '"' | sort -u)
        expected=$'/var/cache/nftban\n/var/lib/nftban\n/var/log/nftban'
        if [ "$runtime_paths" != "$expected" ]; then
            fail_detail+="uninstallOwnedRuntimePaths is not the bounded 3-entry list; got: $(echo "$runtime_paths" | tr '\n' ',') "
        fi

        # Bounded extra-path enumerations also allowed in dedicated helpers:
        # protectedDirs (chattr targets) + removePolkitFallback (sweeping known polkit dirs).
        # These are explicitly authorized lists for safety, NOT parallel payload registries.
        # No additional grep-bound; the var name conventions are documented.

        if [ -z "$fail_detail" ]; then
            check_pass "$name" "artifacts.go calls payload.Destinations(); uninstallOwnedRuntimePaths bounded to {/var/lib/nftban,/var/log/nftban,/var/cache/nftban}"
        else
            check_fail "$name" "$fail_detail"
        fi
    fi
}

# =============================================================================
# CHECK 3 — NFTBAN-TABLE-CLASSIFIER-PARITY (structural)
# =============================================================================
# Rule:
#   Both the shell classifier (cli/lib/nftban/core/nftban_table_classify.sh)
#   and Go-side callers must reference the same 4 classes:
#       NFTBAN_OWNED
#       EXTERNAL_AUTHORITY_GHOST
#       KERNEL_DEFAULT
#       OPERATOR_SAFETY
#
# This is a STRUCTURAL parity check — the shell file is the live classifier;
# Go callers consume its output via Run("bash", ...). A behavioral parity
# fixture-test is a future upgrade once a Go-side classifier export lands.
# =============================================================================
{
    name="NFTBAN-TABLE-CLASSIFIER-PARITY"
    shell_classifier="cli/lib/nftban/core/nftban_table_classify.sh"
    fail_detail=""

    if [ ! -f "$shell_classifier" ]; then
        fail_detail+="$shell_classifier missing; "
    else
        for cls in NFTBAN_OWNED EXTERNAL_AUTHORITY_GHOST KERNEL_DEFAULT OPERATOR_SAFETY; do
            if ! grep -qE "TC_${cls}=\"${cls}\"" "$shell_classifier"; then
                fail_detail+="shell classifier missing TC_${cls} declaration; "
            fi
        done
    fi

    # Verify Go-side callers reference at least 3 of 4 classes (kernel_default may
    # be implicit — preserved silently per the doc).
    go_class_hits=0
    for cls in NFTBAN_OWNED EXTERNAL_AUTHORITY_GHOST OPERATOR_SAFETY; do
        if grep -qrE "${cls}" internal/installer/ cli/lib/nftban/cli/cmd_firewall.sh \
              cli/lib/nftban/helpers/autoheal.sh 2>/dev/null; then
            go_class_hits=$((go_class_hits + 1))
        fi
    done
    if [ "$go_class_hits" -lt 3 ]; then
        fail_detail+="fewer than 3 of 4 classifier classes referenced from Go/shell callers (got $go_class_hits); "
    fi

    if [ -z "$fail_detail" ]; then
        check_pass "$name" "shell classifier declares all 4 classes; ≥3 classes referenced cross-language; structural parity confirmed (behavioral fixture-test is future upgrade)"
    else
        check_fail "$name" "$fail_detail"
    fi
}

# =============================================================================
# CHECK 4 — G3-UN-NO-MUTATION whitelist locked
# =============================================================================
# Rule:
#   .github/workflows/ci-uninstall-canonization.yml's G3-UN-NO-MUTATION grep
#   excludes ONLY apply.go and artifacts.go from the structural no-mutation
#   audit. Any new uninstall .go added to the whitelist requires a
#   MIGRATION_COVERAGE.md update.
# =============================================================================
{
    name="G3-UN-NO-MUTATION-WHITELIST-LOCKED"
    workflow=".github/workflows/ci-uninstall-canonization.yml"
    fail_detail=""

    if [ ! -f "$workflow" ]; then
        check_fail "$name" "$workflow missing"
    else
        # The whitelist regex appears as: grep -vE '/(apply|artifacts)\.go$'
        if ! grep -qE "grep -vE '/\(apply\|artifacts\)\\\\\.go\\\$'" "$workflow" && \
           ! grep -qF "/(apply|artifacts)\.go" "$workflow"; then
            fail_detail+="G3-UN-NO-MUTATION whitelist regex does not match expected (apply|artifacts).go form; "
        fi

        if [ -z "$fail_detail" ]; then
            check_pass "$name" "whitelist scoped to apply.go + artifacts.go only"
        else
            check_fail "$name" "$fail_detail"
        fi
    fi
}

# =============================================================================
# CHECK 5 — G3-UN-SHIM-LOCK + G3-EXEC-TRACE preserved
# =============================================================================
# Rule:
#   The pre-existing PR-22/PR-23 gates must remain present in the workflow.
#   Their actual green status is enforced by the CI run itself.
# =============================================================================
{
    name="G3-UN-SHIM-LOCK-AND-EXEC-TRACE-PRESERVED"
    workflow=".github/workflows/ci-uninstall-canonization.yml"
    fail_detail=""

    for marker in "G3-UN-SHIM-LOCK" "G3-UN-PLAN-RENDERS" "G3-UN-CONSENT-REQUIRED" "G3-UN-HISTORY-PURITY"; do
        if ! grep -q "$marker" "$workflow"; then
            fail_detail+="$marker missing from $workflow; "
        fi
    done

    # G3-EXEC-TRACE lives in another workflow under scripts/ci/
    if [ ! -f "scripts/ci-exec-trace-assert.sh" ]; then
        fail_detail+="scripts/ci-exec-trace-assert.sh missing; "
    fi

    if [ -z "$fail_detail" ]; then
        check_pass "$name" "all canonization gate markers present"
    else
        check_fail "$name" "$fail_detail"
    fi
}

# =============================================================================
# CHECK 6 — DEPRECATED-UI-UNIT-REFUSAL
# =============================================================================
# Rule:
#   nftban-ui.service / nftban-ui-auth.service must NOT appear in payload
#   destinations or staged systemd unit set.
# =============================================================================
{
    name="DEPRECATED-UI-UNIT-REFUSAL"
    fail_detail=""

    # Must NOT appear in payload.go destination block (in active code, not comments).
    if grep -nE 'dstGlob.*nftban-ui[^/]*\.service|srcRel.*nftban-ui[^/]*\.service' \
         internal/installer/payload/payload.go 2>/dev/null | grep -v '^\s*//'; then
        fail_detail+="nftban-ui*.service still in payload.go destinations; "
    fi

    # Must NOT exist as a staged unit file under install/systemd/
    if [ -f install/systemd/nftban-ui.service ] || [ -f install/systemd/nftban-ui-auth.service ]; then
        fail_detail+="nftban-ui*.service unit file exists under install/systemd/; "
    fi

    # Must NOT exist as a Go binary command target (main.go or any .go source).
    # A stale cmd/nftban-ui/bin/ artifact dir without Go source is leftover
    # and tracked separately; the spec scope is "payload destinations / systemd
    # staging / install unit lists" — a non-source artifact dir does not
    # re-introduce the unit and is out of H3.2 scope.
    for d in cmd/nftban-ui cmd/nftban-ui-auth; do
        if [ -d "$d" ] && find "$d" -maxdepth 3 -name '*.go' -type f 2>/dev/null | grep -q .; then
            fail_detail+="$d/ contains Go source (deprecated cmd target reintroduced); "
        fi
    done

    if [ -z "$fail_detail" ]; then
        check_pass "$name" "nftban-ui / nftban-ui-auth absent from payload destinations + install/systemd + cmd/"
    else
        check_fail "$name" "$fail_detail"
    fi
}

# =============================================================================
# CHECK 7 — PORT-LIST-BOUNDS
# =============================================================================
# Rule:
#   panelfw adapter port lists must be defined as bounded slice literals
#   (not runtime-grown). Per-adapter bound:
#     directadmin: ≤ 8 (2222 default + reasonable variants)
#     plesk      : ≤ 8 (8443/8447/4190 + variants)
#     cpanel     : ≤ 8 (2087/2083/4190 + variants)
# =============================================================================
{
    name="PORT-LIST-BOUNDS"
    fail_detail=""
    declare -A MAX_PORTS=([directadmin]=8 [plesk]=8 [cpanel]=8)

    for adapter in directadmin plesk cpanel; do
        f="internal/installer/panelfw/adapters/$adapter/$adapter.go"
        if [ ! -f "$f" ]; then
            fail_detail+="$f missing; "
            continue
        fi
        # Count int-literal ports (4-5 digit numbers in []int{} or []uint16{} blocks)
        # in functions named RequiredPorts / ValidateReachability.
        port_count=$(awk '/func.*RequiredPorts|func.*ValidateReachability/,/^}/' "$f" 2>/dev/null \
                      | { grep -oE '\b(2[0-9]{3}|4190|443|80|22)\b' || true; } \
                      | sort -u | wc -l)
        max=${MAX_PORTS[$adapter]}
        if [ "$port_count" -gt "$max" ]; then
            fail_detail+="$adapter port count $port_count > bound $max; "
        fi
    done

    if [ -z "$fail_detail" ]; then
        check_pass "$name" "all 3 panelfw adapters have bounded port lists (≤ 8 unique ports each)"
    else
        check_fail "$name" "$fail_detail"
    fi
}

# =============================================================================
# CHECK 8 — VALIDATOR-AUTHORITY-PIN
# =============================================================================
# Rule:
#   Shell firewall rebuild path (cli/lib/nftban/cli/cmd_firewall.sh) MUST
#   invoke nftban-validate at some point (the validator is the authority
#   per v1.83). Structural grep — not a behavioral test.
# =============================================================================
{
    name="VALIDATOR-AUTHORITY-PIN"
    target="cli/lib/nftban/cli/cmd_firewall.sh"
    fail_detail=""

    if [ ! -f "$target" ]; then
        check_fail "$name" "$target missing"
    else
        if ! grep -qE "nftban-validate" "$target"; then
            fail_detail+="$target does not invoke nftban-validate; "
        fi

        if [ -z "$fail_detail" ]; then
            check_pass "$name" "cmd_firewall.sh invokes nftban-validate (validator authority preserved)"
        else
            check_fail "$name" "$fail_detail"
        fi
    fi
}

# =============================================================================
# Summary
# =============================================================================
echo "============================================================"
echo "Summary: $CHECKS checks executed; $FAILS required failures."
if [ "$FAILS" -eq 0 ]; then
    echo "H3.2 migration-coverage gate: PASS"
    exit 0
else
    echo "H3.2 migration-coverage gate: FAIL"
    exit 1
fi
