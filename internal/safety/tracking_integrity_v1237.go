// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_tracking_integrity_v1237"
// meta:type="library"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup acceptance condition + FHS authority correction (owner 2026-11-15, C1+C2): the permanent-ban tracking state authorizes permanent removal. It stays at /var/lib/nftban/state/permanent_bans.json; state/ is now 0750 root:nftban (fhs-spec), the file root:nftban 0640. Cleanup trusts it only when the file and every parent are root-owned without group/other write AND a root-only trust marker (state/permanent_bans.json.trust, root:root 0600, never re-owned by the permission repair) shows that the records written while state/ was service-account writable have been sanitized: age_source cleared (legacy cleanup records stay ineligible) and pending markers kept but flagged unverified (reported, never acted on). Re-owning a file does not make its old content trusted."
// meta:inventory.files="/var/lib/nftban/state/permanent_bans.json,/var/lib/nftban/state/permanent_bans.json.trust"
// meta:inventory.privileges="root (writer); readers need nftban group read"

package safety

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

// PermanentBansFileMode / PermanentBansGroup: fhs-spec file_permissions (state/permanent_bans.json).
const (
	PermanentBansFileMode os.FileMode = 0640
	PermanentBansGroup                = "nftban"
	// PermanentBansTrustSuffix names the root-only trust marker next to the tracking file.
	PermanentBansTrustSuffix = ".trust"
	trustMarkerContent       = "nftban tracking trust boundary v1237\n"
)

var (
	// trackingOwnerUID is the uid that must own the tracking file, the marker and every parent (root).
	trackingOwnerUID = 0
	// trackingChainTop is where the parent walk ends (inclusive). Production: "/" (the whole chain).
	trackingChainTop = "/"
)

// SetTrackingIntegrityForTest sets the required owner uid and the top of the parent walk (tests run
// unprivileged under a temp dir). Test-only: production code never calls it.
func SetTrackingIntegrityForTest(ownerUID int, chainTop string) (restore func()) {
	oldU, oldT := trackingOwnerUID, trackingChainTop
	trackingOwnerUID, trackingChainTop = ownerUID, filepath.Clean(chainTop)
	return func() { trackingOwnerUID, trackingChainTop = oldU, oldT }
}

// ErrTrackingUntrusted: the tracking state is not under the required ownership boundary, or the
// records written before that boundary existed have not been sanitized yet.
var ErrTrackingUntrusted = errors.New("permanent-ban tracking state is not trusted")

func trustMarkerPath() string { return permanentBansPath + PermanentBansTrustSuffix }

// CheckPermanentBansIntegrity verifies the ownership boundary only: the tracking file (when present)
// is a regular non-symlink owned by the required uid without group/other write, and EVERY parent up
// to / is owned by that uid or root without group/other write (a writable parent can replace the
// entry whatever the file's own mode).
func CheckPermanentBansIntegrity() error {
	p := permanentBansPath
	fi, err := os.Lstat(p)
	if err != nil {
		if os.IsNotExist(err) {
			return checkParents(firstExistingAncestor(filepath.Dir(p)))
		}
		return err
	}
	if err := regularOwnedNotWritable(p, fi); err != nil {
		return err
	}
	return checkParents(filepath.Dir(p))
}

func firstExistingAncestor(d string) string {
	for {
		if _, err := os.Lstat(d); err == nil || d == trackingChainTop || d == filepath.Dir(d) {
			return d
		}
		d = filepath.Dir(d)
	}
}

func regularOwnedNotWritable(p string, fi os.FileInfo) error {
	if fi.Mode()&os.ModeSymlink != 0 || !fi.Mode().IsRegular() {
		return fmt.Errorf("%w: %s is not a regular file", ErrTrackingUntrusted, p)
	}
	return ownedNotWritable(p, fi)
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

// trustMarkerValid: the marker exists, is a regular non-symlink owned by the required uid, has no
// group/other access at all, and carries the expected content. A marker the service account planted
// while state/ was writable is owned by it (the permission repair never re-owns the marker), so it
// is not valid.
func trustMarkerValid() bool {
	m := trustMarkerPath()
	fi, err := os.Lstat(m)
	if err != nil || regularOwnedNotWritable(m, fi) != nil || fi.Mode().Perm()&0o077 != 0 {
		return false
	}
	b, err := os.ReadFile(m) // #nosec G304 -- fixed path next to the tracking file, ownership checked above
	return err == nil && string(b) == trustMarkerContent
}

// EstablishTrackingTrust runs by root under the shared reason-file locks (daemon start). Precondition:
// the ownership boundary holds (CheckPermanentBansIntegrity). If the trust marker is already valid it
// does nothing. Otherwise every record present NOW was written while state/ could be modified by the
// service account, so it is sanitized: age_source cleared (legacy-age-unverified -> never eligible),
// cleanup_pending kept but flagged unverified (reported, never finished); ip, added_at, reason, source
// and protected are kept. Then the file is saved root-owned and the marker written root:root 0600.
// Idempotent: a second call is a no-op.
func EstablishTrackingTrust() (kept int, err error) {
	if err := os.MkdirAll(filepath.Dir(permanentBansPath), 0750); err != nil { // exists in production (tmpfiles)
		return 0, err
	}
	if err := CheckPermanentBansIntegrity(); err != nil {
		return 0, err
	}
	if trustMarkerValid() {
		return 0, nil
	}
	st, err := LoadPermanentBans()
	if err != nil {
		return 0, err
	}
	cleared, flagged := 0, 0
	for _, b := range st.Bans {
		if b == nil {
			continue
		}
		if b.AgeSource != "" {
			b.AgeSource = ""
			cleared++
		}
		if b.CleanupPending != "" && !b.CleanupPendingUnverified {
			b.CleanupPendingUnverified = true
			flagged++
		}
	}
	if _, statErr := os.Lstat(permanentBansPath); statErr == nil {
		if err := SavePermanentBans(st); err != nil {
			return 0, err
		}
	}
	m := trustMarkerPath()
	_ = os.Remove(m) // an invalid marker (e.g. planted while state/ was writable) is replaced, never trusted
	if err := SafeWriteFile(m, []byte(trustMarkerContent), 0600); err != nil {
		return 0, err
	}
	if os.Geteuid() == 0 {
		_ = os.Lchown(m, 0, 0)
	}
	log.Printf("[TRACKING] trust boundary established: %d record(s) kept (age_source cleared on %d -> legacy, %d pending marker(s) kept as unverified)",
		len(st.Bans), cleared, flagged)
	return len(st.Bans), nil
}

// LoadPermanentBansForCleanup is the ONLY load cleanup decisions use: ownership boundary and trust
// marker first, fail closed.
func LoadPermanentBansForCleanup() (*PermanentBansState, error) {
	if err := CheckPermanentBansIntegrity(); err != nil {
		return nil, err
	}
	if !trustMarkerValid() {
		return nil, fmt.Errorf("%w: records written before the root-owned state boundary are not sanitized yet (nftband establishes this at start)", ErrTrackingUntrusted)
	}
	return LoadPermanentBans()
}

// setTrackingOwnership puts the written tracking file at root:nftban (fhs-spec) when running as root.
// In place: the inode does not change.
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
