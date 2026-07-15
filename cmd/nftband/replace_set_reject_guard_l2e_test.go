// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband/replace_set_reject_guard_l2e_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="L2e reject-guard: handleReplaceSetRequest must DENY the legacy non-atomic replace_set IPC for the atomic-owned interval sets (blacklist_ipv4/blacklist_ipv6), which are the sole domain of the FULL-sync atomic writer (setsync). Proves the two protection sets are rejected with an explicit error and that a non-interval set is not blocked by this guard. Hermetic; no nft/netlink/root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/opqueue"
)

// stubReplaceBackend is a no-op NetlinkBackend so we can build a real OpQueue; the
// L2e guard rejects before the queue is ever used for the protection sets.
type stubReplaceBackend struct{}

func (stubReplaceBackend) FlushSet(table, set string) error { return nil }
func (stubReplaceBackend) AddElements(table, set string, e []opqueue.SetElement) (int, error) {
	return len(e), nil
}
func (stubReplaceBackend) DeleteElements(table, set string, e []opqueue.SetElement) error { return nil }
func (stubReplaceBackend) GetSetElements(table, set string) ([]string, error)             { return nil, nil }

const l2eBlockedMsg = "blocked for interval/protection set"

func newReplaceGuardDaemon() *Daemon {
	return &Daemon{opQueue: opqueue.NewOpQueue(stubReplaceBackend{}, opqueue.DefaultQueueConfig())}
}

// The atomic-owned interval sets MUST be rejected: the non-atomic opqueue replace_set
// path can never touch them (they belong to the FULL-sync atomic writer).
func TestReplaceSet_RejectsAtomicOwnedIntervalSets(t *testing.T) {
	d := newReplaceGuardDaemon()
	for _, set := range []string{"blacklist_ipv4", "blacklist_ipv6"} {
		resp := d.handleReplaceSetRequest(map[string]any{
			"set": set, "file": "/nonexistent", "source": "test",
		})
		if resp.Success {
			t.Fatalf("replace_set for %s must be rejected, got Success=true", set)
		}
		if !strings.Contains(resp.Error, l2eBlockedMsg) {
			t.Fatalf("replace_set %s reject error must mention %q; got %q", set, l2eBlockedMsg, resp.Error)
		}
	}
}

// A valid non-interval set must NOT be blocked by the L2e guard (it fails later, at
// file read, proving the guard is set-specific and did not fire).
func TestReplaceSet_GuardIsSetSpecific(t *testing.T) {
	d := newReplaceGuardDaemon()
	resp := d.handleReplaceSetRequest(map[string]any{
		"set": "geoban_ipv4", "file": "/nonexistent/file", "source": "test",
	})
	if resp.Success {
		t.Fatal("expected failure at file read for a missing file")
	}
	if strings.Contains(resp.Error, l2eBlockedMsg) {
		t.Fatalf("non-interval set must NOT be blocked by the L2e guard; got %q", resp.Error)
	}
}

// The guard set must contain exactly the two atomic-owned interval blacklist sets.
func TestReplaceSet_GuardSetMembership(t *testing.T) {
	if !intervalSetsOwnedByAtomicSync["blacklist_ipv4"] || !intervalSetsOwnedByAtomicSync["blacklist_ipv6"] {
		t.Fatal("both blacklist_ipv4 and blacklist_ipv6 must be in intervalSetsOwnedByAtomicSync")
	}
	if intervalSetsOwnedByAtomicSync["blacklist_manual_ipv4"] {
		t.Fatal("manual hash sets must NOT be in the interval-owned guard set")
	}
}
