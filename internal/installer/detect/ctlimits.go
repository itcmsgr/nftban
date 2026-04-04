// =============================================================================
// NFTBan v1.73 - Installer CT Limits Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-ctlimits"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="DDoS connection tracking limit reads from config"
// meta:inventory.files="internal/installer/detect/ctlimits.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/ddos/classic.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// CTLimits holds DDoS connection tracking limits used in nftables template rendering.
type CTLimits struct {
	SSH  int // DDOS_CLASSIC_SSH_CONN_LIMIT, default 15
	HTTP int // DDOS_CLASSIC_HTTP_CONN_LIMIT, default 200
	Mail int // DDOS_CLASSIC_SMTP_CONN_LIMIT, default 30
}

const (
	ddosConfPath      = "/etc/nftban/conf.d/ddos/classic.conf"
	ddosConfLocalPath = "/etc/nftban/conf.d/ddos/classic.conf.local"
)

// DefaultCTLimits returns the defaults matching the shell %post.
func DefaultCTLimits() CTLimits {
	return CTLimits{SSH: 15, HTTP: 200, Mail: 30}
}

// ReadCTLimits reads DDoS connection tracking limits from config files.
// Reads classic.conf first, then classic.conf.local as override.
// Returns defaults for any value not found.
func ReadCTLimits(exec executor.Executor, log *logging.Logger) CTLimits {
	limits := DefaultCTLimits()

	// Read main config, then local override
	for _, path := range []string{ddosConfPath, ddosConfLocalPath} {
		data, err := exec.ReadFile(path)
		if err != nil {
			continue
		}
		parseCTLimitsFile(string(data), &limits)
	}

	log.Detect("ctlimits", "ssh", strconv.Itoa(limits.SSH))
	log.Detect("ctlimits", "http", strconv.Itoa(limits.HTTP))
	log.Detect("ctlimits", "mail", strconv.Itoa(limits.Mail))

	return limits
}

// parseCTLimitsFile extracts CT limit values from a shell-style config file.
// Format: KEY="value" or KEY=value (one per line).
func parseCTLimitsFile(content string, limits *CTLimits) {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		key := line[:idx]
		val := strings.Trim(line[idx+1:], "\"' ")

		n, err := strconv.Atoi(val)
		if err != nil || n <= 0 {
			continue
		}

		switch key {
		case "DDOS_CLASSIC_SSH_CONN_LIMIT":
			limits.SSH = n
		case "DDOS_CLASSIC_HTTP_CONN_LIMIT":
			limits.HTTP = n
		case "DDOS_CLASSIC_SMTP_CONN_LIMIT":
			limits.Mail = n
		}
	}
}
