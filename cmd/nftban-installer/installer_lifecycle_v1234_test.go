// =============================================================================
// NFTBan v1.234.0 — installer lifecycle: timer ordering + emergency-table handoff
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-lifecycle-v1234-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-29"
// meta:description="End-to-end runInstall arms for BUG-RPM-REINSTALL-AFTER-UNINSTALL-FAILS-REBUILD-ON-TIMER-LIVENESS and BUG-INSTALL-EMERGENCY-SSH-TABLE-LEFT-AFTER-REINSTALL. The mocked firewall rebuild classifies its post-validation with the REAL shell classifier from this tree (cli/lib/nftban/core/nftban_rebuild_classify.sh, _rebuild_disposition_classify) over a validator observation built from the mock's live timer state, so the arms exercise the shipped classifier rather than a model of it. Arms: a clean fresh install reaches COMMITTED with the core timers enabled+active, no timer started before the rebuild, and the opt-in timers untouched; a reinstall with a leftover emergency table removes it only when NFTBan's own rules admit SSH, and keeps it otherwise; VAL-TIMER-001 still blocks COMMITTED when the core timers cannot be started."
// meta:inventory.files="cmd/nftban-installer/installer_lifecycle_v1234_test.go"
// meta:inventory.binaries="bash, jq"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/services"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	coresafety "github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
)

// The timers a completed install enables: 9 core + botscan + botscan-collector
// (optional, enabled when the unit file exists — both ship). m1 RESULT.md.
var lcCoreTimers = []string{
	"nftban-maintenance.timer", "nftban-health.timer", "nftban-unified-exporter.timer",
	"nftban-core-geoip.timer", "nftban-core-feeds.timer", "nftban-watchdog.timer",
	"nftban-queue.timer", "nftban-update-check.timer", "nftban-geoban-refresh.timer",
	"nftban-botscan.timer", "nftban-botscan-collector.timer",
}

// Opt-in timers: must NEVER be enabled or started by the installer.
var lcOptInTimers = []string{
	"nftban-community-stats.timer", "nftban-update-apply.timer", "nftban-pro-license.timer",
	"nftban-pro-inventory.timer", "nftban-soak.timer", "nftban-tunnel.timer",
	"nftban-rbl-check.timer", "nftban-snapshot.timer", "nftban-report-daily.timer",
	"nftban-rebuild-recovery.timer", "nftban-rollback.timer",
}

const lcEmergencyKey = "inet:nftban_install_emergency"

// The service-accept rule exactly as `nft list chain` printed it on el9-clean
// (m1_recovery_procedure_2026_09_29), plus a SYN-meter line that also ends in accept.
const lcInputChain = "table ip nftban {\n\tchain input {\n" +
	"\t\ttype filter hook input priority filter; policy drop;\n" +
	"\t\ttcp flags syn ct state new tcp dport @tcp_ports_in update @syn_meter_v4 { ip saddr limit rate 25/second burst 50 packets } counter name \"total_input_accept\" accept comment \"SYN rate OK — service ports only\"\n" +
	"\t\ttcp dport @tcp_ports_in ct state new counter name \"input_service_tcp_accept\" counter name \"total_input_accept\" accept\n" +
	"\t}\n}\n"

// startRefusingExec wraps the mock so selected units REFUSE to start (the negative
// control). A wrapper, not a mock field, so this file compiles unchanged against the
// v1.233.1 tree — a historical reproducer must execute against the historical subject.
type startRefusingExec struct {
	*executor.MockExecutor
	refuse map[string]bool
}

func (e *startRefusingExec) ServiceStart(unit string) error {
	if e.refuse[unit] {
		e.MockExecutor.Commands = append(e.MockExecutor.Commands,
			executor.RecordedCommand{Name: "systemctl", Args: []string{"start", unit}})
		return errors.New("Job for " + unit + " failed (test: start refused)")
	}
	return e.MockExecutor.ServiceStart(unit)
}

type lcHost struct {
	m   *executor.MockExecutor
	ex  executor.Executor
	cfg *config
	dir string

	classifier string // absolute path to THIS tree's nftban_rebuild_classify.sh

	// observations made INSIDE the mocked rebuild
	rebuilds            int
	activeTimersAtBuild int
	timerStartsBefore   int
	lastDisposition     string
	lastReasons         string
}

func lcClassifierPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate this test file")
	}
	p := filepath.Join(filepath.Dir(file), "..", "..", "cli", "lib", "nftban", "core", "nftban_rebuild_classify.sh")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("classifier not found at %s: %v", p, err)
	}
	for _, bin := range []string{"bash", "jq"} {
		if _, err := exec.LookPath(bin); err != nil {
			// ⛔ tool absence is NOT an empty pass: the arm cannot execute its subject.
			t.Fatalf("NOT_EXECUTED: %s is required to run the real rebuild classifier: %v", bin, err)
		}
	}
	return p
}

func (h *lcHost) activeNftbanTimers() int {
	n := 0
	for _, u := range services.KnownTimers() {
		if h.m.ServiceActive(u) {
			n++
		}
	}
	return n
}

func (h *lcHost) timerStartsSoFar() int {
	n := 0
	for _, c := range h.m.Commands {
		if c.Name == "systemctl" && len(c.Args) == 2 && c.Args[0] == "start" &&
			strings.HasPrefix(c.Args[1], "nftban-") && strings.HasSuffix(c.Args[1], ".timer") {
			n++
		}
	}
	return n
}

// classify runs THIS tree's shell classifier over a validator observation shaped
// like the real nftban-validate --json post-rebuild output (m1 evidence:
// el9-clean_04_regression-post-validator.json), built from the mock's live state.
func (h *lcHost) classify(t *testing.T) (string, string) {
	t.Helper()
	n := h.activeNftbanTimers()
	status, findings := "protected", `[]`
	if n == 0 {
		status = "degraded"
		findings = `[{"code":"VAL-TIMER-001","severity":"error","component":"service"},` +
			`{"code":"VAL-GEOBAN-001","severity":"warn","component":"module"}]`
	}
	obs := fmt.Sprintf(`{"schema_version":"1.84.0","status":%q,`+
		`"service_state":{"nftband":"RUNNING","nftband_detail":"active","timer_count":%d},`+
		`"modules":{"ddos":{"config":"disabled"},"portscan":{"config":"disabled"}},`+
		`"findings":%s,"summary":{"checked_families":2,"protected_families":2}}`, status, n, findings)
	vj := filepath.Join(t.TempDir(), "postval.json")
	if err := os.WriteFile(vj, []byte(obs), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("bash", "-c",
		`set -u; source "$1" || exit 97; _rebuild_disposition_classify install-deferred "$2" "" "$3"`,
		"_", h.classifier, vj, status).Output()
	if err != nil {
		t.Fatalf("real classifier did not execute: %v", err)
	}
	line := strings.TrimRight(string(out), "\n")
	disp, reasons, _ := strings.Cut(line, "\t")
	return disp, reasons
}

func newLCHost(t *testing.T, fresh bool) *lcHost {
	t.Helper()
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	t.Cleanup(cleanup)
	inj.logRetentionValidator = nil
	h := &lcHost{m: m, ex: m, classifier: lcClassifierPath(t)}
	logRoot := t.TempDir()
	_ = hermeticLogretention(t, logRoot)
	p := coresafety.HealthServiceMemoryLimits()
	m.RunResults[healthShowKey()] = executor.Result{
		Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile),
	}
	t.Setenv("NFTBAN_MIN_DISK_FREE_MB", "1")
	m.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n")
	t.Cleanup(switchop.SetRebuildResultBaseDirForTest(t.TempDir()))
	for _, c := range []string{
		"jq", "curl", "socat", "bc", "gawk", "getfacl", "tar", "nft", "systemctl",
		"install", "chown", "chmod", "setcap", "sed", "grep", "awk",
	} {
		m.ExistingCommands[c] = true
	}
	m.Files["/etc/os-release"] = []byte("ID=almalinux\nVERSION_ID=\"9.8\"\n")
	m.Files[switchop.BootProjectionPath] = []byte("table ip nftban {\n}\n")
	m.Files[switchop.ConvergenceGenerationPath] = []byte("7\n")

	// ⛔ TIMER RECONCILIATION ON — the shipped default. The shared fixture opts out
	// (NFTBAN_RECONCILE_CORE_TIMERS=false) for arms about other assertions; here the
	// timers ARE the subject. Same size/SPDX shape, without the opt-out line.
	// REUSE-IgnoreStart
	conf := "# SPDX-License-Identifier: MPL-2.0\n" +
		// REUSE-IgnoreEnd
		"# nftban.conf fixture (v1.234 lifecycle) — padding for the >=256-byte integrity check. " +
		strings.Repeat("padpadpad ", 24) + "\n"
	m.Files["/etc/nftban/nftban.conf"] = []byte(conf)

	// Every shipped timer unit file exists (both optional botscan timers ship).
	for _, u := range services.KnownTimers() {
		m.Files["/usr/lib/systemd/system/"+u] = []byte("[Timer]\n")
	}

	// Kernel: the rendered service-accept rule, in both families.
	m.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{Stdout: lcInputChain}
	m.RunResults["nft:list:chain:ip6:nftban:input"] = executor.Result{Stdout: strings.Replace(lcInputChain, "table ip ", "table ip6 ", 1)}

	if fresh {
		// BASE_OS_CLEAN: no nftban tables, daemon down, no timers.
		m.Services["nftband.service"] = false
		m.NftTables["ip:nftban"] = false
		m.NftTables["ip6:nftban"] = false
	} else {
		m.NftTables["ip:nftban"] = true
		m.NftTables["ip6:nftban"] = true
		m.NftSets["ip:nftban:tcp_ports_in"] = "22"
		m.NftSets["ip6:nftban:tcp_ports_in"] = "22"
		// The m1 recovery step-2 shape: core timers already enabled+active, so the
		// reinstall arms isolate the emergency-table defect from the timer defect.
		for _, u := range lcCoreTimers {
			m.Services[u] = true
			m.ServicesEnabled[u] = true
		}
	}

	h.dir = t.TempDir()
	mode := "upgrade"
	if fresh {
		mode = "install"
	}
	h.cfg = &config{mode: mode, stateDir: h.dir, inject: inj}

	gen := 7
	m.RunHook = func(name string, args []string) (executor.Result, bool) {
		// Emergency SSH table injection (`nft -f /tmp/.nftban-emergency-ssh.nft`).
		if name == "nft" && len(args) == 2 && args[0] == "-f" && strings.Contains(args[1], "emergency") {
			m.NftTables[lcEmergencyKey] = true
			return executor.Result{ExitCode: 0}, true
		}
		// Exact kernel set membership: `nft get element <fam> nftban tcp_ports_in { P }`.
		if name == "nft" && len(args) == 6 && args[0] == "get" && args[1] == "element" {
			fam, set, elem := args[2], args[4], strings.Trim(args[5], "{} ")
			for _, e := range strings.Split(m.NftSets[fam+":nftban:"+set], ",") {
				if strings.TrimSpace(e) == elem {
					return executor.Result{ExitCode: 0, Stdout: "elements = { " + elem + " }"}, true
				}
			}
			return executor.Result{ExitCode: 1, Stderr: "Error: Could not process rule: No such file or directory"}, true
		}
		if name != fhs.NftbanCLI || len(args) < 2 || args[0] != "firewall" || args[1] != "rebuild" {
			return executor.Result{}, false
		}
		var rp, op, wp string
		for i := 0; i < len(args)-1; i++ {
			switch args[i] {
			case "--result-file":
				rp = args[i+1]
			case "--operation-id":
				op = args[i+1]
			case "--execution-witness":
				wp = args[i+1]
			}
		}
		if wp != "" {
			_ = os.MkdirAll(filepath.Dir(wp), 0o750)
			_ = os.WriteFile(wp, []byte("operation_id="+op+"\n"), 0o640)
		}
		// The rebuild loads NFTBan's tables with the detected sshd port in tcp_ports_in.
		m.NftTables["ip:nftban"] = true
		m.NftTables["ip6:nftban"] = true
		m.NftSets["ip:nftban:tcp_ports_in"] = "22"
		m.NftSets["ip6:nftban:tcp_ports_in"] = "22"
		h.rebuilds++
		h.activeTimersAtBuild = h.activeNftbanTimers()
		h.timerStartsBefore = h.timerStartsSoFar()
		disp, reasons := h.classify(t)
		h.lastDisposition, h.lastReasons = disp, reasons
		var body string
		rc := 0
		switch disp {
		case "COMPLETE":
			gen++
			m.Files[switchop.ConvergenceGenerationPath] = []byte(itoaLine(gen))
			rcodes := "[]"
			if reasons != "" {
				rcodes = `["` + reasons + `"]`
			}
			body = `{"schema_version":"1","operation_id":"` + op + `","context":"install-deferred",` +
				`"disposition":"COMPLETE","reason_codes":` + rcodes + `,"rollback_performed":false,` +
				`"modified":true,"enforcement_unchanged":false,` +
				`"transaction":{"committed":true,"reason":"COMMITTED"},"retry":{"reason":"NONE"},` +
				`"pre_status":"down","post_status":"protected","emitted_at":"2026-09-29T00:00:00Z"}`
		default: // REGRESSION -> rollback (the v1.233.1 behaviour on a clean host)
			rc = 2
			body = `{"schema_version":"1","operation_id":"` + op + `","context":"install-deferred",` +
				`"disposition":"REGRESSION","reason_codes":["` + reasons + `"],"rollback_performed":true,` +
				`"modified":true,"enforcement_unchanged":false,` +
				`"transaction":{"committed":false,"reason":"FAILURE"},"retry":{"reason":"FAILURE_RECOVERY"},` +
				`"pre_status":"degraded","post_status":"degraded","emitted_at":"2026-09-29T00:00:00Z"}`
		}
		_ = os.MkdirAll(filepath.Dir(rp), 0o750)
		_ = os.WriteFile(rp, []byte(body), 0o640)
		return executor.Result{ExitCode: rc}, true
	}
	return h
}

