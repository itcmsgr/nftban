# ci-bash INFORMATIONAL_BASELINE — 19 pre-existing newly-exposed failures

**Lane:** v1.226.0 PR-C (index-driven runner). **State:** `CI_BASH_ENFORCEMENT = INFORMATIONAL_BASELINE` (non-blocking).
**Classification:** `PRE_EXISTING_NEWLY_EXPOSED_TEST_FAILURES` — not PR-C regressions.

Executing the previously-unenforced `ci-bash` class through the authority runner exposed 19 failing
tests. All 19 reproduce under direct `bash <test>` invocation from the repository root (runner-caused
failures = 0; harness mismatch = 0). They are recorded here as evidence and carried as a bounded,
non-increasing baseline (`scripts/ci/ci-bash-informational-baseline.tsv`). They **must not** be
silently changed to PASS, skipped, or deleted. PR-D owns triage and the transition to blocking
enforcement; product defects, if confirmed, split into their own failure-domain lanes.

Baseline (this PR-C head): SELECTED=184 · PASS=165 · FAIL=19 · TIMEOUT=0.

Buckets: source/spec drift = 12 · behavior/regression investigation = 4 · RBL fixture debt = 1 · spool/timing investigation = 2.

| # | ta.id | path (repo-relative, `cli/lib/nftban/tests/…`) | gate | bucket | observed (concise) | serial repro | provisional disposition | finding handle |
|---|-------|-----|------|--------|--------------------|--------------|-------------------------|----------------|
| 1 | banner_nobanner_v153_test | banner_nobanner_v153_test.sh | ci-bash | source-spec-drift | subcommands not routed to one-line header — `PATH:NONE-OR-FULLBODY` (10P/6F) | fails | challenge test vs current banner routing source | V1226-CIBASH-DRIFT-01 |
| 2 | b2_badbot_aibot_v188_test | b2_badbot_aibot_v188_test.sh | ci-bash | source-spec-drift | spec must ship `*.patterns` as `config(noreplace)` glob | fails | challenge test vs current RPM spec | V1226-CIBASH-DRIFT-02 |
| 3 | botguard_diag_6b2_test | botguard_diag_6b2_test.sh | ci-bash | source-spec-drift | botguard diag surface assertion drift | fails | challenge test vs current botguard diag | V1226-CIBASH-DRIFT-03 |
| 4 | botguard_explain_shell_6b1_test | botguard_explain_shell_6b1_test.sh | ci-bash | source-spec-drift | render must label section TEMPORARY/not-durable | fails | challenge test vs current explain render | V1226-CIBASH-DRIFT-04 |
| 5 | logs_truth_v150_test | logs_truth_v150_test.sh | ci-bash | source-spec-drift | T4.1 header exact-path enumeration wording | fails | challenge test vs current logs header | V1226-CIBASH-DRIFT-05 |
| 6 | stats_manual_cache_v150_test | stats_manual_cache_v150_test.sh | ci-bash | source-spec-drift | display: IPv4 `manual:` label | fails | challenge test vs current stats display | V1226-CIBASH-DRIFT-06 |
| 7 | stats_producer_reconcile_v152_test | stats_producer_reconcile_v152_test.sh | ci-bash | source-spec-drift | consumer manual-subset label missing | fails | challenge test vs current stats producer | V1226-CIBASH-DRIFT-07 |
| 8 | stats_status_truth_v150_test | stats_status_truth_v150_test.sh | ci-bash | source-spec-drift | T9.2 `.local` override still sourced | fails | challenge test vs current stats status | V1226-CIBASH-DRIFT-08 |
| 9 | v127_ux4_suricata_desurfacing_test | v127_ux4_suricata_desurfacing_test.sh | ci-bash | source-spec-drift | E1: scope-creep `levenshtein\|edit_distance` now present in nftban | fails | challenge test vs intentional current surface | V1226-CIBASH-DRIFT-09 |
| 10 | v127_ux6_help_cleanup_test | v127_ux6_help_cleanup_test.sh | ci-bash | source-spec-drift | F3/F4 help REQUIRES-section polkit-aware wording | fails | challenge test vs current help blocks | V1226-CIBASH-DRIFT-10 |
| 11 | v128_help_code_correlation_test | v128_help_code_correlation_test.sh | ci-bash | source-spec-drift | C4: 1 `cmd_<X>.sh` has no canonical-command match | fails | challenge test vs current command registry | V1226-CIBASH-DRIFT-11 |
| 12 | v128_polkit_aware_wording_sweep_test | v128_polkit_aware_wording_sweep_test.sh | ci-bash | source-spec-drift | A3/A4: `requires root`/`must run as root` strings present in CLI | fails | challenge test vs current CLI wording policy | V1226-CIBASH-DRIFT-12 |
| 13 | cmd_firewall_takeover_test | cmd_firewall_takeover_test.sh | ci-bash | behavior-regression-investigation | T6.1 non-root refusal | fails | runtime reachability + env-sensitivity analysis | V1226-CIBASH-BEHAV-01 |
| 14 | cmd_firewall_trust_remerge_test | cmd_firewall_trust_remerge_test.sh | ci-bash | behavior-regression-investigation | missing warning: `Failed to re-apply trust providers…` | fails | confirm defect vs stale expectation | V1226-CIBASH-BEHAV-02 |
| 15 | cmd_update_lock_cleanup_v135_test | cmd_update_lock_cleanup_v135_test.sh | ci-bash | behavior-regression-investigation | S3 contention path removes holders file (`unsafe`) | fails | confirm defect vs stale expectation | V1226-CIBASH-BEHAV-03 |
| 16 | v129_pr_c_runtime_defect_fixes_test | v129_pr_c_runtime_defect_fixes_test.sh | ci-bash | behavior-regression-investigation | 1 assertion failing | fails | confirm defect vs stale expectation | V1226-CIBASH-BEHAV-04 |
| 17 | rbl_seven_state_v206_test | rbl_seven_state_v206_test.sh | ci-bash | rbl-fixture-debt-PR-E | T7.1 unsupported_ipv6_zone, T8.1 skipped_ipv4_only_zone | fails | **assigned to PR-E** synthetic-public fixture correction | V1226-CIBASH-RBL-01 (→ PR-E) |
| 18 | botscan_spool_oom_v2093_test | botscan_spool_oom_v2093_test.sh | ci-bash | spool-timing-investigation | T2/T3/T6 spool byte/size = 0 (`/tmp` spool) | fails | inspect fixed `/tmp` names, isolation, timing, real-log deps | V1226-CIBASH-SPOOL-01 |
| 19 | botscan_throughput_v187_test | botscan_throughput_v187_test.sh | ci-bash | spool-timing-investigation | prefilter kept 2 candidates, expected 1 | fails | inspect prefilter counting, isolation, timing | V1226-CIBASH-SPOOL-02 |

## PR-D responsibilities (not "fix all 19")

PR-D is authority-enforcement policy, not a bulk product-fix lane. For each of the 19 it must determine
whether the **product** is wrong, the **test expectation** is stale, the test is **environment-sensitive**,
the test **belongs to PR-E**, the test is **flaky**, or the **classification** is wrong — then introduce a
justified temporary quarantine/deferred mechanism (owner + reason + finding handle + review condition),
activate blocking `ci-bash` for all non-quarantined tests, and add zero-unclassified / execution-completeness
blockers. Any product change requires its own failure-domain GO. The RBL row stays with PR-E. If runner
concurrency is ever shown to cause a spool/timing failure, the runner is fixed; serial reproduction (as
recorded above) means the failure is genuine test/timing debt, handled separately.
