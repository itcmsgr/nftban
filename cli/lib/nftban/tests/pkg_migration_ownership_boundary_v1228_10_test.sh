#!/usr/bin/env bash
# =============================================================================
# NFTBan - package migration ownership boundary (v1.228.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="pkg_migration_ownership_boundary_v1228_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-09"
# meta:description="Behavioural proof for OPEN_PACKAGE_MIGRATION_RECURSIVE_OWNERSHIP_BOUNDARY. Extracts the REAL _nftban_migrate_reports_to_log() from packaging/deb/postinst and runs it against a sandbox with recording chown/chmod shims, so the assertion is WHICH PATHS the privileged maintainer script claims ownership of. Proves INV-PKG-OWN-01..06: only artifacts the migration created or moved are chowned; a foreign file already in the destination keeps its ownership; a symlink is never a chown target; a host without the legacy source performs no ownership mutation; repeated execution is idempotent. Also asserts DEB/RPM parity by comparing the emitted RPM scriptlet body in packaging/build_nftban.sh. Unprivileged and hermetic — real ownership change needs package-native lab validation."
# meta:input="None (sandbox fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,mktemp"
# meta:inventory.files="packaging/deb/postinst,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,awk,grep,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="pkg_migration_ownership_boundary_v1228_10_test"
# meta:ta.owner="packaging"
# meta:ta.module="package-migration-ownership"
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
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
POSTINST="$ROOT/packaging/deb/postinst"
BUILDER="$ROOT/packaging/build_nftban.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== pkg_migration_ownership_boundary_v1228_10 ==="

[[ -f "$POSTINST" ]] || { echo "  [FATAL] missing $POSTINST"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the REAL migration function verbatim from the shipped postinst.
FN="$WORK/migrate.sh"
awk '/^_nftban_migrate_reports_to_log\(\) \{/{f=1} f{print} f&&/^[[:space:]]*\}[[:space:]]*$/{exit}' \
    "$POSTINST" > "$FN"
if grep -q '_nftban_migrate_reports_to_log()' "$FN"; then
    ok "extracted _nftban_migrate_reports_to_log() from packaging/deb/postinst"
else
    bad "could not extract the migration function"; echo "FAIL=$FAIL"; exit 1
fi

# The function hardcodes absolute paths. Rebase them onto the sandbox so the test
# never touches real system directories.
run_migration() { # $1 = sandbox root
    local sb="$1"
    sed -e "s#/var/lib/nftban#$sb/var/lib/nftban#g" \
        -e "s#/var/log/nftban#$sb/var/log/nftban#g" "$FN" > "$sb/fn.sh"
    (
        cd "$sb" || exit 1
        export CHOWN_LOG="$sb/chown.log" CHMOD_LOG="$sb/chmod.log"
        : > "$CHOWN_LOG"; : > "$CHMOD_LOG"
        # Recording shims: real chown needs root, and the property under test is
        # WHICH PATHS ownership is claimed on — not the kernel's uid bookkeeping.
        #
        # A recursive invocation must be EXPANDED here. `chown -R DIR` names only DIR
        # on its command line while the real binary walks every descendant, so a shim
        # that logged the literal arguments would let the pre-fix implementation pass
        # the foreign-file and symlink assertions vacuously. Expansion is what makes
        # this test discriminate. Symlinks are recorded as targets but NOT followed,
        # matching chown's documented default (-P), so the test never claims that a
        # referent outside the tree was mutated.
        chown() {
            printf '%s\n' "$*" >> "$CHOWN_LOG"
            local a recursive=0 t
            for a in "$@"; do
                case "$a" in -R|--recursive|-*R*) recursive=1 ;; esac
            done
            if [ "$recursive" -eq 1 ]; then
                for t in "$@"; do
                    [ -e "$t" ] || continue
                    case "$t" in -*|*:*) continue ;; esac
                    command find "$t" -print 2>/dev/null >> "$CHOWN_LOG"
                done
            fi
            return 0
        }
        chmod() { printf '%s\n' "$*" >> "$CHMOD_LOG"; command chmod "$@" 2>/dev/null; return 0; }
        restorecon() { return 0; }
        # shellcheck source=/dev/null
        . "$sb/fn.sh"
        _nftban_migrate_reports_to_log
    ) >/dev/null 2>&1
}

mk_sandbox() { # -> echoes sandbox root; legacy report present by default
    local sb; sb="$(mktemp -d "$WORK/sb.XXXXXX")"
    mkdir -p "$sb/var/lib/nftban/reports" "$sb/var/log/nftban/reports"
    printf 'legacy\n' > "$sb/var/lib/nftban/reports/report.json"
    echo "$sb"
}

chowned() { grep -qF -- "$2" "$1/chown.log"; }

