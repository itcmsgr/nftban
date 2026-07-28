#!/usr/bin/env bash
# =============================================================================
# NFTBan — Suricata subcommand authority (v1.228.2, F2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="suricata_subcommand_authority_v1228_2_test"
# meta:type="test"
# meta:version="1.228.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="F2 structural authority test for the retired Suricata surface. DERIVES four independent subcommand sets at runtime — the dispatcher case arms in cli/lib/nftban/cli/cmd_suricata*.sh, the suricata.subcommands block in commands.registry.yml, the suricata_cmds token list in install/bash-completion/nftban, and the documented set (registry suricata.examples UNION the COMMANDS block of cmd_suricata_help) — and asserts SET EQUALITY across all four. Deliberately does NOT hardcode the member names: a name check would still pass if every authority were wrong in the same way, and would need editing (i.e. would be silently weakened) the next time the surface legitimately changes. The load-bearing assertion is PHANTOM_SUBCOMMANDS=0: (registry UNION completion UNION docs) MINUS dispatcher must be empty, which is the bug class v1.228.2 removes — 42 advertised subcommands, 14 examples and a 15-token completion list for a dispatcher that accepts two verbs. ORPHAN_SUBCOMMANDS=0 is the converse (a verb that dispatches but is advertised nowhere). Section F proves the comparison is falsifiable against mutated fixtures rather than trusting it. Hermetic static analysis: reads files, invokes no CLI, contacts no host."
# meta:input="cli/lib/nftban/cli/cmd_suricata.sh, cli/lib/nftban/cli/cmd_suricata_setup.sh, commands.registry.yml, install/bash-completion/nftban"
# meta:output="exit 0 if all four authorities agree and no phantom/orphan exists; exit 1 with the offending set members otherwise"
# meta:depends="bash,awk,grep,sed,sort,comm,mktemp"
# meta:inventory.files="commands.registry.yml,install/bash-completion/nftban,cli/lib/nftban/cli/cmd_suricata.sh,cli/lib/nftban/cli/cmd_suricata_setup.sh"
# meta:inventory.binaries="bash,awk,grep,sed,sort,comm"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="suricata_subcommand_authority_v1228_2_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-command-correlation"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
set +e

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)

CMD_SURICATA="$REPO/cli/lib/nftban/cli/cmd_suricata.sh"
REGISTRY="$REPO/commands.registry.yml"
COMPLETION="$REPO/install/bash-completion/nftban"

for f in "$CMD_SURICATA" "$REGISTRY" "$COMPLETION"; do
    [[ -f "$f" ]] || { echo "FAIL: missing required input $f" >&2; exit 1; }
done

WORK=$(mktemp -d)
# shellcheck disable=SC2064  # expand WORK now, at trap-installation time
trap "rm -rf '$WORK'" EXIT

echo "==============================================================================="
echo "v1.228.2 F2 — Suricata subcommand authority (derived sets, set-equality)"
echo "==============================================================================="

# =============================================================================
# EXTRACTORS
# =============================================================================
# Each extractor reads ONE authority and emits a sorted, de-duplicated token
# list on stdout. They take the file path as an argument so section F can run
# the identical logic against a mutated fixture — the falsification proof and
# the real assertion share one code path, so the proof cannot drift from what
# is actually enforced.
#
# Option-shaped tokens (`--json`, `-h`) are NOT subcommands and are filtered
# everywhere; `*` (the catch-all arm) is not a subcommand either.
# -----------------------------------------------------------------------------

_drop_non_subcommands() {
    grep -vE '^-' | grep -vE '^\*$' | grep -E '^[a-z][a-z0-9_-]*$' | sort -u
}

# (1) DISPATCHER — the case arms inside nftban_cmd_suricata().
# Scans every cmd_suricata*.sh so a router that moves to a sibling module is
# still found rather than silently reported as an empty set.
extract_dispatcher() {
    local cli_dir="$1" f
    for f in "$cli_dir"/cmd_suricata*.sh; do
        [[ -f "$f" ]] || continue
        awk '
            /^nftban_cmd_suricata\(\)[[:space:]]*\{/ { inf=1 }
            inf && /^\}/                             { inf=0 }
            inf                                      { print }
        ' "$f" \
        | grep -oE '^[[:space:]]+[a-z0-9*|_-]+\)' \
        | sed -E 's/^[[:space:]]+//; s/\)$//' \
        | tr '|' '\n'
    done | _drop_non_subcommands
}

