#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""
Self-tests for scripts/ci/private-identifier-gate.py (v1.226.0 privacy defense-in-depth).

ALL denylist values here are SYNTHETIC (RFC5737 IPv4 / RFC3849 IPv6). No real identifier is
present or required. Tests build throwaway git repos and drive the real gate as a subprocess
with the denylist + HMAC key supplied ONLY via the environment (never committed).

Run:  python3 scripts/ci/private-identifier-gate-selftest.py
Exit: 0 = all pass · 1 = a self-test failed · 2 = harness error.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
GATE = os.path.join(HERE, "private-identifier-gate.py")
# synthetic denylist tokens (documentation ranges) — safe to appear in this test file
D4 = "198.51.100.23"
D6 = "2001:db8:1234::abcd"
KEY = "selftest-fingerprint-key-not-a-secret"
_fail = []


def check(cond, label, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label + ("" if cond else "  " + detail))
    if not cond:
        _fail.append(label)


def make_repo(files):
    root = tempfile.mkdtemp(prefix="pig-selftest-")
    subprocess.run(["git", "init", "-q", root], check=True)
    subprocess.run(["git", "-C", root, "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", root, "config", "user.name", "t"], check=True)
    for rel, content in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True) if os.path.dirname(p) else None
        open(p, "w").write(content)
    subprocess.run(["git", "-C", root, "add", "-A"], check=True)
    subprocess.run(["git", "-C", root, "commit", "-q", "-m", "init"], check=True)
    return root


def run(root, args, denylist=D4 + "\n" + D6, key=KEY, extra_env=None):
    env = dict(os.environ)
    env.pop("NFTBAN_PRIVACY_DENYLIST_FILE", None)
    if denylist is None:
        env.pop("NFTBAN_PRIVACY_DENYLIST", None)
    else:
        env["NFTBAN_PRIVACY_DENYLIST"] = denylist
    if key is None:
        env.pop("NFTBAN_PRIVACY_FP_KEY", None)
    else:
        env["NFTBAN_PRIVACY_FP_KEY"] = key
    if extra_env:
        env.update(extra_env)
    p = subprocess.run([sys.executable, GATE] + args, cwd=root, capture_output=True, text=True, env=env)
    return p.returncode, p.stdout, p.stderr


def test_detection_forms():
    print("test_detection_forms")
    content = "\n".join([
        "a = 198.51.100.23",
        "grep '^198\\.51\\.100\\.23$'",
        'x="198\\\\.51\\\\.100\\\\.23"',
        "url = http://198%2e51%2e100%2e23/path",
        "v6 = 2001:0db8:1234:0000:0000:0000:0000:abcd",   # expanded form of D6
        "v6b = [2001:db8:1234::ABCD]:443",                 # bracketed + uppercase
    ]) + "\n"
    root = make_repo({"f.txt": content})
    rc, out, err = run(root, ["--whole-tree", "--mode", "publication"])
    check(rc == 1, "publication scan flags private identifiers (exit 1)", err.strip())
    check(out.count("PRIVATE_IDENTIFIER") >= 6, "all six obfuscated forms detected", "found=%d" % out.count("PRIVATE_IDENTIFIER"))
    check("fp=" in out, "fingerprint emitted")


def test_output_hygiene():
    print("test_output_hygiene")
    line = "secret host at 198.51.100.23 here-is-the-full-line-marker"
    root = make_repo({"f.txt": line + "\n"})
    rc, out, err = run(root, ["--whole-tree", "--mode", "publication"])
    combined = out + err
    check(D4 not in combined, "raw IPv4 token absent from output")
    check(D6 not in combined, "raw IPv6 token absent from output")
    check("here-is-the-full-line-marker" not in combined, "full matching source line absent from output")
    check("198.51.x.x" in out, "redacted representation present")


def test_hmac_fingerprint():
    print("test_hmac_fingerprint")
    root = make_repo({"f.txt": "198.51.100.23\n"})
    _, o1, _ = run(root, ["--whole-tree", "--mode", "publication"], key="KEY-A")
    _, o2, _ = run(root, ["--whole-tree", "--mode", "publication"], key="KEY-A")
    _, o3, _ = run(root, ["--whole-tree", "--mode", "publication"], key="KEY-B")
    def fp(o):
        for tok in o.split():
            if tok.startswith("fp="):
                return tok
        return None
    check(fp(o1) and fp(o1) == fp(o2), "fingerprint stable for same token+key")
    check(fp(o1) and fp(o3) and fp(o1) != fp(o3), "different key => different fingerprint")


