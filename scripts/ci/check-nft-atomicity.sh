#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.0 - CI Gate: nftables Transition Atomicity
# =============================================================================
# meta:name="check-nft-atomicity"
# meta:type="script"
# meta:version="1.192.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Forbid flush/delete-then-repopulate-in-a-separate-transaction on live nftban tables and shared sets"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Closes the v1.192 transition-atomicity class
# (D-NFTBAN-SOAK-NONATOMIC-FIREWALL-REBUILD-DROP-WINDOW and siblings F-FEED/
# F-GEO). Two guards:
#
#   V-NFT-REBUILD-ATOMICITY
#     A PRODUCTION firewall path must NOT flush/delete the live `nftban` table
#     in a standalone `nft` call and then load the replacement in a separate
#     `nft -f`. The rebuild must reset the table INSIDE the loaded file so
#     `nft -f` applies it as one transaction (no fail-CLOSED drop window).
#     Recovery/reset/rollback/restore funcs are EXEMPT (operator/by-design).
#
#   V-NFT-SET-REFRESH-ATOMICITY
#     A PRODUCTION set-refresh path must NOT flush a live shared set in a
#     standalone call and repopulate it in a separate transaction (the F-FEED/
#     F-GEO fail-OPEN window on blacklist_*). Flush + add must go in one
#     `nft -f` (see internal/setsync renderSetReplaceScript).
#
# Exit codes: 0 = clean · 1 = violation (PR must not merge)
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
echo "========================================"
echo "NFTBan Architecture Check: nft Transition Atomicity"
echo "========================================"
echo ""

# -----------------------------------------------------------------------------
# V-NFT-REBUILD-ATOMICITY
# -----------------------------------------------------------------------------
# Scan cmd_firewall.sh: any literal `nft (flush|delete) table (ip|ip6|inet)
# nftban` that lives OUTSIDE an exempt recovery function is a violation.
# (The ghost-table cleanup uses a `$TABLE_SPEC` variable, not literal `nftban`,
# so it is not matched.)
FW="cli/lib/nftban/cli/cmd_firewall.sh"
echo "[V-NFT-REBUILD-ATOMICITY] scanning $FW ..."

if [[ ! -f "$FW" ]]; then
    echo "::error::$FW not found"; exit 1
fi

# Recovery/operator funcs allowed to flush/delete the live table by design.
#
# v1.228.10 A1: _rebuild_rollback REMOVED from this list. It was exempt, and the
# exemption is precisely how the defect survived — the forward lane's prohibition on
# flush-then-load was enforced while the AUTOMATIC recovery path that fires when a
# rebuild regresses was allowed to do exactly that, plus a global `nft flush ruleset`
# that also destroyed foreign (Docker/panel/operator) tables.
#
# An exemption is a claim that a path is safe by design. That claim was never true
# here: rollback now builds an NFTBan-scoped, self-resetting candidate, pre-validates
# it with `nft -c -f`, and commits it in ONE `nft -f`. It therefore needs no exemption
# and must be held to the same rule as the forward lane.
#
# The three remaining entries are operator-invoked, --force-gated paths (B15) and stay
# exempt for now; they are tracked separately and are NOT in this lane's scope.
REBUILD_EXEMPT='firewall_reset _restore_from_file _restore_previous_firewall'