# (2) REGISTRY — keys under suricata: -> subcommands:.
# Lightweight scan (no pyyaml), matching the parser discipline of
# scripts/ci/check-cli-surface-parity.sh so both guards agree in the same
# ci-bash image. Handles both the block form and the inline `k: {…}` form.
extract_registry() {
    awk '
        /^suricata:[[:space:]]*$/          { in_cmd=1; next }
        in_cmd && /^[a-z_][a-z0-9_-]*:/    { exit }            # next top-level key
        in_cmd && /^  subcommands:[[:space:]]*$/ { in_sub=1; next }
        in_sub && /^  [a-z]/               { in_sub=0 }        # next command-level key
        in_sub && /^    #/                 { next }            # comment
        in_sub && /^    [a-z][a-z0-9_-]*:/ {
            line=$0
            sub(/^    /, "", line)
            sub(/:.*$/, "", line)
            print line
        }
    ' "$1" | _drop_non_subcommands
}

# (3) COMPLETION — the suricata_cmds token list.
extract_completion() {
    grep -m1 -E 'local[[:space:]]+suricata_cmds=' "$1" \
        | sed -E 's/.*suricata_cmds="//; s/".*//' \
        | tr ' ' '\n' | _drop_non_subcommands
}

# (4) DOCUMENTED — registry `suricata:` examples UNION the COMMANDS block of
# cmd_suricata_help. Operator-facing text is an authority too: an example or a
# help row for a verb that no longer dispatches is the same lie as a registry
# entry for it.
extract_documented() {
    local registry="$1" cmd_file="$2"
    {
        # 4a: `- "nftban suricata <token> …"` inside the suricata block only.
        awk '
            /^suricata:[[:space:]]*$/       { in_cmd=1; next }
            in_cmd && /^[a-z_][a-z0-9_-]*:/ { exit }
            in_cmd && /nftban suricata /    { print }
        ' "$registry" \
        | sed -E 's/.*nftban suricata[[:space:]]+//; s/[[:space:]].*$//; s/"$//'

        # 4b: the COMMANDS: block of the help heredoc (indented "verb  text" rows).
        awk '
            /^COMMANDS:[[:space:]]*$/ { in_b=1; next }
            in_b && /^[A-Z]+:/        { in_b=0 }
            in_b && /^[[:space:]]*$/  { in_b=0 }
            in_b                      { print }
        ' "$cmd_file" \
        | grep -oE '^[[:space:]]+[a-z][a-z0-9_-]*' \
        | sed -E 's/^[[:space:]]+//'
    } | _drop_non_subcommands
}

# =============================================================================
# (A) Derive the four sets
# =============================================================================
echo "--- A: derive the four authority sets ---"

extract_dispatcher "$REPO/cli/lib/nftban/cli"          > "$WORK/dispatcher"
extract_registry   "$REGISTRY"                          > "$WORK/registry"
extract_completion "$COMPLETION"                        > "$WORK/completion"
extract_documented "$REGISTRY" "$CMD_SURICATA"          > "$WORK/documented"

N_DISPATCH=$(grep -c . < "$WORK/dispatcher"  || true)
N_REGISTRY=$(grep -c . < "$WORK/registry"    || true)
N_COMPLETE=$(grep -c . < "$WORK/completion"  || true)
N_DOCUMENT=$(grep -c . < "$WORK/documented"  || true)

