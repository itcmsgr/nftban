#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 feed snapshot ownership boundary + single-feed update dispatch
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="feed_snapshot_boundary_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-20"
# meta:description="v1.238 prerequisites (owner 2026-11-20). SEC-FEED-STAGING-SNAPSHOTS-OWNED-BY-NFTBAN-ACCOUNT: enforced feed snapshots /var/lib/nftban/feeds/*.txt are root:nftban 0640 in the canonical FHS spec (glob entry; the broad nftban:nftban file rule excludes feeds/); the ONE generated policy restores them in place (never through a symlink, only under a root-owned closed parent); both repair sweeps prune feeds/; both writers create root:nftban. BUG-FEEDS-UPDATE-SINGLE-FEED-REFRESHES-ALL: the CLI passes a named feed to nftban-core feeds update. Static parity runs unprivileged; the policy's in-place repair runs as root (planted nftban-owned snapshot re-owned, planted link removed, target untouched)."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk,stat,find"
# meta:inventory.files="build/fhs-spec.yaml,build/generate-fhs-outputs.sh,cli/lib/nftban/setup/fhs-state-policy.sh,cli/lib/nftban/setup/fhs-permissions.sh,cli/lib/nftban/core/nftban_permissions.sh,cli/lib/nftban/helpers/autoheal.sh,cli/lib/nftban/core/nftban_feeds.sh,cli/lib/nftban/cli/cmd_feeds.sh,cmd/nftban-core/cmd_feeds.go"
# meta:inventory.binaries="bash,grep,awk,stat,find"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="feed_snapshot_boundary_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="feeds"
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
FEEDS_SH="$REPO_ROOT/cli/lib/nftban/core/nftban_feeds.sh"
CMD_FEEDS="$REPO_ROOT/cli/lib/nftban/cli/cmd_feeds.sh"
GO_FEEDS="$REPO_ROOT/cmd/nftban-core/cmd_feeds.go"
for f in "$SPEC" "$POL" "$PERMS_SH" "$PERMS" "$HEAL" "$FEEDS_SH" "$CMD_FEEDS" "$GO_FEEDS"; do
    [[ -f "$f" ]] || { echo "missing: $f"; exit 1; }
done
F=/var/lib/nftban/feeds

echo "=== spec: feeds/*.txt root:nftban 0640; broad rule excludes feeds/ ==="
sweep=$(awk '/^  - path: \/var\/lib\/nftban$/ {f=1; next} f && /^  - path:/ {exit} f {print}' "$SPEC")
grep -qF "\"$F\"" <<<"$sweep" && ok "broad nftban:nftban file rule excludes feeds/" || no "broad rule does not exclude feeds/"
gblock=$(awk -v p="  - path: $F" '$0 == p {f=1; next} f && /^  - path:/ {exit} f {print}' "$SPEC" | grep -v '^ *#')
for kv in 'pattern: "\*\.txt"' 'mode: "0640"' 'owner: root' 'group: nftban' 'glob: true' 'type: file'; do
    grep -qE "^    $kv$" <<<"$gblock" && ok "spec feeds/ glob entry: ${kv//\\/}" || no "spec feeds/ glob entry lacks ${kv//\\/}"
done
grep -qE '^    (recursive: true|exact: true)$' <<<"$gblock" && no "glob entry must be neither recursive nor exact" || ok "glob entry is non-recursive, not exact"

echo "=== generated outputs ==="
n_ex=$(grep -cF -- "-not -path \"$F\" -not -path \"$F/*\"" "$PERMS_SH" || true)
[[ "$n_ex" -eq 2 ]] && ok "fhs-permissions.sh sweeps exclude feeds/ (generated)" || no "generated sweep exclusion for feeds/ ($n_ex)"
grep -qF "\"$F\"/*.txt" "$PERMS_SH" && no "install sweep also emits the glob entry (must be policy-only)" || ok "glob entry is not in the install find/chown sweep"
gl=$(grep -E '^    for _nftban_fhs_p in ' "$POL" || true)
[[ "$gl" == "    for _nftban_fhs_p in \"$F\"/*.txt; do _nftban_fhs_exact file root:nftban 0640 \"\$_nftban_fhs_p\"; done" ]] \
    && ok "generated policy restores feeds/*.txt root:nftban 0640 with the exact-entry helper" || no "policy glob line" "$gl"
awk '/^nftban_fhs_enforce_exact_entries\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$POL" | grep -qF 'for _nftban_fhs_p in' \
    && ok "glob line is inside nftban_fhs_enforce_exact_entries (every consumer runs it)" || no "glob line outside the policy function"

