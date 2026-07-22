#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan privacy / infrastructure-disclosure scanner (SEC-INFRA dual-scope)
# =============================================================================
# Two explicit enforcement tiers (GO_IMPLEMENT_SEC_INFRA_DUAL_SCOPE_PRIVACY_GATES):
#
#   --scope release   → Gate A. The publication surface: files a user RECEIVES
#                       or READS (binary-package payload + compiled-in source +
#                       public docs), enumerated from the authoritative
#                       `scripts/ci/release-surface.txt` manifest. With --strict
#                       this is a BLOCKING gate: exit 1 on any UNAPPROVED REAL
#                       identifier reaching users. It answers: "Can this release
#                       expose an unapproved real identifier?"
#
#   --scope repository → Gate B. The full tracked tree, ADVISORY (--report exits
#                       0). It answers: "What privacy debt or ambiguous
#                       public-looking data remains anywhere in dev/tests/history?"
#                       Findings are CLASSIFIED, never silently excluded.
#
# Every finding is classified into exactly one category. The release gate blocks
# ONLY on REAL_OPERATOR_IDENTIFIER and SHIPPED_PUBLIC_SURFACE — a synthetic
# attacker/example IP in a test fixture is NOT equivalent to publishing an
# operator IP, hostname, management address, private domain, or personal path.
#
# IPs are classified with the stdlib `ipaddress` module (NOT regex alone) so that
# reserved documentation ranges and approved public infrastructure are allowed
# and only genuinely-unknown public addresses can reach SHIPPED_PUBLIC_SURFACE.
# Findings are REDACTED by default: "<path>:<line> <CATEGORY> <KIND> <redacted>";
# --show prints raw matches and is LOCAL-ONLY (never in CI logs).
#
# Exit code 0 = pass (or advisory), 1 = blocking findings, 2 = usage/error.
# =============================================================================
import argparse
import ipaddress
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

# --- Categories -------------------------------------------------------------
REAL_OPERATOR_IDENTIFIER = "REAL_OPERATOR_IDENTIFIER"
SHIPPED_PUBLIC_SURFACE = "SHIPPED_PUBLIC_SURFACE"
TEST_FIXTURE_SYNTHETIC_IP = "TEST_FIXTURE_SYNTHETIC_IP"
PSEUDONYMOUS_DEV_PATH = "PSEUDONYMOUS_DEV_PATH"
HISTORICAL_DOCUMENTATION = "HISTORICAL_DOCUMENTATION"
SCANNER_SELF_TEST = "SCANNER_SELF_TEST"
INTENTIONALLY_DEFERRED_PRIVATE_TOOLING = "INTENTIONALLY_DEFERRED_PRIVATE_TOOLING"
APPROVED_PUBLIC_INFRASTRUCTURE = "APPROVED_PUBLIC_INFRASTRUCTURE"

ALL_CATEGORIES = [
    REAL_OPERATOR_IDENTIFIER, SHIPPED_PUBLIC_SURFACE, TEST_FIXTURE_SYNTHETIC_IP,
    PSEUDONYMOUS_DEV_PATH, HISTORICAL_DOCUMENTATION, SCANNER_SELF_TEST,
    INTENTIONALLY_DEFERRED_PRIVATE_TOOLING, APPROVED_PUBLIC_INFRASTRUCTURE,
]
# The release gate (Gate A) blocks on exactly these — an unapproved REAL
# identifier that reaches users. Everything else is classified but advisory.
RELEASE_BLOCKING_CATEGORIES = {REAL_OPERATOR_IDENTIFIER, SHIPPED_PUBLIC_SURFACE}