printf '  SURICATA_DISPATCHABLE_SUBCOMMANDS = %s  [%s]\n' "$N_DISPATCH" "$(tr '\n' ' ' < "$WORK/dispatcher")"
printf '  SURICATA_REGISTRY_SUBCOMMANDS     = %s  [%s]\n' "$N_REGISTRY" "$(tr '\n' ' ' < "$WORK/registry")"
printf '  SURICATA_COMPLETION_SUBCOMMANDS   = %s  [%s]\n' "$N_COMPLETE" "$(tr '\n' ' ' < "$WORK/completion")"
printf '  SURICATA_DOCUMENTED_SUBCOMMANDS   = %s  [%s]\n' "$N_DOCUMENT" "$(tr '\n' ' ' < "$WORK/documented")"

# A0: the dispatcher set must be non-empty. Without this, an extractor that
# silently stops matching would make every set-difference below trivially
# empty and turn the whole test green on a broken parse.
if (( N_DISPATCH > 0 )); then
    ok "A0: dispatcher set is non-empty (${N_DISPATCH}) — extractor is live, not silently matching nothing"
else
    no "A0: dispatcher set is non-empty" \
       "extracted 0 case arms from nftban_cmd_suricata() — the router changed shape and this test is blind"
fi

# A0b: same fail-closed guard for the three advertising extractors. An empty
# advertising set would also make PHANTOM trivially 0.
for pair in "registry:$N_REGISTRY" "completion:$N_COMPLETE" "documented:$N_DOCUMENT"; do
    nm="${pair%%:*}"; cnt="${pair#*:}"
    if (( cnt > 0 )); then
        ok "A0b: ${nm} extractor is live (${cnt} token(s))"
    else
        no "A0b: ${nm} extractor is live" "extracted 0 tokens — parse broke; PHANTOM would be vacuously 0"
    fi
done

# =============================================================================
# (B) PHANTOM_SUBCOMMANDS — the load-bearing assertion
# =============================================================================
# A phantom is a verb some surface ADVERTISES that the dispatcher does NOT
# accept: the operator is told it exists, types it, and gets a usage error.
echo "--- B: PHANTOM_SUBCOMMANDS (advertised but not dispatchable) ---"
cat "$WORK/registry" "$WORK/completion" "$WORK/documented" | sort -u > "$WORK/advertised"
comm -23 "$WORK/advertised" "$WORK/dispatcher" > "$WORK/phantom"
N_PHANTOM=$(grep -c . < "$WORK/phantom" || true)

if (( N_PHANTOM == 0 )); then
    ok "B1: PHANTOM_SUBCOMMANDS=0 — nothing advertised is undispatchable"
else
    no "B1: PHANTOM_SUBCOMMANDS=0" \
       "$N_PHANTOM phantom verb(s) advertised with no dispatcher arm: $(tr '\n' ' ' < "$WORK/phantom")"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        src=""
        grep -qxF "$p" "$WORK/registry"   && src+="registry "
        grep -qxF "$p" "$WORK/completion" && src+="completion "
        grep -qxF "$p" "$WORK/documented" && src+="docs "
        printf '         phantom: %-20s advertised by: %s\n' "$p" "$src"
    done < "$WORK/phantom"
fi

# =============================================================================
# (C) ORPHAN_SUBCOMMANDS — the converse
# =============================================================================
# A verb that dispatches but is advertised nowhere is undiscoverable. Reported
# per-authority so the missing surface is named, not merely counted.
echo "--- C: ORPHAN_SUBCOMMANDS (dispatchable but unadvertised) ---"
for auth in registry completion documented; do
    comm -23 "$WORK/dispatcher" "$WORK/$auth" > "$WORK/orphan_$auth"
    n=$(grep -c . < "$WORK/orphan_$auth" || true)
    if (( n == 0 )); then
        ok "C-${auth}: every dispatchable verb appears in ${auth}"
    else
        no "C-${auth}: every dispatchable verb appears in ${auth}" \
           "$n dispatchable verb(s) missing from ${auth}: $(tr '\n' ' ' < "$WORK/orphan_$auth")"
    fi
done

# =============================================================================
# (D) SET EQUALITY across all four authorities
# =============================================================================
echo "--- D: set-equality across all four authorities ---"
for auth in registry completion documented; do
    if diff -q "$WORK/dispatcher" "$WORK/$auth" >/dev/null 2>&1; then
        ok "D-${auth}: ${auth} set == dispatcher set"
    else
        no "D-${auth}: ${auth} set == dispatcher set" \
           "symmetric difference: $(comm -3 "$WORK/dispatcher" "$WORK/$auth" | tr -d '\t' | tr '\n' ' ')"
    fi
