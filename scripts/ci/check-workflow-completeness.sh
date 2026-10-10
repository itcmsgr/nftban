#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - workflow syntax + expected-vs-executed CI completeness
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# Why (owner 2026-10-09): five workflows (ci-install/update/uninstall/restore-canonization,
# ci-runtime-truth) carried invalid YAML. GitHub does not run an invalid workflow and reports
# nothing on the PR, so "all checks green" was green over checks that never executed.
#
# Modes:
#   syntax   [dir]                      every *.yml/*.yaml parses, has `on:` and `jobs:`, and
#                                       every job has runs-on or uses. Exit 1 on any defect.
#   expected <base> <changed-files> [dir]
#                                       names of workflows a pull_request to <base> must run,
#                                       honouring branches / paths / paths-ignore filters.
#   compare  <expected-file> <executed-file>
#                                       every expected name is present in executed (one name
#                                       per line, e.g. from `gh run list --commit SHA --json
#                                       workflowName`). Exit 1 listing each missing workflow.
set -uo pipefail

mode="${1:-}"; shift || true
case "$mode" in
    syntax|expected) ;;
    compare)
        exp="${1:?expected-file}"; got="${2:?executed-file}"
        [[ -r "$exp" && -r "$got" ]] || { echo "[FAIL] compare: unreadable input"; exit 1; }
        [[ -s "$exp" ]] || { echo "[FAIL] compare: expected set is empty (nothing would be checked)"; exit 1; }
        missing=0
        while IFS= read -r w; do
            [[ -z "$w" ]] && continue
            if grep -qxF -- "$w" "$got"; then echo "  [RAN]     $w"
            else echo "  [MISSING] $w"; missing=$((missing+1)); fi
        done < <(sort -u "$exp")
        if [[ $missing -eq 0 ]]; then echo "[PASS] every expected workflow ran"; exit 0; fi
        echo "[FAIL] $missing expected workflow(s) did not run"; exit 1 ;;
    *) echo "usage: $0 syntax [dir] | expected <base> <changed-files> [dir] | compare <expected> <executed>" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "[FAIL] python3 is required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "[FAIL] python3-yaml is required"; exit 1; }

if [[ "$mode" == syntax ]]; then
    dir="${1:-.github/workflows}"
else
    base="${1:?base branch}"; changed="${2:?changed-files list}"; dir="${3:-.github/workflows}"
    [[ -r "$changed" ]] || { echo "[FAIL] changed-files list unreadable: $changed"; exit 1; }
fi
[[ -d "$dir" ]] || { echo "[FAIL] workflow dir not found: $dir"; exit 1; }

MODE="$mode" DIR="$dir" BASE="${base:-}" CHANGED="${changed:-}" python3 - <<'PY'
import glob, os, re, sys, yaml

mode, d = os.environ["MODE"], os.environ["DIR"]
files = sorted(glob.glob(os.path.join(d, "*.yml")) + glob.glob(os.path.join(d, "*.yaml")))
if not files:
    print(f"[FAIL] no workflow files in {d}"); sys.exit(1)

def load(f):
    with open(f) as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        raise ValueError("top level is not a mapping")
    on = doc.get("on", doc.get(True))   # YAML 1.1 reads a bare `on` key as True
    if on is None:
        raise ValueError("no `on:` trigger")
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        raise ValueError("no `jobs:`")
    for j, body in jobs.items():
        if not isinstance(body, dict) or not ("runs-on" in body or "uses" in body):
            raise ValueError(f"job {j!r} has neither runs-on nor uses")
    return doc, on

if mode == "syntax":
    bad = 0
    for f in files:
        try:
            load(f); print(f"  [OK]   {os.path.basename(f)}")
        except Exception as e:
            bad += 1; print(f"  [BAD]  {os.path.basename(f)}: {str(e).splitlines()[0]}")
    print(f"[{'PASS' if bad == 0 else 'FAIL'}] workflow syntax: {len(files) - bad}/{len(files)} valid")
    sys.exit(1 if bad else 0)

# expected: GitHub filter-pattern semantics (* = no slash, ** = anything, ? = one char).
def rx(p):
    out, i = "", 0
    while i < len(p):
        if p.startswith("**/", i): out += "(?:.*/)?"; i += 3
        elif p.startswith("**", i): out += ".*"; i += 2
        elif p[i] == "*": out += "[^/]*"; i += 1
        elif p[i] == "?": out += "[^/]"; i += 1
        else: out += re.escape(p[i]); i += 1
    return re.compile("^" + out + "$")

def matches(pats, s):
    hit = False
    for p in pats:                      # later !negations override earlier matches
        neg = p.startswith("!")
        if rx(p[1:] if neg else p).match(s): hit = not neg
    return hit

base = os.environ["BASE"]
changed = [l.strip() for l in open(os.environ["CHANGED"]) if l.strip()]
bad = 0
for f in files:
    try:
        doc, on = load(f)
    except Exception as e:
        bad += 1; print(f"INVALID {os.path.basename(f)}: {e}", file=sys.stderr); continue
    if isinstance(on, str): on = {on: None}
    elif isinstance(on, list): on = {k: None for k in on}
    if "pull_request" not in on: continue
    pr = on["pull_request"] or {}
    if "branches" in pr and not matches(pr["branches"], base): continue
    if "branches-ignore" in pr and matches(pr["branches-ignore"], base): continue
    if "paths" in pr and not any(matches(pr["paths"], c) for c in changed): continue
    if "paths-ignore" in pr and all(matches(pr["paths-ignore"], c) for c in changed): continue
    print(doc.get("name") or os.path.basename(f))
if bad:
    print(f"[FAIL] {bad} invalid workflow(s): their expected runs cannot be computed", file=sys.stderr)
    sys.exit(1)
PY
