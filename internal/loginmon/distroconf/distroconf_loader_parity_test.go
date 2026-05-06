// =============================================================================
// NFTBan v1.106 - distroconf shell↔Go loader parity test (MFST-C5)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="distroconf-loader-parity-test"
// meta:type="test"
// meta:header="distroconf shell↔Go loader parity test"
// meta:version="1.106.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:homepage="https://nftban.com"
//
// meta:description="Iterate all etc/nftban/distros/*.conf fixtures and assert each parses cleanly via Go LoadFromFile() with the 7 shell-recognized sections present"
// meta:inventory.files="etc/nftban/distros/*.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="user"
//
// meta:created_date="2026-05-06"
// meta:updated_date="2026-05-06"
//
// Closes drift D5 (shell distro loader ↔ Go distro loader equivalence). Today's
// Go-side test coverage exercises only 2 of 18 fixtures (TestLoadFromFile_Almalinux9
// + TestLoadFromFile_Debian12). This test extends Go-side fixture coverage to
// all 18, symmetric to the shell-side coverage already provided in CI by
// .github/workflows/ci-architecture.yml:201 (which runs
// cli/lib/nftban/tests/validate_distro_configs.sh against the same fixtures).
//
// Acceptable design asymmetries (NOT enforced by this test, documented for
// future readers):
//
//  1. Shell parse_config()'s switch-case at nftban_distro_config.sh:158-180
//     silently drops sections not in {distro, package_manager, packages,
//     services, paths, repository, features}. All 18 current fixtures include
//     a [tier] section that the shell loader ignores by design; the Go loader
//     captures it. The required-sections check below verifies the 7 shell-
//     recognized sections only; extra sections are tolerated.
//
//  2. Shell's ${DISTRO_PATHS[$key]:-} collapses absent / empty / "n/a" to "".
//     Go's Resolve() distinguishes 4 outcomes (Resolved, NotApplicable,
//     Absent, LoaderUnavailable). This is a coarse-vs-fine asymmetry by
//     design; not enforced here.
//
//  3. Shell find_config 3-tier waterfall (id-version → id-major → id) vs Go
//     loadByID exact + family forward-fit. Generic fallbacks centos.conf and
//     fedora.conf are reachable only via shell's third tier; Go's loadByID
//     never reaches them at runtime. This test still calls LoadFromFile on
//     them defensively to verify Go's parser handles their content.
// =============================================================================

package distroconf

import (
	"path/filepath"
	"runtime"
	"sort"
	"testing"
)

// shellRecognizedSections lists the section names the shell loader's
// nftban_distro_parse_config() switch-case stores into named associative
// arrays. Sections outside this set (e.g., [tier]) are silently dropped by
// the shell loader; the Go loader captures them. The parity test asserts
// these 7 are PRESENT in every fixture; extra sections are tolerated.
var shellRecognizedSections = []string{
	"distro",
	"package_manager",
	"packages",
	"services",
	"paths",
	"repository",
	"features",
}

// TestAllDistroConfsLoad iterates every committed fixture in
// etc/nftban/distros/*.conf and asserts:
//
//  1. Go's LoadFromFile(path) succeeds (no parse error).
//  2. The resulting Loader's parsed INI contains each of the 7
//     shell-recognized sections from shellRecognizedSections.
//
// On failure the error message names the offending fixture and the missing
// section, so future regressions are diagnosed without further investigation.
func TestAllDistroConfsLoad(t *testing.T) {
	_, filename, _, _ := runtime.Caller(0)
	repoRoot := filepath.Join(filepath.Dir(filename), "..", "..", "..")
	fixtureDir := filepath.Join(repoRoot, "etc", "nftban", "distros")

	matches, err := filepath.Glob(filepath.Join(fixtureDir, "*.conf"))
	if err != nil {
		t.Fatalf("glob %s: %v", fixtureDir, err)
	}
	if len(matches) == 0 {
		t.Fatalf("no fixtures in %s (expected at least one *.conf)", fixtureDir)
	}

	sort.Strings(matches)
	t.Logf("parity-iterating %d fixture(s) under %s", len(matches), fixtureDir)

	for _, path := range matches {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			l, err := LoadFromFile(path)
			if err != nil {
				t.Fatalf("LoadFromFile(%s): %v", filepath.Base(path), err)
			}
			if l == nil || l.ini == nil {
				t.Fatalf("LoadFromFile(%s): nil loader or nil ini", filepath.Base(path))
			}

			for _, sec := range shellRecognizedSections {
				if _, ok := l.ini[sec]; !ok {
					t.Errorf("fixture %s missing required shell-recognized section [%s]\n"+
						"(shell parse_config switch-case in cli/lib/nftban/lib/nftban_distro_config.sh\n"+
						"requires this section; the Go loader sees the same set plus any extras)",
						filepath.Base(path), sec)
				}
			}
		})
	}
}
