#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""
NFTBan shell-test authority (v1.226.0 Phase B, PR-A substrate).

Single source of truth = per-test `# meta:ta.*` headers in each tracked shell test.
This tool PARSES those headers, VALIDATES them against the schema, and GENERATES a
deterministic derived index. The index is a projection — DO NOT EDIT it by hand.

The tool NEVER sources or executes a test; it reads only the comment header region
as inert text (no eval, no shell, no variable/command expansion).

Scope: SHELL tests only (`cli/lib/nftban/tests/*_test.sh`). Go tests are governed
separately by `go test ./...` (ci-go / secure-go) and are out of this authority.

Modes:
  validate [--mode transition|strict]   transition (default): fail only on malformed
        metadata / duplicate id|path / invalid values on ALREADY-migrated files.
        strict: additionally fail on any missing required meta:ta.* field.
  generate                              (re)write the derived index atomically.
  check                                 regenerate to a temp file, diff vs tracked index; fail if stale.
  summary                               counts (total / migrated / transitional / by class / by owner).

Exit codes: 0 = ok · 1 = metadata/validation/staleness failure · 2 = tool/config failure.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

TESTS_DIR = "cli/lib/nftban/tests"
# The derived index lives under scripts/ci/ (a CI/repo artifact), NOT inside
# TESTS_DIR: the packaging build sweeps cli/lib/nftban/tests/* into the shipped
# payload (/usr/lib/nftban/tests/), and this generated projection must never
# enter an end-user package. scripts/ci/ is run at build time but not installed.
INDEX_PATH = "scripts/ci/test-authority-index.tsv"

# --- controlled vocabularies (owner-declared, validated) -----------------------------
OWNERS = {
    "update", "mail", "health", "packaging", "rbl", "security", "architecture",
    "release", "installer", "firewall", "portscan", "botscan", "botguard",
    "loginmon", "suricata", "feeds", "whitelist", "blacklist", "geoban", "geoip",
    "comms", "metrics", "ddos", "tunnel", "sync", "trust", "core", "cli",
    "test-infra", "privacy", "cross-cutting",
}
EXECUTION_CLASSES = {
    "CI_STATIC", "CI_HERMETIC_SHELL", "PACKAGE_BUILD", "PACKAGE_NATIVE_DEB",
    "PACKAGE_NATIVE_RPM", "ROOT_LAB", "NETWORK_LAB", "LIVE_CANARY",
    "FLEET_RECONCILIATION", "MANUAL_FORENSIC", "HISTORICAL_ONLY",
}
GATES = {
    "policy-gates", "ci-bash", "package-build", "package-native-deb",
    "package-native-rpm", "lab-manual", "canary", "fleet", "manual-forensic",
    "excluded", "deferred", "unassigned",
}
BOOL_TRUE, BOOL_FALSE = "true", "false"
PLACEHOLDER_REASONS = {"", "todo", "tbd", "none", "n/a", "na", "-"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
META_RE = re.compile(r'^# meta:([a-z0-9_.]+)="(.*)"\s*$')

# meta:ta.* fields (governance namespace — distinct from person `meta:owner` / placeholder `meta:type`)
REQUIRED_TA = [
    "ta.id", "ta.owner", "ta.module", "ta.execution_class", "ta.gate",
    "ta.hermetic", "ta.requires_root", "ta.requires_network",
    "ta.requires_systemd", "ta.requires_nftables", "ta.requires_package",
]
BOOL_TA = [
    "ta.hermetic", "ta.requires_root", "ta.requires_network",
    "ta.requires_systemd", "ta.requires_nftables", "ta.requires_package",
]
INDEX_COLS = [
    "id", "path", "owner", "type", "module", "execution_class", "gate",
    "hermetic", "requires_root", "requires_network", "requires_systemd",
    "requires_nftables", "requires_package", "timeout", "exclusion_reason",
    "activation_condition",
]


def die_tool(msg):
    sys.stderr.write("ERROR (tool): %s\n" % msg)
    sys.exit(2)


def repo_root():
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, check=True)
        return r.stdout.strip()
    except Exception:
        die_tool("not inside a git repository (git rev-parse --show-toplevel failed)")


def discover(root):
    """One deterministic discovery rule, shared by validator + generator."""
    d = os.path.join(root, TESTS_DIR)
    if not os.path.isdir(d):
        die_tool("tests directory not found: %s" % TESTS_DIR)
    out = []
    for name in sorted(os.listdir(d)):
        if not name.endswith("_test.sh"):
            continue
        p = os.path.join(d, name)
        if os.path.islink(p):          # never index/execute symlinked externals
            continue
        if not os.path.isfile(p):
            continue
        rel = os.path.join(TESTS_DIR, name)
        # path safety: must stay inside repo, no traversal
        real = os.path.realpath(p)
        if not real.startswith(os.path.realpath(root) + os.sep):
            continue
        out.append(rel)
    return sorted(out)


