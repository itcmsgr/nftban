# ci-bash disposition record — v1.226.0 PR-D (all 19 challenged)

PR-C exposed 19 failing `ci-bash` tests (`PRE_EXISTING_NEWLY_EXPOSED_TEST_FAILURES`). PR-D challenged
every one against current source (evidence-based, per-test, `file:line` cited). Outcome: **15 were stale
or obsolete test expectations, corrected test-only (no product change); 4 remain quarantined** (still
executed + reported, excluded from the blocking tally only via valid metadata + a matched failure pattern).

Enforcement after PR-D: `ci-bash` is **BLOCKING**. The informational 184/165/19 baseline is retired.
Quarantine ceiling was **4** (now **3** after PR-E2) (`scripts/ci/ci-bash-quarantine.tsv`). `CONFIRMED_PRODUCT_DEFECT` entries are
registered for a separate failure-domain lane and are **not** fixed in PR-D.

## Disposition summary

| disposition | count |
|---|---|
| TEST_EXPECTATION_STALE | 13 |
| FALSE_OR_OBSOLETE_TEST | 2 |
| PR_E_RBL_FIXTURE | 1 (quarantined) |
| ENVIRONMENT_SENSITIVE | 1 (quarantined) |
| CONFIRMED_PRODUCT_DEFECT | 2 (quarantined) |
| **total** | **19** |

**Fixed test-only (15):** product behavior verified correct; the test tracked drifted wording/structure.

| # | ta.id | disposition | test-only correction (product unchanged) |
|---|-------|-------------|------------------------------------------|
| 1 | banner_nobanner_v153_test | TEST_EXPECTATION_STALE | stub `nftban_render_banner_compact` (renderer renamed v1.187.3) |
| 2 | b2_badbot_aibot_v188_test | TEST_EXPECTATION_STALE | assert against the RPM-spec generator (`packaging/build_nftban.sh`), not a build artifact |
| 3 | botguard_explain_shell_6b1_test | TEST_EXPECTATION_STALE | bind stable substring of the reworded v1.219.0 cache-only header |
| 4 | botguard_diag_6b2_test | TEST_EXPECTATION_STALE | recovers transitively once #3 passes (no edit) |
| 5 | logs_truth_v150_test | TEST_EXPECTATION_STALE | header "exact"→"EXACT" (v1.222.0 banner shifted the line) |
| 6 | stats_manual_cache_v150_test | TEST_EXPECTATION_STALE | label "manual:"→"manual-set:" (v1.206.1 relabel) |
| 7 | stats_producer_reconcile_v152_test | TEST_EXPECTATION_STALE | label "incl. manual:"→"incl. manual-set:" (v1.206.1) |
| 8 | stats_status_truth_v150_test | TEST_EXPECTATION_STALE | `source`→`_source_local` (config-local-recovery helper migration) |
| 9 | cmd_firewall_takeover_test | TEST_EXPECTATION_STALE + harness | needle "requires root"→"insufficient privileges" (polkit wording, #675); **also** gated the T9 git-ref scope guard (`git diff main` errored → spurious SCOPE VIOLATION on shallow CI checkouts with no local `main` ref → now SKIPs unless `main` resolves) + declared git/unshare deps in metadata |
| 10 | cmd_firewall_trust_remerge_test | TEST_EXPECTATION_STALE | needle → current v1.126.1 warning wording |
| 11 | cmd_update_lock_cleanup_v135_test | TEST_EXPECTATION_STALE | awk anchor "in progress"→"already in progress" |
| 12 | v129_pr_c_runtime_defect_fixes_test | FALSE_OR_OBSOLETE_TEST | exclude the A15 scrub form (lookbehind) — grep false positive |
| 13 | botscan_spool_oom_v2093_test | TEST_EXPECTATION_STALE | fixture content → valid access-log lines (R22A content gate, v1.221.4) |
| 14 | v127_ux4_suricata_desurfacing_test | FALSE_OR_OBSOLETE_TEST | remove obsolete E1 cross-PR scope-guard (UX-5 shipped) |
| 15 | v127_ux6_help_cleanup_test | TEST_EXPECTATION_STALE + harness | drop superseded "site-approved privilege method" requirement (v1.128 canonical); **also** HARNESS_DEFECT_FIXED — 17 `awk … \| grep -q` pipelines rewritten to capture-to-var `grep -q <<< "$(awk …)"` to kill a `pipefail`+SIGPIPE(141) race that intermittently failed a *varying* assertion (19/20 → 100/100 direct + 100/100 runner + 30/30 parallel; pipefail kept; mutation-proven; no assertion weakened) |

All 15 verified: direct `bash <test>` PASS, product tree unchanged, a meaningful regression assertion retained.

**Quarantined (4)** — see `scripts/ci/ci-bash-quarantine.tsv` for owner/reason/finding/expiry/pattern:

| ta.id | disposition | expected_failure_class | finding | remediation lane |
|-------|-------------|------------------------|---------|------------------|
| rbl_seven_state_v206_test | PR_E_RBL_FIXTURE | RBL_FIXTURE_NONPUBLIC_IPV6 | V1226-CIBASH-RBL-01 | PR-E |
| botscan_throughput_v187_test | ENVIRONMENT_SENSITIVE | MISSING_MATCHER_BINARY | V1226-CIBASH-ENV-01 | OPEN_BOTSCAN_MATCHER_CI_PROVISIONING |
| v128_help_code_correlation_test | CONFIRMED_PRODUCT_DEFECT | CANONICAL_COMMAND_REGISTRY_DRIFT | V1226-CIBASH-PRODDEF-01 | OPEN_CANONICAL_LOGS_REGISTRATION |
| v128_polkit_aware_wording_sweep_test | CONFIRMED_PRODUCT_DEFECT | POLKIT_WORDING_DRIFT | V1226-CIBASH-PRODDEF-02 | OPEN_POLKIT_WORDING_REWORD |

### The two confirmed product defects (registered, NOT fixed in PR-D)

- **V1226-CIBASH-PRODDEF-01** — `nftban logs` (`cmd_logs.sh`, shipped v1.222.0) is routed and shown in
  completion but is absent from `_nftban_canonical_commands()`. The test correctly detects canonical-registry
  drift. Product-side registration required in `OPEN_CANONICAL_LOGS_REGISTRATION`. (This test also carries a
  stale `D2` PR-diff-size assertion; both are reconciled in that lane.)
- **V1226-CIBASH-PRODDEF-02** — 5 operator-facing CLI surfaces (`cmd_common.sh`, `cmd_whitelist.sh`,
  `cmd_botscan.sh`, `cmd_permissions.sh`, …) reintroduced root/sudo wording after the v1.133 polkit sweep,
  undetected while this test was unwired. Product-side reword to the nftban-group/PolicyKit model (or a
  targeted allowlist for genuine root file-write paths) required in `OPEN_POLKIT_WORDING_REWORD`.

Neither product defect is changed in PR-D (scope: authority enforcement only). Both remain quarantined,
visible, and executed, with a hard review date of 2026-10-31.

> **PR-E2 update (2026-07-23):** `rbl_seven_state_v206` fixture repaired (benchmarking IPv6) + **de-quarantined** (quarantine 4→3); the 5 RBL/whitelist deferred tests + `cmd_firewall_whitelist_session` (product-fixed in PR-E1) **activated** to `ci-bash` (deferred 6→0). RBL suite 31/31. The whitelist-session cleanup fd-9 **product defect** was fixed in PR-E1 (#1149), not here.
