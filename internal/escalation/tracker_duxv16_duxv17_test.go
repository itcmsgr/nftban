// =============================================================================
// NFTBan - D-UXV-16 / D-UXV-17 regression tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="tracker_duxv16_duxv17_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Regression tests for the coupled V127 shared-resource blocker. D-UXV-16: CountRecentBans/parseBanEntry must read the canonical BLC-1 pipe bans.log (not the dead space-delimited format) so repeat-offender escalation fires instead of silently reading 0. D-UXV-17: AddToPersistentOffenders + persistence.PersistBan write the SAME 30-persistent-offenders.conf and must not clobber or duplicate under concurrency (single canonical writer + stable-lockfile flock + atomic temp+rename + dedup)."
// meta:input="None (self-contained temp dirs)"
// meta:output="None"
// meta:depends="testing,os,path/filepath,strings,sync,fmt,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package escalation

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/persistence"
)

// blc1 builds a canonical 10-field BLC-1 bans.log row (local-time DATE|TIME).
func blc1(ts time.Time, source, ip, status, reason string) string {
	return fmt.Sprintf("%s|%s|%s|%s|US|%s|%s|bid|0|temp",
		ts.Format("2006-01-02"), ts.Format("15:04:05"), source, ip, status, reason)
}

// readOffenderIPs returns the IP (first field) of every non-comment line.
func readOffenderIPs(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var ips []string
	for _, ln := range strings.Split(string(data), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		if f := strings.Fields(ln); len(f) > 0 {
			ips = append(ips, f[0])
		}
	}
	return ips
}

// D-UXV-16: CountRecentBans must count recent BANNED rows from BLC-1 data, and
// exclude UNBANNED rows, other IPs, and rows outside the period.
func TestCountRecentBans_BLC1_CountsRecentBannedOnly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bans.log")
	now := time.Now()
	old := now.Add(-3 * time.Hour)
	lines := []string{
		blc1(now, "login", "1.2.3.4", "BANNED", "r1"),
		blc1(now, "login", "1.2.3.4", "BANNED", "r2"),
		blc1(now, "login", "1.2.3.4", "BANNED", "r3"),
		blc1(now, "login", "1.2.3.4", "UNBANNED", "expired"), // not a ban
		blc1(now, "login", "9.9.9.9", "BANNED", "other ip"),  // different IP
		blc1(old, "login", "1.2.3.4", "BANNED", "too old"),   // outside period
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0644); err != nil {
		t.Fatal(err)
	}

	got, err := CountRecentBans(path, "1.2.3.4", time.Hour)
	if err != nil {
		t.Fatalf("CountRecentBans: %v", err)
	}
	if got != 3 {
		t.Errorf("CountRecentBans = %d, want 3 (3 recent BANNED for the IP; UNBANNED/other-IP/old excluded). Pre-fix this was 0 — the reader parsed the dead space format.", got)
	}
}

// D-UXV-16: prove the escalation gate (banCount >= threshold) actually fires
// from BLC-1 data — the live cmd_ban.go / daemon_handlers_ban.go path.
func TestCountRecentBans_BLC1_EscalationThresholdReached(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bans.log")
	now := time.Now()
	const threshold = 3
	var lines []string
	for i := 0; i < 5; i++ {
		lines = append(lines, blc1(now, "login", "5.6.7.8", "BANNED", fmt.Sprintf("ban %d", i)))
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0644); err != nil {
		t.Fatal(err)
	}

	got, err := CountRecentBans(path, "5.6.7.8", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if got < threshold {
		t.Errorf("CountRecentBans = %d, want >= %d so the escalation gate fires from BLC-1 data; pre-fix it read 0 and repeat-offender escalation never fired", got, threshold)
	}
}

// D-UXV-16: the dead space-delimited rows must NOT be counted (BLC-1 canonical).
func TestCountRecentBans_LegacySpaceFormatCountsZero(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bans.log")
	now := time.Now().UTC().Format(time.RFC3339)
	legacy := now + " 1.2.3.4 nftban-sshd SSH brute force\n"
	if err := os.WriteFile(path, []byte(strings.Repeat(legacy, 5)), 0644); err != nil {
		t.Fatal(err)
	}
	got, err := CountRecentBans(path, "1.2.3.4", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if got != 0 {
		t.Errorf("legacy space-delimited rows counted = %d, want 0 (BLC-1 is canonical)", got)
	}
}

// D-UXV-17: concurrent AddToPersistentOffenders + persistence.PersistBan on the
// SAME 30-persistent-offenders.conf must not LOSE (clobber) any distinct IP.
func TestPersistentOffenders_ConcurrentNoClobber(t *testing.T) {
	configDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(configDir, "blacklist.d"), 0750); err != nil {
		t.Fatal(err)
	}
	confPath := filepath.Join(configDir, "blacklist.d", "30-persistent-offenders.conf")

	const n = 50
	want := make(map[string]bool, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		ip := fmt.Sprintf("45.33.%d.%d", i/256, i%256)
		want[ip] = true
		wg.Add(1)
		go func(i int, ip string) {
			defer wg.Done()
			if i%2 == 0 {
				_ = AddToPersistentOffenders(confPath, ip, "concurrent")
			} else {
				_, _, _ = persistence.PersistBan(configDir, ip, "concurrent", "persistent")
			}
		}(i, ip)
	}
	wg.Wait()

	seen := map[string]int{}
	for _, ip := range readOffenderIPs(t, confPath) {
		seen[ip]++
	}
	for ip := range want {
		if seen[ip] == 0 {
			t.Errorf("IP %s was LOST (clobbered) by a concurrent rename — D-UXV-17 race", ip)
		}
		if seen[ip] > 1 {
			t.Errorf("IP %s DUPLICATED %d times", ip, seen[ip])
		}
	}
}

// D-UXV-17: the SAME IP persisted concurrently through both writers must end up
// exactly once (dedup under the shared lock + normalized single format).
func TestPersistentOffenders_ConcurrentSameIPDedup(t *testing.T) {
	configDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(configDir, "blacklist.d"), 0750); err != nil {
		t.Fatal(err)
	}
	confPath := filepath.Join(configDir, "blacklist.d", "30-persistent-offenders.conf")

	const ip = "45.33.32.7"
	var wg sync.WaitGroup
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if i%2 == 0 {
				_ = AddToPersistentOffenders(confPath, ip, "dup test")
			} else {
				_, _, _ = persistence.PersistBan(configDir, ip, "dup test", "persistent")
			}
		}(i)
	}
	wg.Wait()

	count := 0
	for _, got := range readOffenderIPs(t, confPath) {
		if got == ip {
			count++
		}
	}
	if count != 1 {
		t.Errorf("same IP persisted concurrently appears %d times, want exactly 1 (dedup under shared lock)", count)
	}
}