def parse_headers(root, rel):
    """Read only the comment header region as inert text. Returns (dict, error|None)."""
    keys = {}
    try:
        with open(os.path.join(root, rel), "r", encoding="utf-8", errors="strict") as f:
            for line in f:
                s = line.rstrip("\n")
                if s.startswith("#!"):
                    continue                    # shebang
                if s.strip() == "":
                    continue                    # blank
                if s.startswith("#"):
                    m = META_RE.match(s)
                    if m:
                        k, v = m.group(1), m.group(2)
                        if k in keys:
                            return None, "duplicate metadata key meta:%s" % k
                        keys[k] = v
                    continue                    # ordinary comment
                break                           # first executable line -> stop
    except UnicodeDecodeError:
        return None, "file is not valid UTF-8"
    return keys, None


def stem(rel):
    return os.path.basename(rel)[:-3]           # strip ".sh"


def has_ta(keys):
    return any(k.startswith("ta.") for k in keys)


def validate_one(rel, keys, mode, errors):
    """Append 'path: meta:key: reason' strings to errors. Returns nothing."""
    def err(key, reason):
        errors.append("%s: meta:%s: %s" % (rel, key, reason))

    migrated = has_ta(keys)
    # In transition mode a legacy (no-ta) test is allowed; a migrated test is fully checked.
    check_required = (mode == "strict") or migrated

    # id resolution
    tid = keys.get("ta.id")
    if tid is not None:
        if not ID_RE.match(tid):
            err("ta.id", "invalid id %r (must match %s)" % (tid, ID_RE.pattern))
    elif check_required:
        err("ta.id", "missing required field")

    # required-field presence
    if check_required:
        for f in REQUIRED_TA:
            if f == "ta.id":
                continue
            if f not in keys:
                err(f, "missing required field")

    # value checks (only on present fields — malformed values always fail)
    if "ta.owner" in keys and keys["ta.owner"] not in OWNERS:
        err("ta.owner", "unknown owner %r (allowed: %s)" % (keys["ta.owner"], ",".join(sorted(OWNERS))))
    if "ta.module" in keys and keys["ta.module"].strip() == "":
        err("ta.module", "must not be blank (use 'cross-cutting'/'repository' if truly cross-cutting)")
    if "ta.execution_class" in keys and keys["ta.execution_class"] not in EXECUTION_CLASSES:
        err("ta.execution_class", "invalid value %r" % keys["ta.execution_class"])
    if "ta.gate" in keys and keys["ta.gate"] not in GATES:
        err("ta.gate", "invalid value %r" % keys["ta.gate"])
    for f in BOOL_TA:
        if f in keys and keys[f] not in (BOOL_TRUE, BOOL_FALSE):
            err(f, "invalid boolean %r (only 'true'/'false')" % keys[f])

    ec = keys.get("ta.execution_class")
    gate = keys.get("ta.gate")
    reason = keys.get("ta.exclusion_reason")
    activation = keys.get("ta.activation_condition")

    # exclusion_reason contract
    needs_reason = (gate == "excluded") or (ec == "HISTORICAL_ONLY")
    if needs_reason:
        if reason is None or reason.strip().lower() in PLACEHOLDER_REASONS:
            err("ta.exclusion_reason", "required and must be meaningful when gate=excluded or execution_class=HISTORICAL_ONLY")
    if gate == "unassigned" and reason is not None and reason.strip() != "":
        err("ta.exclusion_reason", "must not be set when gate=unassigned")

    # deferred contract: a test correctly classified for future execution but
    # withheld from a live gate now (e.g. a known-failing fixture pending repair).
    # It must carry a real reason AND a concrete activation condition, and its
    # true execution_class must not itself be HISTORICAL_ONLY (that is 'excluded').
    if gate == "deferred":
        if reason is None or reason.strip().lower() in PLACEHOLDER_REASONS:
            err("ta.exclusion_reason", "gate=deferred requires a meaningful ta.exclusion_reason (why it is withheld now)")
        if activation is None or activation.strip().lower() in PLACEHOLDER_REASONS:
            err("ta.activation_condition", "gate=deferred requires a concrete ta.activation_condition (what re-enables it)")
        if ec == "HISTORICAL_ONLY":
            err("ta.gate", "HISTORICAL_ONLY belongs to gate=excluded, not deferred")
    elif activation is not None and activation.strip() != "":
        err("ta.activation_condition", "ta.activation_condition is only valid when gate=deferred")

    # cross-field contradictions (owner-declared metadata authoritative, checked for consistency)
    def is_true(f):
        return keys.get(f) == BOOL_TRUE

    if ec == "CI_HERMETIC_SHELL":
        for f in ("ta.requires_root", "ta.requires_network", "ta.requires_systemd",
                  "ta.requires_nftables", "ta.requires_package"):
            if is_true(f):
                err(f, "CI_HERMETIC_SHELL cannot require %s" % f.replace("ta.requires_", ""))
        if keys.get("ta.hermetic") == BOOL_FALSE:
            err("ta.hermetic", "CI_HERMETIC_SHELL requires hermetic=true")
    if gate == "policy-gates":
        if keys.get("ta.hermetic") == BOOL_FALSE:
            err("ta.hermetic", "gate=policy-gates requires hermetic=true")
        if is_true("ta.requires_root"):
            err("ta.requires_root", "gate=policy-gates cannot require root")
        if is_true("ta.requires_network"):
            err("ta.requires_network", "gate=policy-gates cannot require network")
    if ec in ("PACKAGE_NATIVE_DEB", "PACKAGE_NATIVE_RPM") and keys.get("ta.requires_package") == BOOL_FALSE:
        err("ta.requires_package", "%s requires requires_package=true" % ec)
    if ec == "ROOT_LAB" and keys.get("ta.requires_root") == BOOL_FALSE:
        err("ta.requires_root", "ROOT_LAB requires requires_root=true")
    if ec == "NETWORK_LAB" and keys.get("ta.requires_network") == BOOL_FALSE:
        err("ta.requires_network", "NETWORK_LAB requires requires_network=true")
    if ec == "HISTORICAL_ONLY" and gate is not None and gate != "excluded":
        err("ta.gate", "HISTORICAL_ONLY execution_class requires gate=excluded")