def test_fail_closed():
    print("test_fail_closed")
    root = make_repo({"f.txt": "nothing here\n"})
    rc, _, err = run(root, ["--whole-tree", "--mode", "publication"], denylist=None)
    check(rc == 2 and "FAIL_CLOSED" in err, "missing denylist => fail-closed in publication")
    rc, _, err = run(root, ["--whole-tree", "--mode", "publication"], denylist="# only comments\n")
    check(rc == 2 and "FAIL_CLOSED" in err, "empty denylist => fail-closed")
    rc, _, err = run(root, ["--whole-tree", "--mode", "publication"], denylist="not-an-ip-or-id\n")
    check(rc == 2 and "FAIL_CLOSED" in err, "malformed denylist => fail-closed")
    rc, _, err = run(root, ["--whole-tree", "--mode", "publication"], key=None)
    check(rc == 2 and "FAIL_CLOSED" in err, "missing fingerprint key => fail-closed in publication")
    rc, out, _ = run(root, ["--whole-tree", "--mode", "advisory"], denylist=None)
    check(rc == 0 and "NOT_RUN" in out, "advisory mode with no denylist => NOT_RUN exit 0")


def test_clean_pass_and_false_positive_controls():
    print("test_clean_pass_and_false_positive_controls")
    content = "release v1.226.0\nrpm 4.16\ndoc 192.0.2.5\nresolver 8.8.8.8\nv6 2001:db8:9999::1\n"
    root = make_repo({"f.txt": content})
    rc, out, _ = run(root, ["--whole-tree", "--mode", "publication"])
    check(rc == 0 and "PRIVATE_GATE = PASS" in out, "clean tree passes; unrelated values not flagged", out)


