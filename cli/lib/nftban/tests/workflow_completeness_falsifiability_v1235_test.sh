#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - workflow syntax + expected-vs-executed completeness gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="workflow_completeness_falsifiability_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-09"
# meta:description="Owner 2026-10-09: five workflows carried invalid YAML (a step name containing ': ') and GitHub silently never ran them. Drives the REAL scripts/ci/check-workflow-completeness.sh on fixtures: syntax mode FAILS on that exact defect, on a missing on:/jobs: and on a job without runs-on/uses, and PASSES valid files; expected mode honours branches/paths/paths-ignore and refuses when a workflow is invalid; compare mode FAILS when an expected workflow did not run and on an empty expected set. Also: the repository's own workflows pass syntax mode and ci-architecture.yml runs it. Hermetic: temp dirs; needs python3-yaml."
# meta:input="None"
# meta:output="PASS/FAIL per arm; exit 1 on any failure"
# meta:depends="bash,python3,python3-yaml"
# meta:inventory.files="scripts/ci/check-workflow-completeness.sh,.github/workflows"
# meta:inventory.binaries="bash,python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="workflow_completeness_falsifiability_v1235_test"
# meta:ta.owner="test-infra"
# meta:ta.module="ci"
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
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
S="$REPO/scripts/ci/check-workflow-completeness.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "[NOT_EXECUTED] python3-yaml is not installed"; exit 1
fi

good() {  # <name> <pull_request body (indented 4)> <file>
    printf 'name: %s\non:\n  pull_request:\n%s\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' "$1" "$2" > "$3"
}
fresh() { rm -rf "$WORK/wf"; mkdir -p "$WORK/wf"; }
want() {  # <want rc> <desc> <cmd...>
    local w="$1" d="$2"; shift 2
    "$@" > "$WORK/out" 2>&1; local rc=$?
    if [[ $rc -eq $w ]]; then ok "$d (rc=$rc)"; else no "$d (rc=$rc, want $w)"; sed 's/^/        /' "$WORK/out"; fi
}

echo "=== syntax mode ==="
fresh; good "Valid" "    branches: [main]" "$WORK/wf/a.yml"
want 0 "valid workflow passes" bash "$S" syntax "$WORK/wf"
# The exact defect: an unquoted step name containing ': '.
fresh; cat > "$WORK/wf/bad.yml" <<'EOF'
name: Broken
on:
  pull_request:
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: Set up Go (every leg: the release compiler)
        run: echo hi
EOF
good "Valid" "    branches: [main]" "$WORK/wf/a.yml"
want 1 "step name with ': ' (the 2026-10-09 defect) fails" bash "$S" syntax "$WORK/wf"
fresh; printf 'name: X\njobs:\n  a:\n    runs-on: x\n' > "$WORK/wf/noon.yml"
want 1 "missing on: fails" bash "$S" syntax "$WORK/wf"
fresh; printf 'name: X\non: push\n' > "$WORK/wf/nojobs.yml"
want 1 "missing jobs: fails" bash "$S" syntax "$WORK/wf"
fresh; printf 'name: X\non: push\njobs:\n  a:\n    steps: []\n' > "$WORK/wf/norun.yml"
want 1 "job without runs-on/uses fails" bash "$S" syntax "$WORK/wf"
fresh
want 1 "empty workflow dir fails (nothing checked is not a pass)" bash "$S" syntax "$WORK/wf"
want 0 "the repository's own workflows are valid" bash "$S" syntax "$REPO/.github/workflows"
grep -q "check-workflow-completeness.sh syntax" "$REPO/.github/workflows/ci-architecture.yml" \
    && ok "ci-architecture.yml runs the syntax gate" || no "ci-architecture.yml does not run the syntax gate"

echo "=== expected mode ==="
fresh
good "Always"     "    branches: [main]" "$WORK/wf/1.yml"
good "OtherBase"  "    branches: [develop]" "$WORK/wf/2.yml"
good "GoOnly"     "    branches: [main]
    paths: ['cmd/**', 'internal/**']" "$WORK/wf/3.yml"
good "ShellOnly"  "    paths: ['cli/lib/nftban/*.sh']" "$WORK/wf/4.yml"
good "NotDocs"    "    paths-ignore: ['docs/**']" "$WORK/wf/5.yml"
printf 'name: PushOnly\non: push\njobs:\n  a:\n    runs-on: x\n' > "$WORK/wf/6.yml"
printf 'cli/lib/nftban/core/nftban_mail.sh\ndocs/a.md\n' > "$WORK/changed"
bash "$S" expected main "$WORK/changed" "$WORK/wf" > "$WORK/exp" 2>&1; rc=$?
got=$(sort "$WORK/exp" | tr '\n' ' ')
[[ $rc -eq 0 && "$got" == "Always NotDocs " ]] && ok "branches/paths/paths-ignore honoured (got: $got)" \
    || no "expected set wrong (rc=$rc got: $got; want: Always NotDocs)"
printf 'internal/x/y.go\n' > "$WORK/changed2"
got=$(bash "$S" expected main "$WORK/changed2" "$WORK/wf" | sort | tr '\n' ' ')
[[ "$got" == "Always GoOnly NotDocs " ]] && ok "a Go change adds the Go-filtered workflow (got: $got)" \
    || no "Go change expected set wrong (got: $got)"
printf 'name: Broken\non:\n  pull_request:\njobs:\n  a:\n    runs-on: x\n    steps:\n      - name: a: b\n' > "$WORK/wf/7.yml"
want 1 "an invalid workflow makes the expected set uncomputable (fails)" bash "$S" expected main "$WORK/changed" "$WORK/wf"

echo "=== compare mode ==="
printf 'Always\nNotDocs\n' > "$WORK/e"
printf 'Always\nNotDocs\nExtra\n' > "$WORK/x1"
want 0 "all expected ran" bash "$S" compare "$WORK/e" "$WORK/x1"
printf 'Always\n' > "$WORK/x2"
want 1 "an expected workflow that did not run fails" bash "$S" compare "$WORK/e" "$WORK/x2"
: > "$WORK/e0"
want 1 "an empty expected set fails" bash "$S" compare "$WORK/e0" "$WORK/x1"
printf 'Always-2\nNotDocs\n' > "$WORK/x3"
want 1 "names match exactly (no prefix/substring credit)" bash "$S" compare "$WORK/e" "$WORK/x3"

echo ""
echo "=== workflow_completeness_falsifiability_v1235: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
