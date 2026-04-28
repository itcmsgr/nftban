// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-26-code-C — CSF/LFD cron-backup manifest
// =============================================================================
// meta:name="installer-switchop-cron-manifest"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Shared CSF/LFD cron-backup manifest types + sha256 helper. The writer (disarmCSFArtifacts) records the two cron files (/etc/cron.d/csf-cron, /etc/cron.d/lfd-cron) before removing them at install-time; the reader (restore_deps_csf.go A.4) verifies sha256 + restores from the manifest. Per Amendment 1 §33 E.5 + §51.6, the writer MUST land before any A.4 restore code reads the manifest; both ship in the same PR-26-code-C commit pair."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/logging"
// meta:inventory.files="/var/lib/nftban/state/csf-cron-backup/manifest.json,/var/lib/nftban/state/csf-cron-backup/csf-cron,/var/lib/nftban/state/csf-cron-backup/lfd-cron"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/cron.d/csf-cron,/etc/cron.d/lfd-cron"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package switchop

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// =============================================================================
// Constants — paths and schema
// =============================================================================

const (
	// CronManifestSchemaVersion is the on-disk schema version of the
	// manifest. Reader rejects manifests whose schema_version field
	// does not match this constant exactly. Bumping this constant is
	// a contract event (treat as Amendment-1 §31 A.4 evolution).
	CronManifestSchemaVersion = "1.0.0"

	// CronManifestDir is the on-disk directory the manifest writer
	// stores backups + manifest.json under. Hardcoded by §42.2 lock.
	CronManifestDir = "/var/lib/nftban/state/csf-cron-backup"

	// CronManifestFile is the absolute path of the manifest JSON
	// file (CronManifestDir + "/manifest.json").
	CronManifestFile = "/var/lib/nftban/state/csf-cron-backup/manifest.json"

	// Backup file names within CronManifestDir. The reader resolves
	// each ManifestEntry's BackupName relative to CronManifestDir.
	cronBackupCSFName = "csf-cron"
	cronBackupLFDName = "lfd-cron"

	// CronCSFSrcPath / CronLFDSrcPath are the canonical /etc/cron.d
	// source paths the writer backs up and the reader restores to.
	// Hardcoded by §42.2 lock — only these two cron files are
	// backed up; never any other /etc/cron.d/* entry.
	CronCSFSrcPath = "/etc/cron.d/csf-cron"
	CronLFDSrcPath = "/etc/cron.d/lfd-cron"
)

// =============================================================================
// Types
// =============================================================================

// CronManifestEntry records one backed-up cron file.
type CronManifestEntry struct {
	Path       string `json:"path"`        // absolute /etc/cron.d/<name>
	BackupName string `json:"backup_name"` // basename within CronManifestDir
	SHA256     string `json:"sha256"`      // hex sha256 of the backed-up content
	Mode       uint32 `json:"mode"`        // os.FileMode-compatible permission bits
	UID        int    `json:"uid"`
	GID        int    `json:"gid"`
	Size       int64  `json:"size"`
}

// CronManifest is the manifest.json on-disk shape.
type CronManifest struct {
	SchemaVersion string              `json:"schema_version"`
	CapturedAt    time.Time           `json:"captured_at"`
	Files         []CronManifestEntry `json:"files"`
}

// =============================================================================
// Sentinel errors — typed for both writer and reader paths
// =============================================================================

var (
	// ErrCronManifestSchemaMismatch is returned by the reader when
	// manifest.json parses but its schema_version does not match
	// CronManifestSchemaVersion exactly.
	ErrCronManifestSchemaMismatch = errors.New("cron manifest: schema_version mismatch")

	// ErrCronManifestSHA256Mismatch is returned by the reader when
	// a manifest entry's recorded sha256 does not match the actual
	// sha256 of the on-disk backup file. Indicates corruption or
	// tampering — restore MUST refuse this entry.
	ErrCronManifestSHA256Mismatch = errors.New("cron manifest: sha256 mismatch — backup file does not match manifest entry")

	// ErrCronManifestUnknownEntry is returned when the manifest lists
	// a Path that is not one of the two §42.2-locked cron source
	// paths (/etc/cron.d/csf-cron or /etc/cron.d/lfd-cron). Defensive
	// guard; readers MUST refuse unknown entries.
	ErrCronManifestUnknownEntry = errors.New("cron manifest: entry path is not in the §42.2 locked set {csf-cron, lfd-cron}")

	// ErrCronManifestParseFailed is returned by the reader when
	// manifest.json cannot be parsed as JSON. Distinct from a
	// missing manifest (ReadCronBackupManifest returns ok=false in
	// that case, no error).
	ErrCronManifestParseFailed = errors.New("cron manifest: failed to parse manifest.json")
)

