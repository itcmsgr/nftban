#!/usr/bin/env bash
# =============================================================================
# NFTBan - daemon-callable neutrality (v1.229.7 PR-2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="daemon_callable_neutrality_v1229_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="Pins the v1.229.7 PR-2 authority separation: the daemon-callable halves (nftban_{ddos,portscan}_{apply,teardown}) must consume operator intent WITHOUT writing durable config and WITHOUT restarting the service that invoked them. Before PR-2 the daemon called the CLI orchestrators, whose Step 3 wrote DDOS_ENABLED/PORTSCAN_ENABLED into main.conf.local and whose Step 4 ran systemctl restart nftband from inside the daemon's own Start(). That was masked only by ProtectSystem=strict denying the write (EROFS) plus set -e aborting before the restart -- two accidental side effects, not gates, one packaging edit from re-arming. RUNTIME_WITNESSED on lab4 2026-08-21: a daemon restart built 10 module chains with both modules configured false."
# meta:ta.id="daemon_callable_neutrality_v1229_7_test"
# meta:ta.owner="firewall"
# meta:ta.module="daemon-runtime-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh,internal/ddos/module.go,internal/portscan/module.go"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
#
# -----------------------------------------------------------------------------
# SUBJECT SCOPING -- why this guard reads FUNCTION BODIES, not files.
#
# The forbidden literals (`systemctl restart nftband`, a `main.conf.local`
# write) MUST appear in this test's own negative controls, and they legitimately
# remain in the CLI orchestrators in the SAME files as the neutral halves. A
# file-scoped scan would therefore flag its own fixtures and the legitimate CLI
# code. So the subject is extracted per-function and nothing else is read.
#
#   TEST FIXTURE / PATTERN DATA   !=   PRODUCTION CALLABLE SUBJECT
#
# ⛔ This is deliberately NOT solved by exempting the guard from an upstream
#    scanner: AN ALLOWLISTED GUARD IS THE DEAD AUTHORITY IT EXISTS TO PREVENT.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

# extract_fn <file> <name>  -- prints the body of `name() { ... }` only.
extract_fn() {
    awk -v fn="$2" '
        $0 ~ "^"fn"\\(\\) \\{" { inside=1; next }
        inside && /^\}/        { inside=0 }
        inside                 { print }
    ' "$1"
}

echo "=== daemon-callable neutrality (v1.229.7 PR-2) ==="

DDOS="$ROOT/cli/lib/nftban/core/nftban_ddos.sh"
PSCAN="$ROOT/cli/lib/nftban/core/nftban_portscan.sh"

# SUBJECT_NOT_FOUND = FAILURE, never a skip.
for f in "$DDOS" "$PSCAN"; do
    [[ -f "$f" ]] || { fail "SUBJECT_NOT_FOUND: $f"; }
done
[[ $FAILURES -eq 0 ]] || { echo "::error::subjects unresolved"; exit 1; }

# --- 1. the neutral halves exist and are non-empty -----------------------------
for spec in "$DDOS:nftban_ddos_apply" "$DDOS:nftban_ddos_teardown" \
            "$PSCAN:nftban_portscan_apply" "$PSCAN:nftban_portscan_teardown"; do
    file="${spec%%:*}"; fn="${spec##*:}"
    body="$(extract_fn "$file" "$fn")"
    if [[ -z "$body" ]]; then
        fail "neutral half missing or empty: $fn"
    else
        ok "neutral half present: $fn"
    fi
done

# --- 2. NEUTRALITY: no durable-config write, no service restart ----------------
# Assembled at runtime so this guard's own source does not contain the literals
# it forbids -- SECURITY_GUARD_SOURCE_TEXT_CAN_MATCH_ITS_OWN_POLICY.
CONF_PAT="main\.conf\.local"
SVC_PAT="systemctl[[:space:]]+(restart|start|stop)"

for spec in "$DDOS:nftban_ddos_apply" "$DDOS:nftban_ddos_teardown" \
            "$PSCAN:nftban_portscan_apply" "$PSCAN:nftban_portscan_teardown"; do
    file="${spec%%:*}"; fn="${spec##*:}"
    body="$(extract_fn "$file" "$fn")"
    if grep -qE "$CONF_PAT" <<<"$body"; then
        fail "$fn writes durable config (matched ${CONF_PAT}) -- a daemon-callable path must CONSUME intent, not rewrite it"
    else
        ok "$fn does not touch durable config"
    fi
    if grep -qE "$SVC_PAT" <<<"$body"; then
        fail "$fn performs a service lifecycle action -- SERVICE RESTART MUST NOT COME FROM THE APPLY PATH"
    else
        ok "$fn performs no service lifecycle action"
    fi
done

