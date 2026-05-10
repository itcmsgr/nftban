# V108 Item 3 — Heredoc-Safety Test Fixtures

Test inputs for `scripts/ci/test-heredoc-safety.sh`.

## Layout

Each fixture is a single `.sh` file under this directory plus a sibling `.expected` file describing the expected exit code and matching substring. The gate is invoked as:

```
bash scripts/ci/test-heredoc-safety.sh scan \
    --paths='<fixture-file>' \
    --allowlist=/dev/null
```

Each fixture directory may also contain a fixture-scoped allowlist file.

## Fixtures

| Fixture | Probes | Expected exit |
|---|---|---|
| `pass-clean.sh` | Quoted + var-only unquoted heredocs (PASS baseline) | 0 |
| `pass-escaped-tokens.sh` | Unquoted heredoc with `\``, `\$(...)`, `\${...}` — all escaped | 0 |
| `pass-function-context.sh` | Unquoted heredoc inside `usage()` with `$(basename "$0")` (Option-α PASS_FUNCTION_CONTEXT) | 0 |
| `fail-unescaped-backtick.sh` | Unquoted heredoc with raw markdown backtick — the v1.107.1-class defect | 1 |
| `fail-unescaped-cmd-subst.sh` | Unquoted heredoc with raw `$(some_command)` outside function context | 1 |
| `fail-unescaped-arith.sh` | Unquoted heredoc with raw `$((1+2))` | 1 |
| `fail-unclosed-heredoc.sh` | Heredoc opener with no closer | 1 |
| `warn-should-be-quoted.sh` | Unquoted heredoc with NO `$` and NO backticks (style WARN) | 0 (WARN only) |

## Running fixtures

```bash
cd /home/gituser/github/nftban
for f in scripts/ci/fixtures/heredoc-safety/*.sh; do
    expected=$(grep '^# expected-exit:' "$f" | head -1 | sed 's/^# expected-exit: //')
    set +e
    bash scripts/ci/test-heredoc-safety.sh scan --paths="$f" --allowlist=/dev/null >/dev/null 2>&1
    actual=$?
    set -e
    [[ "$actual" == "$expected" ]] && echo "✅ $f" || echo "❌ $f (got $actual, want $expected)"
done
```

## Notes

- Fixtures intentionally include the SPDX + meta header block so they pass `tools/validate-headers.sh` on commit.
- `set -Eeuo pipefail` is included even though fixtures aren't executed at runtime — they're scanned only.
- Fixture content stays minimal — just enough to exercise one specific failure mode.
