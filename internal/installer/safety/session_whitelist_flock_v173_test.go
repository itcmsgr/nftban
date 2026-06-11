// =============================================================================
// NFTBan v1.173 - §4.1 session-whitelist flock (cross-process lost-update fix)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-safety-session-flock-v173-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-11"
// meta:description="Locks the v1.173 §4.1 fix: the session-whitelist read-modify-write is serialized by an exclusive flock on /run/nftban/session_whitelist.lock so concurrent writers cannot lose updates, and that lock interlocks cross-language with shell flock(1) (both flock(2)). (1) ConcurrentAdd: N parallel AddSessionWhitelist via the RealExecutor on a temp file → all N entries survive (no lost update). (2) CrossLanguageFlock: while Go holds LOCK_EX, a non-blocking shell `flock -n` on the SAME path fails; after release it succeeds. Hermetic: temp data path + temp lock path (TestMain); no /run, no root, no nft."
// meta:inventory.files="internal/installer/safety/session_whitelist.go,internal/installer/executor/real.go,cli/lib/nftban/cli/cmd_firewall.sh"
// meta:inventory.binaries="flock"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	osexec "os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// withTempSessionFile redirects sessionWhitelistPath to a per-test temp file
// and restores it afterwards. sessionWhitelistLockPath is already a temp path
// (set once in TestMain).
func withTempSessionFile(t *testing.T) {
	t.Helper()
	old := sessionWhitelistPath
	sessionWhitelistPath = filepath.Join(t.TempDir(), "00-session.conf")
	t.Cleanup(func() { sessionWhitelistPath = old })
}

// TestSessionWhitelist_ConcurrentAddNoLostUpdate proves the §4.1 flock
// serializes the whole read-modify-write: N parallel AddSessionWhitelist calls
// (real filesystem) all survive. Without a lock around the full RMW, each
// goroutine would read the file, modify in memory, and the last writer would
// clobber the others (atomic rename prevents torn reads, NOT lost updates).
func TestSessionWhitelist_ConcurrentAddNoLostUpdate(t *testing.T) {
	withTempSessionFile(t)
	re := &executor.RealExecutor{}
	log := newSessionTestLogger(t)

	const n = 24
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			e := SessionWhitelistEntry{
				IP:        "10.0.0." + strconv.Itoa(i),
				ExpiresAt: time.Now().Add(time.Hour),
				Reason:    "concurrent",
				AddedBy:   "test",
			}
			if err := AddSessionWhitelist(re, log, e); err != nil {
				errs <- err
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent AddSessionWhitelist: %v", err)
	}

	entries, err := ReadSessionWhitelist(re, log)
	if err != nil {
		t.Fatalf("ReadSessionWhitelist: %v", err)
	}
	if len(entries) != n {
		t.Fatalf("lost-update: expected %d entries after %d concurrent adds, got %d", n, n, len(entries))
	}
}

// TestSessionWhitelist_CrossLanguageFlockExcludesShell proves the Go lock and
// the shell flock(1) interlock on the SAME path (both flock(2)): while Go holds
// LOCK_EX, a non-blocking shell `flock -n` must FAIL; after release it must
// succeed. This is the cross-language guarantee a Go-only test cannot cover.
func TestSessionWhitelist_CrossLanguageFlockExcludesShell(t *testing.T) {
	if _, err := osexec.LookPath("flock"); err != nil {
		t.Skip("flock(1) not available")
	}

	unlock, err := lockSessionWhitelist()
	if err != nil {
		t.Fatalf("lockSessionWhitelist: %v", err)
	}

	// While Go holds the lock, a non-blocking shell flock on the same path must fail.
	if err := osexec.Command("flock", "-n", sessionWhitelistLockPath, "-c", "true").Run(); err == nil {
		unlock()
		t.Fatalf("cross-language: shell `flock -n` acquired the lock while Go held it (no exclusion)")
	}

	// After release, the shell flock must succeed.
	unlock()
	if err := osexec.Command("flock", "-n", sessionWhitelistLockPath, "-c", "true").Run(); err != nil {
		t.Fatalf("cross-language: shell `flock -n` failed after Go released the lock: %v", err)
	}
}