# =============================================================================
# ALLOWLIST REVIEW (SEC-INFRA — security-sensitive; keep bounded + documented)
# =============================================================================
# Every allowlist entry below is a bounded value or CIDR (never a bare wildcard
# like 1.2.3.* / *.gr / "public IPv4"). Version-string false positives are handled
# by the VERSION_CONTEXT_RE parsing rule, NOT by approving numbers as IPs.
#
# group / value           | category                       | why                                   | file classes            | scope
# ------------------------|--------------------------------|---------------------------------------|-------------------------|--------------
# ALLOWED_NETS (RFC5737/  | (silent — not a finding)       | reserved documentation ranges; the    | any                     | release+repo+
#   RFC3849)              |                                | correct value for shipped examples    |                         | staging
# APPROVED_INFRA_NETS     | APPROVED_PUBLIC_INFRASTRUCTURE | well-known resolver/CDN anycast that   | product data (well-     | release+repo+
#   (Cloudflare/Google/   |                                | is legitimate PRODUCT data, not        | known.sh, whitelist     | staging
#   Quad9/OpenDNS/        |                                | operator infra                        | examples, tests)        |
#   Googlebot)            |                                |                                       |                         |
# PLACEHOLDER_NETS        | TEST_FIXTURE_SYNTHETIC_IP      | NFTBan's pervasive synthetic example  | help/usage/docs/worked  | release+repo+
#   (1.2.3/4.3.2/5.6.7/   |                                | convention; 1.2.3.0/24 is also the    | examples + tests; NOT   | staging
#   9.10.11/7.7.7 /24)    |                                | product's "public CIDR" test value    | operator config         |
#                         |                                | (RFC5737 can't be used because the    |                         |
#                         |                                | product classifies doc-ranges as      |                         |
#                         |                                | NON-bannable)                         |                         |
#
# SAFETY: none of these can MASK an operator identifier — (1) the ranges are
# disjoint from real operator space; (2) a known-real value in privacy-forbidden.txt
# is REAL_OPERATOR_IDENTIFIER and takes precedence over every allowlist; (3) every
# allowlisted hit is still CLASSIFIED and COUNTED in the report (never silently
# dropped), so the debt stays visible. Fully retiring the 1.2.3.x convention across
# ~130 shipped call sites is a separate, larger lane (many sites are classifier-
# sensitive Go code where doc-ranges would change runtime behaviour).
# --- Allowlists -------------------------------------------------------------
# Reserved documentation ranges (RFC 5737 / RFC 3849) — always allowed.
ALLOWED_NETS = {
    "192.0.2.0/24":   "RFC 5737 TEST-NET-1 documentation range",
    "198.51.100.0/24": "RFC 5737 TEST-NET-2 documentation range",
    "203.0.113.0/24": "RFC 5737 TEST-NET-3 documentation range",
    "2001:db8::/32":  "RFC 3849 IPv6 documentation range",
}
# Approved public infrastructure explicitly referenced as legitimate product
# data (well-known resolvers/anycast; the nftban_well_known.sh reference file;
# whitelist examples). Real, but NOT operator infra — APPROVED_PUBLIC_INFRASTRUCTURE.
APPROVED_INFRA_NETS = {
    "1.1.1.0/24":     "Cloudflare public resolver anycast",
    "1.0.0.0/24":     "Cloudflare public resolver anycast (1.0.0.1)",
    "8.8.8.0/24":     "Google Public DNS anycast",
    "8.8.4.0/24":     "Google Public DNS anycast (8.8.4.4)",
    "9.9.9.0/24":     "Quad9 public resolver anycast",
    "149.112.112.0/24": "Quad9 secondary resolver anycast",
    "208.67.220.0/22": "OpenDNS public resolver anycast",
    "104.16.0.0/12":  "Cloudflare edge range (whitelist example)",
    "66.249.64.0/19": "Googlebot crawler range (verified-crawler / botguard example)",
    "2606:4700::/32": "Cloudflare public resolver / edge (IPv6)",
    "2001:4860:4860::/48": "Google Public DNS (IPv6)",
    "2620:fe::/48":   "Quad9 public resolver (IPv6)",
    "2620:119::/32":  "OpenDNS public resolver range (IPv6; 2620:119:35::35 / :53::53)",
}
# Canonical synthetic placeholders conventionally used in help/usage text and
# worked examples. Globally routable but universally understood as stand-ins,
# never a real operator address — classify TEST_FIXTURE_SYNTHETIC_IP.
PLACEHOLDER_NETS = {
    "1.2.3.0/24":    "canonical synthetic placeholder block (help/usage/worked examples)",
    "4.3.2.0/24":    "synthetic reversed-placeholder block (RBL/reverse examples)",
    "5.6.7.0/24":    "synthetic placeholder block (paired with 1.2.3.x examples)",
    "9.10.11.0/24":  "synthetic placeholder block (9.10.11.12 example)",
    "7.7.7.0/24":    "synthetic placeholder block (interval-math examples)",
}
_ALLOWED_NET_OBJS = [(ipaddress.ip_network(n), r) for n, r in
                     {**ALLOWED_NETS, **APPROVED_INFRA_NETS}.items()]