REBUILD_VIOLATIONS="$(
    awk -v exempt="$REBUILD_EXEMPT" '
        BEGIN { split(exempt, e, " "); for (i in e) ex[e[i]] = 1; fn = "(top-level)" }
        # Track the current top-level function (name() at column 0).
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{?[[:space:]]*$/ {
            f = $0; sub(/\(\).*/, "", f); fn = f; next
        }
        # Match a real (non-comment) standalone flush/delete of live state.
        #
        # v1.228.10 A1: `nft flush ruleset` added. The rule previously matched only a
        # NAMED nftban table, so the GLOBAL flush — which is strictly worse, because it
        # also destroys foreign (Docker/panel/operator) tables — was invisible to it.
        # Removing _rebuild_rollback from the exemption list alone did NOT catch the old
        # code; measured, the guard still passed. Both changes were required.
        /nft[[:space:]]+(flush|delete)[[:space:]]+table[[:space:]]+(ip|ip6|inet)[[:space:]]+nftban|nft[[:space:]]+flush[[:space:]]+ruleset/ {
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (line ~ /^#/) next
            # v1.228.10 A1: the subject is the EXECUTABLE surface. An operator hint or a
            # warning that NAMES the forbidden command is not the command. Approximate
            # "inside a quoted string" by counting quotes before the match — imperfect,
            # but it fails toward reporting (a real command is never skipped), and the
            # alternative was flagging a message that warns AGAINST the very primitive.
            pre = line; sub(/nft[[:space:]]+(flush|delete).*/, "", pre)
            q = gsub(/"/, "\"", pre)
            if (q % 2 == 1) next
            if (line ~ /^(echo|printf)[[:space:]]/) next
            if (!(fn in ex)) printf "  %s:%d  [in %s()]  %s\n", FILENAME, NR, fn, line
        }
    ' "$FW"
)"

if [[ -n "$REBUILD_VIOLATIONS" ]]; then
    echo "::error::V-NFT-REBUILD-ATOMICITY violation — standalone flush/delete of the live nftban table in a production path:"
    echo "$REBUILD_VIOLATIONS"
    echo "  Fix: reset the table INSIDE the loaded \$load_conf (it already begins with"
    echo "       'table ... { }' + 'delete table ...'), so 'nft -f' applies it atomically."
    FAIL=1
else
    echo "  PASS — no standalone live-table flush/delete outside recovery funcs."
fi
echo ""

# -----------------------------------------------------------------------------
# V-NFT-SET-REFRESH-ATOMICITY
# -----------------------------------------------------------------------------
# In internal/setsync, a shared-set replace must NOT use a standalone set flush
# followed by a separate add. Two negative checks + one positive wiring check.
echo "[V-NFT-SET-REFRESH-ATOMICITY] scanning internal/setsync ..."

# (a) No standalone set-flush helper callsites (helper removed in v1.192).
NFTFLUSH_HITS="$(grep -rnE '\bnftFlushSet[[:space:]]*\(' --include='*.go' internal/setsync 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$NFTFLUSH_HITS" ]]; then
    echo "::error::V-NFT-SET-REFRESH-ATOMICITY violation — standalone nftFlushSet() callsite (flush in a separate transaction from the add):"
    echo "$NFTFLUSH_HITS"
    echo "  Fix: replace contents via replaceSetElementsViaFile() — flush+add in ONE nft -f."
    FAIL=1
fi

# (b) No direct standalone `nft flush set` exec/runNft in setsync.
DIRECT_FLUSH_HITS="$(grep -rnE '(runNft[A-Za-z]*\(|exec\.Command\("nft"[^)]*)[^)]*"flush"[[:space:]]*,[[:space:]]*"set"' \
    --include='*.go' internal/setsync 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$DIRECT_FLUSH_HITS" ]]; then
    echo "::error::V-NFT-SET-REFRESH-ATOMICITY violation — direct standalone 'nft flush set' in setsync:"
    echo "$DIRECT_FLUSH_HITS"
    echo "  Fix: emit 'flush set' as the first line of the nft -f script (renderSetReplaceScript)."
    FAIL=1
fi

# (c) Positive wiring: the atomic replace path must exist and emit an in-file flush.
if ! grep -q 'func renderSetReplaceScript' internal/setsync/nft_cli.go 2>/dev/null; then
    echo "::error::V-NFT-SET-REFRESH-ATOMICITY: renderSetReplaceScript missing (atomic replace path absent)."
    FAIL=1
elif ! grep -qE '"flush set %s %s %s' internal/setsync/nft_cli.go 2>/dev/null; then
    echo "::error::V-NFT-SET-REFRESH-ATOMICITY: renderSetReplaceScript does not emit an in-file 'flush set'."
    FAIL=1