func (h *lcHost) install(t *testing.T) (*state.StateFile, int, string) {
	t.Helper()
	sf := state.NewStateFile(h.dir)
	_ = sf.Read()
	sf.Version = version.Version
	if sf.SSHPort == 0 {
		sf.SSHPort = 22
	}
	globalPhaseData = phaseData{}
	globalPhaseData.inject = h.cfg.inject
	logPath := filepath.Join(h.dir, "installer.log")
	_ = os.Remove(logPath)
	log := logging.New(logPath, false)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cfg := *h.cfg
	rc := runInstall(ctx, h.ex, sf, &cfg, log)
	log.Close()
	b, _ := os.ReadFile(logPath)
	return sf, rc, string(b)
}

func (h *lcHost) assertOptInUntouched(t *testing.T) {
	t.Helper()
	for _, u := range lcOptInTimers {
		if h.m.CommandCalled("systemctl", "enable", u) || h.m.CommandCalled("systemctl", "start", u) {
			t.Errorf("opt-in timer %s was enabled/started by the installer — it must NEVER be", u)
		}
		if h.m.ServiceEnabled(u) || h.m.ServiceActive(u) {
			t.Errorf("opt-in timer %s ended enabled=%t active=%t; want disabled/inactive",
				u, h.m.ServiceEnabled(u), h.m.ServiceActive(u))
		}
	}
}

