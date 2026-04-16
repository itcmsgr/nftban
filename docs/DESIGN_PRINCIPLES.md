# NFTBan Design Principles — v1.9x Contract

**Version:** 1.0
**Date:** 2026-04-16
**Scope:** All components (kernel schema, validator, CLI, modules, CI gates)
**Authority:** Kernel is the only source of truth
**Enforcement:** Violations must be caught by CI or validator (not human review)

---

## 1. Kernel Authority Principle (NON-NEGOTIABLE)

**Statement:** The nftables kernel state is the only authoritative
representation of protection.

- CLI must derive, never assume
- Config is intent, not truth
- Cache is optimization, not authority
- Validator reads kernel → produces truth → CLI renders

**Hard rules:**
- No CLI output without kernel verification
- No "assumed protected" states
- No config-based status decisions

**Enforcement:** G16 (validator tests), G17 (health schema), soak invariant

---

## 2. Evidence-Based Protection Principle

**Statement:** A system is PROTECTED only if measurable enforcement activity exists.

**Accepted evidence:**
- Named counters (primary)
- Set element activity (secondary)
- Rate-limit/meter hits
- Drop/accept deltas tied to protection logic

**Rejected evidence:**
- Structural presence alone
- Module "enabled" flags
- Process running state

**Hard rules:**
- Structural-only modules cannot claim PROTECTED
- Zero-activity = IDLE (not PROTECTED)
- Missing counters = DEGRADED

---

## 3. Structural Integrity Principle

**Statement:** Kernel structure must match the canonical schema exactly.

- Anchors (7 per family)
- Chain ordering
- Jump placement (no shadowing)
- Required sets existence and type

**Hard rules:**
- Shadowed rules = DEGRADED
- Missing anchor = DOWN
- Misordered jumps = DEGRADED
- Chain behind unreachable accept = structurally dead

**Enforcement:** Validator structural pass, shadow detection (1.90)

---

## 4. Consistency Principle (Three Truth Sources)

**Statement:** All system views must agree.

| Source | Role |
|---|---|
| Kernel | Real enforcement state |
| Validator | Interpreted health |
| CLI | Presented to operator |

**Hard rules:**
- Any mismatch = DEGRADED
- CLI optimistic output = forbidden
- Partial parsing = DEGRADED

---

## 5. Deterministic Lifecycle Principle

**Statement:** All modules must have a fully defined lifecycle contract.

**States:** ENABLED → ACTIVE → IDLE → DEGRADED → DISABLED

**Hard rules:**
- No "ghost modules" (jumps without backing logic)
- Disable must remove all kernel artifacts (or document residual)
- Enable must be idempotent
- Stale jumps after disable = violation

---

## 6. Observability First Principle

**Statement:** Every protection decision must be observable via kernel-native signals.

**Mechanisms:**
- Named counters (mandatory)
- Structured logging (secondary)
- Set transitions (BotGuard, blacklist)

**Hard rules:**
- Logic without counters = invalid
- Unobservable drops = invalid
- Metrics derived outside kernel = advisory only

**Direction:** Unified Metrics Layer (kernel → normalized metrics → CLI)

---

## 7. No Shadowing Principle

**Statement:** No rule may render another rule unreachable.

**Shadow types:**
- Early ACCEPT masking detection
- Meter ACCEPT masking analysis
- Broad port rules before specific detectors

**Hard rules:**
- Any shadowing = DEGRADED
- Silent shadowing = CRITICAL BUG

**1.90 requirement:** Shadow detection (static + runtime anchor analysis)

---

## 8. Fail-Closed Truth Principle

**Statement:** When in doubt, report DEGRADED, never PROTECTED.

**Hard rules:**
- Missing data ≠ OK
- Partial parsing ≠ OK
- Unknown state ≠ OK

**Mapping:**
- Unknown → DEGRADED
- Broken structure → DOWN
- No activity → IDLE

---

## 9. Reproducibility & Idempotency Principle

**Statement:** All operations must produce deterministic results.

**Applies to:** Rebuild, enable/disable, update, validator output

**Hard rules:**
- Rebuild drift = BUG
- Multiple states from same input = BUG

**Enforcement:** G18 (rebuild safety), soak rebuild tests

---

## 10. Minimal Trust Surface Principle

**Statement:** Trust only what is measurable inside the system boundary.

| Trusted | Untrusted |
|---|---|
| Kernel nftables state | Logs (unless validated) |
| Netlink-derived data | External APIs |
| | Config files |

**Implication:** Suricata, BotGuard inputs = advisory → must materialize in kernel

---

## 11. Metrics Unification Principle

**Statement:** All observability must converge into a single, canonical metrics layer.

**Target state (1.9x):**
- Unified metrics model: metric_id, source, semantic meaning, module binding
- CLI = metrics renderer
- Validator = metrics validator

**Hard rules:**
- No duplicate metric logic across components
- No implicit metric meaning
- No CLI-only metrics

---

## 12. CI-Enforced Truth Principle

**Statement:** All principles must be machine-enforced.

**Required gates:**
- G16 → Validator correctness
- G17 → Health schema
- G18 → Rebuild safety
- G19 → Validator binary integrity

**1.90 additions:**
- Shadow detection tests
- Lifecycle integrity tests
- Metrics schema validation

---

## System-Level Invariants (Must Always Hold)

1. Kernel == Truth
2. No Shadowed Logic
3. All Protection Has Evidence
4. All Views Are Consistent
5. Lifecycle Leaves No Residue
6. Metrics Are Unified
7. Unknown → DEGRADED

---

## Usage

This document must be:
- Referenced in every PR touching kernel/validator/CLI
- Enforced via CI gates
- Embedded into validator assumptions
- Linked from README and STATUS page
