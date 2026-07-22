#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""
Self-tests for scripts/ci/test-authority.py (v1.226.0 PR-A substrate).

Hermetic: builds throwaway git repos in a tempdir, populates
cli/lib/nftban/tests/*_test.sh fixtures, and drives the real CLI as a
subprocess so exit codes and stderr are exercised end-to-end. No network,
no root, no dependency on the live test corpus.

Run:  python3 scripts/ci/test-authority-selftest.py
Exit: 0 = all self-tests pass · 1 = a self-test failed · 2 = harness error.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL = os.path.join(HERE, "test-authority.py")
TESTS_REL = "cli/lib/nftban/tests"
INDEX_REL = "scripts/ci/test-authority-index.tsv"  # must mirror tool's INDEX_PATH

# A complete, contradiction-free hermetic header (the happy path).
GOOD_TA = [
    '# meta:ta.id="good_test"',
    '# meta:ta.owner="update"',
    '# meta:ta.module="update"',
    '# meta:ta.execution_class="CI_HERMETIC_SHELL"',
    '# meta:ta.gate="policy-gates"',
    '# meta:ta.hermetic="true"',
    '# meta:ta.requires_root="false"',
    '# meta:ta.requires_network="false"',
    '# meta:ta.requires_systemd="false"',
    '# meta:ta.requires_nftables="false"',
    '# meta:ta.requires_package="false"',
]

_failures = []


def _die(msg):
    sys.stderr.write("HARNESS ERROR: %s\n" % msg)
    sys.exit(2)


def make_repo(files):
    """files: {basename: header_lines[]}. Returns repo root path."""
    root = tempfile.mkdtemp(prefix="ta-selftest-")
    subprocess.run(["git", "init", "-q", root], check=True)
    tdir = os.path.join(root, TESTS_REL)
    os.makedirs(tdir)
    os.makedirs(os.path.join(root, os.path.dirname(INDEX_REL)))  # index parent (scripts/ci)
    for name, header in files.items():
        body = "#!/usr/bin/env bash\n" + "\n".join(header) + '\necho "body"\n'
        with open(os.path.join(tdir, name), "w") as f:
            f.write(body)
    return root


def run(root, *args):
    p = subprocess.run([sys.executable, TOOL, *args], cwd=root,
                       capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def expect(cond, label, detail=""):
    if cond:
        print("  ok   %s" % label)
    else:
        print("  FAIL %s  %s" % (label, detail))
        _failures.append(label)


def ta_with(**overrides):
    """Clone GOOD_TA, override/append meta:ta.<k> lines."""
    base = {}
    for ln in GOOD_TA:
        k = ln.split(":", 1)[1].split("=", 1)[0]
        base[k] = ln
    for k, v in overrides.items():
        key = "ta." + k
        if v is None:
            base.pop(key, None)
        else:
            base[key] = '# meta:%s="%s"' % (key, v)
    # preserve GOOD_TA ordering, then any new keys
    order = [ln.split(":", 1)[1].split("=", 1)[0] for ln in GOOD_TA]
    out = [base[k] for k in order if k in base]
    out += [base[k] for k in base if k not in order]
    return out


# ---- positive path ------------------------------------------------------------
def test_happy_path():
    print("test_happy_path")
    root = make_repo({"good_test.sh": GOOD_TA})
    rc, out, err = run(root, "validate", "--mode", "strict")
    expect(rc == 0, "strict validate passes on complete metadata", err)
    expect("migrated=1" in out, "reports migrated=1", out)
    rc, _, _ = run(root, "generate")
    expect(rc == 0, "generate succeeds")
    rc, out, _ = run(root, "check")
    expect(rc == 0 and "INDEX_FRESH = YES" in out, "check is FRESH after generate", out)


def test_transition_allows_legacy():
    print("test_transition_allows_legacy")
    # A legacy file with NO ta.* headers.
    legacy = ['# meta:name="legacy"', '# meta:type="test"']
    root = make_repo({"legacy_test.sh": legacy, "good_test.sh": GOOD_TA})
    rc, out, _ = run(root, "validate", "--mode", "transition")
    expect(rc == 0, "transition passes with a legacy (no-ta) test present", out)
    expect("transitional=1" in out and "migrated=1" in out, "counts split legacy vs migrated", out)
    rc, _, err = run(root, "validate", "--mode", "strict")
    expect(rc == 1, "strict FAILS on the same legacy test (missing required)", err)
    expect("missing required field" in err, "strict names the missing-field reason", err)


def test_determinism():
    print("test_determinism")
    root = make_repo({"good_test.sh": GOOD_TA, "b_test.sh": ta_with(id="b_test")})
    run(root, "generate")
    with open(os.path.join(root, INDEX_REL)) as f:
        first = f.read()
    run(root, "generate")
    with open(os.path.join(root, INDEX_REL)) as f:
        second = f.read()
    expect(first == second, "generate is byte-deterministic across runs")
    expect("GENERATED FILE — DO NOT EDIT" in first, "index carries do-not-edit banner")
    expect("\t".join(["id", "path", "owner"]) in first, "index has tab-separated header row")


def test_stale_index_detected():
    print("test_stale_index_detected")
    root = make_repo({"good_test.sh": GOOD_TA})
    run(root, "generate")
    idx = os.path.join(root, INDEX_REL)
    with open(idx, "a") as f:
        f.write("tampered\textra\trow\n")
    rc, _, err = run(root, "check")
    expect(rc == 1 and "STALE" in err, "check detects a hand-tampered index", err)


# ---- negative fixtures (each MUST exit 1) -------------------------------------
NEGATIVES = [
    ("unknown_owner", ta_with(owner="not-a-real-owner"), "unknown owner"),
    ("bad_exec_class", ta_with(execution_class="CI_BOGUS"), "invalid value"),
    ("bad_gate", ta_with(gate="not-a-gate"), "invalid value"),
    ("bad_boolean", ta_with(requires_root="yes"), "invalid boolean"),
    ("bad_id_chars", ta_with(id="Has Spaces/And.CAPS!"), "invalid id"),
    ("hermetic_needs_no_root",
     ta_with(execution_class="CI_HERMETIC_SHELL", requires_root="true"),
     "CI_HERMETIC_SHELL cannot require"),
    ("policygate_needs_hermetic",
     ta_with(gate="policy-gates", hermetic="false"),
     "requires hermetic=true"),
    ("excluded_needs_reason",
     ta_with(gate="excluded", exclusion_reason="TODO"),
     "must be meaningful"),
    ("historical_needs_excluded",
     ta_with(execution_class="HISTORICAL_ONLY", gate="policy-gates"),
     "HISTORICAL_ONLY execution_class requires gate=excluded"),
    ("pkg_native_needs_pkg",
     ta_with(execution_class="PACKAGE_NATIVE_DEB", gate="package-native-deb",
             hermetic="false", requires_package="false"),
     "requires requires_package=true"),
]


def test_negatives():
    print("test_negatives")
    for name, header, needle in NEGATIVES:
        root = make_repo({name + "_test.sh": header})
        rc, _, err = run(root, "validate", "--mode", "transition")
        expect(rc == 1 and needle in err, "reject: %s" % name, "rc=%d err=%s" % (rc, err.strip()[:160]))


def test_duplicate_id():
    print("test_duplicate_id")
    a = ta_with(id="collide")
    b = ta_with(id="collide")
    root = make_repo({"a_test.sh": a, "b_test.sh": b})
    rc, _, err = run(root, "validate", "--mode", "transition")
    expect(rc == 1 and "duplicate id" in err, "two files sharing ta.id are rejected", err)


def test_duplicate_key_in_file():
    print("test_duplicate_key_in_file")
    dup = GOOD_TA + ['# meta:ta.owner="mail"']  # ta.owner twice
    root = make_repo({"dup_test.sh": dup})
    rc, _, err = run(root, "validate", "--mode", "transition")
    expect(rc == 1 and "duplicate metadata key" in err, "duplicate meta key in one file rejected", err)


def test_header_region_stops_at_code():
    print("test_header_region_stops_at_code")
    # A ta.* line placed AFTER an executable line must NOT be parsed (header region only).
    hdr = GOOD_TA[:]
    # Insert code, then a contradictory ta line that would fail IF parsed.
    injected = hdr + ['echo run', '# meta:ta.requires_root="true"']
    root = make_repo({"good_test.sh": injected})
    rc, out, err = run(root, "validate", "--mode", "strict")
    expect(rc == 0, "meta after first code line is ignored (not parsed)", err)


def test_tool_failure_exit2():
    print("test_tool_failure_exit2")
    # No tests dir at all -> tool/config failure (exit 2), distinct from validation (1).
    root = tempfile.mkdtemp(prefix="ta-selftest-empty-")
    subprocess.run(["git", "init", "-q", root], check=True)
    rc, _, err = run(root, "validate")
    expect(rc == 2 and "tests directory not found" in err, "missing tests dir => exit 2 (tool failure)", err)


def main():
    if not os.path.exists(TOOL):
        _die("tool not found: %s" % TOOL)
    tests = [
        test_happy_path, test_transition_allows_legacy, test_determinism,
        test_stale_index_detected, test_negatives, test_duplicate_id,
        test_duplicate_key_in_file, test_header_region_stops_at_code,
        test_tool_failure_exit2,
    ]
    for t in tests:
        t()
    print()
    if _failures:
        print("SELFTEST_FAIL (%d): %s" % (len(_failures), ", ".join(_failures)))
        return 1
    print("SELFTEST_PASS (all self-tests green)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
