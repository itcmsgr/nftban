#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""
Self-tests for scripts/ci/privacy-scan.py — focused on the v1.226.0 hardening that
closes the ESCAPED-DOT IPv4 bypass (a real dotted-quad written as a shell grep
pattern with backslash-escaped dots evaded the literal-dot detector).

ALL fixtures here are SYNTHETIC (RFC5737 documentation / RFC5771 doc-multicast /
private ranges / made-up deny patterns). No real operator identifier appears in
this file, and none is required to prove the gap is closed.

Run:  python3 scripts/ci/privacy-scan-selftest.py
Exit: 0 = all pass · 1 = a self-test failed · 2 = harness error.
"""
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
_spec = importlib.util.spec_from_file_location("privacy_scan", os.path.join(HERE, "privacy-scan.py"))
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)

BLOCKING = ps.RELEASE_BLOCKING_CATEGORIES
_fail = []


def check(cond, label, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label + ("" if cond else "  " + detail))
    if not cond:
        _fail.append(label)


def findings(line):
    return list(ps.scan_line(line, path="cli/lib/nftban/tests/example_test.sh"))


def ipv4_values(line):
    return [v for (k, v, c) in findings(line) if k == "IPV4"]


def blocking_findings(line):
    return [(k, v, c) for (k, v, c) in findings(line) if c in BLOCKING]


# ---- 1. de-escape normalization is data-only and correct ----------------------
def test_deescape():
    print("test_deescape_dots")
    check(ps.deescape_dots(r"^203\.0\.113\.5$") == "^203.0.113.5$", "single-backslash dots collapse")
    check(ps.deescape_dots(r'"203\\.0\\.113\\.5"') == '"203.0.113.5"', "double-backslash dots collapse")
    check(ps.deescape_dots("203.0.113.5") == "203.0.113.5", "unescaped text unchanged")
    check(ps.deescape_dots(r"\d{1,3}\.\d{1,3}") == r"\d{1,3}.\d{1,3}", "de-escape does not fabricate digits")


# ---- 2. detection: escaped dotted-quads are now visible to IPV4_RE -------------
# (Doc-range IPs are intentionally NOT yielded as findings — they are clean — so this
# asserts detection at the normalization+regex layer that feeds every classifier.)
def _detects(line):
    for src in (line, ps.deescape_dots(line)):
        if ps.IPV4_RE.search(src):
            return ps.IPV4_RE.search(src).group(0)
    return None


def test_escaped_detected():
    print("test_escaped_ipv4_detected")
    check(_detects(r"n=$(grep -c '^203\.0\.113\.5$')") == "203.0.113.5", "anchored escaped grep pattern detected")
    check(_detects(r'assert_not_contains "$X" "^198\.51\.100\.9"') == "198.51.100.9", "quoted escaped pattern detected")
    check(_detects(r'T=$(printf "%s" "$C" | grep -c "^203\\.0\\.113\\.5")') == "203.0.113.5", "double-escaped-in-grep detected")
    check(_detects("plain 203.0.113.5 here") == "203.0.113.5", "literal form still detected (no regression)")
    # and the raw literal-dot regex ALONE (pre-hardening behavior) would miss the escaped form:
    check(ps.IPV4_RE.search(r"^203\.0\.113\.5$") is None, "regression witness: raw regex misses escaped form")


# ---- 3. ESCAPED_IPV4_BYPASS_TEST: a deny-listed value blocks in escaped form ---
def test_deny_authority_escaped_bypass_closed():
    print("test_deny_authority_escaped_bypass_closed")
    saved = ps._PRIV_PATTERNS
    try:
        # synthetic 'forbidden' identifier (doc-multicast test range) — stands in for a
        # real operator IP the owner would list in the gitignored privacy-forbidden.txt.
        ps._PRIV_PATTERNS = [re.compile(r"233\.252\.0\.99")]
        forms = {
            "literal":        "x 233.252.0.99 x",
            "escaped":        r"grep '^233\.252\.0\.99$'",
            "double-escaped": r'grep "^233\\.252\\.0\\.99$"',
            "anchored":       r"[[ $(grep -c '^233\.252\.0\.99$') == 1 ]]",
            "quoted":         r'assert_not_contains "$X" "233\.252\.0\.99"',
            "heredoc-line":   r"233\.252\.0\.99",
        }
        for name, ln in forms.items():
            blk = blocking_findings(ln)
            hit = any(v == "233.252.0.99" and c == ps.REAL_OPERATOR_IDENTIFIER for (k, v, c) in blk)
            check(hit, "deny authority blocks form: %s" % name, "findings=%r" % blk)
        # documented boundary: whitespace/char-class obfuscation is NOT normalized
        blk = blocking_findings(r"233 . 252 . 0 . 99")
        check(not blk, "documented boundary: space-split obfuscation not normalized (out of scope)")
    finally:
        ps._PRIV_PATTERNS = saved


# ---- 4. precedence: deny beats allowlist / synthetic classification ------------
def test_deny_precedence_over_allowlist():
    print("test_deny_precedence_over_allowlist")
    saved = ps._PRIV_PATTERNS
    try:
        # deny-list a value that ALSO falls in the RFC5737 synthetic range: deny must win.
        ps._PRIV_PATTERNS = [re.compile(r"192\.0\.2\.7")]
        blk = blocking_findings(r"grep '^192\.0\.2\.7$'")
        hit = any(v == "192.0.2.7" and c == ps.REAL_OPERATOR_IDENTIFIER for (k, v, c) in blk)
        check(hit, "deny authority overrides synthetic classification (escaped)", "findings=%r" % blk)
    finally:
        ps._PRIV_PATTERNS = saved


# ---- 5. false-positive controls: none of these produce a BLOCKING finding ------
def test_false_positive_controls():
    print("test_false_positive_controls")
    cases = {
        "3-part version v1.226.0":        "release v1.226.0 shipped",
        "package version rpm 4.16":       "requires rpm >= 4.16 on el9",
        "4-part synthetic 1.2.3.4":       "example client 1.2.3.4 banned",
        "RFC5737 doc 192.0.2.5":          "fixture ip 192.0.2.5 added",
        "RFC5737 escaped 203\\.0\\.113":  r"grep '^203\.0\.113\.5$'",
        "well-known DNS 8.8.8.8":         "resolver 8.8.8.8 configured",
        "escaped regex metachar non-IP":  r"pattern \d{1,3}\.\d{1,3}\.\d{1,3}",
        "version-context dotted quad":    "version string 10.20.30.40 in changelog",
    }
    for name, ln in cases.items():
        blk = blocking_findings(ln)
        check(not blk, "no blocking finding: %s" % name, "unexpected=%r" % blk)


def test_no_whole_file_self_exemption():
    print("test_no_whole_file_self_exemption")
    # v1.226.0 defense-in-depth: the scanner and its self-tests must NOT be whole-file exempt.
    check("scripts/ci/privacy-scan.py" not in ps.SELF_TEST_FILES, "privacy-scan.py not whole-file exempt")
    check("scripts/ci/privacy-scan-selftest.py" not in ps.SELF_TEST_FILES, "privacy-scan-selftest.py not whole-file exempt")


def test_scanner_source_canary_generic():
    print("test_scanner_source_canary_generic")
    # A deny-listed token placed in the scanner's OWN source path must still block — i.e. the
    # classifier does not grant the scanner file a self-exemption (deny authority wins by path too).
    saved = ps._PRIV_PATTERNS
    try:
        import re as _re
        ps._PRIV_PATTERNS = [_re.compile(r"233\.252\.0\.42")]
        got = list(ps.scan_line(r"# canary example 233\.252\.0\.42", path="scripts/ci/privacy-scan.py"))
        blk = [c for (k, v, c) in got if c in BLOCKING]
        check(ps.REAL_OPERATOR_IDENTIFIER in blk,
              "deny-listed token in scanner-source path still blocks (no self-exemption)")
    finally:
        ps._PRIV_PATTERNS = saved


def main():
    for t in (test_deescape, test_escaped_detected,
              test_deny_authority_escaped_bypass_closed,
              test_deny_precedence_over_allowlist, test_false_positive_controls,
              test_no_whole_file_self_exemption, test_scanner_source_canary_generic):
        t()
    print()
    if _fail:
        print("PRIVACY_SELFTEST_FAIL (%d): %s" % (len(_fail), ", ".join(_fail)))
        return 1
    print("PRIVACY_SELFTEST_PASS (escaped-IPv4 bypass closed; no false positives)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
