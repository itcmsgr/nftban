// =============================================================================
// NFTBan v1.233.1 — Uninstall removes NFTBan SYNPROXY raw notrack rules
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-uninstall-apply-synproxy-raw-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-26"
// meta:description="BUG-UNINSTALL-DOES-NOT-REMOVE-SYNPROXY-RAW-NOTRACK-RULES: Apply step 7 deletes ONLY NFTBan SYNPROXY-commented rules in ip/ip6 raw prerouting, by handle, after a trusted listing; operator raw rules, other chains, the raw tables and chains survive; unobservable kernel and failed deletes are reported (Success=false) without changing the terminal state"
// meta:inventory.files="internal/installer/uninstall/apply.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package uninstall

import (
	"fmt"
	"sort"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

type rawRule struct {
	handle int
	chain  string
	text   string
}

// rawKernel is a tiny stateful model of the ip/ip6 raw tables, served through
// MockExecutor.RunHook. Everything else falls through to the mock unchanged.
type rawKernel struct {
	tables       map[string]bool      // "ip" / "ip6" -> raw table present
	rules        map[string][]rawRule // family -> rules
	listTablesRC int                  // non-zero => `nft list tables` fails
	listTablesSO *string              // override stdout of `nft list tables`
	listRawFail  map[string]bool      // family -> `nft -a list table F raw` fails (EPERM)
	deleteFail   map[string]bool      // "fam:handle" -> delete rule fails
	deleted      []string             // "fam:handle" actually deleted
	rawMutations []string             // any other mutation that touched a raw table
}

func newRawKernel() *rawKernel {
	return &rawKernel{
		tables:      map[string]bool{},
		rules:       map[string][]rawRule{},
		listRawFail: map[string]bool{},
		deleteFail:  map[string]bool{},
	}
}

const (
	nftbanNotrack  = `tcp dport { 80, 443 } tcp flags syn / syn,ack,fin,rst notrack comment "SYNPROXY: notrack SYN"`
	operatorNotrk  = `udp dport 53 notrack comment "operator: dns notrack"`
	operatorPlain  = `iifname "docker0" notrack`
	otherChainSynp = `tcp dport 25 notrack comment "SYNPROXY: output-chain rule"`
)

func (k *rawKernel) seedFamily(fam string, base int) {
	k.tables[fam] = true
	k.rules[fam] = []rawRule{
		{base + 1, "prerouting", operatorNotrk},
		{base + 2, "prerouting", nftbanNotrack},
		{base + 3, "prerouting", operatorPlain},
		{base + 4, "output", otherChainSynp},
	}
}

func (k *rawKernel) listing(fam string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "table %s raw { # handle 7\n", fam)
	for _, ch := range []string{"prerouting", "output"} {
		fmt.Fprintf(&b, "\tchain %s { # handle %d\n", ch, len(ch))
		fmt.Fprintf(&b, "\t\ttype filter hook %s priority raw; policy accept;\n", ch)
		for _, r := range k.rules[fam] {
			if r.chain == ch {
				fmt.Fprintf(&b, "\t\t%s # handle %d\n", r.text, r.handle)
			}
		}
		b.WriteString("\t}\n")
	}
	b.WriteString("}\n")
	return b.String()
}

func (k *rawKernel) hook(name string, args []string) (executor.Result, bool) {
	if name != "nft" {
		return executor.Result{}, false
	}
	a := strings.Join(args, " ")
	switch {
	case a == "list tables":
		if k.listTablesRC != 0 {
			return executor.Result{ExitCode: k.listTablesRC, Stderr: "Error: Operation not permitted"}, true
		}
		if k.listTablesSO != nil {
			return executor.Result{Stdout: *k.listTablesSO}, true
		}
		out := "table inet nftban_install_emergency\n"
		for _, fam := range []string{"ip", "ip6"} {
			if k.tables[fam] {
				out += "table " + fam + " raw\n"
			}
		}
		return executor.Result{Stdout: out}, true
	case len(args) == 5 && args[0] == "-a" && args[1] == "list" && args[2] == "table" && args[4] == "raw":
		fam := args[3]
		if k.listRawFail[fam] {
			return executor.Result{ExitCode: 1, Stderr: "Error: Operation not permitted"}, true
		}
		if !k.tables[fam] {
			return executor.Result{ExitCode: 1, Stderr: "Error: No such file or directory"}, true
		}
		return executor.Result{Stdout: k.listing(fam)}, true
	case len(args) == 7 && args[0] == "delete" && args[1] == "rule" && args[3] == "raw" && args[5] == "handle":
		fam, ch, h := args[2], args[4], args[6]
		if k.deleteFail[fam+":"+h] {
			return executor.Result{ExitCode: 1, Stderr: "Error: Device or resource busy"}, true
		}
		for i, r := range k.rules[fam] {
			if fmt.Sprint(r.handle) == h && r.chain == ch {
				k.rules[fam] = append(k.rules[fam][:i], k.rules[fam][i+1:]...)
				k.deleted = append(k.deleted, fam+":"+h)
				return executor.Result{}, true
			}
		}
		return executor.Result{ExitCode: 1, Stderr: "Error: Could not process rule: No such file or directory"}, true
	case strings.Contains(a, " raw"):
		k.rawMutations = append(k.rawMutations, a)
		return executor.Result{}, true
	}
	return executor.Result{}, false
}

