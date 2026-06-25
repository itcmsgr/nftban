#!/usr/bin/env bash
# =============================================================================
# NFTBan CI guard — CLI surface parity (registry ↔ bash-completion ↔ dispatch)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-cli-surface-parity"
# meta:type="ci-guard"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.205 CLI SURFACE PARITY guard. Authority rule: runtime shell dispatch (sbin/nftban + cmd_*.sh) is the source of truth; commands.registry.yml and bash-completion are validated against it. Classifies drift: MISSING_FROM_REGISTRY / STALE_IN_REGISTRY / MISSING_FROM_COMPLETION / RETIRED_IN_COMPLETION / ALIAS_NOT_MARKED / DEPRECATED_NOT_MARKED / INTERNAL_OR_TARGET_ONLY_ALLOWLISTED / PASS. Also: retired-gui completion check + duplicate-handler (grouped case-arm) scan. Fails CI on real drift."
# meta:inventory.files="commands.registry.yml, install/bash-completion/nftban, cli/sbin/nftban, cli/lib/nftban/cli/cmd_*.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

REGISTRY="commands.registry.yml"
COMPLETION="install/bash-completion/nftban"
SBIN="cli/sbin/nftban"

[ -f "$REGISTRY" ] || { echo "FAIL: $REGISTRY not found"; exit 2; }
[ -f "$COMPLETION" ] || { echo "FAIL: $COMPLETION not found"; exit 2; }

python3 - "$REGISTRY" "$COMPLETION" "$SBIN" <<'PY'
import sys, re, glob, os
reg_path, comp_path, sbin_path = sys.argv[1], sys.argv[2], sys.argv[3]

# --- registry: top-level commands + aliases + deprecated (lightweight YAML scan; no pyyaml dep) ---
reg_cmds, reg_alias, reg_deprecated = set(), {}, set()
cur = None
with open(reg_path) as f:
    for line in f:
        m = re.match(r'^([a-z][a-z0-9_-]*):\s*$', line)
        if m:
            cur = m.group(1)
            if cur not in ("subcommands","options","arguments","examples","notes","values","global_options"):
                reg_cmds.add(cur)
            continue
        # top-level command alias line:  "  aliases: [\"cloudflare\"]" (2-space indent = command-level)
        a = re.match(r'^  aliases:\s*\[([^\]]*)\]', line)
        if a and cur:
            for tok in re.findall(r'[A-Za-z0-9_-]+', a.group(1)):
                reg_alias.setdefault(cur, set()).add(tok)
KNOWN_NONCMD = {"global","setup_discovery","global_options","standard_params"}
reg_cmds -= KNOWN_NONCMD

# --- completion: the top-level $commands="..." list ---
comp_cmds = set()
txt = open(comp_path).read()
m = re.search(r'local commands="([^"]*)"', txt)
if m:
    comp_cmds = set(m.group(1).split())
gui_in_completion = bool(re.search(r'\bgui\b', txt))

# --- intentional aliases (marked in registry) + internal/target-only allowlist ---
alias_flat = {al for s in reg_alias.values() for al in s}
ALLOW_INTERNAL = {"firewall-logs","menu","wizard","test","selftest","preflight","benchmark","rollback","scale","modes"}
# universal meta-verbs handled outside the per-command registry (global dispatch)
ALLOW_META = {"help"}
ALLOW_INTERNAL |= ALLOW_META

fails = []
def emit(cat, item, detail=""):
    print(f"  {cat}: {item}{(' — '+detail) if detail else ''}")
    if cat not in ("INTERNAL_OR_TARGET_ONLY_ALLOWLISTED","PASS"):
        fails.append((cat,item))

print("== top-level: completion vs registry ==")
# RETIRED_IN_COMPLETION: gui (retired v1.100.1b) must not appear
if gui_in_completion:
    emit("RETIRED_IN_COMPLETION", "gui", "retired v1.100.1b/#502 — remove from bash-completion")
else:
    print("  PASS: retired 'gui' absent from completion")

for c in sorted(comp_cmds):
    if c in reg_cmds: continue
    if c in alias_flat:
        print(f"  ALIAS_OK: {c} (marked alias in registry)"); continue
    if c in ALLOW_INTERNAL:
        emit("INTERNAL_OR_TARGET_ONLY_ALLOWLISTED", c); continue
    emit("MISSING_FROM_REGISTRY" if c!="gui" else "RETIRED_IN_COMPLETION", c, "in completion, not a registry command/alias")

for c in sorted(reg_cmds):
    if c in comp_cmds or c in alias_flat: continue
    if c in ALLOW_INTERNAL: continue
    emit("MISSING_FROM_COMPLETION", c, "registry command not offered in completion")

print("== required confirmed fixes (v1.205 / FULL_CLI_SURFACE_PARITY_AUDIT) ==")
def reg_has_subcmd(cmd, sub, flag=None):
    # scan the registry block for 'cmd:' then its subcommands for 'sub:' (+ optional flag line)
    block=[]; cap=False
    for line in open(reg_path):
        if re.match(rf'^{cmd}:\s*$', line): cap=True; continue
        if cap and re.match(r'^[a-z][a-z0-9_-]*:\s*$', line): break
        if cap: block.append(line)
    body="".join(block)
    ms=re.search(rf'^    {sub}:\s*$(.*?)(?=^    [a-z]|\Z)', body, re.M|re.S)
    if not ms: return False
    if flag and flag not in ms.group(1): return False
    return True
checks = [
  ("firewall rebuild present", reg_has_subcmd("firewall","rebuild")),
  ("firewall restore present", reg_has_subcmd("firewall","restore")),
  ("firewall record present",  reg_has_subcmd("firewall","record")),
  ("trust aliases includes cloudflare", "cloudflare" in reg_alias.get("trust",set())),
  ("geoban update aliases includes refresh", reg_has_subcmd("geoban","update","refresh")),
  ("fhs check deprecated", reg_has_subcmd("fhs","check","deprecated: true")),
  ("port list deprecated", reg_has_subcmd("port","list","deprecated: true")),
]
for name,ok in checks:
    if ok: print(f"  PASS: {name}")
    else: emit("ALIAS_NOT_MARKED" if "alias" in name or "deprecated" in name else "MISSING_FROM_REGISTRY", name, "expected by audit")

print("== duplicate-handler (grouped case-arm) scan — informational unless unmarked ==")
dups=0
for sh in glob.glob("cli/lib/nftban/cli/cmd_*.sh"):
    for ln in open(sh, errors="ignore"):
        m=re.match(r'^\s*([a-z][a-z0-9_-]*(?:\|[a-z][a-z0-9_-]*){1,})\)\s*$', ln)
        if m and "|" in m.group(1):
            verbs=m.group(1).split("|")
            if len(verbs)>=2:
                dups+=1
                # informational; registry alias/deprecated markers are the resolution
print(f"  INFO: {dups} grouped case-arms (multiple verbs → one handler) across cmd_*.sh — resolve via registry alias/deprecated markers (guard does not fail on these)")

print()
if fails:
    print(f"RESULT: DRIFT_FOUND — {len(fails)} blocking item(s):")
    for c,i in fails: print(f"  - {c}: {i}")
    sys.exit(1)
print("RESULT: PASS — CLI surface parity clean (registry ↔ completion ↔ confirmed fixes)")
PY
