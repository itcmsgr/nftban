// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-26-code-C — cron manifest tests
// =============================================================================
// meta:name="installer-switchop-cron-manifest-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Unit tests for the CSF/LFD cron-backup manifest writer + reader. Verifies the §42.2 locked invariants: only the two cron files are backed up; sha256 + mode + uid + gid + size are recorded; manifest is rejected on schema mismatch / parse failure / unknown-entry / sha256 mismatch."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/executor"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package switchop

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// =============================================================================
// Helpers
// =============================================================================

func newWriterTestLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "test.log"), false)
}

func seedCronFile(mock *executor.MockExecutor, path, content string, mode uint32, uid, gid int) {
	mock.Files[path] = []byte(content)
	mock.FileStats[path] = executor.FileMeta{
		Mode: 0644,
		UID:  uid,
		GID:  gid,
		Size: int64(len(content)),
	}
	if mode != 0 {
		mock.FileStats[path] = executor.FileMeta{
			Mode: 0644,
			UID:  uid,
			GID:  gid,
			Size: int64(len(content)),
		}
	}
}

// =============================================================================
// Writer tests
// =============================================================================

func TestWriteCronBackupManifest_BothPresent_RecordsBoth(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedCronFile(mock, CronCSFSrcPath, "0 0 * * * root /usr/sbin/csf -r\n", 0644, 0, 0)
	seedCronFile(mock, CronLFDSrcPath, "0 0 * * * root /usr/sbin/csf --lfd restart\n", 0644, 0, 0)

	manifest, err := WriteCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if len(manifest.Files) != 2 {
		t.Errorf("entries = %d; want 2", len(manifest.Files))
	}
	if manifest.SchemaVersion != CronManifestSchemaVersion {
		t.Errorf("schema_version = %q; want %q", manifest.SchemaVersion, CronManifestSchemaVersion)
	}
	for _, e := range manifest.Files {
		if e.Path != CronCSFSrcPath && e.Path != CronLFDSrcPath {
			t.Errorf("manifest entry has unauthorized Path %q", e.Path)
		}
		if e.SHA256 == "" {
			t.Errorf("entry %s has empty SHA256", e.Path)
		}
		if e.Size == 0 {
			t.Errorf("entry %s has zero Size", e.Path)
		}
	}
}

func TestWriteCronBackupManifest_OnlyOnePresent_OnlyOneRecorded(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedCronFile(mock, CronCSFSrcPath, "csf body\n", 0644, 0, 0)
	// LFD intentionally absent.

	manifest, err := WriteCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if len(manifest.Files) != 1 {
		t.Errorf("entries = %d; want 1", len(manifest.Files))
	}
	if manifest.Files[0].Path != CronCSFSrcPath {
		t.Errorf("entry path = %q; want %q", manifest.Files[0].Path, CronCSFSrcPath)
	}
}

func TestWriteCronBackupManifest_NeitherPresent_EmptyManifest(t *testing.T) {
	mock := executor.NewMockExecutor()

	manifest, err := WriteCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Fatalf("err = %v; want nil (writer is graceful)", err)
	}
	if len(manifest.Files) != 0 {
		t.Errorf("entries = %d; want 0 (no cron files present)", len(manifest.Files))
	}
}

func TestWriteCronBackupManifest_WritesOnlyManifestDir(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedCronFile(mock, CronCSFSrcPath, "csf body\n", 0644, 0, 0)
	seedCronFile(mock, CronLFDSrcPath, "lfd body\n", 0644, 0, 0)

	_, _ = WriteCronBackupManifest(mock, newWriterTestLogger(t))

	for path := range mock.WrittenFiles {
		if !strings.HasPrefix(path, CronManifestDir) {
			t.Errorf("writer wrote outside CronManifestDir: %s", path)
		}
	}
}

func TestWriteCronBackupManifest_ManifestPathPinnedExact(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedCronFile(mock, CronCSFSrcPath, "x", 0644, 0, 0)

	_, _ = WriteCronBackupManifest(mock, newWriterTestLogger(t))

	if _, ok := mock.WrittenFiles[CronManifestFile]; !ok {
		t.Errorf("manifest file %s not written; got %v", CronManifestFile, keysOf(mock.WrittenFiles))
	}
}

func TestWriteCronBackupManifest_OnlyAuthorizedSrcPaths(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Seed a cron file at an UNAUTHORIZED path; writer must NOT
	// pick it up.
	mock.Files["/etc/cron.d/some-other-cron"] = []byte("evil")
	mock.FileStats["/etc/cron.d/some-other-cron"] = executor.FileMeta{Mode: 0644, Size: 4}

	manifest, _ := WriteCronBackupManifest(mock, newWriterTestLogger(t))

	for _, e := range manifest.Files {
		if e.Path != CronCSFSrcPath && e.Path != CronLFDSrcPath {
			t.Errorf("writer recorded unauthorized path: %s", e.Path)
		}
	}
}

func TestWriteCronBackupManifest_SHA256ComputedCorrectly(t *testing.T) {
	mock := executor.NewMockExecutor()
	content := "0 0 * * * root /usr/sbin/csf -r\n"
	seedCronFile(mock, CronCSFSrcPath, content, 0644, 0, 0)

	manifest, _ := WriteCronBackupManifest(mock, newWriterTestLogger(t))
	if len(manifest.Files) != 1 {
		t.Fatalf("entries = %d; want 1", len(manifest.Files))
	}
	want := ComputeCronBackupSHA256([]byte(content))
	if manifest.Files[0].SHA256 != want {
		t.Errorf("recorded sha256 = %q; want %q", manifest.Files[0].SHA256, want)
	}
}

