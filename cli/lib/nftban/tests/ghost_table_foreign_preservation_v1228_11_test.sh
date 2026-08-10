#!/usr/bin/env bash
# =============================================================================
# NFTBan - foreign nftables state preservation (v1.228.11)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ghost_table_foreign_preservation_v1228_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-10"
# meta:description="INV-FOREIGN-NFT-01: no NFTBan mutation path may delete populated foreign nftables state solely because family/name matches a known ghost identity. Drives the REAL nftban_table_content_class and nftban_delete_ghost_table_if_empty from nftban_table_classify.sh with an nft shim, and asserts STAGE-LOCALLY so component attribution is preserved. Includes the pre-fix mutation control (bare delete-by-name) proving the fixture is discriminating, a positive control proving empty ghosts are still removable, and an observation-failure control proving an unreadable table is never deleted."
# meta:input="None (nft shim fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp"
# meta:inventory.files="cli/lib/nftban/core/nftban_table_classify.sh,cli/lib/nftban/core/nftban_firewall_conflicts.sh"
# meta:inventory.binaries="bash,grep,sed,mktemp"
# meta:inventory.privileges="none"
# meta:ta.id="ghost_table_foreign_preservation_v1228_11_test"
# meta:ta.owner="firewall"
# meta:ta.module="table-classify"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/cli/lib/nftban/core/nftban_table_classify.sh"
# v1.228.11: nftban_delete_ghost_table_if_empty lives in the AUTHORIZED nft-writer
# (check-nft-writes.sh), not in the read-only classifier.
WRITER="$REPO_ROOT/cli/lib/nftban/core/nftban_firewall_conflicts.sh"
GUARD="$REPO_ROOT/scripts/ci/check-ghost-table-drift.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== ghost_table_foreign_preservation_v1228_11 ==="
[[ -f "$LIB" ]] || { echo "  FATAL: $LIB missing"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# nft shim: STATE dir holds one file per existing table; content decides class.
cat > "$WORK/bin/nft" <<'SHIM'
#!/usr/bin/env bash
S="${NFT_STATE:?}"
case "$1 $2" in
  "list tables")
      for f in "$S"/*.tbl; do [[ -e "$f" ]] || continue
          b="$(basename "$f" .tbl)"; echo "table ${b/__/ }"; done; exit 0 ;;
esac
if [[ "$1" == "list" && "$2" == "table" ]]; then
    f="$S/$3__$4.tbl"; [[ -f "$f" ]] || exit 1
    [[ "$(cat "$f")" == "UNREADABLE" ]] && exit 1
    cat "$f"; exit 0
fi
if [[ "$1" == "delete" && "$2" == "table" ]]; then
    rm -f "$S/$3__$4.tbl"; exit 0
fi
exit 0
SHIM
chmod +x "$WORK/bin/nft"
export PATH="$WORK/bin:$PATH"
export NFT_STATE="$WORK/state"; mkdir -p "$NFT_STATE"

mkpop(){ printf 'table %s %s {\n\tchain c {\n\t\ttype filter hook input priority 0; policy accept;\n\t\tip saddr 198.51.100.1 counter accept comment "FOREIGN-OWNED"\n\t}\n}\n' "$1" "$2" > "$NFT_STATE/$1__$2.tbl"; }
mkempty(){ printf 'table %s %s {\n}\n' "$1" "$2" > "$NFT_STATE/$1__$2.tbl"; }
mkbad(){ printf 'UNREADABLE' > "$NFT_STATE/$1__$2.tbl"; }
exists(){ [[ -f "$NFT_STATE/$1__$2.tbl" ]] && echo yes || echo no; }

# shellcheck source=/dev/null
. "$LIB" 2>/dev/null
set +eEuo pipefail; trap - ERR   # the sourced lib re-enables errexit
. "$WRITER" 2>/dev/null
set +eEuo pipefail; trap - ERR

echo "--- A. content classifier (the primitive both languages share) ---"
mkpop ip filter;   [[ "$(nftban_table_content_class ip filter)"   == "$TC_CONTENT_POPULATED"  ]] && ok "populated -> POPULATED"   || no "populated misclassified"
mkempty ip nat;    [[ "$(nftban_table_content_class ip nat)"      == "$TC_CONTENT_EMPTY"      ]] && ok "empty -> EMPTY"           || no "empty misclassified"
mkbad ip mangle;   [[ "$(nftban_table_content_class ip mangle)"   == "$TC_CONTENT_UNREADABLE" ]] && ok "unreadable -> UNREADABLE" || no "unreadable misclassified"
rm -f "$NFT_STATE/ip__security.tbl"
[[ "$(nftban_table_content_class ip security)" == "$TC_CONTENT_ABSENT" ]] && ok "absent -> ABSENT" || no "absent misclassified"

echo "--- B. MUTATION CONTROL: the pre-fix form destroys the same fixture ---"
mkpop ip filter
prefix_delete(){ nft delete table "$1" "$2"; }   # the exact pre-fix one-liner
prefix_delete ip filter
[[ "$(exists ip filter)" == "no" ]] && ok "pre-fix bare delete DOES destroy it — fixture discriminates" \
    || no "pre-fix form did not destroy the fixture; this suite would be vacuous"

echo "--- C. gated helper: STAGE-LOCAL assertions ---"
mkpop ip filter; mkpop ip mangle; mkpop ip6 filter; mkpop inet firewalld; mkempty ip nat
for t in "ip filter" "ip mangle" "ip6 filter" "inet firewalld" "ip nat"; do
    nftban_delete_ghost_table_if_empty "${t%% *}" "${t#* }" true >/dev/null 2>&1
done
[[ "$(exists ip filter)"      == "yes" ]] && ok "stage[helper]: populated ip filter PRESERVED"      || no "populated ip filter deleted"
[[ "$(exists ip mangle)"      == "yes" ]] && ok "stage[helper]: populated ip mangle PRESERVED"      || no "populated ip mangle deleted"
[[ "$(exists ip6 filter)"     == "yes" ]] && ok "stage[helper]: populated ip6 filter PRESERVED"     || no "populated ip6 filter deleted"
[[ "$(exists inet firewalld)" == "yes" ]] && ok "stage[helper]: populated inet firewalld PRESERVED" || no "populated inet firewalld deleted"
[[ "$(exists ip nat)"         == "no"  ]] && ok "stage[helper]: empty ghost REMOVED (positive control — path not inert)" \
    || no "empty ghost preserved; cleanup authority is inert"

echo "--- D. observation failure is never permission to delete ---"
mkbad ip security
nftban_delete_ghost_table_if_empty ip security true >/dev/null 2>&1
[[ "$(exists ip security)" == "yes" ]] && ok "unreadable table PRESERVED (OBSERVATION_FAILURE != EMPTY)" \
    || no "unreadable table was deleted"

echo "--- E. canonical identity authority + drift guard ---"
[[ "${#_NFTBAN_GHOST_TABLE_IDENTITIES[@]}" -ge 10 ]] && ok "canonical identity list present (${#_NFTBAN_GHOST_TABLE_IDENTITIES[@]} entries)" \
    || no "canonical identity list missing/short"
if [[ -x "$GUARD" ]]; then
    bash "$GUARD" >/dev/null 2>&1 && ok "Go/shell ghost identities in sync" || no "drift guard reports divergence"
    # non-vacuity: the guard must fail when the shell list gains an entry
    TMPL="$WORK/classify_drift.sh"; cp "$LIB" "$TMPL"
    sed -i 's/    "inet firewalld" "inet filter"/    "inet firewalld" "inet filter" "ip drifttest"/' "$TMPL"
    if grep -q 'ip drifttest' "$TMPL"; then ok "drift-guard non-vacuity fixture builds" ; else no "could not build drift fixture"; fi
else
    no "drift guard not found at scripts/ci/check-ghost-table-drift.sh"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
