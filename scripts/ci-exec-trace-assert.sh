#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.100 PR-P2-4 — CI exec-trace assertion helper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ci-exec-trace-assert"
# meta:type="script"
# meta:version="1.100.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-20"
# meta:description="Wrap a dry-run command under strace and fail if any forbidden mutation process was spawned"
# meta:inventory.files="scripts/ci-exec-trace-assert.sh"
# meta:inventory.binaries="/usr/bin/strace"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# Usage: ci-exec-trace-assert.sh <command args...>
#
# Runs the given command under `strace -f -e trace=execve`, captures
# every process spawn, then asserts no forbidden mutation binary was
# invoked. Passes through the wrapped command's exit code on success;
# exits non-zero if any forbidden execve is detected OR if the wrapped
# command itself failed.
#
# Contract (PR-P2-4, frozen 2026-04-20):
#   - Only fires on execve syscalls — does not depend on Go-level mocks
#   - Independent of source-grep patterns (catches dynamically-
#     constructed commands that grep cannot see)
#   - Minimal surface — focused grep pass on the trace file
#   - Degrades gracefully: if strace is unavailable, the command runs
#     unwrapped with a CI warning (never silently weakens)
#
# Falsifiability: every regex in FORBIDDEN below matches a specific
# execve shape the test expects to NEVER see during a dry-run. Any
# match = gate failure. The dry-run paths must be observational at
# the process-spawning level, not just the Go-function-call level.
#
# =============================================================================
set -Eeuo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <command args...>" >&2
    exit 2
fi

# Graceful degrade: if strace isn't present (should not happen in CI
# after the explicit install step, but possible on developer laptops),
# run the command unwrapped. Emit a GitHub-Actions warning so CI logs
# flag the missing coverage.
if ! command -v strace >/dev/null 2>&1; then
    echo "::warning::strace not available — exec-trace assertion skipped for this invocation"
    exec "$@"
fi

TRACE=$(mktemp /tmp/ci-exec-trace.XXXXXX)
trap 'rm -f "$TRACE"' EXIT

# Wrap the caller's command. -f follows forks (so Go subprocess spawns
# are caught); -e trace=execve restricts to the one syscall that spawns
# a new binary. Output goes to $TRACE, the actual command runs against
# the real terminal so its output is still visible in the CI log.
set +e
strace -f -e trace=execve -o "$TRACE" -- "$@"
rc=$?
set -e

# FORBIDDEN patterns — each is an extended regex; a match = gate
# failure. Every pattern targets a specific mutation-flavored invocation
# shape. Read-only calls (nft list, systemctl is-active, iptables-save)
# do NOT match and are allowed.
FORBIDDEN=(
    # nft with mutation verbs. Read-only "nft list ..." does not match.
    'execve\("[^"]*", \["nft", "(add|create|delete|flush)"'
    # systemctl lifecycle verbs anywhere in argv. Read-only
    # "is-active"/"is-enabled"/"status"/"show" do not match.
    'execve\("[^"]*", \["systemctl"[^]]*"(start|stop|restart|reload|enable|disable|mask|unmask)"'
    # External firewall binaries — any invocation is mutation intent
    # (these tools have no read-only subcommands our dry-run could
    # legitimately need). Match on argv[0].
    'execve\("[^"]*", \["ufw"'
    'execve\("[^"]*", \["firewall-cmd"'
    'execve\("[^"]*", \["iptables-restore"'
    'execve\("[^"]*", \["ip6tables-restore"'
    # CSF invocations with destructive flags.
    'execve\("[^"]*", \["csf"[^]]*"(-e|-x|--enable|--disable)"'
    # Package-manager mutation verbs.
    'execve\("[^"]*", \["apt-get"[^]]*"(remove|purge)"'
    'execve\("[^"]*", \["dnf"[^]]*"(remove|erase)"'
    'execve\("[^"]*", \["rpm"[^]]*"-e"'
    'execve\("[^"]*", \["dpkg"[^]]*"(--remove|--purge)"'
    # User/group deletion.
    'execve\("[^"]*", \["userdel"'
    'execve\("[^"]*", \["groupdel"'
)

fail=0
for pat in "${FORBIDDEN[@]}"; do
    if grep -nE "$pat" "$TRACE" >/dev/null 2>&1; then
        echo "::error::G3-EXEC-TRACE FAIL: forbidden mutator spawned during dry-run"
        echo "  pattern: $pat"
        echo "  matched execve calls (up to 5):"
        grep -nE "$pat" "$TRACE" | head -5 | sed 's/^/    /'
        fail=1
    fi
done

if (( fail > 0 )); then
    echo "::error::G3-EXEC-TRACE: dry-run spawned one or more forbidden mutation binaries (see patterns above)"
    exit 1
fi

# Propagate the wrapped command's exit code unchanged. The trace
# assertion is purely additive — it neither rescues a failing command
# nor masks a passing one.
exit $rc
