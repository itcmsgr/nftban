#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — placeholder substitution must have exactly ONE authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-placeholder-substitution-authority"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-05"
# meta:description="v1.229.13 Lane 3D.2 exit gate. Asserts GO_PLACEHOLDER_SUBSTITUTION=0, SHELL_PLACEHOLDER_SUBSTITUTION=1, TEMPLATE_PLACEHOLDER_OWNER_COUNT=1. Product Go code must never substitute __SSH_PORT__ or __CT_LIMIT_*__ again: a second substitution authority is how 15/150/150 and 15/200/30 diverged. Comments are STRIPPED before scanning, because a mention is not an implementation. Carries its own negative control (--self-test)."
# meta:inventory.files="internal/installer/render/nftables.go,cli/lib/nftban/cli/cmd_firewall.sh,install/nftables/nftables.conf.tpl"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
note(){ printf '  %s\n' "$1"; }
bad(){ rc=1; printf '  FAIL  %s\n' "$1"; }
good(){ printf '  PASS  %s\n' "$1"; }

PH_RE='__SSH_PORT__|__CT_LIMIT_SSH__|__CT_LIMIT_HTTP__|__CT_LIMIT_MAIL__'

# Strip // line comments and /* */ blocks so a DOC MENTION is never mistaken for
# an implementation. Same discipline as the other FPA guards.
strip_go_comments(){ sed -e 's://.*::' "$1" | perl -0pe 's{/\*.*?\*/}{}gs'; }

scan_go(){ # <dir-root> -> prints "path:line" for each real substitution site
    local base="$1"
    while IFS= read -r f; do
        case "$f" in *_test.go) continue;; esac
        strip_go_comments "$f" | grep -nE "(ReplaceAll|Replace)\(.*($PH_RE)" \
            | sed "s|^|${f}:|"
    done < <(find "$base" -name '*.go' -type f 2>/dev/null)
}

echo "== GO_PLACEHOLDER_SUBSTITUTION (product code, comments stripped) =="
GO_HITS="$(scan_go "$ROOT/internal"; scan_go "$ROOT/cmd")"
GO_COUNT=$(printf '%s' "$GO_HITS" | grep -c . || true)
if [[ "$GO_COUNT" -eq 0 ]]; then
    good "GO_PLACEHOLDER_SUBSTITUTION=0"
else
    bad "GO_PLACEHOLDER_SUBSTITUTION=$GO_COUNT — a second substitution authority reappeared"
    printf '%s\n' "$GO_HITS" | sed 's/^/        /'
    note "Substitution belongs to _firewall_substitute_placeholders (cmd_firewall.sh)."
fi

echo "== SHELL_PLACEHOLDER_SUBSTITUTION =="
SHELL_DEFS=$(grep -rlE '^_firewall_substitute_placeholders\(\)' "$ROOT/cli/lib/nftban" 2>/dev/null | grep -v '/tests/' | wc -l | tr -d ' ')
if [[ "$SHELL_DEFS" -eq 1 ]]; then good "SHELL_PLACEHOLDER_SUBSTITUTION=1"
else bad "SHELL_PLACEHOLDER_SUBSTITUTION=$SHELL_DEFS — want exactly one definition"; fi

echo "== TEMPLATE_CT_PLACEHOLDER_OWNER_COUNT =="
# The CT limits are what diverged (15/150/150 vs 15/200/30), so CT placeholders
# are the ones that must have exactly ONE carrier. This mirrors the policy already
# encoded in .github/workflows/ci-architecture.yml, which forbids __CT_LIMIT_*__ in
# nftables-safe.conf. __SSH_PORT__ is deliberately NOT constrained here: the safe
# and ipv4 artifacts carry it by existing policy, and inventing a stricter rule
# than CI already enforces would be a guard asserting its author's preference.
CT_CARRIERS=$(grep -rlE '__CT_LIMIT_[A-Z]+__' "$ROOT/install/nftables" 2>/dev/null | sed "s|$ROOT/||" | sort)
CT_COUNT=$(printf '%s' "$CT_CARRIERS" | grep -c . || true)
if [[ "$CT_COUNT" -eq 1 && "$CT_CARRIERS" == "install/nftables/nftables.conf.tpl" ]]; then
    good "TEMPLATE_CT_PLACEHOLDER_OWNER_COUNT=1 (nftables.conf.tpl)"
else
    bad "TEMPLATE_CT_PLACEHOLDER_OWNER_COUNT=$CT_COUNT — CT placeholders must live in nftables.conf.tpl alone"
    printf '%s\n' "$CT_CARRIERS" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- self-test
# ⛔ A guard that cannot fail is not a guard. Reintroduce the exact defect this
# gate exists to prevent — a Go ReplaceAll of a placeholder — and require a catch.
if [[ "${1:-}" == "--self-test" ]]; then
    echo "== NEGATIVE CONTROL =="
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/internal/fake"
    cat > "$TMP/internal/fake/regress.go" <<'INJ'
package fake

import "strings"

func bad(content string, port string) string {
	return strings.ReplaceAll(content, "__SSH_PORT__", port)
}
INJ
    if [[ -n "$(scan_go "$TMP/internal")" ]]; then
        good "NEGATIVE CONTROL: an injected Go ReplaceAll IS detected"
    else
        bad "NEGATIVE CONTROL FAILED — guard is blind to the motivating defect"
    fi
    # And a comment-only MENTION must NOT be flagged.
    cat > "$TMP/internal/fake/mention.go" <<'INJ'
package fake

// Historically this substituted __SSH_PORT__ via strings.ReplaceAll(content, "__SSH_PORT__", p).
func fine() {}
INJ
    rm -f "$TMP/internal/fake/regress.go"
    if [[ -z "$(scan_go "$TMP/internal")" ]]; then
        good "NEGATIVE CONTROL: a comment-only mention is NOT flagged"
    else
        bad "NEGATIVE CONTROL FAILED — guard flags prose, not implementation"
    fi
fi

exit "$rc"
