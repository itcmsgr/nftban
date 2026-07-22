#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""
NFTBan private-identifier deny gate (v1.226.0 privacy defense-in-depth).

A SECOND, INDEPENDENT privacy control, deliberately separate from privacy-scan.py:
it has its OWN candidate-extraction and canonicalization (no shared detection/normalization
core with the primary scanner — common-mode failure prevention, control 12). Its job is to
prove that a set of KNOWN-REAL identifiers, supplied at runtime OUTSIDE the repository (a CI
secret or a maintainer-local file), does not appear anywhere in the scanned text — in any
literal, escaped, quoted, URL-encoded, or compressed/expanded form.

The private identifier set NEVER enters the repository, workflow YAML, logs, artifacts, cache
keys, job summaries, commit messages, or PR text. Diagnostics print only: path, line number,
identifier class, a redacted representation, and a short HMAC-keyed fingerprint — never the raw
token and never the full matching source line.

Inputs (all from the environment / outside the repo):
  NFTBAN_PRIVACY_DENYLIST_FILE  path to a file with one identifier per line (comments '#' ok)
  NFTBAN_PRIVACY_DENYLIST       inline denylist content (alternative to the file)
  NFTBAN_PRIVACY_FP_KEY         HMAC-SHA256 key for fingerprints (required in publication mode)

Modes:
  --mode publication   FAIL-CLOSED: missing/empty/malformed denylist or any scan error => exit 2.
  --mode advisory      untrusted context (secret may be absent): if no denylist is available,
                       emit an explicit NOT_RUN status and exit 0 (generic gates still block).