// =============================================================================
// SHA256 helper — shared by writer + reader so the integrity check
// uses identical bytes-to-hex semantics in both directions.
// =============================================================================

// ComputeCronBackupSHA256 returns the lowercase-hex sha256 of the
// given content. Used by the writer to record the manifest entry
// and by the reader to verify the on-disk backup file's integrity
// before A.4 restoration.
func ComputeCronBackupSHA256(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

// =============================================================================
// Writer — install-time backup capture
// =============================================================================

// WriteCronBackupManifest captures the two §42.2-locked cron files
// (CronCSFSrcPath, CronLFDSrcPath) before they are removed at
// install-time. For each file that exists:
//
//   - Reads content via exec.ReadFile.
//   - Reads metadata via exec.Stat (mode/uid/gid/size).
//   - Computes sha256.
//   - Writes the content to CronManifestDir/<backup-name> via
//     exec.WriteFileAtomic.
//
// Then writes manifest.json containing exactly the entries that were
// backed up. Entries for files that did not exist at capture time
// are NOT included in the manifest.
//
// Returns the manifest that was written, plus an error if any
// step failed. The caller (disarmCSFArtifacts) MAY proceed with the
// rm even if manifest writing fails — the rm is the install-time
// invariant; the manifest is best-effort fidelity. But on success
// the caller should log the manifest path so the operator can
// observe it.
//
// MUST be called BEFORE the cron files are removed; otherwise the
// content read returns os.ErrNotExist and the entry is skipped.
func WriteCronBackupManifest(exec executor.Executor, log *logging.Logger) (CronManifest, error) {
	if exec == nil {
		return CronManifest{}, errors.New("cron manifest writer: nil executor")
	}

	if err := exec.MkdirAll(CronManifestDir, 0755); err != nil {
		return CronManifest{}, fmt.Errorf("cron manifest writer: mkdir %s: %w", CronManifestDir, err)
	}

	type pair struct{ src, name string }
	pairs := []pair{
		{CronCSFSrcPath, cronBackupCSFName},
		{CronLFDSrcPath, cronBackupLFDName},
	}

	manifest := CronManifest{
		SchemaVersion: CronManifestSchemaVersion,
		CapturedAt:    time.Now().UTC(),
		Files:         make([]CronManifestEntry, 0, len(pairs)),
	}

	for _, p := range pairs {
		if !exec.FileExists(p.src) {
			if log != nil {
				log.Info("cron manifest writer: %s absent — no entry recorded (graceful skip)", p.src)
			}
			continue
		}

		content, err := exec.ReadFile(p.src)
		if err != nil {
			if log != nil {
				log.Warn("cron manifest writer: ReadFile(%s) failed: %v", p.src, err)
			}
			continue
		}

		meta, err := exec.Stat(p.src)
		if err != nil {
			if log != nil {
				log.Warn("cron manifest writer: Stat(%s) failed: %v", p.src, err)
			}
			continue
		}

		entry := CronManifestEntry{
			Path:       p.src,
			BackupName: p.name,
			SHA256:     ComputeCronBackupSHA256(content),
			Mode:       uint32(meta.Mode.Perm()),
			UID:        meta.UID,
			GID:        meta.GID,
			Size:       meta.Size,
		}

		backupAbs := CronManifestDir + "/" + p.name
		if err := exec.WriteFileAtomic(backupAbs, content, meta.Mode.Perm()); err != nil {
			if log != nil {
				log.Warn("cron manifest writer: WriteFileAtomic(%s) failed: %v", backupAbs, err)
			}
			continue
		}

		manifest.Files = append(manifest.Files, entry)
		if log != nil {
			log.Info("cron manifest writer: backed up %s -> %s (sha256=%s, mode=%o, uid=%d, gid=%d, size=%d)",
				p.src, backupAbs, entry.SHA256, entry.Mode, entry.UID, entry.GID, entry.Size)
		}
	}

	body, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return manifest, fmt.Errorf("cron manifest writer: json marshal: %w", err)
	}
	body = append(body, '\n')
	if err := exec.WriteFileAtomic(CronManifestFile, body, 0644); err != nil {
		return manifest, fmt.Errorf("cron manifest writer: WriteFileAtomic(%s): %w", CronManifestFile, err)
	}
	if log != nil {
		log.Info("cron manifest writer: wrote %s (%d entries)", CronManifestFile, len(manifest.Files))
	}
	return manifest, nil
}

