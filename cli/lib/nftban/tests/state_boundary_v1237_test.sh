#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.237 root-owned state boundary (FHS C1+C2) + commit-confirm input trust
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="state_boundary_v1237_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-15"
# meta:description="Owner 2026-11-15 C1+C2: /var/lib/nftban/state is 0750 root:nftban in the canonical FHS spec (tmpfiles, installer RequiredDirs follow); the broad /var/lib/nftban nftban:nftban file rule excludes state/; the identified entries are exact spec entries restored IN PLACE by ONE generated policy (fhs-state-policy.sh) that fhs-permissions.sh, perms_enforce_var_files and autoheal all call (state/ pruned from their sweeps); the two locks are root-only; trust markers are declared but never enforced. Commit-confirm: root applies rollback/confirm inputs only when the state chain is root-owned and closed, the root-only trust marker is valid, and applied/ + commit-confirm/ are exactly 0700 with no foreign-owned, group/other-writable or symlinked entry; the marker is written only after a fresh baseline while no apply is pending. Hermetic: repo source + temp dirs; the policy's in-place re-own runs only as root (labs/package acceptance)."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk,stat,find"
# meta:inventory.files="build/fhs-spec.yaml,cli/lib/nftban/setup/fhs-state-policy.sh,cli/lib/nftban/setup/fhs-permissions.sh,cli/lib/nftban/core/nftban_permissions.sh,cli/lib/nftban/helpers/autoheal.sh,cli/lib/nftban/lib/commit_confirm.sh,install/systemd/tmpfiles.d/nftban.conf,internal/installer/fhs/paths.go"
# meta:inventory.binaries="bash,grep,awk,stat,find"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,CC_TRUST_UID,CC_TRUST_TOP"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="state_boundary_v1237_test"
# meta:ta.owner="core"
# meta:ta.module="state-boundary"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

SPEC="$REPO_ROOT/build/fhs-spec.yaml"
POL="$REPO_ROOT/cli/lib/nftban/setup/fhs-state-policy.sh"
PERMS_SH="$REPO_ROOT/cli/lib/nftban/setup/fhs-permissions.sh"
PERMS="$REPO_ROOT/cli/lib/nftban/core/nftban_permissions.sh"
HEAL="$REPO_ROOT/cli/lib/nftban/helpers/autoheal.sh"
CC="$REPO_ROOT/cli/lib/nftban/lib/commit_confirm.sh"
TMPF="$REPO_ROOT/install/systemd/tmpfiles.d/nftban.conf"
PATHS="$REPO_ROOT/internal/installer/fhs/paths.go"
for f in "$SPEC" "$POL" "$PERMS_SH" "$PERMS" "$HEAL" "$CC" "$TMPF" "$PATHS"; do [[ -f "$f" ]] || { echo "missing: $f"; exit 1; }; done
S=/var/lib/nftban/state

echo "=== C1: state/ directory owner ==="
dblock=$(awk '/^    - path: \/var\/lib\/nftban\/state$/ {f=1; next} f && /^    - path:/ {exit} f {print}' "$SPEC")
grep -qE '^      owner: root$' <<<"$dblock" && grep -qE '^      group: nftban$' <<<"$dblock" && grep -qE '^      mode: "0750"$' <<<"$dblock" \
    && ok "spec: state/ 0750 root:nftban" || no "spec state/ owner"
grep -qF 'AUTHORITY-MODEL CORRECTION' <<<"$dblock" && ok "spec records the authority-model correction" || no "correction note missing"
grep -qE "^z $S 0750 root nftban" "$TMPF" && ok "tmpfiles z re-owns state/ (generated)" || no "tmpfiles state/ line"
grep -qE '\{StateDir, 0750, "root:nftban"\}' "$PATHS" && ok "installer RequiredDirs state/ root:nftban" || no "RequiredDirs state/"

