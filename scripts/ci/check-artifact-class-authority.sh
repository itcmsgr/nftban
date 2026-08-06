#!/usr/bin/env bash
# =============================================================================
# NFTBan - artifact class authority guard (v1.228.5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-artifact-class-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-06"
# meta:description="v1.228.5 RECURRENCE guard for the FHS/log-authority class defect. The prior guards could not have caught that defect because they verified CONSISTENCY (does the writer match the test?) rather than CORRECTNESS (is the expectation itself right?) - logs_truth_v150_test.sh affirmatively asserted /var/lib/nftban/permissions_audit.log, so CI defended the misplacement. This guard derives correctness from a DECLARED artifact_class in the canonical build/fhs-spec.yaml instead of pinning path strings, so a newly added artifact cannot pass by merely being self-consistent. Rules: every declared directory carries an artifact_class; class determines the legal FHS root (log->/var/log, state->/var/lib, cache->/var/cache, runtime->/run, config->/etc); only class=log may be a logrotate target and every logrotate target must be class=log; class=state may never be rotated; each artifact declares exactly one retention_owner. Reads the GENERATOR (internal/logretention/inventory.go) as the rotation authority because /etc/logrotate.d/nftban is a %ghost regenerated at postinstall - a template-only fix is reverted on install. Static analysis only - reads files, invokes nothing, contacts no host."
# meta:input="build/fhs-spec.yaml, internal/logretention/inventory.go"
# meta:output="PASS/FAIL per rule; exit 0 on all-pass, 1 on any violation"
# meta:depends="bash,python3"
# meta:inventory.files=""
# meta:inventory.binaries="bash,python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

exec python3 - "$ROOT" <<'PY'
import re, sys, os

root = sys.argv[1]
spec = os.path.join(root, "build/fhs-spec.yaml")
gen  = os.path.join(root, "internal/logretention/inventory.go")
fail = 0

def ok(m):  print(f"  [PASS] {m}")
def no(m):
    global fail
    print(f"  [FAIL] {m}"); fail = 1

# ---------------------------------------------------------------------------
# Parse the canonical spec. Deliberately a narrow line parser rather than a YAML
# dependency: this guard must run in any CI image without extra packages, and the
# fields it needs are flat scalars under "- path:".
# ---------------------------------------------------------------------------
entries, cur = [], None
try:
    for ln in open(spec, encoding="utf-8"):
        m = re.match(r'\s*-\s+path:\s*(\S+)', ln)
        if m:
            if cur: entries.append(cur)
            cur = {"path": m.group(1)}
            continue
        if cur is not None:
            m = re.match(r'\s+(artifact_class|retention_owner|owner|group|mode):\s*"?([A-Za-z0-9_:\-/.]+)"?\s*$', ln)
            if m: cur[m.group(1)] = m.group(2)
    if cur: entries.append(cur)
except OSError as e:
    print(f"  [FAIL] cannot read {spec}: {e}"); sys.exit(1)

if not entries:
    # Non-vacuity: an empty parse would make every rule below pass for free, which is
    # the exact failure mode this guard exists to prevent.
    print("  [FAIL] parsed ZERO entries from fhs-spec.yaml - extraction is degenerate, "
          "every rule would pass vacuously"); sys.exit(1)
print(f"  parsed {len(entries)} declared directories from build/fhs-spec.yaml")

# ---------------------------------------------------------------------------
CLASS_ROOT = {
    "log":     "/var/log/nftban",
    "state":   "/var/lib/nftban",
    "cache":   "/var/cache/nftban",
    "runtime": "/run/nftban",
    "config":  "/etc/nftban",
    "program": "/usr/",
}
VALID = set(CLASS_ROOT) | {"external"}   # external = written by another tier, class asserted not inferred

