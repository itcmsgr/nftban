// SPDX-License-Identifier: MPL-2.0
// meta:name="botguard/never_ban_exempt_l3b_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="L3b caller-side never-ban pre-check: a BotGuard ban signal for an exempt IP must NOT enter any drop/enforcement set (the enforcer/batch-signal path skips before EnqueueBan). Control: a non-exempt IP with the same signal IS banned, proving the skip is specific to the exempt IP and the path is otherwise live. Uses the package recBackend harness; no netlink/root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package botguard

import (
	"context"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

func bannedAnywhere(b *recBackend, ip string) (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for set, ips := range b.adds {
		for _, got := range ips {
			if got == ip {
				return set, true
			}
		}
	}
	return "", false
}

func TestBATCH_SIGNAL_EXEMPT_IP_NOT_BANNED_L3b(t *testing.T) {
	b := &recBackend{adds: make(map[string][]string)}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(b, qcfg)

	const exemptIP = "198.51.100.88"
	const normalIP = "198.51.100.99"
	// L3b resolver: the exempt IP must never enter a drop/enforcement set.
	q.SetExemptResolver(func(set, ip string) (bool, string) {
		if ip == exemptIP {
			return true, "test-exempt"
		}
		return false, ""
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q.Start(ctx)

	m := New()
	m.bus = eventbus.New()
	m.InitEnforcer(q)

	// Control: a normal IP with a ban signal must reach a drop set.
	m.applyBatchSignal(mkSig(normalIP, "scanner", "ban", "scanner pattern: webshell"))
	// The exempt IP with the SAME ban signal must be skipped (never-ban).
	m.applyBatchSignal(mkSig(exemptIP, "scanner", "ban", "scanner pattern: webshell"))

	// Wait until the control IP lands (proves the path is live), then assert the exempt
	// IP never appears.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := bannedAnywhere(b, normalIP); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := bannedAnywhere(b, normalIP); !ok {
		t.Fatalf("control: normal IP %s was not banned — path not exercised (sets: %v)", normalIP, b.adds)
	}
	// Small grace for any late async apply, then the exempt IP must be absent.
	time.Sleep(100 * time.Millisecond)
	if set, ok := bannedAnywhere(b, exemptIP); ok {
		t.Fatalf("never-ban violation: exempt IP %s was banned into %s", exemptIP, set)
	}
}