echo "=== C2: broad rule excludes state/; exact entries via ONE generated policy ==="
sweep=$(awk '/^  - path: \/var\/lib\/nftban$/ {f=1; next} f && /^  - path:/ {exit} f {print}' "$SPEC")
grep -qF '"/var/lib/nftban/state"' <<<"$sweep" && ok "nftban:nftban file rule excludes state/" || no "broad rule does not exclude state/"
n_ex=$(grep -cF -- "-not -path \"$S\" -not -path \"$S/*\"" "$PERMS_SH" || true)
[[ "$n_ex" -eq 2 ]] && ok "fhs-permissions.sh sweeps exclude state/ (generated)" || no "generated sweep exclusion"
grep -qF 'nftban_fhs_enforce_exact_entries' "$PERMS_SH" && ok "fhs-permissions.sh calls the policy" || no "fhs-permissions.sh does not call the policy"
fn=$(awk '/^perms_enforce_var_files\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$PERMS")
[[ $(grep -cF -- '-o -path "$PERMS_VAR/state" \) -prune' <<<"$fn" || true) -eq 2 ]] && ok "perms_enforce_var_files prunes state/ in both sweeps" || no "perms_enforce_var_files does not prune state/"
grep -qF 'setup/fhs-state-policy.sh' <<<"$fn" && grep -qF 'nftban_fhs_enforce_exact_entries' <<<"$fn" && ok "perms_enforce_var_files calls the policy" || no "perms_enforce_var_files does not call the policy"
[[ $(grep -cF -- '-path "${NFTBAN_DATA_DIR}/state" -prune' "$HEAL" || true) -eq 2 ]] && ok "autoheal prunes state/ in both sweeps" || no "autoheal does not prune state/"
grep -qF 'nftban_fhs_enforce_exact_entries' "$HEAL" && ok "autoheal calls the policy" || no "autoheal does not call the policy"

# every enforced exact spec entry appears in the policy with the same triple, nothing else does
spec_rows=$(awk '
  /^  - path: / { if (p!="" && ex=="true" && en!="false") print typ, own":"grp, mode, p"/"pat; p=$3; pat=""; ex=""; en=""; typ=""; own=""; grp=""; mode=""; next }
  /^    pattern: / { pat=$2; gsub(/"/,"",pat) } /^    exact: / { ex=$2 } /^    install_enforce: / { en=$2 }
  /^    type: / { typ=$2 } /^    owner: / { own=$2 } /^    group: / { grp=$2 } /^    mode: / { mode=$2; gsub(/"/,"",mode) }
  /^[a-z_]+:/ && !/^file_permissions:/ { if (p!="" && ex=="true" && en!="false") print typ, own":"grp, mode, p"/"pat; p="" }
  END { if (p!="" && ex=="true" && en!="false") print typ, own":"grp, mode, p"/"pat }' "$SPEC" | sort)
pol_rows=$(awk '/^    _nftban_fhs_exact / { gsub(/"/,"",$5); print $2, $3, $4, $5 }' "$POL" | sort)
[[ -n "$spec_rows" && "$spec_rows" == "$pol_rows" ]] && ok "generated policy == spec exact entries ($(grep -c . <<<"$spec_rows") entries)" || no "policy/spec drift" "spec=[$spec_rows] policy=[$pol_rows]"
for n in installer.lock commit-confirm.lock; do
    grep -qE "^file root:root 0600 $S/$n$" <<<"$pol_rows" && ok "lock $n: root:root 0600 (root-only)" || no "lock $n not root-only"
done
grep -qE "^dir root:root 0700 $S/applied$" <<<"$pol_rows" && grep -qE "^dir root:root 0700 $S/commit-confirm$" <<<"$pol_rows" \
    && ok "applied/ and commit-confirm/: directory only, root 0700" || no "root-only dirs"
grep -qE '\.trust$' <<<"$pol_rows" && no "a trust marker is enforced (would re-own a planted file)" || ok "trust markers are never re-owned by the repair"
grep -qE 'chown -R|chmod -R|find ' "$POL" && no "policy recurses" || ok "policy is never recursive"
grep -qF 'chown -h' "$POL" && grep -qF '[[ -L "$p" ]] && return 0' "$POL" && ok "policy never follows a symlink" || no "policy symlink guard"
grep -qF '_nftban_fhs_parent_root_closed' "$POL" && ok "policy acts only under a root-owned, closed parent" || no "policy parent guard"
grep -qE '^set -|shopt ' "$POL" && no "policy changes shell options when sourced" || ok "policy is definitions only (safe to source)"

echo "=== commit-confirm: rollback/confirm inputs are validated before root applies them ==="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
chmod 0750 "$T"
mk_tree(){
    rm -rf "$T/data"; mkdir -p "$T/data/state/applied/config" "$T/data/state/commit-confirm"
    chmod 0750 "$T/data" "$T/data/state"; chmod 0700 "$T/data/state/applied" "$T/data/state/commit-confirm"
    echo x > "$T/data/state/applied/manifest"; echo x > "$T/data/state/commit-confirm/kernel-before.nft"
    printf 'apply_id=t\nstatus=pending\n' > "$T/data/state/commit-confirm.state"; chmod 0640 "$T/data/state/commit-confirm.state"
}
cc_case(){  # name expected(0|1) mutation
    local name="$1" want="$2" mut="$3" rc
    mk_tree
    rc=$(NFTBAN_DATA_DIR="$T/data" NFTBAN_CONFIG_DIR="$T/etc" CC_TRUST_UID="$(id -u)" CC_TRUST_TOP="$T" bash -c '
        set +e; source "$1" >/dev/null 2>&1
        printf "%s" "$CC_TRUST_CONTENT" > "$CC_TRUST"; chmod 600 "$CC_TRUST"
        eval "$2"
        cc_inputs_trusted record work base; echo $?' _ "$CC" "$mut" 2>/dev/null | tail -1)
    [[ "$rc" == "$want" ]] && ok "cc_inputs_trusted: $name -> $([[ $want == 0 ]] && echo trusted || echo refused)" || no "cc_inputs_trusted: $name" "rc=$rc want=$want"
}
cc_case "valid layout" 0 ':'
cc_case "no trust marker" 1 'rm -f "$CC_TRUST"'
cc_case "marker group-readable" 1 'chmod 640 "$CC_TRUST"'
cc_case "marker wrong content" 1 'echo forged > "$CC_TRUST"; chmod 600 "$CC_TRUST"'
cc_case "state dir group-writable" 1 'chmod 0770 "$CC_STATE_DIR"'
cc_case "baseline dir 0750" 1 'chmod 0750 "$CC_BASE"'
cc_case "baseline file group-writable" 1 'chmod 0660 "$CC_BASE/manifest"'
cc_case "symlink in work dir" 1 'ln -s /etc/passwd "$CC_WORK/changeset"'
cc_case "work dir replaced by a symlink" 1 'rm -rf "$CC_WORK"; mkdir -p "$CC_STATE_DIR/x"; chmod 0700 "$CC_STATE_DIR/x"; ln -s "$CC_STATE_DIR/x" "$CC_WORK"'
cc_case "record group-writable" 1 'chmod 0660 "$CC_RECORD"'
# the marker is written only when the boundary holds and nothing is pending
est(){  # status expected_marker(yes|no) mutation
    mk_tree
    NFTBAN_DATA_DIR="$T/data" NFTBAN_CONFIG_DIR="$T/etc" CC_TRUST_UID="$(id -u)" CC_TRUST_TOP="$T" bash -c '
        set +e; source "$1" >/dev/null 2>&1
        printf "apply_id=t\nstatus=%s\n" "$2" > "$CC_RECORD"; eval "$3"
        _cc_establish_trust; _cc_trust_marker_ok && echo yes || echo no' _ "$CC" "$1" "$2" 2>/dev/null | tail -1
}
[[ "$(est confirmed ':')" == yes ]] && ok "_cc_establish_trust writes the marker after a baseline, nothing pending" || no "_cc_establish_trust did not write the marker"
[[ "$(est pending ':')" == no ]] && ok "_cc_establish_trust refuses while an apply is pending (pre-boundary window stays untrusted)" || no "marker written during a pending apply"
[[ "$(est confirmed 'chmod 0770 "$CC_STATE_DIR"')" == no ]] && ok "_cc_establish_trust refuses while state/ is writable by group" || no "marker written without the boundary"
grep -qE 'cc_inputs_trusted base' "$CC" && grep -qE 'cc_inputs_trusted record work base' "$CC" && ok "apply_begin, confirm and rollback validate before applying" || no "a consumer does not validate"
grep -qF '_cc_establish_trust || true; return 0' "$CC" && ok "a fresh applied baseline establishes trust" || no "baseline does not establish trust"
grep -qF '(umask 077; : >> "$CC_LOCK")' "$CC" && ok "commit-confirm.lock created root-only" || no "lock creation mode"

echo "================================================================"
echo "state_boundary_v1237_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