func (k *rawKernel) has(fam, text string) bool {
	for _, r := range k.rules[fam] {
		if r.text == text {
			return true
		}
	}
	return false
}

func applyWithRaw(t *testing.T, k *rawKernel) (*ApplyResult, *executor.MockExecutor) {
	t.Helper()
	m := executor.NewMockExecutor()
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true
	m.Services["nftband.service"] = true
	hookEmergencySSHInject(m)
	m.RunHook = k.hook
	return Apply(m, &ApplyConfig{SSHPort: 22}, newTestLogger()), m
}

func synproxyStep(t *testing.T, r *ApplyResult) StepResult {
	t.Helper()
	for i, s := range r.Steps {
		if s.Name == synproxyRawStepName {
			if i == 0 || r.Steps[i-1].Name != "delete_ip6_nftban" {
				t.Errorf("remove_synproxy_raw at index %d is not right after delete_ip6_nftban", i)
			}
			return s
		}
	}
	t.Fatalf("Apply did not record %s; steps=%+v", synproxyRawStepName, r.Steps)
	return StepResult{}
}

// A7-GO: NFTBan rules go, operator rules (POSITIVE CONTROL) and other chains stay.
func TestApplySynproxyRaw_RemovesOnlyNFTBanRules(t *testing.T) {
	k := newRawKernel()
	k.seedFamily("ip", 10)
	k.seedFamily("ip6", 20)
	r, _ := applyWithRaw(t, k)

	if r.State != "UNINSTALL_RELEASED" {
		t.Fatalf("State = %q; want UNINSTALL_RELEASED (%s)", r.State, r.Reason)
	}
	s := synproxyStep(t, r)
	if !s.Success {
		t.Errorf("step failed: %s", s.Detail)
	}
	sort.Strings(k.deleted)
	if got := strings.Join(k.deleted, ","); got != "ip6:22,ip:12" {
		t.Errorf("deleted handles = %q; want exactly the two NFTBan prerouting rules ip6:22,ip:12", got)
	}
	for _, fam := range []string{"ip", "ip6"} {
		if k.has(fam, nftbanNotrack) {
			t.Errorf("%s: NFTBan SYNPROXY notrack rule survived uninstall", fam)
		}
		if !k.has(fam, operatorNotrk) || !k.has(fam, operatorPlain) {
			t.Errorf("%s: POSITIVE CONTROL broken — an operator raw prerouting rule was removed", fam)
		}
		if !k.has(fam, otherChainSynp) {
			t.Errorf("%s: a rule in raw chain output was touched — scope is prerouting only", fam)
		}
		if !k.tables[fam] {
			t.Errorf("%s: raw table itself was removed", fam)
		}
	}
	if len(k.rawMutations) != 0 {
		t.Errorf("non-rule-scoped raw mutations issued: %v", k.rawMutations)
	}
	if !strings.Contains(s.Detail, "ip: removed=1 failed=0 remaining=0") ||
		!strings.Contains(s.Detail, "ip6: removed=1 failed=0 remaining=0") {
		t.Errorf("Detail does not carry the per-family postcondition: %q", s.Detail)
	}
}

