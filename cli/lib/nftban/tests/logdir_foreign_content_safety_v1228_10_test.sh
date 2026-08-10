#!/usr/bin/env bash
# =============================================================================
# NFTBan - LogDir foreign-content safety (v1.228.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logdir_foreign_content_safety_v1228_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-10"
# meta:description="INV-LOG-OWN-01: no install-time permission authority may re-own or re-mode a file under /var/log/nftban merely because it exists there. Runs the REAL generated fhs-permissions.sh and the REAL nftban_permissions.sh log block against a rebased sandbox with recording chown/chmod shims, and asserts that none of the six foreign controls is ever a mutation target. Extension, basename, nesting depth and parent-directory membership are each proven NOT to confer authority — the second of these was a real shipped defect (name-pattern globs), the fourth was a second permission authority found by syscall trace."
# meta:input="None (sandbox fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp"
# meta:inventory.files="cli/lib/nftban/setup/fhs-permissions.sh,cli/lib/nftban/core/nftban_permissions.sh"
# meta:inventory.binaries="bash,grep,sed,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="logdir_foreign_content_safety_v1228_10_test"
# meta:ta.owner="packaging"
# meta:ta.module="fhs-permissions"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
GEN="$ROOT/cli/lib/nftban/setup/fhs-permissions.sh"
PERMS="$ROOT/cli/lib/nftban/core/nftban_permissions.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== logdir_foreign_content_safety_v1228_10 ==="
[[ -f "$GEN" ]] || { echo "  [FATAL] missing $GEN"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The six foreign controls. Names are chosen so that each one falsifies a DIFFERENT
# wrong theory of authority that this codebase has actually shipped or nearly shipped.
CONTROLS=(
  "reports/foreign.txt"            # extension matched a declared pattern — the shipped defect
  "reports/foreign.json"           # ditto, second declared pattern
  "reports/nftban.log"             # basename looks like ours; still not authority
  "reports/random-no-extension"    # no extension at all
  "reports/nested/foreign.txt"     # depth + extension
  "reports/nested/random"          # depth alone — the syscall-traced second-authority case
)

sandbox() {
    local sb="$1"
    mkdir -p "$sb/var/log/nftban/reports/nested" "$sb/var/log/nftban/reports/foreign-dir"
    local c
    for c in "${CONTROLS[@]}"; do
        mkdir -p "$(dirname "$sb/var/log/nftban/$c")"
        printf 'foreign\n' > "$sb/var/log/nftban/$c"
    done
    printf 'x\n' > "$sb/var/log/nftban/reports/foreign-dir/f"
    printf 'ext\n' > "$sb/external-file"
    ln -sfn "$sb/external-file" "$sb/var/log/nftban/reports/link" 2>/dev/null || true
}

# Run one real authority against the sandbox with recording shims. chown/chmod are
# recorded rather than executed: the property under test is WHICH PATHS an authority
# targets, and real ownership change needs root (package-native covers that half).
run_authority() { # $1=sandbox  $2=which  -> writes $sb/mutations.txt
    local sb="$1" which="$2"
    : > "$sb/mutations.txt"
    if [[ "$which" == "generated" ]]; then
        sed -e "s#\"/var/log/nftban#\"$sb/var/log/nftban#g" \
            -e "s#\"/var/lib/nftban#\"$sb/var/lib/nftban#g" \
            -e "s#\"/etc/nftban#\"$sb/etc/nftban#g" \
            -e "s#\"/usr/lib/nftban#\"$sb/usr/lib/nftban#g" \
            -e "s#\"/usr/sbin#\"$sb/usr/sbin#g" "$GEN" > "$sb/auth.sh"
    else
        # the log block of the second authority, with its guards satisfied
        # Extract to the END OF THE ENCLOSING FUNCTION, not to the first `fi`. A
        # first-`fi` range truncates inside nested if-blocks, leaving an unclosed `if`;
        # sourcing then fails silently and every assertion in this arm passes VACUOUSLY.
        awk '/^[[:space:]]*perms_say "Enforcing file permissions in: \$PERMS_LOG"/{f=1}
             f{print}
             f&&/^\}$/{exit}' "$PERMS" > "$sb/auth_body.sh"
        {
            echo "PERMS_LOG=\"$sb/var/log/nftban\""
            echo 'perms_say() { :; }'
            echo 'perms_run() { "$@"; }'
            cat "$sb/auth_body.sh"
        } > "$sb/auth.sh"
    fi
    # PATH shims, NOT shell functions. `find -exec chown …` executes the BINARY, so a
    # bash function would never be called and every assertion would pass vacuously —
    # which is exactly what the negative control caught on the first run of this test.
    mkdir -p "$sb/bin"
    for v in chown chmod setcap; do
        {
            echo '#!/usr/bin/env bash'
            echo "printf '$v %s\\n' \"\$*\" >> \"$sb/mutations.txt\""
            echo 'exit 0'
        } > "$sb/bin/$v"
        chmod +x "$sb/bin/$v"
    done
    (
        cd "$sb" || exit 1
        export PATH="$sb/bin:$PATH"
        # shellcheck source=/dev/null
        . "$sb/auth.sh" 2>/dev/null
        if [[ "$which" == "generated" ]]; then
            nftban_install_set_file_permissions
        fi
    ) >/dev/null 2>&1
}