// =============================================================================
// Reader tests
// =============================================================================

func TestReadCronBackupManifest_AbsentReturnsFalse(t *testing.T) {
	mock := executor.NewMockExecutor()

	_, present, err := ReadCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Errorf("err = %v; want nil (absent = soft-skip)", err)
	}
	if present {
		t.Errorf("present = true; want false")
	}
}

func TestReadCronBackupManifest_ParseFailure(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files[CronManifestFile] = []byte("{{{ not json")

	_, present, err := ReadCronBackupManifest(mock, newWriterTestLogger(t))
	if !present {
		t.Errorf("present = false; want true (file exists but corrupt)")
	}
	if !errors.Is(err, ErrCronManifestParseFailed) {
		t.Errorf("err = %v; want ErrCronManifestParseFailed", err)
	}
}

func TestReadCronBackupManifest_SchemaMismatch(t *testing.T) {
	mock := executor.NewMockExecutor()
	body, _ := json.Marshal(CronManifest{
		SchemaVersion: "0.0.1-old",
		Files:         []CronManifestEntry{},
	})
	mock.Files[CronManifestFile] = body

	_, present, err := ReadCronBackupManifest(mock, newWriterTestLogger(t))
	if !present {
		t.Errorf("present = false; want true")
	}
	if !errors.Is(err, ErrCronManifestSchemaMismatch) {
		t.Errorf("err = %v; want ErrCronManifestSchemaMismatch", err)
	}
}

func TestReadCronBackupManifest_UnknownEntryPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	body, _ := json.Marshal(CronManifest{
		SchemaVersion: CronManifestSchemaVersion,
		Files: []CronManifestEntry{
			{Path: "/etc/cron.d/some-other-cron", BackupName: "x", SHA256: "y", Size: 1},
		},
	})
	mock.Files[CronManifestFile] = body

	_, present, err := ReadCronBackupManifest(mock, newWriterTestLogger(t))
	if !present {
		t.Errorf("present = false; want true")
	}
	if !errors.Is(err, ErrCronManifestUnknownEntry) {
		t.Errorf("err = %v; want ErrCronManifestUnknownEntry", err)
	}
}

func TestReadCronBackupManifest_HappyPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	want := CronManifest{
		SchemaVersion: CronManifestSchemaVersion,
		Files: []CronManifestEntry{
			{Path: CronCSFSrcPath, BackupName: "csf-cron", SHA256: "abc", Mode: 0644, Size: 10},
		},
	}
	body, _ := json.Marshal(want)
	mock.Files[CronManifestFile] = body

	got, present, err := ReadCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if !present {
		t.Errorf("present = false; want true")
	}
	if got.SchemaVersion != want.SchemaVersion || len(got.Files) != 1 {
		t.Errorf("got = %+v; want %+v", got, want)
	}
}

// =============================================================================
// Round-trip tests
// =============================================================================

func TestCronManifest_WriteThenRead_Roundtrip(t *testing.T) {
	mock := executor.NewMockExecutor()
	csfContent := "0 0 * * * root /usr/sbin/csf -r\n"
	lfdContent := "0 0 * * * root /usr/sbin/csf --lfd restart\n"
	seedCronFile(mock, CronCSFSrcPath, csfContent, 0644, 0, 0)
	seedCronFile(mock, CronLFDSrcPath, lfdContent, 0644, 0, 0)

	written, err := WriteCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Fatalf("write err = %v", err)
	}

	read, present, err := ReadCronBackupManifest(mock, newWriterTestLogger(t))
	if err != nil {
		t.Fatalf("read err = %v", err)
	}
	if !present {
		t.Fatalf("present = false")
	}
	if len(read.Files) != len(written.Files) {
		t.Errorf("entry count mismatch: read=%d wrote=%d", len(read.Files), len(written.Files))
	}
	for i, e := range read.Files {
		if e.SHA256 != written.Files[i].SHA256 {
			t.Errorf("entry %d sha256 drift: read=%q wrote=%q", i, e.SHA256, written.Files[i].SHA256)
		}
	}
}

// =============================================================================
// SHA256 verification tests
// =============================================================================

func TestVerifyCronBackupEntry_HappyPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	content := "csf body\n"
	mock.Files[CronManifestDir+"/csf-cron"] = []byte(content)

	entry := CronManifestEntry{
		Path:       CronCSFSrcPath,
		BackupName: "csf-cron",
		SHA256:     ComputeCronBackupSHA256([]byte(content)),
	}
	got, err := VerifyCronBackupEntry(mock, entry)
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if string(got) != content {
		t.Errorf("content drift")
	}
}

func TestVerifyCronBackupEntry_SHA256Mismatch(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files[CronManifestDir+"/csf-cron"] = []byte("tampered")

	entry := CronManifestEntry{
		Path:       CronCSFSrcPath,
		BackupName: "csf-cron",
		SHA256:     ComputeCronBackupSHA256([]byte("original")),
	}
	_, err := VerifyCronBackupEntry(mock, entry)
	if !errors.Is(err, ErrCronManifestSHA256Mismatch) {
		t.Errorf("err = %v; want ErrCronManifestSHA256Mismatch", err)
	}
}

// =============================================================================
// Helper utilities
// =============================================================================

func keysOf(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
