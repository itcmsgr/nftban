#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — LOG WRITER -> RETENTION INVENTORY PARITY  (v1.229.3 P1-2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-log-writer-inventory-parity"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Every log path a writer produces must be claimed by the retention inventory. The existing authority checks the opposite direction only (declared paths resolve), so a writer nobody declared was invisible to every guard. Ratchets against a recorded baseline: a NEW undeclared writer fails; the pre-existing population is listed as registered debt and does not fail."
# meta:inventory.files="internal/logretention/inventory.go,install/config/nftban.logrotate"
# meta:inventory.privileges="none"
# =============================================================================
#
#   DECLARED PATH RESOLVES   != EVERY WRITER IS DECLARED
#
#   The missing direction. logretention already validates that what it declares
#   makes sense. Nothing validated that what the product WRITES is declared, so
#   botguard.log and decisions.log were written for releases with no authority
#   covering them (v1.229.3 P1-1).
#
#   ⛔ SCOPE. This guard DETECTS. It does not authorise a sweep: the writers that
#   were already undeclared when it was introduced are recorded as a baseline and
#   remain registered debt. Only a NEW undeclared writer fails CI. Forcing the
#   pre-existing population into this release is exactly the expansion the
#   v1.229.3 batch rule forbids.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INV="$ROOT/internal/logretention/inventory.go"
BASELINE="$ROOT/scripts/ci/data/log-writer-undeclared-baseline.txt"
RC=0
ok(){ echo "  [PASS] $1"; }
no(){ echo "  [FAIL] $1"; RC=1; }

echo "=== log writer -> retention inventory parity (v1.229.3 P1-2) ==="
[[ -f "$INV" ]] || { echo "  SUBJECT_NOT_FOUND: $INV"; exit 1; }