_PLACEHOLDER_NET_OBJS = [(ipaddress.ip_network(n), r)
                         for n, r in PLACEHOLDER_NETS.items()]

# CONTEXT rule (NOT an IP allowlist): a dotted-quad that the IPv4 regex matches
# is treated as a software VERSION string — not an address — when its line is
# unambiguously a version context (product name + version, or version-argument
# validation prose). This handles false positives by PARSING CONTEXT rather than
# by approving specific numbers as if they were real IPs, so a genuinely real IP
# is never globally excused; it is only reinterpreted on a version-context line.
VERSION_CONTEXT_RE = re.compile(
    r"(?i)\b(cpanel|plesk|almalinux|directadmin|cloudlinux|semver|"
    r"pre-release|release[- ]tag|update\s+github|strict\s+regex|"
    r"version[- ]?(string|arg|argument|tag|number)|rejects?\b)")

# --- Detectors --------------------------------------------------------------
# Forbidden host stems (word-boundary). Generic naming scheme only — NOT a
# secret. Real operator hostnames are caught by the GENERIC domain detector
# (any non-allowlisted FQDN) or the gitignored private-pattern file.
FORBIDDEN_HOST_RE = re.compile(r"\b(dns[1-4]|srv[1-4])\b", re.IGNORECASE)
DOMAIN_RE = re.compile(
    r"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+"
    r"(?:gr|com|net|org|io|cloud|dev|local|test|gov|edu|eu|co|de|uk)\b",
    re.IGNORECASE)
IPV4_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
IPV6_RE = re.compile(r"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])")

# Backslash-escaped-dot normalization (v1.226.0 privacy hotfix). Shell grep patterns
# write dotted-quads with escaped dots (e.g. ^62\.38\.150\.122$ or "62\\.38\\.150\\.122"),
# which the literal-dot IPV4_RE cannot see — a confirmed blocking-gate bypass. We collapse
# one-or-more backslashes before a dot to a single literal dot and re-scan a COPY of the
# line for detection only. This is DATA-ONLY: the normalized text is never executed,
# sourced, or compiled as a regex/command — it is fed only to the same read-only detectors.
_ESCAPED_DOT_RE = re.compile(r"\\+\.")


def deescape_dots(s):
    """Detection-only: `\\.`/`\\\\.` -> `.` so escaped dotted-quads are visible to IPV4_RE.
    Never used to execute or reinterpret the string; purely to widen text detection."""
    return _ESCAPED_DOT_RE.sub(".", s)
# Real operator personal identity (username/name). gituser/commonfolder are
# PSEUDONYMOUS dev accounts (separate, lower category); avoulvou* is the real
# maintainer identity and is a REAL_OPERATOR_IDENTIFIER wherever it appears.
REAL_IDENTITY_RE = re.compile(r"/home/avoulvou\w*\b|\bavoulvou(lis)?\b", re.IGNORECASE)
PSEUDONYMOUS_PATH_RE = re.compile(r"/home/(?:gituser|commonfolder)\b", re.IGNORECASE)
PERSONAL_PATH_RE = re.compile(
    r"/home/(?:gituser|commonfolder|avoulvou\w*)\b|\bavoulvou(lis)?\b", re.IGNORECASE)

