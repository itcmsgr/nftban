#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — every -X linker target must be a DECLARED STRING VARIABLE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:description="BLOCKING. `go build -ldflags -X pkg.Symbol=value` sets STRING
#   VARIABLES ONLY. Pointing it at a function, a constant, or a symbol that does
#   not exist is a SILENT NO-OP: the linker emits no diagnostic and the binary
#   keeps its compiled-in default. That is how .github/slsa/nftban-core.yml came
#   to target pkg/version.FullVersion — a func — so every SLSA-built nftban-core
#   shipped \"vdev (git dev, build unknown)\" while build.sh, targeting the real
#   vars, was correct. Two builders, same intent, silently divergent identity.
#   This guard resolves every -X target in the repo back to its Go declaration and
#   fails unless it is a `var` of string type. It does NOT check the VALUE — only
#   that the target can receive one."
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FAILS=0
ok(){ printf '  [PASS] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== ldflags -X target authority ==="

# Collect every -X target: <import/path>.<Symbol>=
# Sources that can carry ldflags: workflows, SLSA configs, build scripts, Makefiles.
mapfile -t HITS < <(
  # --exclude this file: a CHECKER MUST NOT BE ITS OWN SUBJECT. Its documentation
  # necessarily quotes the -X construct it forbids, and matching that prose would
  # make the guard report on itself instead of on the build configuration.
  grep -rhoE '\-X [A-Za-z0-9_./-]+\.[A-Za-z_][A-Za-z0-9_]*=' \
    --include='*.yml' --include='*.yaml' --include='*.sh' --include='Makefile*' \
    --exclude='check-ldflags-target-authority.sh' \
    .github scripts build.sh packaging 2>/dev/null \
  | sed -E 's/^-X //; s/=$//' | sort -u
)

[ "${#HITS[@]}" -gt 0 ] || { bad "no -X targets found at all — the collector is broken, not the tree"; echo "=== ldflags target authority: FAILS=$FAILS ==="; exit 1; }

MODULE="$(awk '/^module /{print $2; exit}' go.mod 2>/dev/null)"
[ -n "$MODULE" ] || { bad "cannot read module path from go.mod"; exit 1; }

for t in "${HITS[@]}"; do
    sym="${t##*.}"
    pkgpath="${t%.*}"
    case "$pkgpath" in
        "$MODULE"/*) rel="${pkgpath#"$MODULE"/}" ;;
        *) ok "$t (outside this module — not resolvable here, skipped)"; continue ;;
    esac
    if [ ! -d "$rel" ]; then
        bad "$t -> package directory '$rel' does not exist"
        continue
    fi
    # A valid target: `var Symbol = "..."` or `var Symbol string`
    if grep -rhqE "^[[:space:]]*var[[:space:]]+${sym}[[:space:]]*(=[[:space:]]*\"|string\b)" "$rel"/*.go 2>/dev/null; then
        ok "$t -> declared string var"
    elif grep -rhqE "^[[:space:]]*func[[:space:]]+${sym}[[:space:]]*\(" "$rel"/*.go 2>/dev/null; then
        bad "$t -> '${sym}' is a FUNC. -X on a function is a SILENT NO-OP; the binary keeps its default"
    elif grep -rhqE "^[[:space:]]*const[[:space:]]+${sym}\b" "$rel"/*.go 2>/dev/null; then
        bad "$t -> '${sym}' is a CONST. -X cannot set a constant; silent no-op"
    else
        bad "$t -> '${sym}' is not declared in '$rel' — silent no-op"
    fi
done

echo "=== ldflags target authority: FAILS=$FAILS ==="
[ "$FAILS" -eq 0 ]