# ---- declared set: paths the inventory claims -------------------------------
mapfile -t DECLARED < <(grep -oE '"/var/log/nftban/[A-Za-z0-9_./-]+\.log"' "$INV" | tr -d '"' | sort -u)
if [[ ${#DECLARED[@]} -eq 0 ]]; then
    no "PARSE_INCOMPLETE: zero declared paths extracted from the inventory — an empty parse is not a pass"
    echo "RESULT: FAIL"; exit 1
fi

# ---- written set: paths the product actually opens ---------------------------
# Go: filepath.Join(LogDir, "x.log") and direct literals. Shell: literal paths.
# Comments are stripped first — a path named in a comment is not a writer.
written_tmp="$(mktemp)"; trap 'rm -f "$written_tmp"' EXIT
# ⛔ THE AUTHORITY IS NOT A WRITER. internal/logretention/ holds the declarations
# themselves; scanning it as source made the guard compare the inventory to itself and
# report a perfect 42/42 match that proved nothing. The declaring package is excluded.
#
# ⛔ LITERAL PATHS ARE NOT THE ONLY WRITERS. Go opens most logs as
# filepath.Join(cfg.LogDir, "x.log"), so a literal-only scan sees a fraction of them.
# Both forms are collected.
while IFS= read -r f; do
    stripped="$(sed -E 's://.*$::; s:(^|[[:space:]])#.*$:\1:' "$f" 2>/dev/null)"
    # form 1: full literal path
    grep -oE '"/var/log/nftban/[A-Za-z0-9_./-]+\.log"' <<<"$stripped" | tr -d '"'
    # form 2: a LogDir-relative name joined at runtime — ONLY when the same line
    # actually OPENS the file. Matching every mention produced two false writers:
    #   - Suricata's own stats.log lives under a DIFFERENT directory
    #   - watchdog/stats.log lost its subdirectory and was rewritten as a
    #     top-level path that no writer opens
    # ⛔ A PATH MENTION IS NOT A WRITER, and a basename is not a path. The
    # subdirectory is preserved, and only open/create sites count.
    grep -oE '(OpenFile|os\.Create|Create)\([^)]*(LogDir|logDir)[^)]*"[A-Za-z0-9_./-]+\.log"' <<<"$stripped" \
      | grep -oE '"[A-Za-z0-9_./-]+\.log"' | tr -d '"' | sed 's:^:/var/log/nftban/:'
    # form 2b: filepath.Join(logDir, "x.log") assigned to a variable that is opened
    # later. This is how internal/botguard/logger.go:59,65 writes — the very files
    # P1-1 corrects — and a form-2-only scan did NOT detect them, so removing them
    # from the inventory did not fail this guard. Found by inverting the guard
    # against its own motivating case.
    grep -oE 'filepath\.Join\([^)]*(LogDir|logDir)[^)]*"[A-Za-z0-9_./-]+\.log"\)' <<<"$stripped" \
      | grep -oE '"[A-Za-z0-9_./-]+\.log"' | tr -d '"' | sed 's:^:/var/log/nftban/:'
    # form 3: a SHELL WRITE to a path under the log dir. Requires a redirection or
    # tee on the same line; `Logs: ${NFTBAN_LOG_DIR}/geoip.log` in help text is
    # documentation, not a writer, and previously registered as one.
    grep -oE '(>>?|tee(\s+-a)?)\s*"?\$\{?NFTBAN_LOG_DIR\}?/[A-Za-z0-9_./-]+\.log' <<<"$stripped" \
      | grep -oE '\$\{?NFTBAN_LOG_DIR\}?/[A-Za-z0-9_./-]+\.log' \
      | sed -E 's:^[^/]+:/var/log/nftban:'
done < <(find "$ROOT/internal" "$ROOT/cmd" "$ROOT/cli" -type f \( -name '*.go' -o -name '*.sh' \) \
         ! -name '*_test.go' ! -path '*/tests/*' ! -path '*/logretention/*' 2>/dev/null) \
    | sort -u > "$written_tmp"

mapfile -t WRITTEN < "$written_tmp"
echo "    declared=${#DECLARED[@]}  written_literals=${#WRITTEN[@]}"

# ---- baseline of already-undeclared writers ---------------------------------
declare -A BASE=()
if [[ -f "$BASELINE" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        BASE["$line"]=1
    done < "$BASELINE"
fi

declare -A DECL=()
for d in "${DECLARED[@]}"; do DECL["$d"]=1; done

new_undeclared=(); known_undeclared=()
for w in "${WRITTEN[@]}"; do
    [[ -n "${DECL[$w]:-}" ]] && continue
    if [[ -n "${BASE[$w]:-}" ]]; then known_undeclared+=("$w"); else new_undeclared+=("$w"); fi
done

if [[ ${#new_undeclared[@]} -eq 0 ]]; then
    ok "no NEW undeclared log writer (baseline: ${#known_undeclared[@]} known, registered as debt)"
else
    no "${#new_undeclared[@]} NEW undeclared log writer(s) — every writer needs a retention authority:"
    for w in "${new_undeclared[@]}"; do echo "        $w"; done
    echo "        -> declare it in internal/logretention/inventory.go and add a logrotate stanza,"
    echo "           or add it to the baseline with a registered handle if it is knowingly deferred."
fi

# ---- stale baseline entries: a writer that is now declared must leave the baseline
stale=()
for b in "${!BASE[@]}"; do
    [[ -n "${DECL[$b]:-}" ]] && stale+=("$b")
done
if [[ ${#stale[@]} -eq 0 ]]; then
    ok "baseline carries no entry that is already declared (no false debt)"
else
    no "${#stale[@]} baseline entry/entries are now DECLARED — remove them so the debt count stays true:"
    for b in "${stale[@]}"; do echo "        $b"; done
fi

# ---- the P1-1 regression: botguard paths must match the writer ---------------
if grep -q '"/var/log/nftban/botguard/botguard.log"' "$INV"; then
    no "inventory still declares the botguard/ SUBDIRECTORY path that no writer uses (P1-1 regression)"
else
    ok "botguard inventory paths match the writer's top-level output (P1-1)"
fi

echo
if [[ $RC -eq 0 ]]; then echo "RESULT: writer->inventory parity PASS"; else echo "RESULT: writer->inventory parity FAIL"; fi
exit $RC