echo "=== repair consumers prune feeds/; writers create root:nftban ==="
fn=$(awk '/^perms_enforce_var_files\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$PERMS")
[[ $(grep -cF -- '-prune -o -path "$PERMS_VAR/feeds" -prune -o -type f' <<<"$fn" || true) -eq 2 ]] && ok "perms_enforce_var_files prunes feeds/ in both sweeps" || no "perms_enforce_var_files does not prune feeds/"
[[ $(grep -cF -- '-prune -o -path "${NFTBAN_DATA_DIR}/feeds" -prune -o -type f' "$HEAL" || true) -eq 2 ]] && ok "autoheal prunes feeds/ in both sweeps" || no "autoheal does not prune feeds/"
grep -qF 'chown root:nftban "${staging_file}.tmp"' "$FEEDS_SH" && ok "bash writer: staging file root:nftban" || no "bash writer owner"
grep -qE 'chown nftban:nftban "\$\{staging_file\}' "$FEEDS_SH" && no "bash writer still chowns nftban:nftban" || ok "bash writer no longer hands the snapshot to the service account"
grep -qF 'os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o640' "$GO_FEEDS" && grep -qF 'out.Chown(uid, gid)' "$GO_FEEDS" \
    && ok "Go writer: exclusive create, owner set through the descriptor before rename" || no "Go writer creation"
grep -qE 'user\.Lookup\("nftban"\)' "$GO_FEEDS" && no "Go writer still looks up the nftban USER as owner" || ok "Go writer does not make the service account the owner"

echo "=== single-feed update dispatch ==="
blk=$(awk '/^        update\)$/ {f=1} f {print} f && /^            ;;$/ {exit}' "$CMD_FEEDS")
grep -qF 'feeds update "$_feed_arg"' <<<"$blk" && ok "CLI passes a named feed to nftban-core feeds update" || no "CLI drops the feed name"
grep -qF 'feedName = os.Args[3]' "$GO_FEEDS" && grep -qF 'selectFeedsForUpdate(feedConfigs, feedName)' "$GO_FEEDS" \
    && ok "nftban-core feeds update [FEED] selects only the named feed" || no "Go update ignores the feed name"

echo "=== policy in place (root only: needs a root-owned parent) ==="
if [[ $EUID -eq 0 ]]; then
    T=$(mktemp -d); chmod 0755 "$T"; trap 'rm -rf "$T"' EXIT
    D="$T/feeds"; mkdir -m 0750 "$D"; chown root:root "$D"
    grp=nobody; getent group nftban >/dev/null 2>&1 && grp=nftban
    echo "victim" > "$T/victim"; chmod 0600 "$T/victim"
    printf '192.0.2.0/24\n' > "$D/a.txt"; chown nobody:"$(id -gn nobody 2>/dev/null || echo nobody)" "$D/a.txt"; chmod 0664 "$D/a.txt"
    ln -s "$T/victim" "$D/b.txt"
    # run the generated glob line against the sandbox dir (same helper, same checks)
    line=${gl//\"$F\"/\"$D\"}; line=${line//root:nftban/root:$grp}
    bash -c 'IFS=$'"'"'\n\t'"'"'; source "$1"; eval "$2"' _ "$POL" "$line" 2>/dev/null
    [[ "$(stat -c '%u:%G %a' "$D/a.txt")" == "0:$grp 640" ]] && ok "planted service-account snapshot re-owned in place to root:$grp 0640" || no "re-own" "$(stat -c '%U:%G %a' "$D/a.txt")"
    [[ ! -e "$D/b.txt" && ! -L "$D/b.txt" ]] && ok "link at a snapshot name removed" || no "link kept"
    [[ "$(cat "$T/victim")" == victim && "$(stat -c '%u %a' "$T/victim")" == "0 600" ]] && ok "link target untouched" || no "link target changed"
    chmod 0770 "$D"; printf 'x\n' > "$D/c.txt"; chown nobody "$D/c.txt"
    bash -c 'IFS=$'"'"'\n\t'"'"'; source "$1"; eval "$2"' _ "$POL" "$line" 2>/dev/null
    [[ "$(stat -c '%U' "$D/c.txt")" == nobody ]] && ok "parent writable by group: nothing touched (boundary first)" || no "repair ran under an open parent"
else
    echo "  - not root: in-place repair is exercised in the root run (static parity above is complete)"
fi

echo ""
echo "TOTAL: pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