ALLOWED_DOMAINS = {
    "example.com", "example.net", "example.org", "example.test",
    "localhost", "nftban.com", "github.com", "raw.githubusercontent.com",
    "schemas.nftban.com",
    # itcms.gr = the project's DELIBERATE public security/legal contact domain
    # (security@itcms.gr / legal@itcms.gr in SECURITY.md, MAINTAINERS, CHANGELOG).
    # Intentional published contact — NOT private infrastructure; kept, not scrubbed.
    "itcms.gr",
}
ALLOWED_DOMAIN_SUFFIXES = (".example.test", ".example.com", ".example.net",
                           ".example.org", ".nftban.com")

# Optional PRIVATE, gitignored exact-pattern file (one regex/literal per line).
# Lets the owner add exact private hostnames/IPs WITHOUT committing the secret.
# Any match here is a KNOWN-REAL identifier → REAL_OPERATOR_IDENTIFIER (BLOCKING).
_PRIV_PATTERNS = []
_priv_file = os.path.join(HERE, "privacy-forbidden.txt")
if os.path.exists(_priv_file):
    with open(_priv_file, "r", encoding="utf-8", errors="ignore") as _pf:
        for _ln in _pf:
            _ln = _ln.strip()
            if _ln and not _ln.startswith("#"):
                try:
                    _PRIV_PATTERNS.append(re.compile(_ln, re.IGNORECASE))
                except re.error:
                    pass

BINARY_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".ico",
              ".mmdb", ".tar", ".gz", ".zip", ".woff", ".woff2", ".ttf"}

# Files whose PURPOSE is to detect/guard these very patterns: the string literals
# they contain are SEARCH PATTERNS, not leaks (same rationale as the old SELF_SKIP).
SELF_TEST_FILES = {
    "scripts/ci/privacy-scan.py":
        "the scanner itself defines the detection patterns",
    "scripts/ci/release-surface.txt":
        "release-surface manifest (path globs, not identifiers)",
    "scripts/ci/privacy-forbidden.txt":
        "gitignored private-pattern file (never committed)",
    "scripts/ci/hooks/pre-commit-privacy":
        "Guard-1 hook wraps the scanner",
    "cli/lib/nftban/tests/nftban_config_rhg_cosmetic_r1a6_test.sh":
        "guard test greps for /home/commonfolder to assert its ABSENCE from CI scripts",
    "cli/lib/nftban/tests/support_bundle_redaction_test.sh":
        "Guard-7 support-bundle redaction test (synthetic sensitive fixtures)",
}
# Product-config / provider paths where real third-party service domains are
# LEGITIMATE (RBL zones, feed source URLs, trust providers) — domain check off.
PRODUCT_DOMAIN_SKIP = (
    "etc/nftban/conf.d/", "install/config/", "cli/lib/nftban/core/nftban_rbl",
    "cmd/nftban-core/cmd_trust", "internal/feeds/", "internal/rbl",
)
# Public documents whose historical prose legitimately QUOTES past identifiers /
# cleanup gates — pseudonymous/example content here is HISTORICAL_DOCUMENTATION.
HISTORICAL_DOC_FILES = {"CHANGELOG.md", "STATUS.md"}


def _load_globs(path):
    globs = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for ln in fh:
                ln = ln.strip()
                if ln and not ln.startswith("#"):
                    globs.append(ln)
    except OSError:
        pass
    return globs


def _glob_to_re(g):
    out, i, n = ["^"], 0, len(g)
    while i < n:
        c = g[i]
        if c == "*":
            if i + 1 < n and g[i + 1] == "*":
                out.append(".*")
                i += 2
                if i < n and g[i] == "/":
                    i += 1
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    out.append("$")
    return re.compile("".join(out))


_RELEASE_GLOBS = [_glob_to_re(g) for g in
                  _load_globs(os.path.join(HERE, "release-surface.txt"))]


def in_release_surface(path):
    return any(rx.match(path) for rx in _RELEASE_GLOBS)


