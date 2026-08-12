// =============================================================================
// NFTBan — CSF REMOVAL CONTRACT (CSF-CLOSE-1/2/3)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="switchop-csf-removal-contract-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-11"
// meta:description="Locks the CSF_POLICY = REMOVE, NOT RESTORE contract: any credible CSF evidence reaches the removal path regardless of Conflict.Service; every CSF re-entry plane (units, both binaries, cron.d, /etc/crontab) is neutralized; CSF kernel state is removed attributably; unrelated foreign iptables state is NEVER flushed."
// meta:inventory.files="internal/installer/switchop/takeover.go"
// meta:inventory.privileges="none"
// =============================================================================
//
// RUNTIME EVIDENCE THIS ENCODES (el9-clean, 2026-08-11):
//
//	ARM 3  orphan-unit — /etc/csf removed, csf.service failed/enabled, binary
//	       present, 129 CSF rules live. extfw saw NO CSF; CONFLICTS omitted it;
//	       nothing was neutralized; restoring config + starting the still-enabled
//	       unit brought CSF back to 129 rules while status said PROTECTED.
//
//	ARM 4  Service="" — CSF WAS detected (CONFLICTS=…,CSF) via the config-file
//	       signal whose Unit is empty. `if c.Service == "" { continue }` ran
//	       BEFORE `hasCSF = true`, so the entire disarm path was skipped while
//	       the operator was told CSF had been handled.
//
//	ARMS 2/3/4  the blanket `iptables -P/-F/-X` destroyed an operator-owned
//	       OPERATOR_QOS mangle chain and Docker-shaped chains, witnessed by the
//	       installer's own "flushed all iptables rules" log line.
//
// HARD REMOVE CSF = YES        HARD FLUSH ALL IPTABLES = NO
package switchop

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// csfHost seeds a host carrying CSF payload + every persistence plane, plus a
// foreign operator artifact that must survive.
func csfHost() *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.Files["/usr/sbin/csf"] = []byte("#!/usr/bin/perl\n# csf\n")
	m.Files["/usr/sbin/lfd"] = []byte("#!/usr/bin/perl\n# lfd\n")
	m.Files["/etc/csf/csf.conf"] = []byte("TESTING = \"1\"\n")
	m.Files["/etc/cron.d/csf-cron"] = []byte("SHELL=/bin/sh\n")
	m.Files["/etc/cron.d/lfd-cron"] = []byte("0 0 * * * root /usr/sbin/csf --lfd restart\n")
	m.Files["/etc/cron.d/csf_update"] = []byte("36 23 * * * root /usr/sbin/csf -u\n")
	m.Files["/etc/crontab"] = []byte(
		"SHELL=/bin/bash\n" +
			"0 3 * * * root /usr/local/bin/operator-backup.sh\n" + // MUST SURVIVE
			"*/5 * * * * root /usr/sbin/csf -f > /dev/null 2>&1\n") // MUST GO
	m.ExistingCommands["iptables"] = true
	m.ExistingCommands["ip6tables"] = true
	return m
}

