#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 INV-C1 — EVERY `retention_mode: managed` CLAIM MUST RESOLVE
#                          TO A REAL, PRODUCTION-REACHABLE AUTHORITY
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="managed-authority-invariant-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="INV-C1. For every state class the FHS schema declares retention_mode=managed, the named authority must resolve in CURRENT SOURCE to a real definition, that definition must have a production call site, and it must bind to the declared path. A managed declaration that cannot be resolved is a false completeness claim and fails. Validates metadata AGAINST SOURCE, never against other metadata."
# meta:inventory.files="build/fhs-spec.yaml"
# meta:inventory.privileges="none"
# meta:ta.id="managed_authority_invariant_v1229_3_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   INV-C0 proved the schema is WELL-FORMED. It could not prove the schema is TRUE.
#   A `managed` entry naming an authority that does not exist would pass INV-C0.
#
#   ⛔ SELF-VALIDATION HAZARD. INV-C0 introduced this metadata. A test that checked
#      the metadata against itself would be green by construction and prove nothing.
#      Every assertion below resolves the CLAIM against PRODUCT SOURCE.
#
#   ⛔ DECLARATION != IMPLEMENTATION
#   ⛔ NAME MENTIONED    != DEFINITION EXISTS      (a comment is not an implementation)
#   ⛔ DEFINITION EXISTS != PRODUCTION REACHABLE   (a caller can itself be dead)
#   ⛔ REACHABLE         != GOVERNS THE DECLARED PATH
#
#   Call-resolution note: Go callers in the SAME package invoke unqualified
#   (`CleanupHistory(...)`, not `stats.CleanupHistory(...)`). A dot-anchored pattern
#   reports two correctly-wired classes as unreachable. That false negative was
#   observed while writing this test and is guarded by C1-2b.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SPEC="$ROOT/build/fhs-spec.yaml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== INV-C1 · managed retention authority invariant (v1.229.3) ==="
[[ -f "$SPEC" ]] || { echo "  SUBJECT_NOT_FOUND: $SPEC"; exit 1; }

