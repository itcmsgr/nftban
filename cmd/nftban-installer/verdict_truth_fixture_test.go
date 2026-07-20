// SPDX-License-Identifier: MPL-2.0
// meta:name="verdict_truth_fixture_test.go"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: the all-assertions-pass fixture (newAllAssertionsPassFixture) that makes EVERY post-install assertion in RunAssertionsWithOpts pass EXCEPT health (each test sets the health live state). Explicit + readable — no blanket success-for-everything. Includes a fixture-validation test that asserts only allow-listed mock commands are issued."
// meta:inventory.files="cmd/nftban-installer/verdict_truth_fixture_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_LR_MAIN,NFTBAN_LR_SURICATA,NFTBAN_LR_STATE,NFTBAN_LR_TEMPLATE"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package main

import (
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
	"github.com/itcmsgr/nftban/internal/installer/validate"
	coresafety "github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
)

const miB = int64(1) << 20

func nolog() *logging.Logger { return logging.New("/dev/null", false) }

// ---- host-class profile helpers (internal/safety; forced tier, deterministic) ----

func profileForRAM(totalRAM int64) coresafety.HealthResourceProfile {
	p := coresafety.ServerProfile{TotalRAM: totalRAM, AvailRAM: totalRAM / 2, CPUCores: 4}
	return coresafety.HealthServiceMemoryLimitsFor(p, coresafety.ClassifyResourceTier(p))
}
func smallProfile() coresafety.HealthResourceProfile  { return profileForRAM(2 << 30) } // 192/256
func mediumProfile() coresafety.HealthResourceProfile { return profileForRAM(6 << 30) } // 256/384
func largeProfile() coresafety.HealthResourceProfile  { return profileForRAM(16 << 30) }

// ---- health systemctl-show seams (mirror internal/installer/services test helpers) ----

func healthShowKey() string {
	return strings.Join([]string{
		"systemctl", "show", "nftban-health.service",
		"-p", "MemoryHigh", "-p", "MemoryMax", "-p", "TasksMax", "-p", "DropInPaths", "-p", "FragmentPath",
	}, ":")
}

func showOut(high, max, tasks int64, dropins string) string {
	i := strconv.FormatInt
	return "MemoryHigh=" + i(high, 10) + "\nMemoryMax=" + i(max, 10) + "\nTasksMax=" + i(tasks, 10) +
		"\nDropInPaths=" + dropins + "\nFragmentPath=/usr/lib/systemd/system/nftban-health.service\n"
}

// setHealthActiveMatch makes the LIVE systemd read (queryEffectiveHealth) report the
// exact calculated policy with OUR drop-in loaded → resolver yields ACTIVE_MATCH.
func setHealthActiveMatch(m *executor.MockExecutor, p coresafety.HealthResourceProfile) {
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)}
	m.Files[healthresource.DropinFile] = healthresource.Render(p, version.Version)
}

// setHealthFallbackUndersized makes the LIVE read report the packaged fallback below
// the calculated policy, no drop-in loaded → resolver yields FALLBACK_UNDERSIZED.
func setHealthFallbackUndersized(m *executor.MockExecutor) {
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(192*miB, 256*miB, 64, "")}
	delete(m.Files, healthresource.DropinFile)
}

// setHealthShowFails makes the LIVE read fail (systemctl show exit!=0) → resolver
// falls to persisted reconstruction or explicit UNAVAILABLE.
func setHealthShowFails(m *executor.MockExecutor) {
	m.RunResults[healthShowKey()] = executor.Result{ExitCode: 1, Stderr: "unit not loaded"}
	delete(m.Files, healthresource.DropinFile)
}

// ---- the all-assertions-pass fixture ----------------------------------------

// allPassSSHPort is the SSH port every fixture seeds into ip nftban tcp_ports_in.
const allPassSSHPort = 22

