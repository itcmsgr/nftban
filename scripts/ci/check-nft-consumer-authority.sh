#!/usr/bin/env bash
# =============================================================================
# NFTBan - nft consumer execution authority guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-nft-consumer-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="v1.228.4 PR-1. Asserts that every shipped systemd unit which reaches nftables declares the execution authority it needs. libmnl opens an AF_NETLINK socket to read kernel state, so a unit that shells out to nft while its RestrictAddressFamilies omits AF_NETLINK fails with EAFNOSUPPORT before nft parses its arguments - and, because the probes discard stderr, that surfaced as a false 'firewall table absent' verdict on 11/11 measured hosts while systemd still reported Result=success. This guard reads build/nft-consumer-authority.yaml and cross-checks it against install/systemd/*.service. It rejects (a) a confirmed_consumer whose unit declares RestrictAddressFamilies without AF_NETLINK, (b) an AF_NETLINK declaration on a no_nft_path_bounded_trace unit, (c) an unprivileged unit gaining CAP_NET_ADMIN without a recorded capability_decision, (d) inventory drift in either direction between the YAML and the shipped unit set. It deliberately does NOT apply the unnecessary-AF_NETLINK rule to unknown_external_executable units, whose absence of an nft path is untraceable rather than proven. Static analysis only - reads files, invokes nothing, contacts no host."
# meta:input="build/nft-consumer-authority.yaml, install/systemd/*.service"
# meta:output="PASS/FAIL per assertion; exit 0 on all-pass, 1 on any violation"
# meta:depends="bash,python3,grep"
# meta:inventory.files="build/nft-consumer-authority.yaml"
# meta:inventory.binaries="bash,python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="all units under install/systemd"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="check_nft_consumer_authority"
# meta:ta.owner="packaging"
# meta:ta.module="systemd-execution-authority"
# meta:ta.execution_class="CI_STATIC"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
AUTHORITY="$REPO/build/nft-consumer-authority.yaml"
UNIT_DIR="$REPO/install/systemd"

# -----------------------------------------------------------------------------
# PRE-FLIGHT: the authority must be real, TRACKED and parseable.
#
# AUTHORITY_FILE_TRACKED exists because build/ is gitignored (.gitignore:8) with
# only two negations. Every other tracked file under build/ was force-added, so a
# new authority file lives on disk, never appears in `git status`, and is silently
# omitted from the commit — a required CI gate would then read a local untracked
# file and PASS, while the committed repository has no authority at all.
# A required CI authority must never be satisfied by an ignored local file.
# -----------------------------------------------------------------------------
echo "=== 0. authority pre-flight ==="
[[ -d "$UNIT_DIR" ]] || { echo "  [FAIL] unit dir not found: $UNIT_DIR" >&2; exit 1; }

if [[ -f "$AUTHORITY" ]]; then
    echo "  [PASS] AUTHORITY_FILE_EXISTS"
else
    echo "  [FAIL] AUTHORITY_FILE_EXISTS — not found: $AUTHORITY" >&2; exit 1
fi

# Tracked-ness is only meaningful inside a git work tree. Outside one (e.g. an
# extracted tarball, or the synthetic copies the negative-control suite uses) the
# check is not applicable and is reported as such rather than silently skipped.
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$REPO" ls-files --error-unmatch -- "build/nft-consumer-authority.yaml" >/dev/null 2>&1; then
        echo "  [PASS] AUTHORITY_FILE_TRACKED"
    else
        echo "  [FAIL] AUTHORITY_FILE_TRACKED — present on disk but NOT tracked by git." >&2
        echo "         build/ is gitignored; the file must be force-added:" >&2
        echo "           git add -f build/nft-consumer-authority.yaml" >&2
        echo "         Until then the committed repository has no authority file and this" >&2
        echo "         gate is passing on a local artefact that CI will never see." >&2
        exit 1
    fi
else
    echo "  [N/A ] AUTHORITY_FILE_TRACKED — not inside a git work tree"
fi

if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$AUTHORITY" 2>/dev/null; then
    echo "  [PASS] AUTHORITY_FILE_PARSEABLE"
else
    echo "  [FAIL] AUTHORITY_FILE_PARSEABLE — YAML does not parse: $AUTHORITY" >&2; exit 1
fi

