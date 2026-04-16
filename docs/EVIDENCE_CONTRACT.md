# NFTBan Evidence Contract (v1.88)

Evidence is an observability layer over kernel enforcement.
It answers: "what is actually happening?" — not "what should be happening?"

## Position in Architecture

| Layer | Role | Authority |
|-------|------|-----------|
| Kernel | Enforcement | Source of truth |
| Validator | Interpretation | Health authority |
| Evidence | Observability | No authority |

**Evidence MUST NOT influence status, exit codes, or protection decisions.**

## Evidence States

Every evidence datum is one of:

| State | Meaning |
|-------|---------|
| Present | Confirmed by kernel/journal data |
| Absent | Confirmed not present |
| Unknown | Collection failed — absence not known |

Evidence MUST NOT guess or infer missing data.
Failure MUST NOT be collapsed into absence.

## Counter Semantics

- Counter > 0 = positive enforcement evidence
- Counter = 0 = neutral (not failure)
- Counter unavailable (nil) = unknown
- Shared counters are family-level only; no source attribution

## Set Semantics

- Exists=true, Count>=0 = collected successfully
- Exists=false, Unknown=false = confirmed absent
- Unknown=true = collection failure

## Chain Semantics

- Same three-state model as sets

## Journal Evidence (v1.88)

- Bounded: 15m window, 500 lines, 3s timeout
- Exec failure = Unknown (not absence)
- Empty output with exit 0 = no events (not failure)
- LoginMon: bans and login_failed events from nftband journal

## Correlation

Correlation compares kernel evidence against validator interpretation.
It is **diagnostic only**.

### Allowed values

| Value | Meaning |
|-------|---------|
| match | Evidence agrees with validator |
| mismatch | Evidence contradicts validator |
| warning | Suspicious but explainable |
| expected_limitation | Not provable (portscan) |
| unknown | Insufficient evidence |

### Rules

- Unknown evidence → unknown correlation (never guessed)
- Correlation MUST NOT derive PROTECTED/DEGRADED/DOWN
- Correlation MUST NOT influence exit codes
- Default fallthrough → unknown (not match)

## Evidence Schema

Version: 1.88.0

```json
{
  "schema_version": "1.88.0",
  "collected_at": "...",
  "truth_authority": "kernel",
  "kernel": { "counters", "sets", "chains" },
  "external": { "loginmon_active", "loginmon_bans", "loginmon_events" },
  "validator": { "status", "modules", "findings" },
  "correlation": { "module": "result" }
}
```

## nft Command Compatibility

Safe everywhere:
- `nft -j list counters` (global)
- `nft list table <family> <table>`
- `nft list set <family> <table> <name>` (singular)
- `nft -j list ruleset` (global)

Broken on v1.0.x-v1.1.x:
- `nft list counters <family> <table>`
- `nft list chains <family> <table>`
- `nft list sets <family> <table>`
