#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-rebuild-result-authority"
# meta:type="tool"
# meta:description="P12-A01/A01b structural guard: ONE OPERATION -> ONE FINAL RECORD -> ONE AUTHORITATIVE CONSUMER; no rc/text fallback may reappear"
#
# ⛔ THIS GUARDS A SEMANTIC, NOT A FLAG.
# The regression to fear is not only "switchop reads rc again". It is also:
#   · a shell path writes a PROVISIONAL record and a later branch overwrites its disposition
#   · a SECOND producer publishes the same operation's record
#   · a SECOND consumer parses the record with its own rules
#   · an rc/text fallback quietly returns as a "compatibility" path
# Publication must be TERMINAL: once the final record exists, no later branch rewrites it.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SH="$ROOT/cli/lib/nftban/core/nftban_rebuild_classify.sh"
CF="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
GO="$ROOT/internal/installer/switchop/rebuild.go"
GR="$ROOT/internal/installer/switchop/rebuildresult.go"
fails=0
fail(){ echo "FAIL: $*" >&2; fails=$((fails+1)); }
ok(){ printf '  PASS  %s\n' "$1"; }

for f in "$SH" "$CF" "$GO" "$GR"; do [[ -r "$f" ]] || { fail "unreadable: $f"; }; done
(( fails )) && exit 2

# 1. ONE PRODUCER — only _rebuild_emit_result may write the result artifact.
if grep -qE 'function _rebuild_emit_result|^_rebuild_emit_result\(\)' "$SH"; then ok "single emitter function present"
else fail "no _rebuild_emit_result producer found"; fi
other=$(grep -rnE '>[[:space:]]*"?\$\{?_NFTBAN_REBUILD_RESULT_FILE' "$ROOT"/cli/lib/nftban/ 2>/dev/null | grep -v 'nftban_rebuild_classify.sh' | wc -l)
[[ "$other" -eq 0 ]] && ok "no second producer writes the result artifact" || fail "$other foreign writer(s) of the result artifact"

# 2. OPERATION ID IS MANDATORY on both sides.
grep -q '"operation_id"' "$SH" || fail "emitter does not record operation_id"
grep -q 'does not match this operation' "$GR" || fail "consumer does not reject a foreign/stale operation_id"
grep -q '"operation_id"' "$SH" && grep -q 'does not match this operation' "$GR" && ok "operation_id mandatory and stale-checked"

# 3. CALLER-ALLOCATED UNIQUE PATH — no fixed literal result filename in Go.
if grep -qE '"/run/nftban/rebuild-result\.json"|rebuild-result\.json"' "$GO"; then
    fail "a FIXED result path literal reintroduces stale/concurrent-run hazards"
else ok "no fixed result-path literal"; fi
grep -qE 'os\.Getpid\(\)|UnixNano\(\)' "$GO" && ok "result path carries a per-operation unique component" \
    || fail "result path has no unique per-operation component"

# 4. NO rc/text FALLBACK MAY AUTHORIZE CONTINUATION.
# The retired shape: a branch keyed on ExitCode == 1 that continues without a record.
if grep -nE 'ExitCode == 1' "$GO" | grep -qv '//'; then
    fail "rc==1 branch present in $GO — rc must not gate continuation"
else ok "no rc==1 continuation branch"; fi
grep -q 'ReadRebuildResult' "$GO" || fail "switchop does not require the structured result"
grep -q 'ContradictsExitCode' "$GO" || fail "rc/result contradiction is not checked"
grep -q 'ReadRebuildResult' "$GO" && grep -q 'ContradictsExitCode' "$GO" && ok "result required + contradiction checked"

# 5. ONE CONSUMER — only switchop parses the record.
consumers=$(grep -rlE 'ReadRebuildResult\(' "$ROOT"/internal "$ROOT"/cmd 2>/dev/null | grep -v _test | wc -l)
[[ "$consumers" -le 2 ]] && ok "single authoritative consumer (${consumers} file(s): definition + caller)" \
    || fail "$consumers files parse the result — a second consumer is a second authority"

# 6. PUBLICATION IS TERMINAL — every emit is immediately followed by a return.
bad=0
while IFS=: read -r ln _; do
    nxt=$(awk -v n="$ln" 'NR>n && NF {print; exit}' "$CF" | tr -d ' ')
    [[ "$nxt" == return* || "$nxt" == ";;" || "$nxt" == "fi" ]] || { echo "    non-terminal emit at $CF:$ln (next: $nxt)"; bad=$((bad+1)); }
done < <(grep -n '_rebuild_emit_result' "$CF")
[[ "$bad" -eq 0 ]] && ok "publication is terminal (no post-emit disposition rewrite)" \
    || fail "$bad emit site(s) are not terminal — a later branch could rewrite the disposition"

echo
if (( fails )); then echo "REBUILD RESULT AUTHORITY: FAIL ($fails)"; exit 1; fi
echo "REBUILD RESULT AUTHORITY: PASS"