# ---------------------------------------------------------------------------
echo "=== A. the migrated artifact IS claimed ==="
SB="$(mk_sandbox)"; run_migration "$SB"
if chowned "$SB" "$SB/var/log/nftban/reports/report.json"; then
    ok "migrated file is chowned at its exact destination path"
else
    bad "migrated file was never chowned — migration output would keep the wrong owner"
fi
if grep -q 'nftban:nftban' "$SB/chown.log"; then
    ok "ownership claimed is nftban:nftban"
else
    bad "unexpected ownership target: $(head -1 "$SB/chown.log")"
fi
[[ -f "$SB/var/log/nftban/reports/report.json" ]] && ok "the file actually moved to the new path" \
    || bad "migration did not move the file — fixture did not exercise the path"

# ---------------------------------------------------------------------------
echo "=== B. INV-PKG-OWN-02 — a foreign file in the destination is NOT claimed ==="
SB="$(mk_sandbox)"
printf 'not ours\n' > "$SB/var/log/nftban/reports/foreign.txt"
run_migration "$SB"
if chowned "$SB" "$SB/var/log/nftban/reports/foreign.txt"; then
    bad "FOREIGN FILE WAS CHOWNED — the package claimed ownership of content it did not create"
else
    ok "foreign file in the destination is never a chown target"
fi
# Negative control: the run must genuinely have chowned SOMETHING, or the assertion
# above would pass simply because ownership was never applied at all.
if [[ -s "$SB/chown.log" ]]; then
    ok "negative control: the migration did claim its own artifacts in the same run"
else
    bad "no ownership was claimed at all — the foreign-file assertion is vacuous"
fi

# ---------------------------------------------------------------------------
echo "=== C. INV-PKG-OWN-03 — a symlink in the destination is NOT a chown target ==="
SB="$(mk_sandbox)"
printf 'external\n' > "$SB/external-owned-file"
ln -s "$SB/external-owned-file" "$SB/var/log/nftban/reports/link.txt" 2>/dev/null || true
run_migration "$SB"
if chowned "$SB" "$SB/var/log/nftban/reports/link.txt"; then
    bad "symlink was a chown target — referent ownership could be mutated"
else
    ok "symlink in the destination is never a chown target"
fi
if chowned "$SB" "$SB/external-owned-file"; then
    bad "the symlink REFERENT was chowned — ownership escaped the destination tree"
else
    ok "symlink referent outside the tree is untouched"
fi

# ---------------------------------------------------------------------------
echo "=== D. INV-PKG-OWN-05 — no legacy source means no ownership mutation ==="
SB="$(mktemp -d "$WORK/sb.XXXXXX")"
mkdir -p "$SB/var/log/nftban/reports"
printf 'pre-existing\n' > "$SB/var/log/nftban/reports/already.json"
run_migration "$SB"
if [[ -s "$SB/chown.log" ]]; then
    bad "ownership was mutated with no legacy source present: $(head -1 "$SB/chown.log")"
else
    ok "absent legacy source -> the migration performs no ownership mutation at all"
fi

# ---------------------------------------------------------------------------
echo "=== E. INV-PKG-OWN-06 — idempotence ==="
SB="$(mk_sandbox)"
printf 'not ours\n' > "$SB/var/log/nftban/reports/foreign.txt"
run_migration "$SB"
run_migration "$SB"   # second execution: legacy dir now empty but still present
if chowned "$SB" "$SB/var/log/nftban/reports/foreign.txt"; then
    bad "second run claimed the foreign file"
else
    ok "second execution still never claims foreign content"
fi
[[ -f "$SB/var/log/nftban/reports/report.json" ]] && ok "second execution preserves migrated content" \
    || bad "second execution lost the migrated file"

# ---------------------------------------------------------------------------
echo "=== F. no recursive ownership/mode verb survives in either family ==="
for f in "$POSTINST" "$BUILDER"; do
    if grep -qE '(chmod[[:space:]]+-R|chmod[[:space:]]+--recursive|chown[[:space:]]+-R|chown[[:space:]]+--recursive)' "$f"; then
        bad "$(basename "$f"): a recursive ownership/mode command is still present"
    else
        ok "$(basename "$f"): no recursive ownership/mode command"
    fi
done

# ---------------------------------------------------------------------------
echo "=== G. DEB/RPM parity — the emitted RPM scriptlet carries the same model ==="
if [[ -f "$BUILDER" ]]; then
    for tok in '_own_file()' '_own_dir()' '_own_dir "\$_new"' '_own_file "\$_n/\$_b"'; do
        if grep -qF -- "$tok" "$BUILDER"; then
            ok "RPM generator emits: $tok"
        else
            bad "RPM generator missing: $tok — package families would diverge"
        fi
    done
else
    bad "packaging/build_nftban.sh not found — cannot assert parity"
fi

echo
echo "=== pkg_migration_ownership_boundary_v1228_10: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