# The resolver is shared by the live run and by every inversion, so an inversion
# exercises exactly the code path the real assertion uses.
resolve() {
    python3 - "$1" "$ROOT" <<'PY'
import re,sys,os,subprocess
spec,root=sys.argv[1],sys.argv[2]
L=open(spec,encoding='utf-8').read().split('\n')

# ---- parse the CLAIMS -------------------------------------------------------
claims=[];cur=None
for l in L:
    m=re.match(r'\s*-\s+path:\s*(\S+)',l)
    if m:
        if cur and cur.get('managed'): claims.append(cur)
        cur={'path':m.group(1)}
        continue
    if cur is None: continue
    if re.match(r'\s+retention_mode:\s*managed\s*$',l): cur['managed']=True
    m=re.match(r'\s+retention_evidence:\s*"?(.+?)"?\s*$',l)
    if m: cur['ev']=m.group(1)
    m=re.match(r'\s+retention_owner:\s*(\S+)',l)
    if m: cur['owner']=m.group(1)
if cur and cur.get('managed'): claims.append(cur)

STOP={'retention','via','through','target','maintenance','collector','internal',
      'stats','step','hard','files','removed','governed','logrotate','authority'}

def src_files():
    out=[]
    for base in ('cli','internal','cmd','scripts'):
        d=os.path.join(root,base)
        if not os.path.isdir(d): continue
        for dp,_,fs in os.walk(d):
            if '/tests/' in dp+'/' or '/test/' in dp+'/': continue
            for f in fs:
                if f.endswith(('.sh','.go')) and not f.endswith('_test.go') and not f.endswith('_test.sh'):
                    out.append(os.path.join(dp,f))
    return out
FILES=src_files()
CACHE={f:open(f,encoding='utf-8',errors='ignore').read().split('\n') for f in FILES}

def code_lines(f):
    """lines with comments stripped — a mention inside a comment is NOT evidence"""
    out=[]
    for ln in CACHE[f]:
        s=re.sub(r'//.*$','',ln)
        s=re.sub(r'(^|\s)#.*$',r'\1',s)
        out.append(s)
    return out

def scope_of(ev):
    """COMPONENT NAME != CANONICAL LOCATION. If the evidence names a source area
    (e.g. 'internal/stats'), the authority MUST be defined there. Without this, a
    same-named symbol in an unrelated package satisfies the claim — observed:
    `runCleanup` binding to internal/botguard/guard.go."""
    m=re.findall(r'((?:internal|cli|cmd|scripts)/[A-Za-z0-9_/]+)',ev)
    return m[0] if m else None

def classify(ident,scope):
    """FUNCTION vs VARIABLE. A managed claim must be anchored to a REAPER, not to a
    tunable: replacing the function name with a fiction while a retention-days
    constant still resolves must NOT pass."""
    kind=None; where=None
    for f in FILES:
        if scope and scope not in os.path.relpath(f,root): continue
        for i,ln in enumerate(code_lines(f)):
            if re.search(r'^func\s+(\([^)]*\)\s*)?'+re.escape(ident)+r'\s*\(',ln) \
               or re.search(r'^\s*(function\s+)?'+re.escape(ident)+r'\s*\(\)\s*\{',ln):
                return 'FUNCTION',f,i+1
            if re.search(r'^\s*(readonly\s+|export\s+|declare\s+\S+\s+)?'+re.escape(ident)+r'=',ln):
                kind,where=kind or 'VARIABLE', where or (f,i+1)
    if kind=='VARIABLE': return 'VARIABLE',where[0],where[1]
    return None,None,None

def has_production_call(ident,deffile,scope=None):
    """Language-aware. Go calls carry parentheses; SHELL calls do NOT —
    `if nftban_stats_cleanup_logs >/dev/null; then` is a call with no parens.
    A parenthesis-anchored pattern reports a live shell reaper as unreachable."""
    go=deffile.endswith('.go')
    if go:
        pat=re.compile(r'(?<![A-Za-z0-9_.])(?:[A-Za-z0-9_]+\.)?'+re.escape(ident)+r'\s*\(')
    else:
        # command position: line start, or after ; && || | ( { if then else do
        pat=re.compile(r'(?:^|[;&|(){}]|\b(?:if|then|else|do|elif|while|until)\s+)\s*'
                       +re.escape(ident)+r'(?=\s|$|[;&|)])')
    for f in FILES:
        if go != f.endswith('.go'): continue
        # a call in an UNRELATED package is not a call to THIS symbol
        if scope and go and scope not in os.path.relpath(f,root): continue
        for i,ln in enumerate(code_lines(f)):
            if re.search(r'^func\s+(\([^)]*\)\s*)?'+re.escape(ident)+r'\s*\(',ln): continue
            if re.search(r'^\s*(function\s+)?'+re.escape(ident)+r'\s*\(\)\s*\{',ln): continue
            if pat.search(ln): return f'{os.path.relpath(f,root)}:{i+1}'
    return None

def path_bound(c,idents,scope):
    p=c['path']; base=os.path.basename(p.rstrip('/'))
    for f in FILES:
        blob='\n'.join(code_lines(f))
        if p in blob: return f'{os.path.relpath(f,root)} (literal path)'
    for ident in idents:
        if not re.search(r'DIR|PATH|Dir|Path',ident): continue
        for f in FILES:
            for ln in code_lines(f):
                if re.search(re.escape(ident)+r'\s*=',ln) and (base in ln or p in ln):
                    return f'{os.path.relpath(f,root)} ({ident})'
    return None

rc=0
print(f"CLAIMS {len(claims)}")
for c in claims:
    p=c['path']; ev=c.get('ev','')
    scope=scope_of(ev)
    idents=[t for t in dict.fromkeys(re.findall(r'[A-Za-z_][A-Za-z0-9_]{5,}',ev)) if t.lower() not in STOP]
    if not ev:
        print(f"UNRESOLVED {p} :: managed but no retention_evidence"); rc=1; continue
    # C1-4 · every code-symbol named in the evidence must exist in NON-COMMENT source.
    # `CleanupReports` was deleted in #1244 yet is still named in two comments; a claim
    # citing it is stale even when a sibling symbol in the same sentence still resolves.
    SYMBOL=re.compile(r'^(?:[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[a-z][a-z0-9]*(?:_[a-z0-9]+){2,})$')
    stale=[]
    for i in idents:
        if not SYMBOL.match(i): continue
        seen_in_code=False
        for f in FILES:
            if scope and scope not in os.path.relpath(f,root) and not f.endswith('.sh'): continue
            if any(re.search(r'(?<![A-Za-z0-9_])'+re.escape(i)+r'(?![A-Za-z0-9_])',ln) for ln in code_lines(f)):
                seen_in_code=True; break
        if not seen_in_code: stale.append(i)
    if stale:
        print(f"STALE_SYMBOL {p} :: evidence cites symbol(s) absent from non-comment source :: {stale}")
        rc=1; continue

    funcs=[]
    for i in idents:
        k,f,l=classify(i,scope)
        if k=='FUNCTION': funcs.append((i,f,l))
    if not funcs:
        sc=f" within scope '{scope}'" if scope else ""
        print(f"UNRESOLVED {p} :: no identifier in evidence is a FUNCTION definition{sc} :: {idents}")
        rc=1; continue
    live=[(i,has_production_call(i,f,scope)) for i,f,_ in funcs]
    live=[(i,cl) for i,cl in live if cl]
    if not live:
        print(f"NO_CALLER {p} :: defined but no production call site :: {[i for i,_,_ in funcs]}"); rc=1; continue
    pb=path_bound(c,idents,scope)
    if not pb:
        print(f"NO_PATH_BIND {p} :: authority never reaches the declared path"); rc=1; continue
    print(f"OK {p} :: {live[0][0]} @ {live[0][1]} :: path via {pb}")
sys.exit(rc)
PY
}

