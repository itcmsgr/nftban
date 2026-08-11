#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.x R2 (O1) — LEGACY RESTORE AUTHORITY NEUTRALIZED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="legacy-restore-neutralized-v1229-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-11"
# meta:description="R2/O1 gate. Proves nftban firewall restore {fail2ban,csf,ufw,firewalld} reach an explicit non-zero refusal and mutate nothing: no NFTBan service change, no nft table deletion, no foreign service start, no foreign vendor binary execution."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.privileges="none"
# meta:ta.id="legacy_restore_neutralized_v1229_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall"
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
# WHAT THIS GUARDS. The legacy path ran, for ALL FOUR targets, an unconditional
# prefix that stopped/disabled NFTBan services and deleted `ip nftban` +
# `ip6 nftban` BEFORE proving the replacement could start:
#
#     REPLACEMENT_NOT_PROVEN + NFTBAN_AUTHORITY_ALREADY_DESTROYED
#       = FAILED_NO_FIREWALL
#
# It was ungated, untested, publicly documented, and duplicated a safer Go
# authority. O1 neutralized all four.
#
# HARNESS POLICY: never `producer | grep -q` under pipefail — SIGPIPE 141 turns
# a MATCH into a non-match. Capture, then match.
# =============================================================================
# shellcheck disable=SC2030,SC2031,SC2015
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; echo "       $2"; FAIL=$((FAIL+1)); }

SANDBOX="$(mktemp -d)"
# PID-guarded: an unguarded EXIT trap is inherited by ( ) subshells and would
# delete the mocks after the first arm, making every later arm pass vacuously.
MAIN_PID=$$
trap '[[ $BASHPID == "$MAIN_PID" ]] && rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# Every mutating tool the legacy prefix used is shadowed and records calls.
for tool in systemctl nft csf ufw firewall-cmd fail2ban-client; do
    cat > "$SANDBOX/bin/$tool" <<MOCK
#!/usr/bin/env bash
echo "$tool \$*" >> "\${MUTATION_LOG:?}"
exit 0
MOCK
    chmod +x "$SANDBOX/bin/$tool"
done
export MUTATION_LOG="$SANDBOX/mutations.log"

# Extract just the function under test so the arm does not need the whole CLI.
extract_fn() { awk '/^_restore_previous_firewall\(\)/{f=1} f{print} f&&/^}/{exit}' "$FW"; }

run_target() { # $1=target -> prints "rc=N" then captured output
    : > "$MUTATION_LOG"
    ( export PATH="$SANDBOX/bin:$PATH"
      eval "$(extract_fn)"
      out=$(_restore_previous_firewall "$1" 2>&1); rc=$?
      echo "rc=$rc"
      printf '%s\n' "$out"
    )
}

mutations_of() { # count recorded calls that are actually STATE-CHANGING
    # `grep -c` prints 0 AND exits 1 on no-match, so a `|| echo 0` fallback
    # emits TWO values and every numeric comparison downstream errors out.
    local L n
    L=$(cat "$MUTATION_LOG" 2>/dev/null)
    n=$(printf '%s\n' "$L" | grep -cE '^(nft (delete|add|flush)|systemctl (stop|start|enable|disable|mask)|csf -[esx]|ufw enable|firewall-cmd|fail2ban-client)' 2>/dev/null) || true
    echo "${n:-0}"
}

echo "── T1  every target REFUSES with non-zero exit ────────────────────────"
for T in fail2ban csf ufw firewalld; do
    OUT="$(run_target "$T")"
    RC=$(printf '%s\n' "$OUT" | sed -n 's/^rc=//p' | head -1)
    [ "${RC:-0}" -ne 0 ] && ok "$T: non-zero refusal (rc=$RC)" \
                         || no "$T: did NOT refuse" "rc=$RC"
    case "$OUT" in *DISABLED*|*disabled*) ok "$T: refusal wording present";; *) no "$T: no refusal wording" "$OUT";; esac
done

echo "── T2  no state mutation of ANY kind ──────────────────────────────────"
for T in fail2ban csf ufw firewalld; do
    run_target "$T" >/dev/null
    M=$(mutations_of)
    [ "$M" -eq 0 ] && ok "$T: zero state-changing calls" \
                   || no "$T: MUTATED state" "$(cat "$MUTATION_LOG")"
done

echo "── T3  the specific forbidden operations, named ───────────────────────"
: > "$MUTATION_LOG"
for T in fail2ban csf ufw firewalld; do run_target "$T" >/dev/null; done
LOG=$(cat "$MUTATION_LOG" 2>/dev/null)
check_absent() { # $1=label $2=regex
    local n; n=$(printf '%s\n' "$LOG" | grep -cE "$2")
    [ "$n" -eq 0 ] && ok "$1 never invoked" || no "$1 INVOKED" "$(printf '%s\n' "$LOG" | grep -E "$2" | head -2)"
}
check_absent "nft table deletion"        '^nft delete'
check_absent "NFTBan service stop"       '^systemctl (stop|disable) (nftband|nftban)'
check_absent "foreign service start"     '^systemctl (start|enable) (fail2ban|lfd|ufw|firewalld|csf)'
check_absent "foreign vendor binary"     '^(csf|ufw|firewall-cmd|fail2ban-client) '

echo "── T4  FALSIFIABILITY: the harness detects the old prefix ─────────────"
# Reintroduce the destructive prefix in a fixture copy. If the harness cannot
# see it, T2/T3 prove nothing.
: > "$MUTATION_LOG"
( export PATH="$SANDBOX/bin:$PATH"
  _legacy_prefix() {
      systemctl stop nftband
      systemctl disable nftban-maintenance.timer
      nft delete table ip nftban
      nft delete table ip6 nftban
      systemctl start fail2ban
  }
  _legacy_prefix >/dev/null 2>&1
) || true
M4=$(mutations_of)
[ "$M4" -gt 0 ] && ok "old destructive prefix IS detected ($M4 calls) — T2/T3 non-vacuous" \
               || no "harness blind to the destructive prefix" "T2/T3 would be meaningless"

echo "── T5  static: the shipped function contains no destructive verb ──────"
# Comments are stripped: prose describing the removed defect must neither
# satisfy nor violate the assertion (GUARD_SUBJECT == GUARD_INPUT).
BODY=$(extract_fn | sed 's/#.*//')
BADV=$(printf '%s\n' "$BODY" | grep -cE '(nft +(delete|flush|add)|systemctl +(stop|start|enable|disable)|csf +-[esx]|ufw +enable)')
[ "$BADV" -eq 0 ] && ok "shipped function body is free of destructive verbs" \
                  || no "destructive verb still present" "$(printf '%s\n' "$BODY" | grep -E '(nft +(delete|flush)|systemctl +(stop|start))' | head -2)"

echo "── T6  backup list/create/file-restore remain reachable ───────────────"
# O1 withdrew the four firewall targets ONLY. The backup subcommands are a
# separate capability and must not have been collaterally disabled.
DISPATCH=$(awk '/^firewall_restore\(\)/{f=1} f{print} f&&/^}/{exit}' "$FW")
for SUB in 'list)' 'backup)' '_restore_from_file'; do
    case "$DISPATCH" in *"$SUB"*) ok "dispatch still routes $SUB";; *) no "$SUB lost" "collateral damage";; esac
done

echo
echo "══ RESULT: PASS=$PASS FAIL=$FAIL ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