targeted() { grep -qF "$2" "$1/mutations.txt" 2>/dev/null; }

for AUTH in generated permissions_module; do
    echo "--- authority: $AUTH ---"
    SB="$(mktemp -d "$WORK/sb.XXXXXX")"; sandbox "$SB"
    run_authority "$SB" "$AUTH"

    for c in "${CONTROLS[@]}"; do
        if targeted "$SB" "$SB/var/log/nftban/$c"; then
            bad "$AUTH: FOREIGN CONTROL TARGETED — $c"
        else
            ok "$AUTH: untouched — $c"
        fi
    done
    if targeted "$SB" "$SB/var/log/nftban/reports/foreign-dir/f"; then
        bad "$AUTH: foreign directory content targeted"
    else
        ok "$AUTH: foreign directory content untouched"
    fi
    if targeted "$SB" "$SB/external-file"; then
        bad "$AUTH: symlink referent targeted"
    else
        ok "$AUTH: symlink referent untouched"
    fi
    if targeted "$SB" "$SB/var/log/nftban/reports/link"; then
        bad "$AUTH: symlink itself targeted"
    else
        ok "$AUTH: symlink itself untouched"
    fi

    # PER-ARM NEGATIVE CONTROL. Without this, an arm whose body fails to source reports
    # nine silent PASSes — which is exactly what happened here before it was added.
    SBN="$(mktemp -d "$WORK/sbn.XXXXXX")"; sandbox "$SBN"
    mkdir -p "$SBN/var/log/nftban/suricata"; printf 'x\n' > "$SBN/var/log/nftban/suricata/eve.json"
    run_authority "$SBN" "$AUTH"
    if [[ -s "$SBN/mutations.txt" ]]; then
        ok "$AUTH: negative control — this arm CAN observe a mutation (not vacuous)"
    else
        bad "$AUTH: negative control — arm observed NOTHING; its assertions are vacuous"
    fi
done

# NEGATIVE CONTROL — the harness must be able to SEE a mutation, or every assertion
# above is vacuous. Re-run the generated authority against a sandbox whose suricata
# subtree is populated: that sweep is deliberately still in scope, so it MUST appear.
SB="$(mktemp -d "$WORK/sb.XXXXXX")"; sandbox "$SB"
mkdir -p "$SB/var/log/nftban/suricata"; printf 'x\n' > "$SB/var/log/nftban/suricata/eve.json"
run_authority "$SB" generated
if targeted "$SB" "$SB/var/log/nftban/suricata/eve.json"; then
    ok "negative control: the harness DOES observe an in-scope mutation (suricata sweep)"
else
    bad "negative control: no mutation observed at all — the assertions above are vacuous"
fi

echo
echo "=== logdir_foreign_content_safety_v1228_10: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