OUT="$(resolve "$SPEC")"; RC=$?
echo "$OUT" | sed 's/^/    /'
N="$(sed -n 's/^CLAIMS \([0-9]*\)$/\1/p' <<<"$OUT")"

# --- C1-0 · the invariant must have a subject ---------------------------------
if [[ -n "$N" && "$N" -gt 0 ]]; then
    pass "C1-0 invariant has $N managed claim(s) to check (not vacuous)"
else
    fail "C1-0 zero managed claims resolved — an empty subject is not a pass"
fi

# --- C1-1/2/3 · every managed claim resolves ----------------------------------
if [[ $RC -eq 0 ]]; then
    pass "C1-1..3 every managed claim resolves to a real, called, path-bound authority"
else
    fail "C1-1..3 at least one managed claim could not be resolved against source"
fi

# --- C1-2b · the resolver matches UNQUALIFIED same-package Go calls ------------
if grep -q 'CleanupHistory' <<<"$OUT" || grep -q 'stats/history' <<<"$OUT"; then
    pass "C1-2b same-package unqualified Go call resolved (dot-anchored patterns would miss it)"
else
    fail "C1-2b the Go-governed class did not resolve — resolver may be dot-anchored again"
fi

# ================= INVERSIONS — each mutates a COPY of the schema =============
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SUM_BEFORE="$(sha256sum "$SPEC" | cut -d" " -f1)"

inv() { # <label> <python-mutation> <expect-fail-token>
    cp -a "$SPEC" "$TMP/spec.yaml"
    python3 - "$TMP/spec.yaml" <<PY
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
$2
open(p,'w',encoding='utf-8').write(s)
PY
    local o r
    o="$(resolve "$TMP/spec.yaml")"; r=$?
    # A rejection is ANY refusal verdict, and it must name the MUTATED PATH.
    # Binding to the path rather than one reason keeps the arm meaningful when the
    # resolver legitimately refuses for a different but still correct reason.
    if [[ $r -ne 0 ]] && grep -qE "^(UNRESOLVED|NO_CALLER|NO_PATH_BIND|STALE_SYMBOL) $3 " <<<"$o"; then
        pass "$1"
    else
        fail "$1 — inversion NOT detected (rc=$r, no refusal for $3)"
        sed 's/^/        /' <<<"$o" | head -4
    fi
}

# I1 · a fabricated managed authority
inv "C1-I1 INVERSION: managed entry naming a non-existent authority is rejected" \
"s=s.replace('retention_evidence: \"nftban_stats_cleanup_logs','retention_evidence: \"nftban_totally_fictional_reaper',1)" \
"/var/lib/nftban/snapshots"

# I2 · evidence stripped entirely
inv "C1-I2 INVERSION: managed entry with no evidence is rejected" \
"i=s.index('retention_evidence:'); j=s.index(chr(10),i); s=s[:i]+'x_removed: 1'+s[j:]" \
"/var/lib/nftban/snapshots"

# I3 · a NEW managed class with a plausible but unimplemented owner
inv "C1-I3 INVERSION: a newly added managed class with no implementation is rejected" \
"s=s.replace('''    - path: /var/lib/nftban/snapshots''','''    - path: /var/lib/nftban/invc1_probe
      artifact_class: state
      retention_mode: managed
      retention_owner: stats-maintenance
      retention_evidence: \"nftban_probe_cleanup_authority governs this class\"
      mode: \"0750\"
    - path: /var/lib/nftban/snapshots''',1)" \
"/var/lib/nftban/invc1_probe"

# I4 · evidence naming a symbol that exists ONLY inside a comment.
# `CleanupReports` is the real case: REMOVED in v1.229.3 (#1244) yet still named in
# two source comments (internal/stats/config.go:81, cleanup.go:189). A comment-blind
# resolver would accept a deleted function as a live retention authority.
inv "C1-I4 INVERSION: an authority that survives only in comments (deleted CleanupReports) is rejected" \
"s=s.replace('retention_evidence: \"internal/stats CleanupHistory','retention_evidence: \"internal/stats CleanupReports',1)" \
"/var/lib/nftban/stats/history"

# restore proof — the production schema must be byte-identical afterwards
if [[ "$(sha256sum "$SPEC" | cut -d" " -f1)" == "$SUM_BEFORE" ]]; then
    pass "C1-R production schema untouched by the inversions (checksum match)"
else
    fail "C1-R the production schema was mutated — inversions must use copies only"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