def is_test_path(path):
    return bool(re.search(
        r"(^|/)(tests?|testdata|fixtures)(/)|_test\.(go|sh)$", path))


def is_claude_path(path):
    return path.startswith(".claude/")


def domain_allowed(dom):
    dom = dom.lower().rstrip(".")
    if dom in ALLOWED_DOMAINS:
        return True
    return any(dom.endswith(sfx) for sfx in ALLOWED_DOMAIN_SUFFIXES)


def _priv_match(value):
    return any(p.search(value) for p in _PRIV_PATTERNS)


def ip_class(text):
    """Return (is_finding, category_hint) for an IP literal.

    category_hint is one of: None (allowlisted, not a finding),
    'APPROVED' (approved public infra — reportable but not blocking),
    'PLACEHOLDER' (synthetic placeholder), or 'PUBLIC' (unknown real public IP).
    """
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return (False, None)
    if not ip.is_global or ip.is_multicast:
        return (False, None)
    # IPv6 detector hygiene: drop IPv4-mapped/compat artifacts (`::ffff:8`,
    # `::ffff:a`) whose embedded v4 isn't global, and tiny `::x` fragments
    # (`::10`) — these are code/regex artifacts, not real routable addresses.
    if ip.version == 6:
        mapped = getattr(ip, "ipv4_mapped", None)
        if mapped is not None and not mapped.is_global:
            return (False, None)
        if int(ip) < (1 << 32):
            return (False, None)
        # Global unicast is 2000::/3 → the leading hextet is always >=3 hex
        # digits. A match whose largest hextet is <3 digits (`f::A1`, `a::b`)
        # is a code/annotation artifact, not a real address.
        if max((len(h) for h in text.split(":") if h), default=0) < 3:
            return (False, None)
    for net, _reason in _PLACEHOLDER_NET_OBJS:
        if ip.version == net.version and ip in net:
            return (True, "PLACEHOLDER")
    for net, _reason in _ALLOWED_NET_OBJS:
        if ip.version == net.version and ip in net:
            # RFC doc ranges are silent (never findings); approved infra is a
            # reportable APPROVED finding.
            if str(net) in ALLOWED_NETS:
                return (False, None)
            return (True, "APPROVED")
    return (True, "PUBLIC")


def classify(kind, value, path, ip_hint=None):
    # Known-real identifiers win over any context.
    if _priv_match(value):
        return REAL_OPERATOR_IDENTIFIER
    if kind == "PATH":
        if REAL_IDENTITY_RE.search(value):
            return REAL_OPERATOR_IDENTIFIER
        if path in SELF_TEST_FILES:
            return SCANNER_SELF_TEST
        if is_claude_path(path):
            return INTENTIONALLY_DEFERRED_PRIVATE_TOOLING
        if path in HISTORICAL_DOC_FILES:
            return HISTORICAL_DOCUMENTATION
        return PSEUDONYMOUS_DEV_PATH
    if kind in ("IPV4", "IPV6"):
        if ip_hint == "APPROVED":
            return APPROVED_PUBLIC_INFRASTRUCTURE
        if ip_hint == "PLACEHOLDER":
            return TEST_FIXTURE_SYNTHETIC_IP
        # ip_hint == "PUBLIC" (unknown real public IP)
        if path in SELF_TEST_FILES:
            return SCANNER_SELF_TEST
        if is_test_path(path):
            return TEST_FIXTURE_SYNTHETIC_IP
        if path in HISTORICAL_DOC_FILES:
            return HISTORICAL_DOCUMENTATION
        return SHIPPED_PUBLIC_SURFACE
    # DOMAIN / HOST — advisory. Never release-blocking unless known-real (handled
    # above). Classify by context so it is not silently dropped.
    if path in SELF_TEST_FILES:
        return SCANNER_SELF_TEST
    if is_claude_path(path):
        return INTENTIONALLY_DEFERRED_PRIVATE_TOOLING
    if path in HISTORICAL_DOC_FILES:
        return HISTORICAL_DOCUMENTATION
    return APPROVED_PUBLIC_INFRASTRUCTURE


