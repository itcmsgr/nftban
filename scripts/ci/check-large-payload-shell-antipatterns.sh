#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-large-payload-shell-antipatterns" meta:type="tool" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="P0-2 preventive guard: forbids whole-payload rewrites used only to answer an emptiness question, and semantically weaker fast substitutes"
# meta:inventory.files="scripts/ci/large-payload-shell-antipatterns.allow"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# THE RULE THIS ENFORCES:
#   Do not normalize or rewrite a large/unbounded captured payload merely to
#   answer a boolean question such as "is there meaningful content?".
#   The canonical idiom is:  nftban_has_non_whitespace "$payload"
#
# GATE A (hard) : new direct whitespace-strip emptiness idioms are forbidden.
# GATE E (hard) : every remaining match must resolve to the exception registry.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOW="$ROOT/scripts/ci/large-payload-shell-antipatterns.allow"
SELFTEST="${1:-}"
rc=0; found=0; allowed=0

scan_root="${NFTBAN_SCAN_ROOT:-$ROOT}"
mapfile -t hits < <(
  grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*//\[\[:(space|blank):\]\]/\}' \
    --include="*.sh" "$scan_root/cli" "$scan_root/install" "$scan_root/build" "$scan_root/scripts" 2>/dev/null \
    | grep -v '/tests/' | grep -v 'shell_predicates.sh' | grep -v 'check-large-payload-shell-antipatterns.sh' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
)
# NOTE: the trailing filter drops COMMENT lines. A guard that fails on its own
# documentation is noise, and noise is what makes people game a guard.
for h in "${hits[@]:-}"; do
  [[ -z "$h" ]] && continue
  found=$((found+1))
  file="${h%%:*}"; rel="${file#"$scan_root"/}"
  if grep -q "^${rel}|" "$ALLOW" 2>/dev/null; then
    allowed=$((allowed+1))
  else
    echo "FAIL [GATE A] unclassified whole-payload whitespace rewrite:"
    echo "       $h"
    echo "       Use: nftban_has_non_whitespace \"\$payload\"   (lib/shell_predicates.sh)"
    echo "       Or register it in scripts/ci/large-payload-shell-antipatterns.allow with CLASS_B/CLASS_C + reason."
    rc=1
  fi
done

# GATE B: the canonical predicate must exist and keep its exact implementation.
pred="$scan_root/cli/lib/nftban/lib/shell_predicates.sh"
if [[ ! -f "$pred" ]]; then
  echo "FAIL [GATE B] canonical predicate missing: lib/shell_predicates.sh"; rc=1
elif ! grep -qF '[[ $1 =~ [^[:space:]] ]]' "$pred"; then
  echo "FAIL [GATE B] nftban_has_non_whitespace no longer uses the approved bounded implementation"; rc=1
fi

# GATE B2: forbid the semantically WRONG fast substitute inside the predicate lib.
if grep -qE '^\s*\[\[ +-n +"?\$\{1:0:1\}"? +\]\]' "$pred" 2>/dev/null; then
  echo "FAIL [GATE B2] \${1:0:1} tests 'has at least one byte' — whitespace-only would pass"; rc=1
fi

# GATE C: caller/source invariant — anything calling the helper must source it.
while IFS= read -r f; do
  [[ "$f" == *shell_predicates.sh ]] && continue
  if ! grep -q 'shell_predicates.sh' "$f"; then
    echo "FAIL [GATE C] calls nftban_has_non_whitespace but does not source shell_predicates.sh: ${f#"$scan_root"/}"; rc=1
  fi
done < <(grep -rl 'nftban_has_non_whitespace' --include="*.sh" "$scan_root/cli" 2>/dev/null | grep -v '/tests/' || true)

echo "scanned: $found match(es); $allowed registered exception(s); rc=$rc"
[[ "$SELFTEST" == "--selftest" ]] && exit 0
exit $rc