def test_changed_lines_mode():
    print("test_changed_lines_mode")
    root = make_repo({"f.txt": "clean baseline\n"})
    base = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    open(os.path.join(root, "f.txt"), "a").write("added 198.51.100.23 line\n")
    subprocess.run(["git", "-C", root, "commit", "-aqm", "add"], check=True)
    rc, out, _ = run(root, ["--changed-lines", base, "--mode", "publication"])
    check(rc == 1 and "PRIVATE_IDENTIFIER" in out, "changed-lines flags a private id added in the diff")
    root2 = make_repo({"f.txt": "old 198.51.100.23 line\nkeep\n"})
    base2 = subprocess.run(["git", "-C", root2, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    open(os.path.join(root2, "f.txt"), "w").write("keep\n")
    subprocess.run(["git", "-C", root2, "commit", "-aqm", "rm"], check=True)
    rc, out, _ = run(root2, ["--changed-lines", base2, "--mode", "publication"])
    check(rc == 0, "changed-lines scans ADDED lines only (removal of a token does not fail)", out)
    # FAIL-CLOSED on a bad base: missing/blank, malformed, and unknown SHA must all exit 2.
    for label, bad in (("blank", ""), ("malformed", "not-a-sha"),
                       ("unknown-sha", "0" * 40)):
        rc, _, err = run(root, ["--changed-lines", bad, "--mode", "publication"])
        check(rc == 2, "changed-lines fail-closed on %s base" % label, "rc=%d %s" % (rc, err.strip()[:80]))


def test_scanner_source_canary():
    print("test_scanner_source_canary")
    scanner_src = open(os.path.join(HERE, "privacy-scan.py"), encoding="utf-8").read()
    tampered = scanner_src + "\n# canary example addr 198.51.100.23\n"
    root = make_repo({"scripts/ci/privacy-scan.py": tampered, "other.txt": "x\n"})
    rc, out, _ = run(root, ["--whole-tree", "--mode", "publication"])
    check(rc == 1 and "scripts/ci/privacy-scan.py" in out,
          "private gate detects a token injected into scanner source (no whole-file skip)")


def test_text_sources_mode():
    """Commit messages and PR title/body are as public as the tree.

    The 2026-08-14 incident put a real administrative identifier in a COMMIT
    MESSAGE while the tree was clean: --whole-tree could not see it and the gate
    passed on the surface that actually mattered. These arms prove the scanner
    now covers that surface, and that it can SEE a true positive there — an arm
    that only ever passes proves nothing.
    """
    print("test_text_sources_mode")
    root = make_repo({"a.txt": "nothing here\n"})
    d = tempfile.mkdtemp(prefix="pig-text-")

    # POSITIVE CONTROL: a denylisted identifier in commit-message-shaped text MUST be caught.
    leak = os.path.join(d, "commit-messages.txt")
    open(leak, "w").write("fix: the witness yielded %s on the affected host\n" % D4)
    rc, out, err = run(root, ["--text-sources", leak, "--mode", "publication"])
    check(rc == 1 and "BLOCKING" in out, "denylisted identifier in commit-message text => FAIL", err.strip())
    check(D4 not in out and D4 not in err, "raw identifier never echoed in diagnostics")

    # Documentation-range-only text MUST pass — the sanctioned fixture form.
    ok = os.path.join(d, "pr-body.txt")
    open(ok, "w").write("peer 192.0.2.50 and 203.0.113.9 and 2001:db8::1 are documentation ranges\n")
    rc, out, err = run(root, ["--text-sources", ok, "--mode", "publication"])
    check(rc == 0 and "PASS" in out, "documentation-range-only text => PASS", err.strip())

    # An EMPTY source is allowed (a PR body may legitimately be empty)...
    empty = os.path.join(d, "empty.txt")
    open(empty, "w").write("")
    rc, _, err = run(root, ["--text-sources", empty, "--mode", "publication"])
    check(rc == 0, "empty text source => PASS (an empty PR body is legitimate)", err.strip())

    # ...but a MISSING source is a coverage gap, never an empty pass.
    rc, _, err = run(root, ["--text-sources", os.path.join(d, "absent.txt"), "--mode", "publication"])
    check(rc == 2 and "FAIL_CLOSED" in err, "missing text source => FAIL_CLOSED, not a silent pass", err.strip())

    # Multiple sources: a leak in ANY one of them must fail the whole scan.
    rc, out, _ = run(root, ["--text-sources", ok, leak, "--mode", "publication"])
    check(rc == 1, "leak in the second of several sources still fails")


def test_fixture_identifier_policy():
    """PRODUCTION_IDENTIFIERS_IN_TEST_FIXTURES = FORBIDDEN.

    Planted-fixture proof: a fixture built from documentation ranges passes, and
    the same fixture carrying a denylisted production identifier fails. Without
    the failing half, a green scan would not distinguish 'clean' from 'blind'.
    """
    print("test_fixture_identifier_policy")
    clean = make_repo({"cli/lib/nftban/tests/x_test.sh":
                       "peer=192.0.2.50\nsrv=198.51.100.10\nv6=2001:db8::1\n"})
    rc, out, err = run(clean, ["--whole-tree", "--mode", "publication"])
    check(rc == 0 and "PASS" in out, "fixture using RFC 5737/3849 documentation ranges => PASS", err.strip())

    dirty = make_repo({"cli/lib/nftban/tests/x_test.sh":
                       "peer=%s\nsrv=198.51.100.10\n" % D4})
    rc, out, _ = run(dirty, ["--whole-tree", "--mode", "publication"])
    check(rc == 1 and "BLOCKING" in out, "fixture carrying a production identifier => FAIL")


def main():
    if not os.path.exists(GATE):
        sys.stderr.write("gate not found: %s\n" % GATE)
        return 2
    for t in (test_detection_forms, test_output_hygiene, test_hmac_fingerprint, test_fail_closed,
              test_clean_pass_and_false_positive_controls, test_changed_lines_mode,
              test_scanner_source_canary, test_text_sources_mode,
              test_fixture_identifier_policy):
        t()
    print()
    if _fail:
        print("PRIVATE_GATE_SELFTEST_FAIL (%d): %s" % (len(_fail), ", ".join(_fail)))
        return 1
    print("PRIVATE_GATE_SELFTEST_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