def redact(kind, value):
    if kind.startswith("IP"):
        return "<REDACTED_" + kind + ">"
    if kind in ("DOMAIN", "HOST"):
        return "<REDACTED_HOST>"
    if kind == "PATH":
        return "<REDACTED_PATH>"
    return "<REDACTED>"


def scan_line(line, path=""):
    """Yield (kind, value, category) findings for one line."""
    # DENY AUTHORITY FIRST — a privacy-forbidden.txt hit is ALWAYS a
    # REAL_OPERATOR_IDENTIFIER (BLOCKING) and can never be excused by any
    # allowlist, doc-range, placeholder, or version-context rule. Values matched
    # here are skipped by the detectors below so they are not double-counted.
    denied = []
    # Deny authority is also escape-aware: a privacy-forbidden.txt entry for a real
    # identifier must catch its backslash-escaped grep-pattern form, not just the literal.
    _dn = deescape_dots(line)
    _deny_sources = (line,) if _dn == line else (line, _dn)
    _seen_deny = set()
    for pat in _PRIV_PATTERNS:
        for _s in _deny_sources:
            for m in pat.finditer(_s):
                g = m.group(0)
                if g in _seen_deny:
                    continue
                _seen_deny.add(g)
                denied.append(g)
                yield ("PRIVATE", g, REAL_OPERATOR_IDENTIFIER)
    if not any(path.startswith(p) or p in path for p in PRODUCT_DOMAIN_SKIP):
        for m in DOMAIN_RE.finditer(line):
            if m.group(0) in denied:
                continue
            if not domain_allowed(m.group(0)):
                yield ("DOMAIN", m.group(0), classify("DOMAIN", m.group(0), path))
    for m in FORBIDDEN_HOST_RE.finditer(line):
        if m.group(0) in denied:
            continue
        yield ("HOST", m.group(0), classify("HOST", m.group(0), path))
    for m in PERSONAL_PATH_RE.finditer(line):
        if m.group(0) in denied:
            continue
        yield ("PATH", m.group(0), classify("PATH", m.group(0), path))
    version_ctx = bool(VERSION_CONTEXT_RE.search(line))
    # Scan the raw line AND a detection-only de-escaped copy, so escaped-dot dotted-quads
    # inside grep patterns cannot bypass the gate. Dedup by value so an unescaped IP that
    # also survives normalization is reported once.
    _sources = [line]
    _norm = deescape_dots(line)
    if _norm != line:
        _sources.append(_norm)
    _seen_ipv4 = set()
    for _src in _sources:
        for m in IPV4_RE.finditer(_src):
            v = m.group(0)
            if v in _seen_ipv4:
                continue
            _seen_ipv4.add(v)
            if v in denied:
                continue
            # Version-context reinterpretation: excuse a dotted-quad only when the
            # line is a version context AND the value is not a known-real identifier
            # (a real operator IP is never excused by context).
            if version_ctx and not _priv_match(v):
                continue
            finding, hint = ip_class(v)
            if finding:
                yield ("IPV4", v, classify("IPV4", v, path, hint))
    for m in IPV6_RE.finditer(line):
        v = m.group(0)
        if v in denied or v.count(":") < 2:
            continue
        finding, hint = ip_class(v)
        if finding:
            yield ("IPV6", v, classify("IPV6", v, path, hint))


def looks_binary(path):
    """True for a non-text file (ELF binaries, images, archives). Extensionless
    compiled binaries in a staging tree must not be scanned as text."""
    try:
        with open(path, "rb") as fh:
            return b"\x00" in fh.read(8192)
    except OSError:
        return True