python3 - "$AUTHORITY" "$UNIT_DIR" <<'PY'
import sys, os, glob, re

try:
    import yaml
except ImportError:
    print("FAIL: python3 yaml module unavailable", file=sys.stderr)
    sys.exit(1)

authority_path, unit_dir = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(authority_path))

REQUIRED_FAMILY = doc.get("required_family", "AF_NETLINK")
units_decl      = {u["name"]: u for u in doc.get("units", [])}
already_auth    = set(doc.get("already_authorized", []))
unrestricted    = set(doc.get("unrestricted_by_design", []))

expected_open  = set(doc.get("expected_open_violations", []))
observed_open  = set()   # confirmed consumers currently missing the family

PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print(f"  [PASS] {m}")
def no(m, d):
    global FAIL; FAIL += 1; print(f"  [FAIL] {m}\n         {d}")

def read_unit(path):
    """Return (raf_declared, raf_value, ambient_caps, user). raf_declared
    distinguishes 'not declared' (systemd default = all families permitted, fine)
    from 'declared without AF_NETLINK' (the defect). Conflating those two is how
    the original inventory overcounted 8 units as 18."""
    raf_declared, raf, caps, user = False, "", "", ""
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("RestrictAddressFamilies="):
                raf_declared = True
                raf = s.split("=", 1)[1].strip()
            elif s.startswith("AmbientCapabilities="):
                caps = s.split("=", 1)[1].strip()
            elif s.startswith("User="):
                user = s.split("=", 1)[1].strip()
    return raf_declared, raf, caps, user

shipped = {os.path.basename(p): p for p in glob.glob(os.path.join(unit_dir, "*.service"))}

# ---------------------------------------------------------------- A. drift
print("=== A. inventory covers the shipped unit set ===")
classified = set(units_decl) | already_auth | unrestricted
missing = sorted(set(shipped) - classified)
if missing:
    no("A1 every shipped unit is classified in the authority file",
       "unclassified: " + ", ".join(missing) +
       " — add it to build/nft-consumer-authority.yaml with an evidence state")
else:
    ok(f"A1 every shipped unit is classified ({len(shipped)} units)")

# A blanket endswith("@.service") exemption let ANY templated name pass as a
# phantom: nftban-phantom@.service injected into already_authorized returned 0.
# Template units are matched by the *.service glob and ARE present in `shipped`
# (nftban-alert@.service is), so no exemption is warranted.
phantom = sorted(c for c in classified if c not in shipped)
if phantom:
    no("A2 authority file lists no unit that is not shipped",
       "listed but absent from install/systemd: " + ", ".join(phantom))
else:
    ok("A2 authority file lists no phantom unit")

# ------------------------------------------------- B. confirmed need AF_NETLINK
print(f"=== B. confirmed consumers declare {REQUIRED_FAMILY} ===")
for name, u in sorted(units_decl.items()):
    if u.get("state") != "confirmed_consumer":
        continue
    path = shipped.get(name)
    if not path:
        no(f"B1 {name} present in install/systemd", "unit file not found")
        continue
    declared, raf, _, _ = read_unit(path)
    if not declared:
        # No restriction at all -> every family permitted -> functionally fine.
        ok(f"B1 {name} unrestricted (no RestrictAddressFamilies) — nft reachable")
    elif REQUIRED_FAMILY in raf:
        ok(f"B1 {name} declares {REQUIRED_FAMILY}")
    else:
        observed_open.add(name)
        if name in expected_open:
            print(f"  [EXPECTED-OPEN] {name} missing {REQUIRED_FAMILY} "
                  f"(RestrictAddressFamilies={raf}) — declared baseline, PR-2 must close it")
        else:
            no(f"B1 {name} declares {REQUIRED_FAMILY}",
               f"RestrictAddressFamilies={raf} — this unit reaches nft ({u.get('evidence','')[:90]}...); "
               f"without {REQUIRED_FAMILY} libmnl fails EAFNOSUPPORT before nft parses its arguments")

