// =============================================================================
// NFTBan v1.79.2 - distroconf INI parser (BUG-15)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: distroconf
// Purpose: Minimal stdlib-only INI parser for distro config files.
//
// meta:name="loginmon_distroconf_ini"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="distroconf"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Minimal INI parser for /etc/nftban/distros/*.conf (BUG-15)"
//
// meta:inventory.files="ini.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Package distroconf parses NFTBan distro configuration files (/etc/nftban/distros/*.conf).
//
// This file implements a minimal INI parser sufficient for the NFTBan distro
// config format. It does NOT depend on any external library; stdlib only.
//
// Format:
//   [section]
//   key = value
//   # comment
//   ; comment
//
// Supported features (intentionally narrow):
//   - section headers: [name]
//   - key-value pairs: key = value (whitespace around = is trimmed)
//   - line comments: lines starting with # or ;
//   - inline comments: NOT supported (values may legitimately contain # or ;)
//
// Not supported (deliberate):
//   - quoted values
//   - multi-line values
//   - section nesting
//   - key references / interpolation
package distroconf

import (
	"bufio"
	"fmt"
	"io"
	"strings"
)

// iniFile is the parsed representation: section -> key -> value.
type iniFile map[string]map[string]string

// parseINI reads an INI stream and returns the parsed map.
// Returns an error only on I/O failure or section/key syntax violation.
func parseINI(r io.Reader) (iniFile, error) {
	out := make(iniFile)
	current := ""
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if line[0] == '#' || line[0] == ';' {
			continue
		}
		if line[0] == '[' {
			if line[len(line)-1] != ']' {
				return nil, fmt.Errorf("line %d: malformed section header: %q", lineNo, line)
			}
			current = strings.TrimSpace(line[1 : len(line)-1])
			if current == "" {
				return nil, fmt.Errorf("line %d: empty section name", lineNo)
			}
			if _, exists := out[current]; !exists {
				out[current] = make(map[string]string)
			}
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			return nil, fmt.Errorf("line %d: expected key=value, got %q", lineNo, line)
		}
		if current == "" {
			return nil, fmt.Errorf("line %d: key=value outside any section", lineNo)
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		if key == "" {
			return nil, fmt.Errorf("line %d: empty key", lineNo)
		}
		out[current][key] = val
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scanner: %w", err)
	}
	return out, nil
}
