// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="switchop-ssh-handoff-v1234-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-29"
// meta:description="SSHHandoffProven / HandOffEmergencySSH: the emergency SSH table is removed only when every sshd port is an exact kernel element of ip AND ip6 nftban tcp_ports_in and the input chain carries the tcp dport @tcp_ports_in ct state new ... accept rule; every unproven leg keeps it."
// meta:inventory.files="internal/installer/switchop/sshhandoff_v1234_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package switchop

import (
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const handoffChain = "table ip nftban {\n\tchain input {\n" +
	"\t\ttcp flags syn ct state new tcp dport @tcp_ports_in update @syn_meter_v4 { ip saddr limit rate 25/second burst 50 packets } counter name \"total_input_accept\" accept comment \"SYN rate OK\"\n" +
	"\t\ttcp dport @tcp_ports_in ct state new counter name \"input_service_tcp_accept\" counter name \"total_input_accept\" accept\n" +
	"\t}\n}\n"

func handoffMock(members map[string][]string, chain string) *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.StrictUnregistered = true // an unmodelled command must never read as success
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true
	m.NftTables["inet:"+emergencyTable] = true
	for _, fam := range []string{"ip", "ip6"} {
		m.RunResults["nft:list:chain:"+fam+":nftban:input"] = executor.Result{Stdout: chain}
		for _, p := range []string{"22", "2222", "55000"} {
			rc := 1
			for _, e := range members[fam] {
				if e == p {
					rc = 0
				}
			}
			m.RunResults["nft:get:element:"+fam+":nftban:tcp_ports_in:{ "+p+" }"] = executor.Result{ExitCode: rc}
		}
	}
	return m
}

func handoffLog(t *testing.T) *logging.Logger {
	t.Helper()
	l := logging.New(filepath.Join(t.TempDir(), "i.log"), false)
	t.Cleanup(l.Close)
	return l
}

func TestSSHHandoff_ProvenRemovesTable(t *testing.T) {
	m := handoffMock(map[string][]string{"ip": {"22"}, "ip6": {"22"}}, handoffChain)
	if !HandOffEmergencySSH(m, []int{22}, handoffLog(t)) {
		t.Fatal("proven handoff did not remove the emergency table")
	}
	if m.NftTableExists("inet", emergencyTable) || len(m.NftDeleteTableCalls) != 1 {
		t.Fatalf("table present=%t deletes=%v", m.NftTableExists("inet", emergencyTable), m.NftDeleteTableCalls)
	}
}

func TestSSHHandoff_UnprovenKeepsTable(t *testing.T) {
	cases := []struct {
		name    string
		members map[string][]string
		chain   string
		ports   []int
		tables  map[string]bool
	}{
		{"ip6 lacks the port", map[string][]string{"ip": {"22"}, "ip6": {}}, handoffChain, []int{22}, nil},
		{"ip lacks the port", map[string][]string{"ip": {}, "ip6": {"22"}}, handoffChain, []int{22}, nil},
		// "22" is a substring of "2222": exact membership, never a listing substring.
		{"only 2222 present, sshd on 22", map[string][]string{"ip": {"2222"}, "ip6": {"2222"}}, handoffChain, []int{22}, nil},
		{"second sshd port missing", map[string][]string{"ip": {"22"}, "ip6": {"22"}}, handoffChain, []int{22, 55000}, nil},
		{"no service accept rule (only the SYN meter)", map[string][]string{"ip": {"22"}, "ip6": {"22"}},
			"\t\ttcp flags syn ct state new tcp dport @tcp_ports_in counter accept\n", []int{22}, nil},
		{"service rule drops instead of accepting", map[string][]string{"ip": {"22"}, "ip6": {"22"}},
			"\t\ttcp dport @tcp_ports_in ct state new counter drop\n", []int{22}, nil},
		{"no known sshd port", map[string][]string{"ip": {"22"}, "ip6": {"22"}}, handoffChain, nil, nil},
		{"ip6 nftban table missing", map[string][]string{"ip": {"22"}, "ip6": {"22"}}, handoffChain, []int{22}, map[string]bool{"ip6:nftban": false}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := handoffMock(c.members, c.chain)
			for k, v := range c.tables {
				m.NftTables[k] = v
			}
			if HandOffEmergencySSH(m, c.ports, handoffLog(t)) {
				t.Fatal("unproven handoff reported the table absent")
			}
			if !m.NftTableExists("inet", emergencyTable) || len(m.NftDeleteTableCalls) != 0 {
				t.Fatalf("unproven handoff touched the table: present=%t deletes=%v",
					m.NftTableExists("inet", emergencyTable), m.NftDeleteTableCalls)
			}
		})
	}
}

func TestSSHHandoff_NoTableIsANoOp(t *testing.T) {
	m := handoffMock(map[string][]string{}, "")
	m.NftTables["inet:"+emergencyTable] = false
	if !HandOffEmergencySSH(m, []int{22}, handoffLog(t)) || len(m.Commands) != 0 {
		t.Fatalf("absent table must be a read-only no-op; commands=%v", m.Commands)
	}
}