Scope:
  --whole-tree                  scan all tracked text files (includes the scanner's own source).
  --changed-lines BASE          scan only added lines of `git diff --unified=0 BASE...HEAD`.

Exit: 0 = clean (or advisory NOT_RUN) · 1 = a private identifier was found · 2 = fail-closed error.
"""
import argparse
import hashlib
import hmac
import ipaddress
import os
import re
import subprocess
import sys
import urllib.parse

# ---- INDEPENDENT candidate extraction (distinct implementation from privacy-scan.py) --------
# IPv4 as four 1-3 digit groups separated by a "dot-ish" separator that tolerates backslash and
# URL-escaping; IPv6 as runs of hex groups with ':' (optionally bracketed). These regexes are
# intentionally NOT imported from the primary scanner.
_SEP = r"(?:\\{1,2}\.|%2[eE]|\.)"          # '.', '\.', '\\.', '%2e'
_IPV4_CAND = re.compile(r"(?<![0-9A-Za-z])(\d{1,3})" + _SEP + r"(\d{1,3})" + _SEP +
                        r"(\d{1,3})" + _SEP + r"(\d{1,3})(?![0-9A-Za-z])")
_IPV6_CAND = re.compile(
    r"\[?("
    r"[0-9A-Fa-f:]*::[0-9A-Fa-f:]*"                                    # compressed (::) form FIRST
    r"|(?:[0-9A-Fa-f]{1,4}(?:\\{0,2}:|%3[aA]|:)){2,}[0-9A-Fa-f]{1,4}"  # else full form, 3+ groups
    r")\]?")


def _views(line):
    """Independent normalization: yield textual VIEWS of a line so escaped/encoded/quoted forms
    become visible. Data-only — never executed, sourced, or compiled as a regex/command."""
    seen = []
    def add(s):
        if s not in seen:
            seen.append(s)
    add(line)
    # collapse backslash-escapes of dot and colon
    add(re.sub(r"\\{1,2}([.:])", r"\1", line))
    # strip one layer of surrounding quotes token-wise
    add(re.sub(r"[\"']", "", line))
    # URL-decode (%2e -> .) — bounded single pass, no recursion
    try:
        add(urllib.parse.unquote(line))
    except Exception:
        pass
    # JSON-ish: turn \\ into \ then collapse escaped dot/colon again
    add(re.sub(r"\\{1,2}([.:])", r"\1", line.replace("\\\\", "\\")))
    return seen


def canon_ipv4(a, b, c, d):
    try:
        ip = ipaddress.IPv4Address("%d.%d.%d.%d" % (int(a), int(b), int(c), int(d)))
        return str(ip)
    except Exception:
        return None


def canon_ipv6(tok):
    t = tok.strip("[]")
    t = re.sub(r"\\{1,2}:", ":", t)
    t = urllib.parse.unquote(t)
    if t.count(":") < 2:
        return None
    try:
        return str(ipaddress.IPv6Address(t))       # compressed, lowercase canonical form
    except Exception:
        return None


def candidates(line):
    """Return a set of canonical identifier strings found in the line, across all views."""
    out = set()
    for v in _views(line):
        for m in _IPV4_CAND.finditer(v):
            c = canon_ipv4(*m.groups())
            if c:
                out.add(c)
        for m in _IPV6_CAND.finditer(v):
            c = canon_ipv6(m.group(1))
            if c:
                out.add(c)
    return out


# ---- denylist (secret-provided, canonicalized in memory) ------------------------------------
def load_denylist():
    """Return (canon_set, source) or (None, reason). Never echoes any value."""
    raw = None
    f = os.environ.get("NFTBAN_PRIVACY_DENYLIST_FILE")
    if f:
        if not os.path.isfile(f):
            return None, "denylist file not found"
        try:
            raw = open(f, "r", encoding="utf-8").read()
        except OSError:
            return None, "denylist file unreadable"
    elif os.environ.get("NFTBAN_PRIVACY_DENYLIST") is not None:
        raw = os.environ["NFTBAN_PRIVACY_DENYLIST"]
    else:
        return None, "no denylist provided"
    canon = set()
    malformed = 0
    for ln in raw.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        c = None
        try:
            a = ipaddress.ip_address(s)
            c = str(a)
        except ValueError:
            # accept a bare dotted/again-canonicalizable token
            got = candidates(s)
            if len(got) == 1:
                c = next(iter(got))
        if c:
            canon.add(c)
        else:
            malformed += 1
    if malformed:
        return None, "denylist contains %d malformed entr%s" % (malformed, "y" if malformed == 1 else "ies")
    if not canon:
        return None, "denylist is empty"
    return canon, "loaded"


def fingerprint(canon_value):
    key = os.environ.get("NFTBAN_PRIVACY_FP_KEY", "").encode()
    if not key:
        return "nokey"
    return hmac.new(key, canon_value.encode(), hashlib.sha256).hexdigest()[:12]


def redact(canon_value):
    if ":" in canon_value:
        head = canon_value.split(":")[0]
        return head + ":<redacted-ipv6>"
    parts = canon_value.split(".")
    return ".".join(parts[:2] + ["x", "x"]) if len(parts) == 4 else "<redacted>"


def klass(canon_value):
    return "IPV6" if ":" in canon_value else "IPV4"


# ---- file enumeration (a harmless shared-style utility; NOT detection) -----------------------
def repo_root():
    return subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip()


def tracked_text_files(root):
    out = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True).stdout.split("\n")
    bin_ext = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".ico", ".mmdb",
               ".tar", ".gz", ".zip", ".woff", ".woff2", ".ttf"}
    files = []
    for rel in out:
        if not rel:
            continue
        if os.path.splitext(rel)[1].lower() in bin_ext:
            continue
        p = os.path.join(root, rel)
        try:
            with open(p, "rb") as fh:
                if b"\x00" in fh.read(8192):
                    continue
        except OSError:
            continue
        files.append(rel)
    return files


def scan_whole_tree(root, deny):
    hits = []
    for rel in tracked_text_files(root):
        try:
            with open(os.path.join(root, rel), "r", encoding="utf-8", errors="ignore") as fh:
                for n, line in enumerate(fh, 1):
                    for c in candidates(line) & deny:
                        hits.append((rel, n, c))
        except OSError:
            # a file we enumerated but cannot read is a coverage gap in publication mode
            raise
    return hits


def scan_changed_lines(root, base, deny):
    diff = subprocess.run(["git", "diff", "--unified=0", "%s...HEAD" % base],
                          cwd=root, capture_output=True, text=True)
    if diff.returncode != 0:
        raise RuntimeError("git diff failed for base %r" % base)
    hits = []
    cur = None
    lineno = 0
    hunk = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
    for ln in diff.stdout.split("\n"):
        if ln.startswith("+++ b/"):
            cur = ln[6:]
            continue
        m = hunk.match(ln)
        if m:
            lineno = int(m.group(1))
            continue
        if ln.startswith("+") and not ln.startswith("+++"):
            for c in candidates(ln[1:]) & deny:
                hits.append((cur, lineno, c))
            lineno += 1
    return hits


def main():
    ap = argparse.ArgumentParser(description="NFTBan private-identifier deny gate (independent).")
    ap.add_argument("--mode", choices=["publication", "advisory"], default="advisory")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--whole-tree", action="store_true")
    g.add_argument("--changed-lines", metavar="BASE")
    ap.add_argument("--selftest-root", help=argparse.SUPPRESS)  # internal: scan an alt tree
    args = ap.parse_args()

    deny, why = load_denylist()
    if deny is None:
        if args.mode == "publication":
            sys.stderr.write("PRIVATE_GATE = FAIL_CLOSED (%s) in publication mode\n" % why)
            return 2
        print("PRIVATE_GATE = NOT_RUN (%s); generic gates remain blocking" % why)
        return 0
    if args.mode == "publication" and not os.environ.get("NFTBAN_PRIVACY_FP_KEY"):
        sys.stderr.write("PRIVATE_GATE = FAIL_CLOSED (no NFTBAN_PRIVACY_FP_KEY) in publication mode\n")
        return 2

    root = args.selftest_root or repo_root()
    if not root:
        sys.stderr.write("PRIVATE_GATE = FAIL_CLOSED (not in a git repository)\n")
        return 2
    try:
        hits = scan_whole_tree(root, deny) if args.whole_tree else scan_changed_lines(root, args.changed_lines, deny)
    except Exception as e:
        # never let the exception body echo a value
        sys.stderr.write("PRIVATE_GATE = FAIL_CLOSED (scan error: %s)\n" % type(e).__name__)
        return 2 if args.mode == "publication" else 1

    if hits:
        for rel, n, c in hits:
            print("%s:%s: PRIVATE_IDENTIFIER %s %s fp=%s [BLOCKING]" %
                  (rel, n, klass(c), redact(c), fingerprint(c)))
        sys.stderr.write("PRIVATE_GATE = FAIL (%d private-identifier occurrence(s))\n" % len(hits))
        return 1
    print("PRIVATE_GATE = PASS (denylist=%d canonical entries; 0 occurrences)" % len(deny))
    return 0


if __name__ == "__main__":
    sys.exit(main())