// newAllAssertionsPassFixture seeds a MockExecutor + injection carrier so EVERY
// assertion in RunAssertionsWithOpts passes EXCEPT health (the caller sets the health
// live state via the setHealth* helpers + inject.healthProfile). It ALSO installs the
// real-filesystem logretention fixtures (temp policy identical to the fallback
// template + env overrides) so assertLogretentionPolicyREADY passes via the real
// DefaultValidator (logrotate present on the CI host). Returns the injection carrier,
// the mock, and a cleanup func (env restoration is handled by t.Setenv).
func newAllAssertionsPassFixture(t *testing.T) (*assertionTestInjection, *executor.MockExecutor, func()) {
	t.Helper()
	m := executor.NewMockExecutor()

	// 1. nftables + daemon active; nftban tables present; NO emergency table.
	m.Services["nftables"] = true
	m.Services["nftband.service"] = true
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true

	// 2. SSH port present in ip nftban tcp_ports_in (assertSSHInSet with port 22).
	m.NftSets["ip:nftban:tcp_ports_in"] = "22"

	// 3. install_state file present.
	m.Files[fhs.StateDir+"/install_state"] = []byte("INSTALL_STATE=DEGRADED\n")

	// 4. payload inventory: the 8 required binaries/configs + 6 non-empty dirs.
	for _, f := range []string{
		"/usr/sbin/nftban",
		"/usr/lib/nftban/bin/nftban-core",
		"/usr/lib/nftban/bin/nftband",
		"/usr/lib/nftban/bin/nftban-validate",
		"/usr/lib/nftban/bin/nftban-installer",
		"/usr/lib/nftban/VERSION",
	} {
		m.Files[f] = []byte("x")
	}
	for _, d := range []string{
		"/usr/lib/nftban/cli", "/usr/lib/nftban/core", "/usr/lib/nftban/lib",
		"/usr/lib/nftban/helpers", "/usr/lib/nftban/data", "/usr/lib/nftban/health",
	} {
		m.Dirs[d] = true
	}

	// 5. config integrity: nftban.conf (>=256B + SPDX token; also carries the
	//    NFTBAN_RECONCILE_CORE_TIMERS=false line so the core-timer assertion takes
	//    the intentional-opt-out Skipped→PASS path) and nftables.conf (>=512B + the
	//    two required tokens).
	conf := "# SPDX-License-Identifier: MPL-2.0\n" +
		"NFTBAN_RECONCILE_CORE_TIMERS=\"false\"\n" +
		"# nftban.conf fixture — padding to satisfy the >=256-byte minimum-viability\n" +
		"# integrity check without any semantic parse. " + strings.Repeat("padpadpad ", 20) + "\n"
	m.Files["/etc/nftban/nftban.conf"] = []byte(conf)
	nft := "#!/usr/sbin/nft -f\n# SPDX-License-Identifier: MPL-2.0\ntable ip nftban {\n}\n" +
		"# padding to satisfy the >=512-byte minimum-viability integrity check.\n" +
		strings.Repeat("# pad pad pad pad pad pad pad pad pad pad pad pad pad pad\n", 12)
	m.Files["/etc/nftban/nftables.conf"] = []byte(nft)

	// 6. logretention: real temp policy identical to the fallback template so
	//    lr.Readiness returns READY_FALLBACK. mode 0644 is mandatory (Perm()==0o644
	//    check). The logrotate VALIDATOR is injected below (deterministic pass) so the
	//    assertion does not depend on the `logrotate` binary — absent in CI containers.
	d := t.TempDir()
	body := []byte("/var/log/nftban/bans.log {\n    daily\n    rotate 7\n    size 10M\n}\n")
	mainPath := d + "/nftban"
	tmplPath := d + "/nftban.logrotate"
	writeMode0644(t, mainPath, body)
	writeMode0644(t, tmplPath, body)
	t.Setenv("NFTBAN_LR_MAIN", mainPath)
	t.Setenv("NFTBAN_LR_TEMPLATE", tmplPath)
	t.Setenv("NFTBAN_LR_STATE", d+"/nonexistent-state.json")  // forces the fallback path
	t.Setenv("NFTBAN_LR_SURICATA", d+"/nonexistent-suricata") // absent → skipped in fallback

	// 7. systemd-payload assertions: inject a valid EMPTY input set (zero units, zero
	//    failed units, no query error) → all four pass (fail-safe preserved: this is
	//    the same verdict the pure validator gives an empty gather).
	inj := &assertionTestInjection{
		systemdPayload: &validate.SystemdPayloadInputs{},
		// Deterministic logrotate validator → logretention_policy_ready passes on any
		// host (no `logrotate` binary needed; CI containers lack it).
		logRetentionValidator: func([]string) (string, error) { return "logrotate", nil },
	}

	return inj, m, func() {}
}