# ------------------------ B2. already_authorized units must RETAIN the family
# These 7 are verified nft consumers whose grant predates this guard. The list was
# previously consumed ONLY by rule D, so stripping AF_NETLINK from any of them left
# the guard at rc=0 — the exact defect class this PR exists to prevent, across 7
# units. Enforce them here, independently of rule B.
print(f"=== B2. already_authorized units retain {REQUIRED_FAMILY} ===")
for name in sorted(already_auth):
    path = shipped.get(name)
    if not path:
        continue          # phantom membership is rule A2's job
    declared, raf, _, _ = read_unit(path)
    if not declared:
        ok(f"B2 {name} unrestricted — nft reachable")
    elif REQUIRED_FAMILY in raf:
        ok(f"B2 {name} retains {REQUIRED_FAMILY}")
    else:
        no(f"B2 {name} retains {REQUIRED_FAMILY}",
           f"RestrictAddressFamilies={raf} — this unit is declared already_authorized "
           f"(a verified nft consumer) and has LOST the family. Either restore it, or "
           f"reclassify the unit if it genuinely no longer reaches nft.")

# --------------------- B3. conditional_consumer has an enforced semantic ------
# Previously `conditional_consumer` appeared only in the VALID set, so a declared
# unit could escape enforcement purely by virtue of its class. nftban-report-daily
# was a silently unasserted SIXTH open unit.
print(f"=== B3. conditional consumers are enforced by activation ===")
for name, u in sorted(units_decl.items()):
    if u.get("state") != "conditional_consumer":
        continue
    act = u.get("activation")
    if act not in ("runtime_ordinary", "operator_action_required"):
        no(f"B3 {name} declares a valid activation",
           f"activation={act!r} — a conditional_consumer MUST declare "
           f"runtime_ordinary or operator_action_required; it may not escape "
           f"enforcement by virtue of its class")
        continue
    path = shipped.get(name)
    if not path:
        continue
    declared, raf, _, _ = read_unit(path)
    has_family = (not declared) or (REQUIRED_FAMILY in raf)
    if act == "operator_action_required":
        # May withhold the family ONLY when the omission is a recorded decision.
        if has_family or u.get("capability_decision"):
            ok(f"B3 {name} operator_action_required "
               f"({'has family' if has_family else 'omission recorded: ' + str(u.get('capability_decision'))})")
        else:
            no(f"B3 {name} operator_action_required omission is recorded",
               f"RestrictAddressFamilies={raf} lacks {REQUIRED_FAMILY} and there is no "
               f"capability_decision — an unrecorded omission is drift, not a decision")
    else:  # runtime_ordinary -> enforced exactly like confirmed_consumer
        if has_family:
            ok(f"B3 {name} runtime_ordinary retains {REQUIRED_FAMILY}")
        else:
            observed_open.add(name)
            if name in expected_open:
                print(f"  [EXPECTED-OPEN] {name} missing {REQUIRED_FAMILY} "
                      f"(runtime_ordinary conditional) — declared baseline, PR-2 must close it")
            else:
                no(f"B3 {name} runtime_ordinary retains {REQUIRED_FAMILY}",
                   f"RestrictAddressFamilies={raf} — activation=runtime_ordinary means the "
                   f"nft path is reachable with NO operator action, so the family is required")

# ------------------------------- C. no unnecessary AF_NETLINK on proven non-users
print(f"=== C. no unnecessary {REQUIRED_FAMILY} on bounded-trace non-consumers ===")
for name, u in sorted(units_decl.items()):
    if u.get("state") != "no_nft_path_bounded_trace":
        continue
    path = shipped.get(name)
    if not path:
        continue
    declared, raf, _, _ = read_unit(path)
    if declared and REQUIRED_FAMILY in raf:
        no(f"C1 {name} does not declare {REQUIRED_FAMILY} unnecessarily",
           f"no nft path found by trace, yet RestrictAddressFamilies={raf} — "
           f"granting it without a functional reason weakens the sandbox. "
           f"If this unit now reaches nft, reclassify it in the authority file.")
    else:
        ok(f"C1 {name} correctly withholds {REQUIRED_FAMILY}")

# unknown_external_executable is deliberately EXEMPT from rule C: absence of an
# nft path is untraceable, not proven, so neither granting nor withholding can be
# asserted as correct.
for name, u in sorted(units_decl.items()):
    if u.get("state") == "unknown_external_executable":
        ok(f"C2 {name} exempt from the unnecessary-{REQUIRED_FAMILY} rule "
           f"(unknown_external_executable — absence NOT proven)")

