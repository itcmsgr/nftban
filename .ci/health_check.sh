#!/usr/bin/env bash
set -euo pipefail

# nftban — Project Health Report (BETA)
# Focus: Bash shell scripts
# Outputs: STATUS.md with summary & details
# Exits non‑zero if any check fails (surfaced in CI)

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPORT="${ROOT_DIR}/STATUS.md"

timestamp() { date -u +"%Y-%m-%d %H:%M:%S UTC"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Collect files
mapfile -d '' SH_FILES < <(git ls-files -z -- \
  '*.sh' \
  ':!:vendor/*' ':!:third_party/*' ':!:node_modules/*')

# Also include executable scripts with bash/shebang
while IFS= read -r -d '' f; do
  if head -n1 "$f" | grep -qE '^#!(.*/|env )ba?sh'; then
    SH_FILES+=("$f")
  fi
done < <(git ls-files -z -- ':!:vendor/*' ':!:third_party/*' ':!:node_modules/*' \
  | xargs -0 -I{} printf "%s\0" {})

# Optional other files
mapfile -d '' YAML_FILES < <(git ls-files -z -- '*.yml' '*.yaml' 2>/dev/null || true)
mapfile -d '' MD_FILES   < <(git ls-files -z -- '*.md' 2>/dev/null || true)
mapfile -d '' JSON_FILES < <(git ls-files -z -- '*.json' 2>/dev/null || true)
mapfile -d '' NFT_FILES  < <(git ls-files -z -- '*.nft' 2>/dev/null || true)

# Checks accumulators
conflict_marker_count=0
todo_count=0
bash_n_exit=0
shellcheck_exit=0
shfmt_exit=0
bashisms_exit=0
yaml_exit=0
md_exit=0
json_exit=0
dup_exit=0
nft_exit=0
# 1) Explicit merge conflict markers
conflicts="$(git grep -n '^[<=>]\{7\}' -- ':!*.lock' || true)"
if [ -n "$conflicts" ]; then conflict_marker_count=$(printf "%s\n" "$conflicts" | wc -l | tr -d ' '); fi

# 2) TODO/FIXME/HACK
todos="$(git grep -nE 'TODO|FIXME|HACK' || true)"
if [ -n "$todos" ]; then todo_count=$(printf "%s\n" "$todos" | wc -l | tr -d ' '); fi

# 3) bash -n (syntax)
if [ "${#SH_FILES[@]}" -gt 0 ]; then
  if ! bash -n "${SH_FILES[@]}"; then bash_n_exit=1; fi
fi
# 4) ShellCheck (undefined vars, quoting, arrays, etc.)
# Tip: configure ignores in .shellcheckrc if needed.
if has_cmd shellcheck && [ "${#SH_FILES[@]}" -gt 0 ]; then
  # Use shellcheck JSON output for later parsing if you want counts per code
  if ! shellcheck -s bash "${SH_FILES[@]}"; then shellcheck_exit=1; fi
fi

# 5) shfmt (format drift)
if has_cmd shfmt; then
  # -i 2: indent 2 spaces, -ci: switch cases indent, -sr: simplify redirects
  if ! shfmt -i 2 -ci -sr -d .; then shfmt_exit=1; fi
fi

# 6) checkbashisms (portability)
if has_cmd checkbashisms && [ "${#SH_FILES[@]}" -gt 0 ]; then
  # Run and fail if any non-POSIX bashism is found
  if ! checkbashisms -n -p "${SH_FILES[@]}"; then bashisms_exit=1; fi
fi

# 7) YAML lint
if [ "${#YAML_FILES[@]}" -gt 0 ] && has_cmd yamllint; then
  if ! yamllint -s .; then yaml_exit=1; fi
fi

# 8) Markdown lint
if [ "${#MD_FILES[@]}" -gt 0 ] && has_cmd node && has_cmd npx; then
  if ! npx --yes markdownlint-cli2@latest "**/*.md" "#node_modules"; then md_exit=1; fi
fi

# 9) JSON validity
if [ "${#JSON_FILES[@]}" -gt 0 ] && has_cmd jq; then
  bad=0
  for jf in "${JSON_FILES[@]}"; do
    jq empty "$jf" 2>/dev/null || { echo "Invalid JSON: $jf"; bad=1; }
  done
  json_exit=$bad
fi

# 10) Duplicate code (jscpd)
dup_section="Skipped (Node+npx not found)."
if has_cmd node && has_cmd npx; then
  rm -rf .jscpd-report >/dev/null 2>&1 || true
  if npx --yes jscpd@latest --silent --reporters json --min-tokens 50 --output .jscpd-report >/dev/null 2>&1; then
    if [ -f .jscpd-report/jscpd-report.json ] && has_cmd jq; then
      dlines=$(jq -r '.statistics.duplicatedLines' .jscpd-report/jscpd-report.json 2>/dev/null || echo "0")
      dperc=$(jq -r '.statistics.percentage' .jscpd-report/jscpd-report.json 2>/dev/null || echo "0")
      dup_section="Duplicated lines: ${dlines} (${dperc}%)"
    else
      dup_section="jscpd report missing."
    fi
  else
    dup_exit=1
    dup_section="jscpd found duplicates (see console)."
  fi
fi

# 11) nftables (syntax check of .nft files, if any)
nft_section="No .nft files."
if [ "${#NFT_FILES[@]}" -gt 0 ]; then
  nft_section=""
  if has_cmd nft; then
    for nf in "${NFT_FILES[@]}"; do
      if ! nft -c -f "$nf"; then
        echo "nft syntax error: $nf"
        nft_exit=1
      fi
    done
    [ -z "$nft_section" ] && nft_section="Checked ${#NFT_FILES[@]} .nft file(s) with nft -c."
  else
    nft_section="Skipped (nft not installed)."
  fi
fi

# 12) Recommend 'set -euo pipefail' for bash scripts
missing_strict=()
for f in "${SH_FILES[@]}"; do
  if ! head -n 5 "$f" | grep -qE 'set -euo pipefail'; then
    missing_strict+=("$f")
  fi
done

# Write STATUS.md
{
  echo "# Project Status (BETA)"
  echo
  echo "- **Generated:** $(timestamp)"
  echo "- **Repo:** $(basename "$ROOT_DIR")"
  echo "- **Tracked files:** $(git ls-files | wc -l | tr -d ' ')"
  echo
  echo "## Summary"
  echo "- Conflict markers: **${conflict_marker_count}**"
  echo "- TODO/FIXME/HACK: **${todo_count}**"
  echo "- Bash syntax (bash -n): $([ $bash_n_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- ShellCheck: $([ $shellcheck_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- shfmt: $([ $shfmt_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- checkbashisms: $([ $bashisms_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- YAML lint: $([ $yaml_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- Markdown lint: $([ $md_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- JSON validity: $([ $json_exit -eq 0 ] && echo "OK" || echo "Issues")"
  echo "- Duplicate code: ${dup_section}"
  echo "- nftables: ${nft_section}"
  echo
  echo "## Details"
  echo "### Potential Conflicts"
  if [ -n "$conflicts" ]; then echo '```'; echo "$conflicts"; echo '```'; else echo "_No explicit conflict markers._"; fi
  echo
  echo "### TODO / FIXME / HACK"
  if [ -n "$todos" ]; then echo '```'; echo "$todos"; echo '```'; else echo "_No TODO/FIXME/HACK found._"; fi
  echo
  echo "### Scripts missing 'set -euo pipefail'"
  if [ "${#missing_strict[@]}" -gt 0 ]; then
    for m in "${missing_strict[@]}"; do echo "- $m"; done
  else
    echo "_All bash scripts include strict mode._"
  fi
  echo
  echo "### Notes"
  echo "- This project is in **BETA**; breaking changes may occur."
  echo "- Shell checks rely on ShellCheck rules (e.g., undefined variables **SC2154**)."
} > "$REPORT"

echo "Wrote ${REPORT}"

# Compose exit code
exit_code=0
for e in $bash_n_exit $shellcheck_exit $shfmt_exit $bashisms_exit $yaml_exit $md_exit $json_exit $dup_exit $nft_exit; do
  if [ "$e" -ne 0 ]; then exit_code=1; fi
done
exit "$exit_code"
