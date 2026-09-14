#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — an observation must not report the OPPOSITE of what happened
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:description="BLOCKING, NARROW. `producer | grep -q PATTERN` inverts its own
#   verdict when the producer is still writing: grep -q exits on the FIRST match,
#   the producer takes SIGPIPE, and under `set -o pipefail` the pipeline reports
#   the PRODUCER's failure — so a SUCCESSFUL match reads as 'not found'.
#   MEASURED (v1.228.10, lab4): rc=141 for a 4195-byte producer, far below the 64K
#   pipe buffer, while a 1445-byte producer on lab2 returned 0. Output size only
#   makes the race more likely; IT IS NOT A BOUND, so 'this output is small' is not
#   a safety argument.
#   WHY IT MATTERS MOST IN A GUARD: when a match means OK, an inversion merely
#   under-claims (fail-safe). When a match means VIOLATION FOUND, an inversion
#   makes the guard MISS the violation and report success — fail-OPEN.
#   SCOPE IS DELIBERATELY scripts/ci/ ONLY. Repo-wide there are ~873 `| grep -q`
#   sites and 705 of 718 shell files set pipefail, so pipefail is not a
#   discriminator and a repo-wide rule would be noise. This guard covers the
#   checkers themselves, where the fail-open direction lives, and can be widened
#   later WITH EVIDENCE.
#   Builtin producers (echo/printf/herestring) are exempt: they complete before
#   grep can exit, so the race cannot occur."
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
SELF="check-observation-truth.sh"
FAILS=0
ok(){ printf '  [PASS] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

# Producers that STREAM: external commands that may still be writing when grep
# exits. echo/printf/cat-of-herestring are builtins or instant and are exempt.
STREAMING='nft|find|journalctl|systemctl|git|ps|ss|ip|awk|sed|grep|curl|rpm|dpkg|docker'

scan_dir="${1:-scripts/ci}"

echo "=== observation truth: producer | grep -q under pipefail ($scan_dir) ==="

hits=0
while IFS= read -r line; do
    f="${line%%:*}"; rest="${line#*:}"; ln="${rest%%:*}"; code="${rest#*:}"
    case "$(basename "$f")" in "$SELF") continue ;; esac   # never its own subject
    # MENTION != CODE. Prose describing the unsafe idiom — including the comments
    # that document WHY a site avoids it — must not be reported as the idiom.
    grep -qE '^[[:space:]]*#' <<<"$code" && continue
    # exempt: the producer is a shell builtin / instant
    grep -qE '(echo|printf)[^|]*\| *grep' <<<"$code" && continue
    # require a STREAMING producer immediately before the pipe
    grep -qE "(${STREAMING})[^|]*\| *grep [^|]*-q" <<<"$code" || continue
    hits=$((hits+1))
    bad "$f:$ln streaming producer piped to grep -q — a successful match can read as 'not found'"
    printf '         %s\n' "$(printf '%s' "$code" | sed 's/^[[:space:]]*//' | cut -c1-100)"
done < <(grep -rnE '\| *grep [^|]*-q' "$scan_dir" --include='*.sh' 2>/dev/null || true)

[ "$hits" -eq 0 ] && ok "no streaming-producer | grep -q verdicts in $scan_dir"
echo "=== observation truth: FAILS=$FAILS ==="
[ "$FAILS" -eq 0 ]