func ranCmd(m *executor.MockExecutor, name string, argContains string) bool {
	for _, c := range m.Commands {
		if c.Name != name {
			continue
		}
		if argContains == "" || strings.Contains(strings.Join(c.Args, " "), argContains) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// CSF-CLOSE-1/2 — removal must not depend on Conflict.Service
// ---------------------------------------------------------------------------

func TestCSFRemoval_ReachedWhenConflictHasNoService(t *testing.T) {
	m := csfHost()
	// EXACT arm-4 shape: CSF observed only via the config file, Unit empty.
	conflicts := []detect.Conflict{{Name: "CSF", Service: "", Active: true}}

	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	if !ranCmd(m, "mv", "/usr/sbin/csf") {
		t.Error("CSF binary not neutralized — disarm path skipped for a Service=\"\" conflict (arm-4 defect)")
	}
	if !ranCmd(m, "rm", "/etc/cron.d/lfd-cron") {
		t.Error("CSF cron persistence not removed for a Service=\"\" conflict")
	}
}

func TestCSFRemoval_ReachedWhenOnlyBinaryEvidenceExists(t *testing.T) {
	// Arm-3 shape: config gone, unit unusable, payload still on disk.
	m := csfHost()
	delete(m.Files, "/etc/csf/csf.conf")
	conflicts := []detect.Conflict{{Name: "CSF", Service: "", Active: true}}

	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}
	if !ranCmd(m, "mv", "/usr/sbin/csf") {
		t.Error("orphaned CSF payload left executable — re-entry plane open (arm-3 defect)")
	}
}

// ---------------------------------------------------------------------------
// CSF-CLOSE-2 — every re-entry plane closed
// ---------------------------------------------------------------------------

func TestCSFRemoval_ClosesEveryReentryPlane(t *testing.T) {
	m := csfHost()
	conflicts := []detect.Conflict{
		{Name: "CSF", Service: "csf.service", Active: true},
		{Name: "CSF", Service: "lfd.service", Active: true},
	}
	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	for _, b := range []string{"/usr/sbin/csf", "/usr/sbin/lfd"} {
		if !ranCmd(m, "mv", b) {
			t.Errorf("%s left executable — re-entry plane open", b)
		}
	}
	for _, c := range []string{"/etc/cron.d/lfd-cron", "/etc/cron.d/csf-cron", "/etc/cron.d/csf_update"} {
		if !ranCmd(m, "rm", c) {
			t.Errorf("%s not removed — scheduled CSF re-entry survives", c)
		}
	}
	// /etc/crontab: CSF lines stripped, operator lines untouched, file kept.
	w, ok := m.WrittenFiles["/etc/crontab"]
	if !ok {
		t.Fatal("/etc/crontab never rewritten — the TESTING=1 root flush job survives")
	}
	got := string(w)
	if strings.Contains(got, "/usr/sbin/csf") {
		t.Error("CSF persistence line still present in /etc/crontab")
	}
	if !strings.Contains(got, "operator-backup.sh") {
		t.Error("operator's own crontab entry was destroyed — only CSF lines may be stripped")
	}
}

// ---------------------------------------------------------------------------
// CSF-CLOSE-3 — attributable removal only; never a blanket flush
// ---------------------------------------------------------------------------

func TestCSFRemoval_NeverFlushesUnrelatedIptablesState(t *testing.T) {
	m := csfHost()
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}
	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	// The blanket flush destroyed operator-owned OPERATOR_QOS and Docker chains
	// on three separate runtime arms. It must not be issued at all.
	for _, c := range m.Commands {
		if c.Name != "iptables" && c.Name != "ip6tables" {
			continue
		}
		joined := strings.Join(c.Args, " ")
		for _, forbidden := range []string{"-F", "-X", "-P"} {
			if strings.Contains(joined, forbidden) {
				t.Errorf("blanket iptables mutation issued (%s %s) — destroys unattributable foreign state",
					c.Name, joined)
			}
		}
	}
}

// CONTRACT CORRECTED 2026-08-12 after package-native runtime validation.
//
// This previously asserted that `csf --stop` IS invoked, on the assumption
// that CSF unwinding its own ruleset counts as attributable removal. Measured
// on el9-clean, it does not: `csf --stop` flushes filter/nat/mangle wholesale
// and destroyed the operator-owned OPERATOR_QOS chain (2 -> 0), exactly like
// the blanket flush CLOSE-3 deleted.
//
//	DELEGATING THE FLUSH TO THE VENDOR != MAKING IT ATTRIBUTABLE
//
// The corrected contract: NFTBan invokes NO vendor stop. CSF's kernel rules
// are left inert once every execution plane is neutralized.
func TestCSFRemoval_NeverInvokesVendorStop(t *testing.T) {
	m := csfHost()
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}
	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	// No vendor firewall binary may be executed — not to probe, not to stop.
	for _, c := range m.Commands {
		switch c.Name {
		case "/usr/sbin/csf", "csf", "/usr/sbin/lfd", "lfd":
			t.Errorf("takeover executed a vendor firewall binary (%s %v) — it flushes "+
				"operator state wholesale", c.Name, c.Args)
		}
	}

	// And the execution planes must still be closed, so the rules are inert.
	if !ranCmd(m, "mv", "/usr/sbin/csf") || !ranCmd(m, "mv", "/usr/sbin/lfd") {
		t.Error("binaries not neutralized — CSF rules would not be inert")
	}
}

