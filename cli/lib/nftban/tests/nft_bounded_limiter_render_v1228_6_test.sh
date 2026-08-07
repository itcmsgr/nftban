#!/usr/bin/env bash
# =============================================================================
# NFTBan - rendered-ruleset bounded-limiter truth (v1.228.6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_bounded_limiter_render_v1228_6_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-07"
# meta:description="T13 of the meter-capacity hotfix asserted on RENDERED output, not source intent. Renders the real DDoS/prefix/BotGuard fragments through their production generator functions, asserts no meter shorthand survives rendering, every update-statement limiter carries a size+timeout+dynamic declaration, v4/v6 pairs render together, and — when an nft binary exists — the composed base+fragment ruleset PARSES with nft -c. Includes a discrimination control: a meter line injected into a rendered fragment must be caught by the same assertions."
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,awk"
# meta:inventory.env_vars="NFTBAN_FRAGMENT_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# The generator writes fragments here; production default is /etc/nftban/rules.d.
export NFTBAN_FRAGMENT_DIR="$WORK/rules.d"
mkdir -p "$NFTBAN_FRAGMENT_DIR"

# shellcheck source=/dev/null
source "$ROOT/cli/lib/nftban/lib/nft_fragment.sh" || { bad "SOURCE nft_fragment.sh"; echo "=== nft_bounded_limiter_render: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

# ---------------------------------------------------------------------------
# STAGE 1 — render the fragments that carry rate limiters, through the REAL
# production functions (no fixture copies of their output).
# ---------------------------------------------------------------------------
echo "--- STAGE 1: render through production generators ---"
RENDERED=()
for fn in nft_fragment_render_ddos_classic nft_fragment_render_ddos_prefix \
          nft_fragment_render_http_botguard_sets nft_fragment_render_http_botguard; do
    out="$($fn 2>/dev/null)"
    if [[ -n "$out" && -f "$out" ]]; then
        ok "RENDERED $fn -> $(basename "$out")"
        RENDERED+=("$out")
    else
        bad "RENDER FAILED: $fn"
    fi
done

# ---------------------------------------------------------------------------
# Assertion helpers operate on a FILE so the discrimination control below can
# run the exact same code against a mutated copy (guard subject == guard input:
# nft fragment comments start with '#', stripped before matching).
# ---------------------------------------------------------------------------
frag_violations() {
    local f="$1" v=0
    local body
    body="$(grep -vE '^[[:space:]]*#' "$f")"
    # V-A: no meter shorthand in a rendered rule
    if grep -qE '[[:space:]]meter[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\{' <<<"$body"; then
        echo "meter-shorthand"; v=1
    fi
    # V-B: every update-statement limiter has a declaration with the bounds
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        local decl
        decl=$(grep -E "add set .*[[:space:]]${name}[[:space:]]*\{" <<<"$body" || true)
        if [[ -z "$decl" ]] || ! grep -q 'size' <<<"$decl" || ! grep -q 'timeout' <<<"$decl" || ! grep -q 'dynamic' <<<"$decl"; then
            echo "undeclared-or-unbounded:$name"; v=1
        fi
    done < <(grep -oE 'update @[^ ]+' <<<"$body" | sed 's/update @//' | sort -u)
    return $v
}

echo ""
echo "--- STAGE 2: rendered-output assertions (T13) ---"
for f in "${RENDERED[@]}"; do
    base="$(basename "$f")"
    case "$base" in
        # The sets fragment declares membership sets only — no limiters expected,
        # but it must still be free of meter shorthand.
        *botguard-sets*)
            if frag_violations "$f" >/dev/null; then
                ok "RENDERED_CLEAN $base"
            else
                bad "RENDERED_VIOLATIONS $base: $(frag_violations "$f" | tr '\n' ' ')"
            fi ;;
        *)
            viol="$(frag_violations "$f")" && rc=0 || rc=1
            if [[ "$rc" -eq 0 ]]; then
                ok "RENDERED_CLEAN $base (limiters bounded, no shorthand)"
            else
                bad "RENDERED_VIOLATIONS $base: $(tr '\n' ' ' <<<"$viol")"
            fi ;;
    esac
done