print("=== R-1: every declared directory carries an artifact_class ===")
missing = [e["path"] for e in entries if not e.get("artifact_class")]
if missing:
    no(f"{len(missing)} declared directories have NO artifact_class:")
    for p in missing[:25]: print(f"        {p}")
    if len(missing) > 25: print(f"        ... and {len(missing)-25} more")
    print("        -> classify each as log|state|cache|runtime|config|external.")
    print("           An unclassified directory is how the original defect survived:")
    print("           'persistent' was treated as 'state', so operational history landed")
    print("           in /var/lib and inherited a SELinux type logrotate cannot manage.")
else:
    ok(f"all {len(entries)} declared directories carry an artifact_class")

print("=== R-2: artifact_class matches the FHS root it lives under ===")
bad = []
for e in entries:
    c = e.get("artifact_class")
    if not c or c == "external": continue
    if c not in VALID:
        bad.append((e["path"], f"unknown class {c!r}")); continue
    want = CLASS_ROOT[c]
    if not e["path"].startswith(want):
        bad.append((e["path"], f"class={c} requires {want}/..."))
if bad:
    no(f"{len(bad)} directories whose class contradicts their location:")
    for p, why in bad[:20]: print(f"        {p}  <- {why}")
else:
    ok("every classified directory lives under the root its class requires")

# ---------------------------------------------------------------------------
# The GENERATOR is the rotation authority. /etc/logrotate.d/nftban is %ghost and is
# regenerated at postinstall from this file, so a fix applied only to the shipped
# template is silently reverted on the next install.
# ---------------------------------------------------------------------------
print("=== R-3: every logrotate target is class=log (and no state is rotated) ===")
try:
    src = open(gen, encoding="utf-8").read()
except OSError as e:
    no(f"cannot read rotation authority {gen}: {e}"); src = ""
src = re.sub(r'//.*', '', src)                      # comments may legitimately cite old paths
targets = sorted(set(re.findall(r'"(/var/[^"]+)"', src)))
if not targets:
    no("parsed ZERO rotation targets from the generator - extraction degenerate")
else:
    # longest declared prefix wins, so /var/lib/nftban/reports/auditors beats /var/lib/nftban
    def klass(p):
        best, bc = "", None
        for e in entries:
            if p.startswith(e["path"]) and len(e["path"]) > len(best):
                best, bc = e["path"], e.get("artifact_class")
        return bc
    offenders = []
    for t in targets:
        c = klass(t)
        if c is None:
            offenders.append((t, "target is under NO declared directory"))
        elif c != "log":
            offenders.append((t, f"target resolves to class={c}, only class=log may be rotated"))
    if offenders:
        no(f"{len(offenders)} rotation targets are not class=log:")
        for t, why in offenders: print(f"        {t}  <- {why}")
        print("        -> logrotate_t has file access to nftban_log_t (via logging_log_file())")
        print("           and NONE to nftban_var_lib_t. Rotating a state path fails the WHOLE")
        print("           system-wide logrotate.service. Move the artifact; never grant")
        print("           logrotate_t access to NFTBan state.")
    else:
        ok(f"all {len(targets)} rotation targets resolve to class=log")

print("=== R-4: each artifact declares exactly one retention_owner ===")
ROWN = {"logrotate", "internal", "registry", "package", "none"}
badr = [(e["path"], e.get("retention_owner"))
        for e in entries
        if e.get("artifact_class") in ("log", "cache") and e.get("retention_owner") not in ROWN]
if badr:
    no(f"{len(badr)} log/cache directories lack a valid retention_owner:")
    for p, r in badr[:20]: print(f"        {p}  <- retention_owner={r!r}")
    print(f"        -> one of: {sorted(ROWN)}. Two mechanisms deleting the same file on")
    print("           different units (count vs age) silently truncates history.")
else:
    ok("every log/cache directory declares a single valid retention_owner")

print()
print("=== RESULT: artifact class authority " + ("PASS" if not fail else "FAIL") + " ===")
sys.exit(fail)
PY
