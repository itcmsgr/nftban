// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftband_ipc_authz_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.236 per-peer IPC authorization: the nftban service account gets the read-only methods and sync, nothing that changes sets, bans, ports, access or the ruleset, and no unknown method; root and other group members keep every method; no restriction applies when the account does not exist."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import "testing"

func TestMethodPermitted_ServiceAccount(t *testing.T) {
	saved := serviceAccountUID
	t.Cleanup(func() { serviceAccountUID = saved })
	serviceAccountUID = 4242

	for _, m := range []string{"status", "stats", "set_counts", "ping", "queue_status", "watchdog_pressure", "sync"} {
		if !methodPermitted(4242, m) {
			t.Errorf("service account refused the read-only/needed method %q", m)
		}
	}
	// Every set-changing method except sync, and the other state-changing ones, are refused.
	refused := []string{"persist_ban", "unpersist_ban", "protect_ban", "unprotect_ban", "reconcile",
		"load_ports", "snapshot_profile", "no_such_method"}
	for m := range setWriteMethods {
		if m != "sync" {
			refused = append(refused, m)
		}
	}
	for _, m := range refused {
		if methodPermitted(4242, m) {
			t.Errorf("service account was permitted %q", m)
		}
	}
	// Root and another group member keep every method.
	for _, uid := range []uint32{0, 1000} {
		for _, m := range []string{"ban", "unban", "flush_set", "apply_ruleset", "access_allow", "sync", "status"} {
			if !methodPermitted(uid, m) {
				t.Errorf("uid %d refused %q (only the service account is restricted)", uid, m)
			}
		}
	}
}

func TestMethodPermitted_NoServiceAccount(t *testing.T) {
	saved := serviceAccountUID
	t.Cleanup(func() { serviceAccountUID = saved })
	serviceAccountUID = -1
	if !methodPermitted(4242, "flush_set") {
		t.Fatal("restriction applied although no nftban service account exists")
	}
}

// Every permitted method must be a real dispatch method that does not change state, except sync.
func TestServiceAccountMethods_AreReadOnlyExceptSync(t *testing.T) {
	for m := range serviceAccountMethods {
		if setWriteMethods[m] && m != "sync" {
			t.Errorf("permitted method %q changes set contents", m)
		}
	}
}
