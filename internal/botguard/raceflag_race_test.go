//go:build race

// SPDX-License-Identifier: MPL-2.0
// meta:name="botguard_raceflag_race_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="underRace=true when built with -race; scale/warm-up wall-clock timing assertions are skipped (the race detector's ~10x slowdown makes absolute time bounds flaky in CI). Correctness assertions still run."
// meta:inventory.files="raceflag_race_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""

package botguard

const underRace = true