// =============================================================================
// Reader — restore-time manifest read + integrity check
// =============================================================================

// ReadCronBackupManifest returns the parsed manifest if present and
// schema-valid. Three return shapes:
//
//   - Manifest absent (no manifest.json at CronManifestFile): returns
//     (zero, false, nil). Caller (A.4 step) treats this as the
//     graceful soft-skip case for pre-PR-26 hosts.
//   - Manifest present but corrupt (parse failure or schema mismatch):
//     returns (zero, true, ErrCronManifestParseFailed or
//     ErrCronManifestSchemaMismatch). Caller refuses A.4.
//   - Manifest present and parseable: returns (manifest, true, nil).
//     Caller still verifies per-entry sha256 against on-disk backups
//     before restoring.
//
// Per-entry integrity is the caller's responsibility (use
// ComputeCronBackupSHA256 + compare to entry.SHA256). The reader
// here only validates the manifest structure.
func ReadCronBackupManifest(exec executor.Executor, log *logging.Logger) (CronManifest, bool, error) {
	if exec == nil {
		return CronManifest{}, false, errors.New("cron manifest reader: nil executor")
	}

	if !exec.FileExists(CronManifestFile) {
		if log != nil {
			log.Info("cron manifest reader: %s absent — pre-PR-26 host, graceful skip", CronManifestFile)
		}
		return CronManifest{}, false, nil
	}

	body, err := exec.ReadFile(CronManifestFile)
	if err != nil {
		return CronManifest{}, true, fmt.Errorf("%w: ReadFile: %v", ErrCronManifestParseFailed, err)
	}

	var manifest CronManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return CronManifest{}, true, fmt.Errorf("%w: %v", ErrCronManifestParseFailed, err)
	}

	if manifest.SchemaVersion != CronManifestSchemaVersion {
		return CronManifest{}, true, fmt.Errorf("%w: got %q, want %q",
			ErrCronManifestSchemaMismatch, manifest.SchemaVersion, CronManifestSchemaVersion)
	}

	for _, entry := range manifest.Files {
		if entry.Path != CronCSFSrcPath && entry.Path != CronLFDSrcPath {
			return CronManifest{}, true, fmt.Errorf("%w: %q", ErrCronManifestUnknownEntry, entry.Path)
		}
	}

	return manifest, true, nil
}

// VerifyCronBackupEntry reads the on-disk backup for entry and
// compares its sha256 to the manifest record. Returns
// ErrCronManifestSHA256Mismatch on mismatch. Reads via the executor
// abstraction.
func VerifyCronBackupEntry(exec executor.Executor, entry CronManifestEntry) ([]byte, error) {
	if exec == nil {
		return nil, errors.New("cron manifest verifier: nil executor")
	}
	backupAbs := CronManifestDir + "/" + entry.BackupName
	content, err := exec.ReadFile(backupAbs)
	if err != nil {
		return nil, fmt.Errorf("cron manifest verifier: ReadFile(%s): %w", backupAbs, err)
	}
	got := ComputeCronBackupSHA256(content)
	if got != entry.SHA256 {
		return nil, fmt.Errorf("%w: %s: got %s, want %s",
			ErrCronManifestSHA256Mismatch, backupAbs, got, entry.SHA256)
	}
	return content, nil
}
