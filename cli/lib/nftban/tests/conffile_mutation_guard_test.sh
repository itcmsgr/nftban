#!/usr/bin/env bash
# =============================================================================
# NFTBan - the shipped-conffile mutation gate must actually discriminate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="conffile-mutation-guard-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="conffile_mutation_guard_test"
# meta:ta.owner="packaging"
# meta:ta.module="release-safety-conffile"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="Changing a shipped DEB conffile makes apt prompt, and an UNATTENDED upgrade then aborts or silently keeps the old file — the 71/74 incident. Before this gate there was no CI check for it: the only protection was a predicate inside tools/add-spdx-copyright.sh, constraining that one script and nothing else, while the places upgrades ARE exercised mask the hazard (lifecycle_deb_matrix.sh passes --force-confold --force-confdef, and ci-update-canonization.yml degrades a dpkg abort to ::warning::). A guard that cannot fail is worse than none, so this drives the REAL gate over synthetic git history and proves it detects a planted mutation, an addition, a removal, a vacuous source set, and the disappearance of the packaging authority it mirrors."
# meta:inventory.files="scripts/ci/check-conffile-mutation.sh,packaging/build_nftban.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-conffile-mutation.sh"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
[[ -x "$GATE" ]] || { echo "  [FAIL] gate not found/executable: $GATE"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email t@example.com; git -C "$R" config user.name t

# Synthetic tree carrying BOTH the packaging authority marker and enough
# conffiles to clear the gate's own non-vacuity floor.
mkdir -p "$R/packaging" "$R/etc/nftban/conf.d" "$R/install/config" "$R/install/nftables" "$R/scripts/ci"
cat > "$R/packaging/build_nftban.sh" <<'EOS'
#!/bin/bash
# v1.227 MAIL-F8: GENERATE the DEB conffiles from the actually-staged config set instead
EOS
for i in 1 2 3 4 5 6; do echo "setting_$i=value" > "$R/etc/nftban/conf.d/mod$i.conf"; done
echo "profile: default" > "$R/etc/nftban/conf.d/prof.yaml"
echo "NFTBAN_X=1"      > "$R/install/config/nftban.conf"
echo "table ip nftban {}" > "$R/install/nftables/nftables.conf"
echo "ignored"         > "$R/etc/nftban/conf.d/sample.conf.default"
echo "ignored"         > "$R/etc/nftban/conf.d/user.conf.local"
cp "$GATE" "$R/scripts/ci/check-conffile-mutation.sh"; chmod +x "$R/scripts/ci/check-conffile-mutation.sh"
git -C "$R" add -A >/dev/null; git -C "$R" commit -qm base
git -C "$R" tag vBASE
run() { ( cd "$R" && bash scripts/ci/check-conffile-mutation.sh vBASE "${1:-HEAD}" 2>&1 ); }

echo "=== UNCHANGED baseline must PASS ==="
out="$(run vBASE)"
grep -q "conffile-mutation PASS" <<<"$out" && ok "identical refs -> PASS" || { bad "identical refs did not pass"; sed 's/^/      /' <<<"$out" | tail -6; }
# 8, not 9: install/nftables/nftables.conf is present in the fixture but is
# NOT a conffile source from v1.229.12 — it became a generated runtime artifact.
grep -qE "conffile sources: baseline=8 candidate=8" <<<"$out" \
    && ok "source set derived correctly (8: 6 .conf + 1 yaml + 1 install), .default/.local and nftables.conf excluded" \
    || { bad "unexpected source count"; grep "conffile sources" <<<"$out" | sed 's/^/      /'; }

# ⛔ PROVE THE EXCLUSION IS REAL, don't just accommodate the new number. The
#    fixture still SHIPS install/nftables/nftables.conf; mutating it must NOT be
#    reported, because it is no longer protected config. If this arm ever fails,
#    the gate and packaging disagree about who owns that file again.
echo "=== generated-runtime artifact is NOT protected config (v1.229.12) ==="
echo "table ip nftban { chain c {} }" > "$R/install/nftables/nftables.conf"
git -C "$R" commit -aqm mutate-generated-artifact
out="$(run HEAD)"
grep -q "conffile-mutation PASS" <<<"$out" \
    && ok "mutating the generated nftables.conf does NOT trip the gate (no ACK needed)" \
    || { bad "generated nftables.conf still treated as protected config"; sed 's/^/      /' <<<"$out" | tail -6; }
grep -qi "NFTBAN_CONFFILE_ACK" <<<"$out" \
    && bad "gate suggested an ACK for a file that is not protected config" \
    || ok "gate did not ask for an acknowledgement"
git -C "$R" reset -q --hard vBASE

echo "=== PLANTED MUTATION must FAIL and name the path ==="
echo "setting_3=CHANGED" > "$R/etc/nftban/conf.d/mod3.conf"
git -C "$R" commit -aqm mutate
out="$(run HEAD)"
grep -q "conffile-mutation FAIL" <<<"$out" && ok "planted mutation -> FAIL" || bad "planted mutation NOT detected"
grep -q "etc/nftban/conf.d/mod3.conf" <<<"$out" && ok "names the exact mutated path" || bad "does not name the path"

echo "=== the mutation can be ACKNOWLEDGED, and only that path ==="
out="$( cd "$R" && NFTBAN_CONFFILE_ACK="etc/nftban/conf.d/mod3.conf" bash scripts/ci/check-conffile-mutation.sh vBASE HEAD 2>&1 )"
grep -q "conffile-mutation PASS" <<<"$out" && ok "explicit ACK permits that one path" || bad "ACK did not permit the path"
out="$( cd "$R" && NFTBAN_CONFFILE_ACK="etc/nftban/conf.d/other.conf" bash scripts/ci/check-conffile-mutation.sh vBASE HEAD 2>&1 )"
grep -q "conffile-mutation FAIL" <<<"$out" && ok "an ACK for a DIFFERENT path does not excuse this one" || bad "ACK leaked across paths"

echo "=== ADDED conffile is reported but SAFE (installs without prompting) ==="
git -C "$R" checkout -q -- . 2>/dev/null; git -C "$R" reset -q --hard vBASE
echo "new=1" > "$R/etc/nftban/conf.d/mod7.conf"; git -C "$R" add -A >/dev/null; git -C "$R" commit -qm add
out="$(run HEAD)"
grep -q "conffiles ADDED" <<<"$out" && ok "addition is reported" || bad "addition not reported"
grep -q "conffile-mutation PASS" <<<"$out" && ok "addition alone does not fail the gate" || bad "addition wrongly failed the gate"

echo "=== REMOVED conffile must FAIL (orphans the operator's file) ==="
git -C "$R" reset -q --hard vBASE
git -C "$R" rm -q "$R/etc/nftban/conf.d/mod4.conf"; git -C "$R" commit -qm remove
out="$(run HEAD)"
grep -q "conffile-mutation FAIL" <<<"$out" && ok "removal -> FAIL" || bad "removal not detected"

echo "=== ⛔ NON-VACUITY: an implausibly small source set must FAIL, not pass ==="
git -C "$R" reset -q --hard vBASE
git -C "$R" rm -q -r "$R/etc/nftban" >/dev/null 2>&1
git -C "$R" rm -q "$R/install/config/nftban.conf" "$R/install/nftables/nftables.conf" >/dev/null 2>&1
git -C "$R" commit -qm strip
out="$(run HEAD)"
grep -q "implausibly small" <<<"$out" && ok "empty source set refuses to pass vacuously" || bad "vacuous set was not caught"

echo "=== ⛔ the gate must FAIL if the packaging authority it mirrors disappears ==="
git -C "$R" reset -q --hard vBASE
echo "#!/bin/bash" > "$R/packaging/build_nftban.sh"   # marker removed
git -C "$R" commit -aqm drop-authority
out="$(run HEAD)"
grep -q "conffile-generation block was not found" <<<"$out" \
    && ok "missing packaging authority -> FAIL (cannot silently drift from what it mirrors)" \
    || bad "gate did not notice its authority vanished"

# =============================================================================
# ⛔ B3 — THE GUARD MUST BE INVOKED. Everything above proves the SCRIPT behaves.
#    None of it proves the release path CALLS it. The gate shipped with tests,
#    passed them all, and protected nothing: `git grep check-conffile-mutation`
#    over .github/ matched only its own meta:name line. Existence is not
#    enforcement — assert the call site, not just the callee.
# =============================================================================
echo "=== ⛔ B3 INTEGRATION EDGE: the release path actually invokes the gate ==="
WF="$REPO_ROOT/.github/workflows/release.yml"
if [[ ! -f "$WF" ]]; then
    bad "release.yml not found — the wiring assertions below would be vacuous"
else
    # ⛔ Strip comments first. These are STRUCTURAL assertions; a comment that
    #    merely NAMES continue-on-error or `|| true` must not satisfy or break an
    #    arm. (Measured: the explanatory comment added with this very step tripped
    #    the continue-on-error assertion.)
    PREFLIGHT="$(awk '/^  release-preflight:/{n=1;next} n && /^  [a-z][a-z-]*:$/{exit} n{print}' "$WF" \
                 | sed 's/[[:space:]]*#.*$//')"
    [[ -n "$PREFLIGHT" ]] \
        && ok "release-preflight job exists in release.yml" \
        || bad "no release-preflight job — nothing gates publication"

    INVOKE="$(printf '%s\n' "$PREFLIGHT" | grep -F 'check-conffile-mutation.sh' | grep -v '^ *#' || true)"
    [[ -n "$INVOKE" ]] \
        && ok "release-preflight INVOKES check-conffile-mutation.sh" \
        || bad "gate is never called from release-preflight — B3: tested but inert"

    # A call that cannot fail the job is not enforcement either.
    if printf '%s\n' "$INVOKE" | grep -qE '\|\| *true|\|\| *:'; then
        bad "the gate invocation swallows its exit status (|| true) — cannot fail the release"
    else
        ok "gate invocation does not suppress its exit status"
    fi
    printf '%s\n' "$PREFLIGHT" | grep -q 'continue-on-error' \
        && bad "release-preflight sets continue-on-error — a failing gate would not stop the release" \
        || ok "release-preflight does not set continue-on-error"

    # The gate resolves its baseline via `git describe --tags`; a shallow
    # checkout returns nothing and the gate exits 2 on every run.
    printf '%s\n' "$PREFLIGHT" | grep -q 'fetch-depth: 0' \
        && ok "release-preflight checkout is deep (baseline tag resolvable)" \
        || bad "shallow checkout — git describe --tags finds no baseline, gate cannot run"

    # And the guard must gate PUBLICATION, not merely exist alongside it.
    grep -q 'needs: release-preflight' "$WF" \
        && ok "a build/publish job declares needs: release-preflight" \
        || bad "no job depends on release-preflight — it gates nothing"

    # NEGATIVE CONTROL: the detector must actually see a suppressed invocation.
    SUPPRESSED='        run: ./scripts/ci/check-conffile-mutation.sh || true'
    printf '%s\n' "$SUPPRESSED" | grep -qE '\|\| *true|\|\| *:' \
        && ok "detector DOES flag a suppressed invocation — assertions non-vacuous" \
        || bad "detector blind to '|| true' — the suppression assertion proves nothing"
fi

echo
echo "=== conffile_mutation_guard: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