def tracked_files():
    out = subprocess.run(["git", "-C", REPO, "ls-files"],
                         capture_output=True, text=True)
    return out.stdout.splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scope", choices=("release", "repository", "staging"),
                    default="repository",
                    help="release = publication surface from the source manifest "
                         "(blocking with --strict); repository = full tree "
                         "(advisory with --report); staging = a concrete built "
                         "package-staging filesystem under --root (blocking)")
    ap.add_argument("--root",
                    help="scope=staging: the built staging filesystem root to scan "
                         "(e.g. the DEB deb_root or the RPM %%{buildroot}). Every "
                         "file beneath it is treated as shipped payload.")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on release-blocking categories "
                         "(REAL_OPERATOR_IDENTIFIER / SHIPPED_PUBLIC_SURFACE)")
    ap.add_argument("--report", action="store_true",
                    help="advisory: always exit 0; print categorized findings")
    ap.add_argument("--show", action="store_true",
                    help="print raw matches (LOCAL ONLY, never in CI logs)")
    ap.add_argument("--paths", nargs="*", help="limit to these paths")
    args = ap.parse_args()

    staging_root = None
    if args.scope == "staging":
        if not args.root or not os.path.isdir(args.root):
            print("scope=staging requires --root <existing staging dir>",
                  file=sys.stderr)
            return 2
        staging_root = os.path.abspath(args.root)
        files = []
        for dp, _dns, fns in os.walk(staging_root):
            for fn in fns:
                files.append(os.path.join(dp, fn))
    elif args.paths:
        files = args.paths
    else:
        files = tracked_files()
        if args.scope == "release":
            # FAIL CLOSED: a blocking release gate must never run against an
            # empty/absent surface manifest (that would scan 0 files and pass).
            if not _RELEASE_GLOBS:
                print("scope=release: release-surface.txt missing or empty — "
                      "refusing to run a blocking gate over an undefined surface",
                      file=sys.stderr)
                return 2
            files = [f for f in files if in_release_surface(f)]

    by_cat = {c: 0 for c in ALL_CATEGORIES}
    total = 0
    blocking = 0
    read_errors = 0
    for f in files:
        if staging_root is not None:
            # Classify by the staged (installed) layout path, so shipped test
            # scripts under .../tests/ still classify as TEST_FIXTURE, etc.
            rel = os.path.relpath(f, staging_root)
        else:
            rel = os.path.relpath(f, REPO) if os.path.isabs(f) else f
        if os.path.splitext(rel)[1].lower() in BINARY_EXT:
            continue
        fpath = f if os.path.exists(f) else os.path.join(REPO, f)
        if looks_binary(fpath):
            continue
        try:
            with open(fpath, "r", encoding="utf-8", errors="ignore") as fh:
                for n, line in enumerate(fh, 1):
                    for kind, value, cat in scan_line(line, rel):
                        total += 1
                        by_cat[cat] += 1
                        is_block = cat in RELEASE_BLOCKING_CATEGORIES
                        if is_block:
                            blocking += 1
                        shown = value if args.show else redact(kind, value)
                        flag = " [BLOCKING]" if is_block else ""
                        print(f"{rel}:{n}: {cat} {kind} {shown}{flag}")
        except IsADirectoryError:
            continue
        except OSError:
            # A file we enumerated but cannot read is a coverage gap, not a pass.
            read_errors += 1

    print("---", file=sys.stderr)
    print(f"scope={args.scope}  files_scanned={len(files)}", file=sys.stderr)
    for c in ALL_CATEGORIES:
        if by_cat[c]:
            tag = " [BLOCKING]" if c in RELEASE_BLOCKING_CATEGORIES else " [advisory]"
            print(f"  {c}: {by_cat[c]}{tag}", file=sys.stderr)
    print(f"TOTAL findings: {total}  (release-blocking: {blocking})", file=sys.stderr)
    if read_errors:
        print(f"read_errors: {read_errors} (unreadable enumerated files)",
              file=sys.stderr)

    if args.report:
        return 0
    if args.strict:
        # FAIL CLOSED in blocking mode: any blocking finding OR any unreadable
        # file fails the gate.
        return 1 if (blocking or read_errors) else 0
    return 1 if (total or read_errors) else 0


if __name__ == "__main__":
    sys.exit(main())
