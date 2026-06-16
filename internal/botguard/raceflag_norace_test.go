//go:build !race

// SPDX-License-Identifier: MPL-2.0
// meta:name="botguard_raceflag_norace_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="underRace=false when the race detector is OFF; scale/warm-up wall-clock timing assertions are enforced only in this build (skipped under -race, where the ~10x slowdown makes absolute time bounds flaky on shared CI)."
// meta:inventory.files="raceflag_norace_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""

package botguard

const underRace = false
