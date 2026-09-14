#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — guard-the-guard for check-observation-truth.sh
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:description="A guard that cannot fail is not a guard. Injects the MOTIVATING
#   defect (the real ARM6 form, nft list set | grep -q under pipefail) and requires a
#   FAIL that names it; injects the SAFE forms (builtin producer, capture-then-match,
#   and prose mentioning the idiom) and requires a PASS. Also proves the inversion is
#   REAL on this machine rather than taking it from documentation."
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
G=scripts/ci/check-observation-truth.sh
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
FAILS=0
ok(){ printf '  [PASS] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== guard-the-guard: observation truth ==="

# --- 0. the inversion is REAL here, not just documented ----------------------
# A large producer piped to grep -q under pipefail must return non-zero DESPITE
# the pattern being present. If this does not reproduce, the guard is guarding a
# condition this machine cannot exhibit and the reader deserves to know.
inv_rc=0
( set -o pipefail; seq 1 200000 | grep -q '^1$' ) || inv_rc=$?
if [ "$inv_rc" -ne 0 ]; then
    ok "0 the inversion reproduces: a PRESENT pattern returned rc=$inv_rc under pipefail"
else
    printf '  [INFO] 0 the inversion did not reproduce here (rc=0); the guard remains correct\n'
    printf '         by construction — SIGPIPE timing is load dependent, not a bound.\n'
fi

# --- 1. POSITIVE: the motivating defect must be caught ------------------------
mkdir -p "$D/ci"
cat > "$D/ci/unsafe_probe.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
if nft list set ip nftban blacklist_manual_ipv4 2>/dev/null | grep -q '10.99.2.2'; then
    echo present
fi
EOS
out="$(bash "$G" "$D/ci" 2>&1 || true)"
if grep -q 'unsafe_probe.sh' <<<"$out"; then
    ok "1 the real ARM6 form is detected"
else
    bad "1 the motivating defect was NOT detected — the guard is inert"
    printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- 2. NEGATIVE: builtin producer must NOT trip ------------------------------
rm -rf "$D/ci"; mkdir -p "$D/ci"
cat > "$D/ci/safe_builtin.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
if echo "$HAYSTACK" | grep -q needle; then echo found; fi
EOS
out="$(bash "$G" "$D/ci" 2>&1 || true)"
if grep -q 'FAILS=0' <<<"$out"; then ok "2 a builtin producer does not trip the guard (no over-match)"
else bad "2 OVER-MATCH: a safe builtin-producer pipeline was flagged"; fi

# --- 3. NEGATIVE: capture-then-match must NOT trip ----------------------------
rm -rf "$D/ci"; mkdir -p "$D/ci"
cat > "$D/ci/safe_capture.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
_out="$(nft list set ip nftban blacklist_manual_ipv4 2>/dev/null || true)"
if grep -q '10.99.2.2' <<<"$_out"; then echo present; fi
EOS
out="$(bash "$G" "$D/ci" 2>&1 || true)"
if grep -q 'FAILS=0' <<<"$out"; then ok "3 the CORRECTED form does not trip the guard"
else bad "3 the corrected form still trips — the guard cannot be satisfied"; fi

# --- 4. NEGATIVE: prose mentioning the idiom must NOT trip --------------------
rm -rf "$D/ci"; mkdir -p "$D/ci"
cat > "$D/ci/safe_comment.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
# Deliberately avoids `nft list ruleset | grep -q foo` because of SIGPIPE.
true
EOS
out="$(bash "$G" "$D/ci" 2>&1 || true)"
if grep -q 'FAILS=0' <<<"$out"; then ok "4 MENTION != CODE: a comment does not trip the guard"
else bad "4 comments are matched as code"; fi

echo "=== guard-the-guard: FAILS=$FAILS ==="
[ "$FAILS" -eq 0 ]