func TestApplySynproxyRaw_ListTablesFails_ReportedNotAborted(t *testing.T) {
	k := newRawKernel()
	k.seedFamily("ip", 10)
	k.listTablesRC = 1
	r, _ := applyWithRaw(t, k)
	s := synproxyStep(t, r)
	if s.Success || !strings.Contains(s.Detail, "NOT_OBSERVED") {
		t.Errorf("unobservable inventory must be reported: %+v", s)
	}
	if len(k.deleted) != 0 {
		t.Errorf("deleted without an observation: %v", k.deleted)
	}
	if r.State != "UNINSTALL_RELEASED" {
		t.Errorf("State = %q; a foreign-table observation failure must not abort the release", r.State)
	}
	if last := r.Steps[len(r.Steps)-1].Name; last != "remove_emergency_ssh" {
		t.Errorf("sequence did not continue to the end; last step %q", last)
	}
}

// An rc=0 inventory that does not show the table this run created is not trusted.
func TestApplySynproxyRaw_UntrustedEmptyInventory(t *testing.T) {
	k := newRawKernel()
	k.seedFamily("ip", 10)
	empty := ""
	k.listTablesSO = &empty
	r, _ := applyWithRaw(t, k)
	s := synproxyStep(t, r)
	if s.Success || !strings.Contains(s.Detail, "NOT_OBSERVED") {
		t.Errorf("empty inventory read as absence: %+v", s)
	}
	if len(k.deleted) != 0 {
		t.Errorf("deleted on an untrusted inventory: %v", k.deleted)
	}
}

func TestApplySynproxyRaw_RawListingEPERM_OneFamily(t *testing.T) {
	k := newRawKernel()
	k.seedFamily("ip", 10)
	k.seedFamily("ip6", 20)
	k.listRawFail["ip6"] = true
	r, _ := applyWithRaw(t, k)
	s := synproxyStep(t, r)
	if s.Success || !strings.Contains(s.Detail, "ip6: NOT_OBSERVED") {
		t.Errorf("ip6 listing failure not reported: %+v", s)
	}
	if k.has("ip", nftbanNotrack) || !k.has("ip6", nftbanNotrack) {
		t.Errorf("want ip cleaned and ip6 untouched; deleted=%v", k.deleted)
	}
	if r.State != "UNINSTALL_RELEASED" {
		t.Errorf("State = %q", r.State)
	}
}

func TestApplySynproxyRaw_DeleteFails_ResidueReported(t *testing.T) {
	k := newRawKernel()
	k.seedFamily("ip", 10)
	k.deleteFail["ip:12"] = true
	r, _ := applyWithRaw(t, k)
	s := synproxyStep(t, r)
	if s.Success || !strings.Contains(s.Detail, "ip: removed=0 failed=1 remaining=1") {
		t.Errorf("residue not reported: %+v", s)
	}
	if r.State != "UNINSTALL_RELEASED" {
		t.Errorf("State = %q", r.State)
	}
}

func TestApplySynproxyRaw_NoRawTables_NoRawCalls(t *testing.T) {
	k := newRawKernel()
	r, m := applyWithRaw(t, k)
	s := synproxyStep(t, r)
	if !s.Success {
		t.Errorf("absent raw tables must be a clean no-op: %+v", s)
	}
	for _, c := range m.Commands {
		if c.Name == "nft" && strings.Contains(strings.Join(c.Args, " "), " raw") {
			t.Errorf("raw command issued with no raw table present: nft %v", c.Args)
		}
	}
}

func TestSynproxyRawHandles_Parser(t *testing.T) {
	listing := "table ip raw { # handle 3\n" +
		"\tchain prerouting { # handle 1\n" +
		"\t\ttype filter hook prerouting priority raw; policy accept;\n" +
		"\t\t" + nftbanNotrack + " # handle 5\n" +
		"\t\ttcp dport 8443 notrack COMMENT \"synproxy: legacy case\" # handle 6\n" +
		"\t\t" + operatorNotrk + " # handle 7\n" +
		"\t\ttcp dport 1 notrack comment \"SYNPROXY: no handle printed\"\n" +
		"\t}\n" +
		"\tchain output { # handle 2\n" +
		"\t\t" + otherChainSynp + " # handle 9\n" +
		"\t}\n" +
		"}\n"
	got := strings.Join(synproxyRawHandles(listing), ",")
	if got != "5,6" {
		t.Errorf("handles = %q; want 5,6 (case-insensitive marker, prerouting only, trailing handle only)", got)
	}
}