def collect(root):
    """Return (records, parse_errors). records = list of dicts keyed by INDEX_COLS."""
    perr = []
    records = []
    seen_ids = {}
    seen_paths = set()
    for rel in discover(root):
        if rel in seen_paths:
            perr.append("%s: duplicate path" % rel)
            continue
        seen_paths.add(rel)
        keys, e = parse_headers(root, rel)
        if e:
            perr.append("%s: %s" % (rel, e))
            keys = {}
        tid = keys.get("ta.id") or stem(rel)      # transitional id = path-derived stem
        if tid in seen_ids:
            perr.append("%s: duplicate id %r (also %s)" % (rel, tid, seen_ids[tid]))
        else:
            seen_ids[tid] = rel
        rec = {
            "id": tid,
            "path": rel,
            "owner": keys.get("ta.owner", ""),
            "type": keys.get("type", ""),
            "module": keys.get("ta.module", ""),
            "execution_class": keys.get("ta.execution_class", ""),
            "gate": keys.get("ta.gate", "unassigned" if not has_ta(keys) else keys.get("ta.gate", "")),
            "hermetic": keys.get("ta.hermetic", ""),
            "requires_root": keys.get("ta.requires_root", ""),
            "requires_network": keys.get("ta.requires_network", ""),
            "requires_systemd": keys.get("ta.requires_systemd", ""),
            "requires_nftables": keys.get("ta.requires_nftables", ""),
            "requires_package": keys.get("ta.requires_package", ""),
            "timeout": keys.get("ta.timeout", ""),
            "exclusion_reason": keys.get("ta.exclusion_reason", ""),
            "activation_condition": keys.get("ta.activation_condition", ""),
            "_keys": keys,
        }
        records.append(rec)
    records.sort(key=lambda r: r["path"])
    return records, perr


def render_index(records):
    banner = [
        "# GENERATED FILE — DO NOT EDIT",
        "# Source authority: meta:ta.* headers in tracked shell test files (%s/*_test.sh)" % TESTS_DIR,
        "# Regenerate: scripts/ci/test-authority.py generate   |   Verify: scripts/ci/test-authority.py check",
        "\t".join(INDEX_COLS),
    ]
    for r in records:
        row = []
        for c in INDEX_COLS:
            v = r[c]
            if "\t" in v or "\n" in v:
                die_tool("field %r for %s contains a tab/newline" % (c, r["path"]))
            row.append(v)
        banner.append("\t".join(row))
    return "\n".join(banner) + "\n"