done

# D-count: state the cardinality agreement as its own number so a reader of the
# CI log sees the invariant, not just a diff verdict.
if [[ "$N_DISPATCH" == "$N_REGISTRY" && "$N_DISPATCH" == "$N_COMPLETE" && "$N_DISPATCH" == "$N_DOCUMENT" ]]; then
    ok "D-count: all four authorities declare the same cardinality (${N_DISPATCH})"
else
    no "D-count: all four authorities declare the same cardinality" \
       "dispatcher=${N_DISPATCH} registry=${N_REGISTRY} completion=${N_COMPLETE} documented=${N_DOCUMENT}"
fi

# =============================================================================
# (E) Retirement invariants that the set comparison cannot express
# =============================================================================
# The sets could agree at the wrong value — e.g. all four re-grow to include
# `install`. These pin the ruling itself (D3: dormant placeholder, no host
# mutation) without hardcoding the surviving member names.
echo "--- E: retirement invariants ---"

# E1: no dispatcher arm names a host-mutating verb.
if grep -qE '^[[:space:]]*(install|enable|disable|setup|rules|update|sid|category|profile|custom|iface|advanced|tools|scan|recommend)[)|]' \
        <(awk '/^nftban_cmd_suricata\(\)[[:space:]]*\{/,/^\}/' "$CMD_SURICATA"); then
    no "E1: dispatcher exposes no rule-management or host-mutating verb" \
       "a retired verb reappeared in the router — D3 says rule management is NOT restored"
else
    ok "E1: dispatcher exposes no rule-management or host-mutating verb"
fi

