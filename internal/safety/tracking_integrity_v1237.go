// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_tracking_integrity_v1237"
// meta:type="library"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup acceptance condition (owner 2026-11-15): the permanent-ban tracking state authorizes permanent removal, so the nftban service account must not be able to forge eligibility, protection or recovery markers. The state lives in the root-owned data directory (/var/lib/nftban/permanent_bans.json, root:nftban 0640, fhs-spec file_permissions); every parent is root-owned with no group/other write. Cleanup loads it only after verifying the file and its whole parent chain (fail closed). The legacy /var/lib/nftban/state/permanent_bans.json (nftban-owned directory) is copied ONCE by root and never read again; its age_source is not trusted (v1.236 never wrote it), so migrated records stay ineligible."
// meta:inventory.files="/var/lib/nftban/permanent_bans.json,/var/lib/nftban/state/permanent_bans.json"
// meta:inventory.privileges="root (writer); readers need nftban group read"

package safety

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

// LegacyPermanentBansFile is the pre-v1.237 location, inside /var/lib/nftban/state (0750 nftban:nftban):
// the service account can rewrite, replace or unlink anything there, so its content is untrusted input.
const LegacyPermanentBansFile = "/var/lib/nftban/state/permanent_bans.json"

// PermanentBansFileMode / PermanentBansGroup: fhs-spec file_permissions (/var/lib/nftban, permanent_bans.json).
const (
	PermanentBansFileMode os.FileMode = 0640
	PermanentBansGroup                = "nftban"
)

var (
	legacyPermanentBansPath = LegacyPermanentBansFile
	// trackingOwnerUID is the uid that must own the tracking file and every parent directory (root).
	trackingOwnerUID = 0
	// trackingChainTop is where the parent walk ends (inclusive). Production: "/" (the whole chain).
	trackingChainTop = "/"
)

// SetTrackingIntegrityForTest redirects the legacy path, the required owner uid and the top of the parent
// walk (tests run unprivileged under a temp dir). Test-only: production code never calls it.
func SetTrackingIntegrityForTest(legacy string, ownerUID int, chainTop string) (restore func()) {
	oldL, oldU, oldT := legacyPermanentBansPath, trackingOwnerUID, trackingChainTop
	legacyPermanentBansPath, trackingOwnerUID, trackingChainTop = legacy, ownerUID, filepath.Clean(chainTop)
	return func() { legacyPermanentBansPath, trackingOwnerUID, trackingChainTop = oldL, oldU, oldT }
}

// ErrTrackingUntrusted: the tracking state is not under the required ownership boundary.
var ErrTrackingUntrusted = errors.New("permanent-ban tracking state is not trusted")

// CheckPermanentBansIntegrity verifies that the tracking file (when present) is a regular file, not a
// symlink, owned by trackingOwnerUID without group/other write, and that EVERY parent directory up to /
// is owned by trackingOwnerUID or root without group/other write (a writable parent can replace the
// entry whatever the file's own mode). A missing file is not an error (no tracked bans).
func CheckPermanentBansIntegrity() error {
	p := permanentBansPath
	fi, err := os.Lstat(p)
	if err != nil {
		if os.IsNotExist(err) {
			// No state yet: check from the first existing ancestor (nothing below it exists to trust).
			d := filepath.Dir(p)
			for d != filepath.Dir(d) && d != trackingChainTop {
				if _, serr := os.Lstat(d); serr == nil {
					break
				}
				d = filepath.Dir(d)
			}
			return checkParents(d)
		}
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 || !fi.Mode().IsRegular() {
		return fmt.Errorf("%w: %s is not a regular file", ErrTrackingUntrusted, p)
	}
	if err := ownedNotWritable(p, fi); err != nil {
		return err
	}
	return checkParents(filepath.Dir(p))
}

func checkParents(dir string) error {
	for d := filepath.Clean(dir); ; d = filepath.Dir(d) {
		fi, err := os.Lstat(d)
		if err != nil {
			return fmt.Errorf("%w: %s: %v", ErrTrackingUntrusted, d, err)
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%w: parent %s is a symlink", ErrTrackingUntrusted, d)
		}
		if err := ownedNotWritable(d, fi); err != nil {
			return err
		}
		if d == trackingChainTop || d == filepath.Dir(d) {
			return nil
		}
	}
}

func ownedNotWritable(p string, fi os.FileInfo) error {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("%w: cannot read owner of %s", ErrTrackingUntrusted, p)
	}
	if int(st.Uid) != trackingOwnerUID && st.Uid != 0 {
		return fmt.Errorf("%w: %s owned by uid %d", ErrTrackingUntrusted, p, st.Uid)
	}
	if fi.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("%w: %s is group/other writable (%04o)", ErrTrackingUntrusted, p, fi.Mode().Perm())
	}
	return nil
}

// LoadPermanentBansForCleanup is the ONLY load cleanup decisions use: integrity first, fail closed.
func LoadPermanentBansForCleanup() (*PermanentBansState, error) {
	if err := CheckPermanentBansIntegrity(); err != nil {
		return nil, err
	}
	return LoadPermanentBans()
}

// migrateLegacyPermanentBans copies the legacy tracking file to the root-owned location ONCE, when the
// new file does not exist. Copy, never move: the legacy file is left in place and never read again.
// Every record keeps ip, added_at, reason, source, protected and cleanup_pending; age_source is cleared
// because v1.236 never wrote it, so a value there can only have been written from outside the product
// (the legacy directory is service-account writable): migrated records stay legacy-age-unverified,
// i.e. ineligible under the approved rules. Returns (nil, nil) when there is nothing to migrate.
func migrateLegacyPermanentBans() (*PermanentBansState, error) {
	data, err := os.ReadFile(legacyPermanentBansPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read legacy tracking %s: %w", legacyPermanentBansPath, err)
	}
	var st PermanentBansState
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, fmt.Errorf("parse legacy tracking %s: %w", legacyPermanentBansPath, err)
	}
	if st.Bans == nil {
		st.Bans = make(map[string]*PermanentBan)
	}
	cleared, protected, pending := 0, 0, 0
	for ip, b := range st.Bans {
		if b == nil {
			delete(st.Bans, ip)
			continue
		}
		if b.AgeSource != "" {
			b.AgeSource = ""
			cleared++
		}
		if b.Protected {
			protected++
		}
		if b.CleanupPending != "" {
			pending++
		}
	}
	if err := SavePermanentBans(&st); err != nil {
		return nil, fmt.Errorf("write migrated tracking %s: %w", permanentBansPath, err)
	}
	log.Printf("[TRACKING] migrated %d record(s) from %s to %s (protected=%d pending=%d age_source_cleared=%d); legacy file left in place, no longer read",
		len(st.Bans), legacyPermanentBansPath, permanentBansPath, protected, pending, cleared)
	return &st, nil
}

// setTrackingOwnership puts the written file at root:nftban (fhs-spec) when running as root. In place:
// the inode does not change.
func setTrackingOwnership(p string) {
	if os.Geteuid() != 0 {
		return
	}
	g, err := user.LookupGroup(PermanentBansGroup)
	if err != nil {
		return
	}
	gid, err := strconv.Atoi(g.Gid)
	if err != nil {
		return
	}
	_ = os.Lchown(p, 0, gid)
}