func emergencyDeleteCalls(m *executor.MockExecutor) int {
	n := 0
	for _, c := range m.NftDeleteTableCalls {
		if c == lcEmergencyKey {
			n++
		}
	}
	return n
}

// ─────────────────────────────────────────────────────────────────────────────
// ARM 1 — BASE_OS_CLEAN fresh install, no active timers: COMMITTED, no manual step.
// v1.233.1: FAILED_REBUILD (SWITCH), VAL-TIMER-001, 0 timers enabled, emergency table left.
// ─────────────────────────────────────────────────────────────────────────────
func TestV1234_FreshInstallWithoutActiveTimersReachesCommitted(t *testing.T) {
	h := newLCHost(t, true)
	sf, rc, logText := h.install(t)

	if h.rebuilds != 1 {
		t.Fatalf("expected exactly one firewall rebuild, got %d", h.rebuilds)
	}
	// The fixture must actually present the m1 condition, or the arm proves nothing.
	if h.activeTimersAtBuild != 0 {
		t.Fatalf("fixture invalid: %d nftban timers active at rebuild time; the defect needs 0", h.activeTimersAtBuild)
	}
	// ⛔ Owner constraint: no job may start against an unfinished setup.
	if h.timerStartsBefore != 0 {
		t.Errorf("%d nftban timer start(s) were issued BEFORE the firewall rebuild; timers must start only after it", h.timerStartsBefore)
	}
	if sf.State != state.StateCommitted || rc != 0 {
		t.Fatalf("fresh install ended %s (rc=%d, reason=%q, rebuild=%s/%s); want COMMITTED rc=0\n%s",
			sf.State, rc, sf.FailureReason, h.lastDisposition, h.lastReasons, tail(logText, 40))
	}
	if h.lastDisposition != "COMPLETE" || h.lastReasons != "TIMER_LIVENESS_DEFERRED_TO_INSTALLER" {
		t.Errorf("rebuild continuation = %s/%s; want COMPLETE/TIMER_LIVENESS_DEFERRED_TO_INSTALLER",
			h.lastDisposition, h.lastReasons)
	}
	for _, u := range lcCoreTimers {
		if !h.m.ServiceEnabled(u) || !h.m.ServiceActive(u) {
			t.Errorf("core timer %s: enabled=%t active=%t; want enabled+active", u, h.m.ServiceEnabled(u), h.m.ServiceActive(u))
		}
	}
	h.assertOptInUntouched(t)
	if h.m.NftTableExists("inet", "nftban_install_emergency") {
		t.Errorf("emergency SSH table still present after a COMMITTED fresh install")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// ARM 2 — reinstall (authority UPDATE) with an emergency table left by a failed
// fresh run: removed ONLY when NFTBan's own rules admit SSH.
// v1.233.1: UPDATE never removes it -> DEGRADED no_emergency_table, every time.
// ─────────────────────────────────────────────────────────────────────────────
func TestV1234_ReinstallRemovesLeftoverEmergencyTableWhenSSHPermitted(t *testing.T) {
	h := newLCHost(t, false)
	h.m.NftTables[lcEmergencyKey] = true // left behind by the failed fresh install
	sf, rc, logText := h.install(t)

	if sf.Authority != "UPDATE" {
		t.Fatalf("fixture invalid: authority=%q; the defect is on the UPDATE (reinstall) path", sf.Authority)
	}
	if h.m.NftTableExists("inet", "nftban_install_emergency") || emergencyDeleteCalls(h.m) != 1 {
		t.Fatalf("emergency table present=%t delete-calls=%d; want removed exactly once\n%s",
			h.m.NftTableExists("inet", "nftban_install_emergency"), emergencyDeleteCalls(h.m), tail(logText, 40))
	}
	if sf.State != state.StateCommitted || rc != 0 {
		t.Fatalf("reinstall ended %s (rc=%d, reason=%q); want COMMITTED\n%s", sf.State, rc, sf.FailureReason, tail(logText, 40))
	}
	h.assertOptInUntouched(t)
}

// ARM 2-NEG — the same reinstall, but the ip6 input chain carries NO
// `tcp dport @tcp_ports_in ct state new … accept` rule, so NFTBan's own rules do not
// admit new SSH over IPv6. (A missing tcp_ports_in ELEMENT is not a usable negative
// here: AssertSSHInLiveSet re-adds the sshd port after the rebuild, by design; the
// element-level negatives are unit arms in switchop/sshhandoff_v1234_test.go.)
// The handoff is unproven, so the table MUST be kept (never deleted-then-re-added),
// and the transaction must not claim COMMITTED.
func TestV1234_ReinstallKeepsEmergencyTableWhenSSHNotPermitted(t *testing.T) {
	h := newLCHost(t, false)
	h.m.NftTables[lcEmergencyKey] = true
	h.m.RunResults["nft:list:chain:ip6:nftban:input"] = executor.Result{
		Stdout: "table ip6 nftban {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n\t\tcounter drop comment \"default deny\"\n\t}\n}\n",
	}
	sf, _, logText := h.install(t)

	if !h.m.NftTableExists("inet", "nftban_install_emergency") {
		t.Fatalf("emergency table REMOVED although ip6 tcp_ports_in admits no new SSH on ip6 — lockout risk\n%s", tail(logText, 40))
	}
	if n := emergencyDeleteCalls(h.m); n != 0 {
		t.Fatalf("emergency table delete was attempted %d time(s); an unproven handoff must never delete it", n)
	}
	if sf.State == state.StateCommitted {
		t.Fatalf("install claimed COMMITTED while the emergency table remains")
	}
	if !strings.Contains(sf.FailureReason, "no_emergency_table") {
		t.Errorf("FAILURE_REASON=%q; want it to name no_emergency_table", sf.FailureReason)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// ARM 3 — NEGATIVE CONTROL: the core timers cannot be started. VAL-TIMER-001 must
// still block COMMITTED — the deferral is a change of OWNER, never a waiver.
// ─────────────────────────────────────────────────────────────────────────────
func TestV1234_TimerLivenessStillBlocksCommitWhenTimersCannotStart(t *testing.T) {
	h := newLCHost(t, true)
	refuse := map[string]bool{}
	for _, u := range services.KnownTimers() {
		refuse[u] = true
	}
	h.ex = &startRefusingExec{MockExecutor: h.m, refuse: refuse}
	sf, _, logText := h.install(t)

	if h.activeNftbanTimers() != 0 {
		t.Fatalf("fixture invalid: %d timers active although every start was refused", h.activeNftbanTimers())
	}
	if sf.State == state.StateCommitted {
		t.Fatalf("install reached COMMITTED with ZERO active nftban timers — VAL-TIMER-001 was waived, not deferred\n%s", tail(logText, 40))
	}
	if sf.State != state.StateDegraded {
		t.Errorf("state=%s; want DEGRADED (the firewall converged; only timer liveness failed)", sf.State)
	}
	if !strings.Contains(sf.FailureReason, "VAL-TIMER-001") {
		t.Errorf("FAILURE_REASON=%q; want it to name VAL-TIMER-001", sf.FailureReason)
	}
	h.assertOptInUntouched(t)
}

// ─────────────────────────────────────────────────────────────────────────────
// ARM 4 — ONE RECOVERY AUTHORITY: the host a v1.233.1 fresh install leaves behind
// (FAILED_REBUILD at SWITCH, emergency table present, 0 timers active, nftban tables
// loaded, daemon up — m1 el9-clean/deb-clean). The persisted RECOVERY_CLASS must be
// the installer's own (RETRY_FULL_TRANSACTION, never --repair), and the operation it
// names must reach COMMITTED with no manual step; the operation it forbids must not.
// ─────────────────────────────────────────────────────────────────────────────
func lcFailedFreshHost(t *testing.T) *lcHost {
	t.Helper()
	h := newLCHost(t, false)
	for _, u := range lcCoreTimers { // %preun / never-started: nothing active
		h.m.Services[u] = false
		h.m.ServicesEnabled[u] = false
	}
	h.m.NftTables[lcEmergencyKey] = true
	sf := state.NewStateFile(h.dir)
	sf.Version, sf.SSHPort, sf.Mode = version.Version, 22, "install"
	_ = sf.Transition(state.StateFailedRebuild, state.PhaseSwitch,
		"nftban firewall rebuild REGRESSION (exit 2, rollback_performed=true, reasons=post_status:degraded)")
	raw, err := os.ReadFile(sf.Path())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "\nRECOVERY_CLASS=RETRY_FULL_TRANSACTION\n") {
		t.Fatalf("FAILED_REBUILD install_state does not persist the installer's recovery class:\n%s", raw)
	}
	return h
}

func TestV1234_FailedFreshInstallRecoversByTheNamedTransactionOnly(t *testing.T) {
	// The named recovery: re-run the full package transaction.
	h := lcFailedFreshHost(t)
	h.cfg.mode = "upgrade" // dnf reinstall / apt-get install --reinstall
	sf, rc, logText := h.install(t)
	if sf.State != state.StateCommitted || rc != 0 {
		t.Fatalf("RETRY_FULL_TRANSACTION from FAILED_REBUILD ended %s (rc=%d, reason=%q); want COMMITTED\n%s",
			sf.State, rc, sf.FailureReason, tail(logText, 40))
	}
	if h.m.NftTableExists("inet", "nftban_install_emergency") {
		t.Errorf("emergency table survived the recovery transaction")
	}
	for _, u := range lcCoreTimers {
		if !h.m.ServiceEnabled(u) || !h.m.ServiceActive(u) {
			t.Errorf("core timer %s not enabled+active after recovery", u)
		}
	}
	h.assertOptInUntouched(t)
	raw, _ := os.ReadFile(filepath.Join(h.dir, "install_state"))
	if !strings.Contains(string(raw), "\nRECOVERY_CLASS=NONE\n") {
		t.Errorf("COMMITTED record must persist RECOVERY_CLASS=NONE:\n%s", raw)
	}

	// The forbidden mechanism: --repair resumes at SWITCH and skips the render, so it
	// must NOT reach COMMITTED — which is why neither surface may advertise it here.
	h2 := lcFailedFreshHost(t)
	sf2 := state.NewStateFile(h2.dir)
	_ = sf2.Read()
	globalPhaseData = phaseData{}
	logPath := filepath.Join(h2.dir, "repair.log")
	log := logging.New(logPath, false)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cfg := *h2.cfg
	cfg.repair = true
	_ = runRepair(ctx, h2.ex, sf2, &cfg, log)
	log.Close()
	t.Logf("--repair from FAILED_REBUILD ended %s (%s)", sf2.State, sf2.FailureReason)
	if sf2.State == state.StateCommitted {
		t.Fatalf("--repair from FAILED_REBUILD reached COMMITTED; RETRY_FULL_TRANSACTION would then be the wrong class")
	}
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