// ---------------------------------------------------------------------------
// Destructive-consequence disclosure must precede mutation
// ---------------------------------------------------------------------------

// OWNER RULING 2026-08-12: legacy-iptables preservation across CSF removal is
// NOT SUPPORTED, because CSF's own ExecStop flushes those tables. That is an
// acceptable contract ONLY if the operator is told before anything is mutated.
func TestCSFRemoval_DisclosesDestructiveConsequenceBeforeMutation(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "installer.log")
	lg := logging.New(logPath, false)

	m := csfHost()
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}
	if err := DisableConflicts(m, conflicts, detect.PanelNone, lg); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}

	warned := strings.Join(lg.Warnings(), " | ")
	for _, must := range []string{"destructive", "FLUSH legacy", "does not restore"} {
		if !strings.Contains(warned, must) {
			t.Errorf("pre-mutation disclosure missing %q — operator not told that CSF shutdown "+
				"may flush legacy iptables rules. warnings: %s", must, warned)
		}
	}

	// NEGATIVE CONTROL: a non-CSF conflict must not emit the CSF disclosure.
	m2 := csfHost()
	lg2 := logging.New(filepath.Join(t.TempDir(), "b.log"), false)
	_ = DisableConflicts(m2, []detect.Conflict{{Name: "UFW", Service: "ufw.service"}}, detect.PanelNone, lg2)
	if strings.Contains(strings.Join(lg2.Warnings(), " "), "CSF takeover authorized") {
		t.Error("CSF destructive disclosure emitted with no CSF conflict present")
	}
}

// ---------------------------------------------------------------------------
// Idempotence — a partially neutralized host must converge, not error
// ---------------------------------------------------------------------------

func TestCSFRemoval_IdempotentOnAlreadyNeutralizedHost(t *testing.T) {
	m := csfHost()
	delete(m.Files, "/usr/sbin/csf") // already renamed by a previous takeover
	delete(m.Files, "/etc/cron.d/csf-cron")
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}

	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts must converge on a partial host, got: %v", err)
	}
	if ranCmd(m, "mv", "/usr/sbin/csf ") {
		t.Error("attempted to rename an absent binary instead of skipping")
	}
	// lfd was still present, so its plane must still be closed.
	if !ranCmd(m, "mv", "/usr/sbin/lfd") {
		t.Error("lfd plane left open on a partially neutralized host")
	}
}

// ---------------------------------------------------------------------------
// Negative control — non-CSF conflicts must not trigger CSF removal
// ---------------------------------------------------------------------------

func TestCSFRemoval_NotTriggeredWithoutCSFEvidence(t *testing.T) {
	m := csfHost()
	conflicts := []detect.Conflict{{Name: "UFW", Service: "ufw.service", Active: true}}

	if err := DisableConflicts(m, conflicts, detect.PanelNone, newTestLogger()); err != nil {
		t.Fatalf("DisableConflicts: %v", err)
	}
	if ranCmd(m, "mv", "/usr/sbin/csf") {
		t.Error("CSF removal ran with no CSF conflict — over-broad trigger")
	}
	if ranCmd(m, "rm", "/etc/cron.d/csf_update") {
		t.Error("CSF cron removed with no CSF conflict present")
	}
	if _, rewritten := m.WrittenFiles["/etc/crontab"]; rewritten {
		t.Error("/etc/crontab rewritten with no CSF conflict present")
	}
}