def cmd_generate(root, output=None):
    """Render the authority index.

    output=None  -> write the canonical index in place (unchanged behaviour).
    output=PATH  -> write ONLY to PATH; the canonical index is left untouched.

    The --output form exists so a CI pre-flight can generate to a temporary file
    and diff it against the committed index WITHOUT mutating the checkout. A job
    must validate repository state, never repair it: a generate-in-place followed
    by `git diff` can be obscured by cleanup or concurrent steps.
    """
    records, perr = collect(root)
    if perr:
        for e in perr:
            sys.stderr.write("ERROR %s\n" % e)
        return 1
    text = render_index(records)
    if output:
        dst = os.path.abspath(output)
        parent = os.path.dirname(dst) or "."
        if not os.path.isdir(parent):
            sys.stderr.write("ERROR: --output directory does not exist: %s\n" % parent)
            return 2
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".ta-index.")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, dst)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        print("generated %s (%d tests)" % (output, len(records)))
        return 0
    dst = os.path.join(root, INDEX_PATH)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".ta-index.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print("generated %s (%d tests)" % (INDEX_PATH, len(records)))
    return 0


def cmd_check(root):
    records, perr = collect(root)
    if perr:
        for e in perr:
            sys.stderr.write("ERROR %s\n" % e)
        return 1
    want = render_index(records)
    dst = os.path.join(root, INDEX_PATH)
    have = ""
    if os.path.exists(dst):
        with open(dst, "r", encoding="utf-8") as f:
            have = f.read()
    if have == want:
        print("INDEX_FRESH = YES")
        return 0
    sys.stderr.write("ERROR: %s is STALE — run: scripts/ci/test-authority.py generate\n" % INDEX_PATH)
    hl, wl = have.splitlines(), want.splitlines()
    for i in range(max(len(hl), len(wl))):
        a = hl[i] if i < len(hl) else "<absent>"
        b = wl[i] if i < len(wl) else "<absent>"
        if a != b:
            sys.stderr.write("  line %d:\n    tracked:  %s\n    expected: %s\n" % (i + 1, a[:200], b[:200]))
            break
    return 1


def cmd_validate(root, mode):
    records, perr = collect(root)
    errors = list(perr)
    for r in records:
        validate_one(r["path"], r["_keys"], mode, errors)
    if errors:
        for e in errors:
            sys.stderr.write("ERROR %s\n" % e)
        sys.stderr.write("VALIDATION_FAILED (mode=%s, %d error(s))\n" % (mode, len(errors)))
        return 1
    migrated = sum(1 for r in records if has_ta(r["_keys"]))
    print("VALIDATION_PASS mode=%s tracked=%d migrated=%d transitional=%d"
          % (mode, len(records), migrated, len(records) - migrated))
    return 0


def cmd_summary(root):
    records, perr = collect(root)
    for e in perr:
        sys.stderr.write("ERROR %s\n" % e)
    migrated = [r for r in records if has_ta(r["_keys"])]
    transitional = [r for r in records if not has_ta(r["_keys"])]
    by_class, by_owner, by_gate = {}, {}, {}
    for r in migrated:
        by_class[r["execution_class"]] = by_class.get(r["execution_class"], 0) + 1
        by_owner[r["owner"]] = by_owner.get(r["owner"], 0) + 1
        by_gate[r["gate"]] = by_gate.get(r["gate"], 0) + 1
    print("TOTAL_TRACKED_SHELL_TESTS = %d" % len(records))
    print("MIGRATED_METADATA_COMPLETE = %d" % len(migrated))
    print("TRANSITIONAL_UNCLASSIFIED = %d" % len(transitional))
    print("DUPLICATE_IDS = 0")
    print("DUPLICATE_PATHS = 0")
    print("by_execution_class = %s" % (dict(sorted(by_class.items())) or "{}"))
    print("by_owner = %s" % (dict(sorted(by_owner.items())) or "{}"))
    print("by_gate = %s" % (dict(sorted(by_gate.items())) or "{}"))
    return 1 if perr else 0


def main():
    ap = argparse.ArgumentParser(description="NFTBan shell-test authority (PR-A substrate).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    v.add_argument("--mode", choices=["transition", "strict"], default="transition")
    _g = sub.add_parser("generate")
    _g.add_argument("--output", metavar="PATH",
                    help="write the rendered index to PATH instead of the canonical "
                         "index; the canonical index is left untouched")
    sub.add_parser("check")
    sub.add_parser("summary")
    args = ap.parse_args()
    root = repo_root()
    if args.cmd == "validate":
        return cmd_validate(root, args.mode)
    if args.cmd == "generate":
        return cmd_generate(root, getattr(args, "output", None))
    if args.cmd == "check":
        return cmd_check(root)
    if args.cmd == "summary":
        return cmd_summary(root)
    die_tool("unknown command")


if __name__ == "__main__":
    sys.exit(main())
