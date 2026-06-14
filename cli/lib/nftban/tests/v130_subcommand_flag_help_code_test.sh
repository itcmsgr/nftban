#!/usr/bin/env bash
# =============================================================================
# v1.134 PR-D — subcommand help/code correlation doctest guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v130_subcommand_flag_help_code_test"
# meta:type="test"
# meta:version="1.134.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-25"
# meta:inventory.files="cli/lib/nftban/tests/v134_help_code_alias_allowlist.tsv"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="V134 PR-D doctest guard (Lane 2). Per command family, asserts the HIGH-VALUE invariant: every token the primary dispatch case accepts is either (a) documented in the command's help text, (b) declared in the intentional-alias allowlist (v134_help_code_alias_allowlist.tsv), or (c) a structural token (* / -h / --help / help / empty). This catches help<->code drift (a NEW undocumented subcommand) while letting genuine aliases/internal/universal-flag/deprecated tokens through via the allowlist. Deliberately single-direction + conservative: a family whose primary dispatch case OR help text cannot be confidently parsed is SKIPPED (reported, not failed) rather than producing the prose-extraction false positives that sank the v1.128 PR-B prototype. The reverse direction (advertised-but-unreachable) and exhaustive flag-level coverage are future hardening. Static scan; no host, no runtime, no privileges."
# =============================================================================
set -Eeuo pipefail

_lib=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)   # .../cli/lib/nftban
_cli="$_lib/cli"
_man="$_lib/tests/v134_help_code_alias_allowlist.tsv"

_pass=0; _fail=0; _skip=0
_t_assert() {
    local name="$1" rc="$2" detail="${3:-}"
    if [[ "$rc" == "0" ]]; then echo "  [PASS] $name"; _pass=$((_pass+1))
    else echo "  [FAIL] $name${detail:+ — $detail}"; _fail=$((_fail+1)); fi
}
_t_skip() { echo "  [SKIP] $1"; _skip=$((_skip+1)); }

# Primary dispatch case labels (depth-1 of the FIRST case on a dispatch var),
# `a|b)` split into separate tokens, quotes stripped.
_case_tokens() {
    awk '
        !seen && /case[[:space:]]+"\$\{?(subcommand|subcmd|action|cmd|command|sub|mode|verb|1)[:%#}A-Za-z0-9_-]*"[[:space:]]+in/ { inb=1; seen=1; depth=1; next }
        inb && /^[[:space:]]*case[[:space:]]/ { depth++; next }
        inb && /^[[:space:]]*esac([[:space:]]|$)/ { depth--; if (depth<=0){inb=0; exit}; next }
        inb && depth==1 {
            l=$0; sub(/^[[:space:]]+/,"",l)
            if (l ~ /^[A-Za-z0-9_"|*.\/-]+\)/) { sub(/\).*/,"",l); print l }
        }
    ' "$1" | tr '|' '\n' | sed -E 's/^"//; s/"$//' | grep -vE '^[[:space:]]*$' | sort -u
}

# Help text = bodies of all functions whose name matches help|usage (close on ^}).
_help_text() {
    awk '
        # (a) bodies of functions whose name matches help|usage (close on ^})
        /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{?[[:space:]]*$/ {
            name=$0; sub(/\(\).*/,"",name); sub(/^[[:space:]]*/,"",name)
            inh = (tolower(name) ~ /help|usage/) ? 1 : 0; next
        }
        /^\}/ { inh=0 }
        inh { print; next }
        # (b) inline help case branch (label includes help/-h/--help) until ;;
        { l=$0; sub(/^[[:space:]]+/,"",l) }
        l ~ /^([A-Za-z0-9_"*|-]*\|)?(help|-h|--help)(\|[A-Za-z0-9_"*|-]*)?\)/ { inc=1; next }
        inc && /;;/ { inc=0; next }
        inc { print }
    ' "$1"
}

_is_structural() { case "$1" in '*'|-h|--help|help|'') return 0;; -*) return 0;; *) return 1;; esac; }  # flags (-*) are option-parsing, not subcommands — flag-level coverage is future hardening
_allowlisted()   { awk -F'\t' -v f="$1" -v t="$2" '$1==f && $2==t {ok=1} END{exit !ok}' "$_man"; }

echo "==============================================================================="
echo "v1.134 PR-D — subcommand help/code correlation doctest guard"
echo "  allowlist: ${_man##*/}"
echo "==============================================================================="

shopt -s nullglob
for f in "$_cli"/cmd_*.sh; do
    rel="cli/$(basename "$f")"
    fam=$(basename "$f" .sh); fam=${fam#cmd_}
    tokens=$(_case_tokens "$f") || true               # empty grep -> rc1 under pipefail; tolerate
    if [[ -z "$tokens" ]]; then continue; fi          # leaf/no-dispatch command — not a family
    help=$(_help_text "$f") || true
    if [[ -z "$help" ]]; then _t_skip "$fam: no help/usage function found — not asserted"; continue; fi
    residual=""
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        _is_structural "$t" && continue
        _allowlisted "$rel" "$t" && continue
        grep -qwF -- "$t" <<<"$help" && continue   # here-string (no upstream pipe → no SIGPIPE/141 flake under pipefail)
        residual+="$t "
    done <<< "$tokens"
    if [[ -z "$residual" ]]; then
        _t_assert "$fam: every accepted token documented or allowlisted" 0
    else
        _t_assert "$fam: every accepted token documented or allowlisted" 1 "undocumented+unallowlisted: ${residual% }"
    fi
done

echo "==============================================================================="
echo "Results: $_pass passed, $_fail failed, $_skip skipped"
echo "==============================================================================="
[[ "$_fail" -eq 0 ]]