# E2: the registry description no longer implies an active protection module.
suri_desc=$(awk '
    /^suricata:[[:space:]]*$/       { in_cmd=1; next }
    in_cmd && /^[a-z_][a-z0-9_-]*:/ { exit }
    in_cmd && /^  description:/     { print; exit }
' "$REGISTRY")
if [[ -n "$suri_desc" ]] && grep -qiE 'dormant|reserved for a future' <<<"$suri_desc"; then
    ok "E2: registry suricata description states the dormant/future-release status"
else
    no "E2: registry suricata description states the dormant/future-release status" \
       "description does not say dormant or reserved-for-a-future-release: ${suri_desc:-<absent>}"
fi

# E3: the registry no longer claims the command mutates or needs root.
suri_block=$(awk '
    /^suricata:[[:space:]]*$/       { in_cmd=1 }
    in_cmd && /^[a-z_][a-z0-9_-]*:/ && !/^suricata:/ { exit }
    in_cmd && /^  [a-z]/            { print }
' "$REGISTRY")
if grep -qE '^  mutates:[[:space:]]*false' <<<"$suri_block" \
   && grep -qE '^  requires_root:[[:space:]]*false' <<<"$suri_block"; then
    ok "E3: registry declares suricata mutates:false requires_root:false (read-only dormant reporter)"
else
    no "E3: registry declares suricata mutates:false requires_root:false" \
       "$(grep -E '^  (mutates|requires_root):' <<<"$suri_block" | tr '\n' ' ')"
fi

# =============================================================================
# (F) FALSIFIABILITY — prove the comparison detects a re-added phantom
# =============================================================================
# A guard that cannot fail is precisely the defect this release removes: the
# pre-v1.228.2 tree advertised 42 subcommands for a 2-verb dispatcher and every
# parity guard in the repo passed, because they all compare TOP-LEVEL commands
# only. So this section does not assert that the tree is clean — sections A-E
# already did — it asserts that the machinery WOULD HAVE CAUGHT the drift.
#
# Each case copies a real authority to a temp fixture, injects one phantom verb
# using a name that is not in the real surface, and re-runs the SAME extractor.
echo "--- F: falsifiability of B1 ---"
PHANTOM_NAME="zzzphantomverb"

# F1: phantom injected into the REGISTRY subcommands block.
cp "$REGISTRY" "$WORK/reg_mut.yml"
awk -v ph="$PHANTOM_NAME" '
    { print }
    /^suricata:[[:space:]]*$/          { in_cmd=1; next }
    in_cmd && /^  subcommands:[[:space:]]*$/ && !done {
        printf "    %s:\n      mutates: false\n      description: \"injected fixture\"\n", ph
        done=1
    }
' "$REGISTRY" > "$WORK/reg_mut.yml"
extract_registry "$WORK/reg_mut.yml" > "$WORK/reg_mut_set"
cat "$WORK/reg_mut_set" "$WORK/completion" "$WORK/documented" | sort -u > "$WORK/adv_mut"
if comm -23 "$WORK/adv_mut" "$WORK/dispatcher" | grep -qxF "$PHANTOM_NAME"; then
    ok "F1: B1 is falsifiable — a phantom injected into the registry is detected"
else
    no "F1: B1 is falsifiable — a phantom injected into the registry is detected" \
       "the mutated fixture produced NO phantom; the registry extractor or the set difference is broken, so B1 above proves nothing"
fi

# F2: phantom injected into the COMPLETION token list.
sed -E "s/(local[[:space:]]+suricata_cmds=\")/\1${PHANTOM_NAME} /" "$COMPLETION" > "$WORK/comp_mut"
extract_completion "$WORK/comp_mut" > "$WORK/comp_mut_set"
cat "$WORK/registry" "$WORK/comp_mut_set" "$WORK/documented" | sort -u > "$WORK/adv_mut2"
if comm -23 "$WORK/adv_mut2" "$WORK/dispatcher" | grep -qxF "$PHANTOM_NAME"; then
    ok "F2: B1 is falsifiable — a phantom injected into bash-completion is detected"
else
    no "F2: B1 is falsifiable — a phantom injected into bash-completion is detected" \
       "the mutated fixture produced NO phantom; the completion extractor or the set difference is broken"
fi

# F3: phantom injected into the DOCUMENTED surface (a registry example).
awk -v ph="$PHANTOM_NAME" '
    { print }
    /^suricata:[[:space:]]*$/  { in_cmd=1; next }
    in_cmd && /^  examples:[[:space:]]*$/ && !done {
        printf "    - \"nftban suricata %s\"\n", ph
        done=1
    }
' "$REGISTRY" > "$WORK/doc_mut.yml"
extract_documented "$WORK/doc_mut.yml" "$CMD_SURICATA" > "$WORK/doc_mut_set"
cat "$WORK/registry" "$WORK/completion" "$WORK/doc_mut_set" | sort -u > "$WORK/adv_mut3"
if comm -23 "$WORK/adv_mut3" "$WORK/dispatcher" | grep -qxF "$PHANTOM_NAME"; then
    ok "F3: B1 is falsifiable — a phantom injected into a registry example is detected"
else
    no "F3: B1 is falsifiable — a phantom injected into a registry example is detected" \
       "the mutated fixture produced NO phantom; the documented-surface extractor is broken"
fi

# F4: falsifiability of the ORPHAN direction — remove a real verb from an
# advertising surface and prove section C would report it.
first_verb=$(head -1 "$WORK/dispatcher")
if [[ -n "$first_verb" ]]; then
    grep -vxF "$first_verb" "$WORK/completion" > "$WORK/comp_short"
    if comm -23 "$WORK/dispatcher" "$WORK/comp_short" | grep -qxF "$first_verb"; then
        ok "F4: C is falsifiable — dropping '${first_verb}' from completion is detected as an orphan"
    else
        no "F4: C is falsifiable — dropping a real verb from completion is detected" \
           "removing '${first_verb}' produced no orphan; the orphan comparison is broken"
    fi
else
    no "F4: C is falsifiable" "dispatcher set empty — cannot build the fixture"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==============================================================================="
echo "suricata_subcommand_authority_v1228_2 results: ${PASS} PASS / ${FAIL} FAIL"
echo "==============================================================================="
if (( FAIL > 0 )); then
    echo "Failed tests:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
