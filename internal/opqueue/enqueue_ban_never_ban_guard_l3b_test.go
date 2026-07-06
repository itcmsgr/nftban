// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/enqueue_ban_never_ban_guard_l3b_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="L3b: the never-ban invariant holds on the opqueue ban path. Proves EnqueueBan refuses (skips) an exempt single IP into an enforcement/drop set (v4+v6) via the injected resolver, increments EnqueueBanExemptSkips, allows normal public IPs, allows exempt IPs into non-enforcement sets, and is fail-safe when no resolver is injected. Also covers CheckExempt (the caller-side pre-check helper). Hermetic: trivial stub backend, no netlink/root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package opqueue

import (
	"context"
	"testing"
)

type l3bStubBackend struct{}

func (l3bStubBackend) FlushSet(table, set string) error { return nil }
func (l3bStubBackend) AddElements(table, set string, e []SetElement) (int, error) {
	return len(e), nil
}
func (l3bStubBackend) DeleteElements(table, set string, e []SetElement) error { return nil }
func (l3bStubBackend) GetSetElements(table, set string) ([]string, error)     { return nil, nil }

// resolver mirroring the daemon closure: enforcement set + exempt single IP → refuse.
func l3bResolver(set, ip string) (bool, string) {
	enforcement := map[string]bool{
		"http_bot_ban": true, "http_bot_ban6": true, "http_bot_emergency": true,
		"blacklist_manual_ipv4": true, "blacklist_ipv4": true,
	}
	exempt := map[string]bool{"10.0.0.5": true, "2001:db8::9": true}
	if enforcement[set] && exempt[ip] {
		return true, "test-exempt"
	}
	return false, ""
}

func newGuardedQueue(t *testing.T) *OpQueue {
	t.Helper()
	q := NewOpQueue(l3bStubBackend{}, DefaultQueueConfig())
	q.SetExemptResolver(l3bResolver)
	q.Start(context.Background())
	t.Cleanup(q.Stop)
	return q
}

func TestEnqueueBan_RejectsExemptIntoEnforcementSet_L3b(t *testing.T) {
	q := newGuardedQueue(t)
	// v4 into a BotGuard drop set
	if err := q.EnqueueBan("http_bot_ban", "10.0.0.5", 3600, "botguard", "test"); err != nil {
		t.Fatalf("exempt v4 EnqueueBan must skip (nil err), got %v", err)
	}
	// v6 into the v6 BotGuard drop set
	if err := q.EnqueueBan("http_bot_ban6", "2001:db8::9", 3600, "botguard", "test"); err != nil {
		t.Fatalf("exempt v6 EnqueueBan must skip (nil err), got %v", err)
	}
	// blacklist_manual (the batch-signal path target) also fenced
	if err := q.EnqueueBan("blacklist_manual_ipv4", "10.0.0.5", 3600, "botscan", "test"); err != nil {
		t.Fatalf("exempt into blacklist_manual must skip, got %v", err)
	}
	if got := q.Stats().EnqueueBanExemptSkips; got != 3 {
		t.Fatalf("EnqueueBanExemptSkips=%d, want 3", got)
	}
}

func TestEnqueueBan_AllowsNormalAndNonEnforcement_L3b(t *testing.T) {
	q := newGuardedQueue(t)
	// normal public IP into an enforcement set → allowed (not skipped)
	if err := q.EnqueueBan("http_bot_ban", "203.0.113.9", 3600, "botguard", "test"); err != nil {
		t.Fatalf("public IP ban should proceed, got %v", err)
	}
	// exempt IP into a NON-enforcement set (allow/grey state) → not fenced
	if err := q.EnqueueBan("http_bot_allow", "10.0.0.5", 3600, "botguard", "test"); err != nil {
		t.Fatalf("non-enforcement set add should proceed, got %v", err)
	}
	if got := q.Stats().EnqueueBanExemptSkips; got != 0 {
		t.Fatalf("EnqueueBanExemptSkips=%d, want 0 (nothing fenced)", got)
	}
}

func TestEnqueueBan_NilResolver_FailSafe_L3b(t *testing.T) {
	q := NewOpQueue(l3bStubBackend{}, DefaultQueueConfig()) // no SetExemptResolver
	q.Start(context.Background())
	t.Cleanup(q.Stop)
	// with no resolver, even an "exempt" IP proceeds (fail-safe: never block a legit ban)
	if err := q.EnqueueBan("http_bot_ban", "10.0.0.5", 3600, "botguard", "test"); err != nil {
		t.Fatalf("nil resolver must not block, got %v", err)
	}
	if got := q.Stats().EnqueueBanExemptSkips; got != 0 {
		t.Fatalf("EnqueueBanExemptSkips=%d, want 0 with nil resolver", got)
	}
}

func TestCheckExempt_L3b(t *testing.T) {
	q := NewOpQueue(l3bStubBackend{}, DefaultQueueConfig())
	// nil resolver → not exempt
	if ex, _ := q.CheckExempt("http_bot_ban", "10.0.0.5"); ex {
		t.Fatal("nil resolver CheckExempt must return false")
	}
	q.SetExemptResolver(l3bResolver)
	if ex, _ := q.CheckExempt("http_bot_ban", "10.0.0.5"); !ex {
		t.Fatal("exempt IP into enforcement set must be exempt")
	}
	if ex, _ := q.CheckExempt("http_bot_allow", "10.0.0.5"); ex {
		t.Fatal("non-enforcement set must not be exempt")
	}
	if ex, _ := q.CheckExempt("http_bot_ban", "203.0.113.9"); ex {
		t.Fatal("public IP must not be exempt")
	}
}
