// SPDX-License-Identifier: MPL-2.0
// meta:name="persistence/blacklistd_classguard_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="v1.220.2 F2: PersistBan refuses non-public/absolute-non-bannable addresses (never written to blacklist.d so the full-sync cannot re-materialize them into a drop set) and still persists public addresses; IPv4/IPv6 symmetric."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// v1.220.2 F2: PersistBan must never write a non-public / absolute-non-bannable address
// into a blacklist file (the file->kernel full-sync would otherwise re-materialize it
// into a drop set). Public addresses still persist; IPv4/IPv6 symmetric.
package persistence

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPersistBanRejectsNonPublic(t *testing.T) {
	reject := []string{
		"127.0.0.1", "127.0.1.1", "::1", "0.0.0.0", "::", "224.0.0.1", "ff02::1",
		"10.0.0.5", "192.168.1.10", "169.254.1.2", "fe80::1", "fc00::1", "100.64.0.1",
		"192.0.2.1", "2001:db8::1", "240.0.0.1",
	}
	for _, ip := range reject {
		dir := t.TempDir()
		_, _, err := PersistBan(dir, ip, "test", "manual")
		if err == nil {
			t.Errorf("PersistBan(%q) = nil error, want refusal", ip)
		}
		if err != nil && !strings.Contains(err.Error(), "refusing to persist") {
			t.Errorf("PersistBan(%q) error=%q, want a 'refusing to persist' class rejection", ip, err.Error())
		}
		// nothing must have been written
		if entries, _ := os.ReadDir(filepath.Join(dir, "blacklist.d")); len(entries) > 0 {
			for _, e := range entries {
				b, _ := os.ReadFile(filepath.Join(dir, "blacklist.d", e.Name()))
				if strings.Contains(string(b), strings.TrimSuffix(ip, "/32")) {
					t.Errorf("PersistBan(%q) wrote the rejected address into %s", ip, e.Name())
				}
			}
		}
	}
}

func TestPersistBanAllowsPublic(t *testing.T) {
	public := []string{"8.8.4.4", "46.225.150.67", "2a01:4f8:c014:5ee1::1", "2606:4700:4700::1111"}
	for _, ip := range public {
		dir := t.TempDir()
		if _, _, err := PersistBan(dir, ip, "test", "manual"); err != nil {
			t.Errorf("PersistBan(%q) public address rejected: %v", ip, err)
		}
	}
}