# v4/v6 pair parity on the rendered ddos fragments
DDOS_OUT="$(cat "${RENDERED[@]}" 2>/dev/null | grep -vE '^[[:space:]]*#')"
PARITY_BAD=0
for v4 in ddos_dns_udp ddos_icmp_flood ddos_udp_flood ddos_prefix_syn ddos_prefix_conn \
          http_bot_grey_meter http_bot_pending_meter http_bot_meter; do
    d4=$(grep -cE "add set .*[[:space:]]${v4}[[:space:]]*\{" <<<"$DDOS_OUT")
    d6=$(grep -cE "add set .*[[:space:]]${v4}6[[:space:]]*\{" <<<"$DDOS_OUT")
    if [[ "$d4" -ge 1 && "$d6" -ge 1 ]]; then :; else
        bad "PARITY $v4: v4_decls=$d4 v6_decls=$d6"
        PARITY_BAD=1
    fi
done
[[ "$PARITY_BAD" -eq 0 ]] && ok "PARITY all 8 rendered limiter pairs declare both families"

# ---------------------------------------------------------------------------
# STAGE 3 — real-parser proof: compose base config + fragments and nft -c it.
# The base pre-rendered boot copy carries __SSH_PORT__/__CT_LIMIT_*__
# placeholders; substitute representative values exactly as the renderer does.
# Skipped loudly when no nft binary exists (CI runners without nftables);
# the lab package gates run this against the real kernel regardless.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 3: composed ruleset parses under a real nft ---"
if command -v nft >/dev/null 2>&1; then
    COMPOSED="$WORK/composed.nft"
    sed -e 's/__SSH_PORT__/22/g' -e 's/__CT_LIMIT_SSH__/15/g' \
        -e 's/__CT_LIMIT_HTTP__/150/g' -e 's/__CT_LIMIT_MAIL__/150/g' \
        "$ROOT/install/nftables/nftables.conf" > "$COMPOSED"
    for f in "${RENDERED[@]}"; do cat "$f" >> "$COMPOSED"; done
    if out=$(nft -c -f "$COMPOSED" 2>&1); then
        ok "NFT_PARSE composed base+fragments ($(nft --version | awk '{print $2}'))"
    elif grep -q 'Operation not permitted' <<<"$out"; then
        # nft -c still opens a netlink cache; unprivileged environments cannot.
        # This is an environment limit, not a parse verdict — the package-native
        # lab gates run the same composition as root on real kernels.
        echo "  [SKIP] nft -c needs netlink (unprivileged environment) — parse proof"
        echo "         is provided by the package-native lab gates"
    else
        bad "NFT_PARSE failed: $(head -2 <<<"$out" | tr '\n' ' ')"
    fi
else
    echo "  [SKIP] no nft binary in this environment — parse proof is provided by the"
    echo "         package-native lab gates (EL9 nft 1.0.9 / EL10 1.1.1 / DEB 1.0.9)"
fi

# ---------------------------------------------------------------------------
# STAGE 4 — discrimination control: the assertions must FAIL on a rendered
# fragment carrying (a) the old shorthand and (b) an unbounded declaration.
# A test that cannot fail is not evidence.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 4: discrimination controls ---"
# frag_violations returns non-zero BY DESIGN when it finds violations, so under
# pipefail it must never sit on the left of a pipeline — capture, then inspect.
MUT="$WORK/mutant.nft"
cp "${RENDERED[0]}" "$MUT"
printf 'add rule ip nftban ddos_classic udp dport 5300 meter zz_bad_meter { ip saddr limit rate 9/second } return\n' >> "$MUT"
viol="$(frag_violations "$MUT" || true)"
if grep -q 'meter-shorthand' <<<"$viol"; then
    ok "DISCRIMINATES meter-shorthand injection"
else
    bad "BLIND to meter-shorthand injection"
fi

cp "${RENDERED[0]}" "$MUT"
printf 'add set ip nftban zz_unbounded { type ipv4_addr; flags dynamic; }\nadd rule ip nftban ddos_classic udp dport 5301 update @zz_unbounded { ip saddr limit rate 9/second } return\n' >> "$MUT"
viol="$(frag_violations "$MUT" || true)"
if grep -q 'undeclared-or-unbounded:zz_unbounded' <<<"$viol"; then
    ok "DISCRIMINATES unbounded-declaration injection"
else
    bad "BLIND to unbounded-declaration injection"
fi

echo ""
echo "=== nft_bounded_limiter_render: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