# --- 3. the daemon calls ONLY the neutral halves --------------------------------
for spec in "internal/ddos/module.go:nftban_ddos" "internal/portscan/module.go:nftban_portscan"; do
    gof="$ROOT/${spec%%:*}"; pre="${spec##*:}"
    if [[ ! -f "$gof" ]]; then fail "SUBJECT_NOT_FOUND: $gof"; continue; fi
    if grep -qE "${pre}_(enable|disable)\"" "$gof"; then
        fail "$(basename "$gof") still invokes the CLI orchestrator ${pre}_enable/${pre}_disable"
    else
        ok "$(basename "$gof") invokes only the neutral halves"
    fi
    # v1.229.7 PR-3A moved the daemon one hop back: it now calls the transaction
    # ROOT, which resolves the mode ONCE and dispatches to the neutral halves.
    # The requirement is unchanged -- the daemon must reach the neutral halves
    # and never the CLI orchestrator -- so this asserts the SAME property across
    # the new topology instead of dropping it:
    #     daemon -> <mod>_reconcile -> {_apply, _teardown}
    # A guard that stops asserting a property because the code moved is the
    # dead authority it exists to prevent.
    if ! grep -q "${pre}_reconcile" "$gof"; then
        fail "$(basename "$gof") does not call ${pre}_reconcile -- the daemon must enter through the transaction root"
    else
        root_body="$(awk -v fn="${pre}_reconcile" '$0 ~ "^"fn"\\(\\) \\{"{i=1;next} i&&/^\}/{exit} i{print}' "$ROOT/cli/lib/nftban/core/${pre}.sh")"
        if [[ -z "$root_body" ]]; then
            fail "${pre}_reconcile not found -- cannot prove the daemon reaches the neutral halves"
        elif grep -q "${pre}_apply" <<<"$root_body" && grep -q "${pre}_teardown" <<<"$root_body"; then
            ok "$(basename "$gof") -> ${pre}_reconcile -> both neutral halves"
        else
            fail "${pre}_reconcile does not dispatch to BOTH ${pre}_apply and ${pre}_teardown"
        fi
    fi
done

# --- 3b. NON-OPERATOR LIFECYCLE ARMS MUST NOT REACH THE CLI ORCHESTRATORS ----
# v1.229.7 PR-2a. `reload`/`restart` re-apply RUNTIME state; they are not
# operator intent changes. Before this, `nftban ddos reload` called
# nftban_ddos_{disable,enable}, which persist DDOS_ENABLED and restart nftband
# -- and the firewall rebuild lane calls `nftban ddos reload`, so a rebuild
# mutated durable config and restarted the daemon mid-rebuild.
#   RELOAD != CONFIG MUTATION
echo ""
echo "3b. reload/restart arms use the neutral halves..."
for spec in "cli/lib/nftban/cli/cmd_ddos.sh:nftban_ddos" \
            "cli/lib/nftban/cli/cmd_portscan.sh:nftban_portscan"; do
    rel="${spec%%:*}"; pre="${spec##*:}"; f="$ROOT/$rel"
    if [[ ! -f "$f" ]]; then fail "SUBJECT_NOT_FOUND: $f"; continue; fi
    # Subject = the reload/restart case arm only, bounded to its own ;; terminator.
    arm="$(awk '/^ *reload\)|^ *reload\|restart\)/{inside=1} inside{print} inside&&/;;/{exit}' "$f")"
    if [[ -z "$arm" ]]; then
        fail "$rel reload/restart arm not found -- cannot assert what it calls"
    elif grep -qE "${pre}_(enable|disable)\b" <<<"$arm"; then
        fail "$rel reload/restart calls ${pre}_enable/${pre}_disable -- a reload must not write durable intent or restart the daemon"
    else
        ok "$rel reload/restart uses the neutral halves"
    fi
done

# --- 4. Start() and Stop() each consume intent -----------------------------------
# extract_go_fn <file> <signature-prefix> -- body of ONE Go method, bounded by its
# own closing brace. Bounding is load-bearing: an earlier revision of this check
# set a flag at Start() and never stopped, so Stop()'s gate satisfied it and
# deleting the Start() gate still passed. The negative control caught that.
extract_go_fn() {
    awk -v sig="$2" '
        index($0, sig) == 1 { inside=1; next }
        inside && /^\}/     { inside=0; exit }
        inside              { print }
    ' "$1"
}

for gof in "$ROOT/internal/ddos/module.go" "$ROOT/internal/portscan/module.go"; do
    [[ -f "$gof" ]] || { fail "SUBJECT_NOT_FOUND: $gof"; continue; }
    base="$(basename "$(dirname "$gof")")/$(basename "$gof")"
    for meth in "func (m *Module) Start(" "func (m *Module) Stop("; do
        name="${meth#func (m \*Module) }"; name="${name%(}"
        body="$(extract_go_fn "$gof" "$meth")"
        if [[ -z "$body" ]]; then
            fail "$base $name() body not found"
        elif grep -q 'm\.config\.Enabled' <<<"$body"; then
            ok "$base $name() gates on effective enabled"
        else
            fail "$base $name() does not gate on m.config.Enabled -- an ungated lifecycle method is an independent policy producer"
        fi
    done
done

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::daemon-callable neutrality FAILED: $FAILURES violation(s)"
    exit 1
fi
echo "daemon-callable neutrality PASSED"