fi
if ! grep -q 'replaceSetElementsViaFile(' internal/setsync/nft_elements.go 2>/dev/null; then
    echo "::error::V-NFT-SET-REFRESH-ATOMICITY: AddCIDRElementsWithStats no longer routes through replaceSetElementsViaFile."
    FAIL=1
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "  PASS — set refresh flushes+adds atomically (single nft -f), no standalone flush callsites."
fi
echo ""

# -----------------------------------------------------------------------------
# V-OPQUEUE-REPLACE-ATOMICITY (netlink replace_set / flush_source)
# -----------------------------------------------------------------------------
# The opqueue replace_set + flush_source apply paths run over the SHARED netlink
# connection. A standalone backend.FlushSet() that COMMITS before the adds leaves
# the kernel set transiently EMPTY (fail-OPEN on enforcement sets — the sibling of
# F-FEED/F-GEO on the netlink side, invisible to the setsync/shell scans above).
# They MUST route through the atomic backend.ReplaceSet() primitive (one netlink
# transaction: flush + add + single commit); the primitive must commit EXACTLY
# once per replace. (Incremental backend.AddElements() for ban/unban is fine — a
# committed flush is not.)
BUF="internal/opqueue/buffer.go"
PRIM="internal/setsync/nft_replace_atomic.go"
echo "[V-OPQUEUE-REPLACE-ATOMICITY] scanning $BUF + $PRIM ..."
OPQ_FAIL=0
# drop `grep -n` lines (LINE:content) whose content is a // or * comment
nocomment() { grep -vE '^[0-9]+:[[:space:]]*(//|\*)'; }

# (a) NEGATIVE: no standalone committed backend.FlushSet() anywhere in buffer.go.
BUF_FLUSH_HITS="$(grep -nE 'backend\.FlushSet\(' "$BUF" 2>/dev/null | nocomment || true)"
if [[ -n "$BUF_FLUSH_HITS" ]]; then
    echo "::error::V-OPQUEUE-REPLACE-ATOMICITY — standalone backend.FlushSet() in $BUF (use backend.ReplaceSet for an atomic flush/replace):"
    echo "$BUF_FLUSH_HITS"
    OPQ_FAIL=1; FAIL=1
fi

# (b) POSITIVE: applyReplace routes through backend.ReplaceSet and does NOT call
#     the separately-committing FlushSet()/AddElements() in its body.
APPLY_BODY="$(awk '/func \(buf \*SetBuffer\) applyReplace\(/{p=1} p{print} p&&/^}/{exit}' "$BUF")"
if ! grep -qE 'backend\.ReplaceSet\(' <<<"$APPLY_BODY"; then
    echo "::error::V-OPQUEUE-REPLACE-ATOMICITY — applyReplace does not call backend.ReplaceSet()."
    OPQ_FAIL=1; FAIL=1
fi
if [[ "$(grep -vE '^[[:space:]]*//' <<<"$APPLY_BODY" | grep -cE 'backend\.(FlushSet|AddElements)\(' || true)" -gt 0 ]]; then
    echo "::error::V-OPQUEUE-REPLACE-ATOMICITY — applyReplace still calls the separately-committing FlushSet()/AddElements()."
    OPQ_FAIL=1; FAIL=1
fi

# (c) POSITIVE: the flush_source branch is folded into the atomic primitive.
if ! grep -qE '\} else if flushPending \{' "$BUF" || ! grep -qE 'pendingAddSetElements\(' "$BUF"; then
    echo "::error::V-OPQUEUE-REPLACE-ATOMICITY — flush_source path not folded into the atomic ReplaceSet primitive."
    OPQ_FAIL=1; FAIL=1
fi

# (d) POSITIVE: the primitive exists and commits EXACTLY ONCE per replace.
if [[ ! -f "$PRIM" ]]; then
    echo "::error::V-OPQUEUE-REPLACE-ATOMICITY — atomic primitive $PRIM missing."
    OPQ_FAIL=1; FAIL=1
