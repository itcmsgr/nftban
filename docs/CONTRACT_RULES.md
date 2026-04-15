# NFTBan Contract Rules (v1.86)

These rules define how the system works. They are enforced by CI.

## Truth Authority

1. **Kernel** (`nft list ruleset`) is the only enforcement authority.
2. **Go validator** (`nftban-validate`) is the only health/truth interpreter.
3. **CLI** (`nftban`) presents validator output only — never derives truth.
4. **Config** expresses operator intent, not runtime state.

When sources disagree, kernel wins.

## Module Inventory

5. **ModuleHealthMap** is the only canonical module representation.
6. Every config-present module must be classified (G8-2).
7. Every CORE_MODULE must have: evaluator + JSON field + tests (G8-1).
8. CORE_INFRA entries are served by parent evaluators.
9. ADVISORY/MONITOR/EXTERNAL modules must NOT appear in validator JSON.

## Classification Taxonomy

| Class | Meaning | Evaluator Required |
|-------|---------|-------------------|
| CORE_MODULE | Protection module with health derivation | YES |
| CORE_INFRA | Internal support, served by parent | NO |
| ADVISORY | Non-blocking, no enforcement | NO |
| MONITOR | Observation only | NO |
| EXTERNAL | Third-party integration | NO |

## Evidence Rules

10. Counter > 0 = positive evidence. Counter = 0 = neutral (not failure).
11. Shared counters cannot be used for source attribution.
12. Structure alone does not imply enforcement.
13. Absence of evidence is not evidence of absence.
14. IPv6 must be checked when IPv4 is checked (G8-3).

## CLI Output Rules

15. No banned terms: "healthy", "working", "OK" (health context), "all clear",
    "no attacks", "protecting your", "rules loaded" (as protection claim).
16. Exit codes: 0=PROTECTED/IDLE, 1=DEGRADED, 2=DOWN (G7-3).
17. JSON schema version must match between binary and CLI (G2-3).

## Forbidden Constructs

18. No legacy fallback paths (enforced by CI grep).
19. No ModuleTruth or dual module inventory (enforced by CI grep).
20. No shell-based truth derivation in truth-critical commands.
