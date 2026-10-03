// =============================================================================
// NFTBan v1.73 - Installer Authority File Write
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-validate-authority"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Write /var/lib/nftban/state/authority and .firewall_authority"
// meta:inventory.files="internal/installer/validate/authority.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package validate

import (
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/immutable"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// WriteAuthorityFiles records the authority decision to state files.
// Two locations for compatibility:
//   - /var/lib/nftban/state/authority         (primary, read by Go daemon)
//   - /etc/nftban/.firewall_authority         (legacy, read by CLI scripts)
func WriteAuthorityFiles(exec executor.Executor, decision authority.Decision, log *logging.Logger) {
	content := []byte(string(decision) + "\n")

	// Primary authority file
	if err := exec.WriteFileAtomic(fhs.AuthorityFile, content, 0644); err != nil {
		log.Warn("write authority file %s: %v", fhs.AuthorityFile, err)
	} else {
		log.Debug("wrote authority=%s to %s", decision, fhs.AuthorityFile)
	}

	// Legacy authority file
	const legacyPath = "/etc/nftban/.firewall_authority"
	legacyContent := []byte("nftban\n")
	if err := exec.WriteFileAtomic(legacyPath, legacyContent, 0644); err != nil {
		log.Warn("write legacy authority %s: %v", legacyPath, err)
	} else {
		log.Debug("wrote firewall_authority=nftban to %s", legacyPath)
	}
}

// ImmutableOwnedRecord / installerLogPath: see internal/installer/immutable.
const ImmutableOwnedRecord = immutable.RecordPath

const installerLogPath = immutable.InstallerLogPath

// SetImmutableFlags applies NFTBan's +i policy to its security-critical files
// (G8 parity) and RECORDS each flag it sets, so later removal or restoration can
// be limited to flags NFTBan provably owns (PR #1439 acceptance 1).
//
//   - file without +i            -> chattr +i, record "locked" (inode, ctime, now)
//   - file with +i, ownership proven (record entry for this inode+ctime in state
//     "locked", or the pre-v1.234 installer.log proof) -> keep / adopt into record
//   - file with +i, ownership NOT proven -> administrator-owned: left exactly as
//     is and not recorded (NFTBan will never remove it)
func SetImmutableFlags(exec executor.Executor, log *logging.Logger) {
	if !exec.CommandExists("chattr") || !exec.CommandExists("lsattr") {
		log.Debug("chattr/lsattr not available — skipping immutable flags")
		return
	}

	immutableFiles := []string{
		fhs.MainConf,
		"/usr/lib/nftban/lib/nft_schema.sh",
	}

	prev := immutable.ReadRecord(exec)
	var lines []string
	now := strconv.FormatInt(time.Now().Unix(), 10)
	for _, path := range immutableFiles {
		if !exec.FileExists(path) {
			continue
		}
		has, measured := immutable.HasImmutable(exec, path)
		if !measured {
			log.Warn("immutable flag on %s UNMEASURED (lsattr failed) — not set, not recorded", path)
			continue
		}
		if has {
			ino, ct, ok := immutable.InoCtime(exec, path)
			if !ok {
				continue
			}
			e, inRec := prev[path]
			switch {
			case inRec && e.State == "locked" && e.Ino == ino && e.Ctime == ct:
				lines = append(lines, strings.Join([]string{path, ino, ct, "locked", e.At}, "\t"))
			case !inRec && immutable.LegacyLogProves(exec, path, ct):
				lines = append(lines, strings.Join([]string{path, ino, ct, "locked", now}, "\t"))
				log.Debug("adopted pre-v1.234 NFTBan immutable flag into the ownership record: %s", path)
			default:
				log.Warn("immutable flag on %s was not set by NFTBan (no ownership proof) — left as is, not recorded", path)
			}
			continue
		}
		res := exec.Run("chattr", "+i", path)
		if res.ExitCode != 0 {
			log.Warn("chattr +i %s failed (exit %d) — non-fatal", path, res.ExitCode)
			continue
		}
		log.Debug("set immutable: %s", path)
		if ino, ct, ok := immutable.InoCtime(exec, path); ok {
			lines = append(lines, strings.Join([]string{path, ino, ct, "locked", now}, "\t"))
		}
	}
	content := "# NFTBan-owned immutable flags (nftban-installer): path, inode, ctime, state, written_at (TAB-separated)\n"
	if len(lines) > 0 {
		content += strings.Join(lines, "\n") + "\n"
	}
	if err := exec.WriteFileAtomic(ImmutableOwnedRecord, []byte(content), 0644); err != nil {
		log.Warn("write %s: %v", ImmutableOwnedRecord, err)
	}
}

// RunPermissionsEnforce calls `nftban permissions enforce` for full FHS fix (G10 parity).
func RunPermissionsEnforce(exec executor.Executor, log *logging.Logger) {
	res := exec.RunTimeout(30*time.Second, fhs.NftbanCLI, "permissions", "enforce")
	if res.ExitCode == 0 {
		log.Debug("permissions enforce completed")
	} else {
		log.Warn("permissions enforce failed (exit %d) — non-fatal", res.ExitCode)
	}
}
