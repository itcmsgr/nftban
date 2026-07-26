# Shell Input Parsing Standard

**Classification:** shell input-parsing / CI-compliance hygiene · **Severity:** LOW ·
**Security impact:** defense-in-depth · **Runtime defect:** NOT PROVEN

This is a secure-parsing standard and a regression-prevention item. It is **not** a confirmed
vulnerability, and must not be described as one unless an actual state-leak or input-confusion
exploit is reproduced. A locally scoped `IFS=x read` inside a tight function is not inherently
exploitable; the repository's scanner prohibits IFS-based input splitting as **policy**.

## The standard

> Do not mutate shell-global parsing state to parse untrusted or externally supplied lists when a
> bounded, explicit parser can be used.

Required properties of a list parser:

- no global or persistent `IFS` mutation for splitting input
- `IFS=` **on the read** so `read` does not trim implicitly — trimming stays explicit and auditable
- only **surrounding** whitespace trimmed, so identifiers containing internal spaces survive
- explicit empty-item handling
- no `|| true` concealing a pipeline failure
- tokens validated against a **strict allowlist**; unknown values fail deterministically
- a trailing newline on the input stream (see the trap below)

## Reference implementation

```bash
declare -A SCOPE_SET=()
while IFS= read -r _m; do
    _m="${_m#"${_m%%[![:space:]]*}"}"      # trim leading
    _m="${_m%"${_m##*[![:space:]]}"}"      # trim trailing
    [[ -z "${_m}" ]] && continue
    case "${_m}" in
        ddos|portscan|loginmon) SCOPE_SET["${_m}"]=1 ;;
        *) printf 'Invalid scope: %s\n' "${_m}" >&2; exit 2 ;;
    esac
done < <(printf '%s\n' "${RAW}" | tr ',' '\n')
```

## Two traps, both found by RUNNING the parser rather than reading it

**`[:space:]` includes the newline.** `tr -d '[:space:]'` after splitting collapses
`"a,b"` back into a single token `ab`. Single-value input still parses correctly, which hides the
defect. Use `[:blank:]`, or trim per-token as above.

**`printf '%s'` emits no trailing newline.** `read` then hits EOF and returns non-zero on the final
token, so the `while` body **never executes** and every list parses as empty — while the caller
reports a confident verdict about a list nobody successfully declared. Use `printf '%s\n'`.

Both are instances of the standing rule: **PASS ≠ INJECTION PROVEN**.

---

## Tracking

Open work for this standard is tracked **only** in the master register:

```
NFTBAN_ROADMAP/NFTBAN_PENDINGS_AND_BUGS_CURRENT.md  →  TODO-SHELL-INPUT-PARSING-AUTHORITY
```

This file is the *standard* (how to write the parser). It is not a TODO list and must not grow one —
there is one master register, and duplicate trackers drift.

**Known scanner population (not yet triaged):** pre-existing `ifs-tampering` findings on `main` in
`cli/lib/nftban/cli/cmd_logs.sh`, `cli/lib/nftban/core/nftban_rbl.sh` and
`cli/lib/nftban/core/nftban_hostaddr.sh`. That is a **triage population, not a defect count** — each
needs the local-versus-global distinction applied before any claim.