func writeMode0644(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0o644); err != nil { // #nosec G306 -- logrotate policy is 0644 by contract
		t.Fatalf("write %s: %v", path, err)
	}
	if err := os.Chmod(path, 0o644); err != nil { // defeat umask; Perm()==0o644 is required
		t.Fatalf("chmod %s: %v", path, err)
	}
}

// passOpts builds AssertionOpts wired to the fixture injection, an EMPTY explicit
// panel-adapter slice (so the package-registered adapters are NOT consulted — keeps
// the command allow-list tight), and the given resolved health verdict.
func passOpts(inj *assertionTestInjection, health *healthresource.Verdict) validate.AssertionOpts {
	o := validate.AssertionOpts{}.WithPanelPolicy(panelfw.DefaultPolicy())
	o.PanelAdapters = []panelfw.PanelAdapter{}
	o.SystemdPayloadInputs = inj.payload()
	o.HealthResource = health
	return o
}

// TASK 4: the fixture makes every assertion pass except health, and issues ONLY
// allow-listed mock commands (an unknown command fails the test).
func TestAllAssertionsPassFixture_OnlyAllowlistedCommands(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()

	// Health forced to ACTIVE_MATCH so the WHOLE suite (incl. health) passes here.
	health := &healthresource.Verdict{
		Profile:        mediumProfile(),
		EffectiveState: healthresource.StateActiveMatch,
	}
	results := validate.RunAssertionsWithOpts(m, allPassSSHPort, nolog(), passOpts(inj, health))

	if !validate.AllPassed(results) {
		t.Fatalf("all assertions must pass, failing: %v", validate.FailedNames(results))
	}

	// Allow-list: RunAssertionsWithOpts issues exactly one recorded Run command —
	// the nftban input-chain probe. Everything else is a typed method (no record),
	// the injected payload (no gather), the real-fs logretention validator (os/exec,
	// not the mock), and the empty panel-adapter slice.
	allowed := map[string]bool{
		"nft list chain ip nftban input": true,
	}
	for _, c := range m.Commands {
		key := c.Name + " " + strings.Join(c.Args, " ")
		if !allowed[key] {
			t.Errorf("UNKNOWN mock command issued (not in allow-list): %q", key)
		}
	}
}

// TASK 4: prove the fixture makes health the ONLY variable — a medium
// FALLBACK_UNDERSIZED health verdict is the sole failing assertion.
func TestAllAssertionsPassFixture_HealthIsTheOnlyVariable(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()

	health := &healthresource.Verdict{
		Profile:        mediumProfile(),
		EffectiveState: healthresource.StateFallbackUnder,
		CalculatedMax:  mediumProfile().MemoryMax,
		EffectiveMax:   256 * miB,
	}
	results := validate.RunAssertionsWithOpts(m, allPassSSHPort, nolog(), passOpts(inj, health))

	failed := validate.FailedNames(results)
	if len(failed) != 1 || failed[0] != "health_resource_policy_active" {
		t.Fatalf("health must be the ONLY failing assertion; got %v", failed)
	}
}
