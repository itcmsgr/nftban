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
            m = re.match(r'\s+(artifact_class|retention_owner|retention_mode|retention_evidence|owner|group|mode|pattern):\s*"?([A-Za-z0-9_:\-/. ()+,;*]+)"?\s*$', ln)
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
print("=== R-5: every state directory declares a lifecycle disposition (v1.229.3 INV-C0) ===")

# TRI-STATE. The decisive rule is that UNKNOWN must stay visibly UNKNOWN:
#     UNCLASSIFIED != NO_RETENTION_BY_DESIGN
# A state directory with no disposition is a silent gap; one labelled `none`
# without a reason is an escape hatch. Both fail.
RMODE = {"managed", "none", "unclassified"}
# Scope to DIRECTORY DECLARATIONS. Entries in file_permissions: carry a `pattern`
# (and recursive/exclude) — they are permission RULES over a class of files, not
# persistent-class declarations. A permission rule has no lifecycle of its own;
# the directory it applies to does, and that directory is declared separately.
state = [e for e in entries
         if e.get("artifact_class") == "state" and not e.get("pattern")]

# C0-6 PARSE VALIDITY, evaluated BEFORE any verdict.
# An empty or partial parse must never read as "nothing to check". The parser's
# result is cross-checked against an INDEPENDENT count of the raw declaration
# lines; if the two disagree the spec was not observed, and no PASS below would
# mean anything. EMPTY_PARSE != ZERO_FINDINGS.
raw_state = sum(1 for ln in open(spec, encoding="utf-8")
                if ln.strip() == "artifact_class: state")
perm_rules = [e for e in entries
              if e.get("artifact_class") == "state" and e.get("pattern")]
if raw_state != len(state) + len(perm_rules):
    no(f"PARSE_INCOMPLETE: {raw_state} raw 'artifact_class: state' lines but the "
       f"parser resolved {len(state)} declarations + {len(perm_rules)} permission rules")
    print("        -> the schema was NOT observed; every result below is invalid.")
elif not state:
    no("PARSE_INCOMPLETE: zero state declarations resolved — an empty parse is not a pass")
else:
    ok(f"parse validity: {len(state)} declarations + {len(perm_rules)} permission "
       f"rules == {raw_state} raw state lines")
bad_mode = [e["path"] for e in state if e.get("retention_mode") not in RMODE]
if bad_mode:
    no(f"{len(bad_mode)} state directories lack a valid retention_mode:")
    for pth in bad_mode[:20]:
        print(f"        {pth}")
    print(f"        -> one of: {sorted(RMODE)}")
else:
    ok(f"all {len(state)} state directories declare a retention_mode")

# managed REQUIRES an owner and the evidence that proves it
bad_managed = [e["path"] for e in state
               if e.get("retention_mode") == "managed"
               and (not e.get("retention_owner") or not e.get("retention_evidence"))]
if bad_managed:
    no(f"{len(bad_managed)} managed state directories lack retention_owner+retention_evidence:")
    for pth in bad_managed[:20]:
        print(f"        {pth}")
    print("        -> a managed class must name its authority AND the proof it is reachable.")
else:
    ok("every managed state directory names an owner and its evidence")

# none REQUIRES a stated reason; it must never be reachable by omission
bad_none = [e["path"] for e in state
            if e.get("retention_mode") == "none" and not e.get("retention_evidence")]
if bad_none:
    no(f"{len(bad_none)} state directories claim retention_mode=none with no justification:")
    for pth in bad_none[:20]:
        print(f"        {pth}")
    print("        -> 'no cleanup required' is a lifecycle DECISION and must state why.")
    print("           UNCLASSIFIED is the honest value when evidence is absent.")
else:
    ok("no unjustified retention_mode=none declarations")

# unclassified must not masquerade as a completed classification
bad_unc = [e["path"] for e in state
           if e.get("retention_mode") == "unclassified"
           and (e.get("retention_owner") or e.get("retention_evidence"))]
if bad_unc:
    no(f"{len(bad_unc)} unclassified entries carry owner/evidence implying they were classified:")
    for pth in bad_unc[:20]:
        print(f"        {pth}")
else:
    ok("unclassified entries carry no owner/evidence (no false completeness)")

# C0-8: classes with PROVEN accumulation + a wired authority cannot be quietly
# downgraded. Relabelling one of these `none` or `unclassified` would erase a
# closure that runtime evidence established, so the schema is pinned against the
# proof rather than against a hand-list of opinions.
PROVEN_MANAGED = {
    "/var/lib/nftban/snapshots":      "nftban_stats_cleanup_logs via maintenance 9d (hourly writer; 4,216 files measured on a fleet host)",
    "/var/lib/nftban/stats/history":  "internal/stats CleanupHistory via collector runCleanup",
    "/var/lib/nftban/stats/profiles": "internal/stats CleanupProfiles via collector runCleanup",
}
downgraded = [(e["path"], e.get("retention_mode"))
              for e in state
              if e["path"] in PROVEN_MANAGED and e.get("retention_mode") != "managed"]
if downgraded:
    no(f"{len(downgraded)} classes with PROVEN retention authority were downgraded:")
    for pth, md in downgraded:
        print(f"        {pth}  <- retention_mode={md!r}")
        print(f"           proof: {PROVEN_MANAGED[pth]}")
    print("        -> a proven authority cannot be relabelled none/unclassified.")
else:
    ok(f"all {len(PROVEN_MANAGED)} classes with proven authority remain managed")

unc = [e["path"] for e in state if e.get("retention_mode") == "unclassified"]
mgd = [e["path"] for e in state if e.get("retention_mode") == "managed"]
print(f"    STATE_LIFECYCLE: managed={len(mgd)} none={len([e for e in state if e.get('retention_mode')=='none'])} "
      f"unclassified={len(unc)} of {len(state)}")
print(f"    INV-C2 declaration completeness: {'COMPLETE' if not unc else f'OPEN — {len(unc)} UNCLASSIFIED state classes'}")

print()
print("=== RESULT: artifact class authority " + ("PASS" if not fail else "FAIL") + " ===")
sys.exit(fail)
PY