# --------------------------------------------- D. capability increases recorded
print("=== D. no silent capability increase ===")
for name, path in sorted(shipped.items()):
    declared, _, caps, user = read_unit(path)
    if "CAP_NET_ADMIN" not in caps:
        continue
    u = units_decl.get(name, {})
    # already_authorized units are verified nft consumers whose grant predates
    # this guard. They are a recorded baseline, not a silent increase.
    if name in already_auth:
        ok(f"D1 {name} CAP_NET_ADMIN is a recorded baseline grant (already_authorized)")
        continue
    if user and user != "root" and not u.get("capability_decision"):
        no(f"D1 {name} CAP_NET_ADMIN is a recorded decision",
           f"User={user} with AmbientCapabilities={caps} but no capability_decision "
           f"in the authority file — an unprivileged unit may not gain CAP_NET_ADMIN silently")
    else:
        ok(f"D1 {name} CAP_NET_ADMIN accounted for (User={user or 'root'})")

# ------------------------------------- E. denied decisions stay unimplemented
print("=== E. denied capability decisions are honoured ===")
for name, u in sorted(units_decl.items()):
    if u.get("capability_decision") != "denied_v1_228_4":
        continue
    path = shipped.get(name)
    if not path:
        continue
    declared, raf, caps, _ = read_unit(path)
    bad = []
    if "CAP_NET_ADMIN" in caps:
        bad.append(f"AmbientCapabilities={caps}")
    if declared and REQUIRED_FAMILY in raf:
        bad.append(f"RestrictAddressFamilies={raf}")
    if bad:
        no(f"E1 {name} honours capability_decision=denied_v1_228_4",
           "; ".join(bad) + " — this unit must not be modified in v1.228.4 "
           "(see OPEN_UNPRIVILEGED_NFT_OPERATION_AUTHORITY)")
    else:
        ok(f"E1 {name} unmodified per denied_v1_228_4")

# ---------------------------------------------------- F. evidence-state hygiene
print("=== F. evidence states are bounded and legible ===")
VALID = {"confirmed_consumer", "conditional_consumer",
         "no_nft_path_bounded_trace", "unknown_external_executable"}
bad_state = [n for n, u in units_decl.items() if u.get("state") not in VALID]
if bad_state:
    no("F1 every entry uses a valid bounded evidence state", "invalid: " + ", ".join(bad_state))
else:
    ok(f"F1 all {len(units_decl)} entries use a valid bounded evidence state")

no_ev = [n for n, u in units_decl.items() if not str(u.get("evidence", "")).strip()]
if no_ev:
    no("F2 every entry carries evidence", "missing evidence: " + ", ".join(no_ev))
else:
    ok("F2 every entry carries evidence")

# The STATE VALUE must not drift to an absolute name. Assert on the values in
# use, not on prose — an earlier version scanned prose and flagged the very
# comment that explains which phrasing to avoid.
ABSOLUTE = {"no_nft_path", "no_nft_path_found", "never_reaches_nft", "no_nft"}
drifted = sorted({u.get("state") for u in units_decl.values()} & ABSOLUTE)
if drifted:
    no("F3 no evidence state uses an absolute (unbounded) name",
       "found: " + ", ".join(drifted) + " — use no_nft_path_bounded_trace")
else:
    ok("F3 no evidence state uses an absolute (unbounded) name")

# ------------------------------------------- G. baseline contract (PR-1 -> PR-2)
print("=== G. temporary baseline contract ===")
if expected_open:
    stale = sorted(expected_open - observed_open)
    if stale:
        no("G1 every declared expected-open violation is still open",
           "these are now FIXED: " + ", ".join(stale) +
           " — PR-2 has landed; remove them from expected_open_violations "
           "(delete the whole block once it reaches zero)")
    else:
        ok(f"G1 all {len(expected_open)} declared expected-open violations are still open")
    if observed_open == expected_open:
        ok("G2 observed violation set EQUALS the declared baseline (no regression)")
    # a mismatch in the other direction already failed as a B1 above
else:
    if observed_open:
        no("G1 no undeclared violations", "open: " + ", ".join(sorted(observed_open)))
    else:
        ok("G1 baseline empty and zero violations — PR-2 closure contract satisfied")

print()
print(f"RESULT: {PASS} passed, {FAIL} failed, {len(observed_open)} expected-open")
sys.exit(1 if FAIL else 0)
PY