else
    PRIM_BODY="$(awk '/func replaceSetElementsOnConn\(/{p=1} p{print} p&&/^}/{exit}' "$PRIM")"
    FLUSH_COMMITS="$(grep -cE 'conn\.Flush\(\)' <<<"$PRIM_BODY" || true)"
    if [[ "$FLUSH_COMMITS" != "1" ]]; then
        echo "::error::V-OPQUEUE-REPLACE-ATOMICITY — replaceSetElementsOnConn must commit exactly once (conn.Flush()); found $FLUSH_COMMITS."
        OPQ_FAIL=1; FAIL=1
    fi
fi

if [[ "$OPQ_FAIL" -eq 0 ]]; then
    echo "  PASS — opqueue replace_set/flush_source route through the single-transaction atomic ReplaceSet."
fi
echo ""

# -----------------------------------------------------------------------------
# V-NFT-SERVICE-PORTS-RENDERED-COMPLETE (static, v1.192.1)
# -----------------------------------------------------------------------------
# Every PRODUCTION render path that substitutes the nftables template
# (_firewall_substitute_placeholders <in> <out>) and then applies/persists it
# MUST complete the service-port sets via _firewall_complete_service_ports on the
# SAME <out> before nft -f — otherwise it can load skeletal tcp_ports_in/out +
# udp_ports_in/out (the D-V192-RESIDUAL-REBUILD-DROP class). This static guard
# requires an _firewall_complete_service_ports call within a short window after
# each production substitute-render call.
echo "[V-NFT-SERVICE-PORTS-RENDERED-COMPLETE] scanning $FW render paths ..."
# Per-function pairing: any function that CALLS _firewall_substitute_placeholders
# (a production render of the nftban ruleset) must also call
# _firewall_complete_service_ports somewhere in the same function (the append is
# placed after the render's if/else block, so a line-proximity check is wrong).
# Allowlist = functions that render for explicitly non-production/offline use.
SP_ALLOW='_firewall_substitute_placeholders'  # the helper's own def (contains the name, no call)
SP_VIOLATIONS="$(
    awk -v allow="$SP_ALLOW" '
        BEGIN { split(allow, a, " "); for (i in a) ex[a[i]]=1; fn="(top)" }
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{?[[:space:]]*$/ {
            # entering a new function: flush the previous one
            if (have_sub && !have_app && !(fn in ex))
                printf "  %s: function %s() renders (_firewall_substitute_placeholders) but never calls _firewall_complete_service_ports\n", FILENAME, fn
            f=$0; sub(/\(\).*/, "", f); fn=f; have_sub=0; have_app=0; next
        }
        /_firewall_substitute_placeholders[[:space:]]+"\$/ { l=$0; sub(/^[[:space:]]+/,"",l); if (l !~ /^#/) have_sub=1 }
        /_firewall_complete_service_ports/ { have_app=1 }
        END { if (have_sub && !have_app && !(fn in ex))
            printf "  %s: function %s() renders but never calls _firewall_complete_service_ports\n", FILENAME, fn }
    ' "$FW"
)"
if [[ -n "$SP_VIOLATIONS" ]]; then
    echo "::error::V-NFT-SERVICE-PORTS-RENDERED-COMPLETE violation — production render not completed with effective service-port sets (skeletal-apply risk):"
    echo "$SP_VIOLATIONS"
    echo "  Fix: call _firewall_complete_service_ports \"\$out\" (fail-closed) before nft -f, OR move the render to an explicitly non-production/offline context."
    FAIL=1
else
    echo "  PASS — every production substitute-render is completed by _firewall_complete_service_ports."
fi
echo ""

# -----------------------------------------------------------------------------
echo "========================================"
if [[ "$FAIL" -eq 0 ]]; then
    echo "RESULT: PASS — transition atomicity invariants hold"
    exit 0
fi
echo "RESULT: FAIL — transition atomicity violation (see ::error:: above)"
exit 1
