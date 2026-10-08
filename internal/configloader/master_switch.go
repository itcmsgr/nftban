// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package configloader

import (
	"os"
	"path/filepath"
	"strings"
)

// SwitchState is the ONE meaning of NFTBAN_ENABLED (owner K2, 2026-10-08), shared by every
// reader: shell (lib/service_control.sh, helpers/nftban-boot-early.sh), the Go installer and
// nftban-core. The cases live in scripts/ci/data/master-switch-cases.tsv and are asserted by
// the shell and the Go tests alike.
type SwitchState string

const (
	SwitchOn      SwitchState = "on"      // true / yes / 1 / on (any case)
	SwitchOff     SwitchState = "off"     // false / no / 0 / off (any case)
	SwitchInvalid SwitchState = "invalid" // any other DECLARED value, including empty
)

// ParseSwitch maps one declared value (the text after "NFTBAN_ENABLED="). A quoted value is the
// text up to its matching quote (a trailing comment after it is ignored; an unterminated quote
// is INVALID); an unquoted value ends at " #" or "\t#". Surrounding whitespace is not part of it.
func ParseSwitch(raw string) SwitchState {
	v := strings.TrimSpace(raw)
	if len(v) > 0 && (v[0] == '"' || v[0] == '\'') {
		end := strings.IndexByte(v[1:], v[0])
		if end < 0 {
			return SwitchInvalid
		}
		v = v[1 : 1+end]
	} else if i := strings.IndexAny(v, " \t"); i >= 0 && strings.HasPrefix(strings.TrimSpace(v[i:]), "#") {
		v = v[:i]
	}
	v = strings.TrimSpace(v)
	switch strings.ToLower(v) {
	case "true", "yes", "1", "on":
		return SwitchOn
	case "false", "no", "0", "off":
		return SwitchOff
	}
	return SwitchInvalid
}

// MasterSwitch reads NFTBAN_ENABLED from <configDir>/conf.d/services.conf then
// services.conf.local (last declaration wins), the same files in the same order as the shell
// authority. An ABSENT key keeps the documented default (on). known=false when an existing
// file could not be read. raw/file name the offending declaration when the state is invalid.
func MasterSwitch(configDir string) (state SwitchState, raw, file string, known bool) {
	state, known = SwitchOn, true
	for _, name := range []string{"services.conf", "services.conf.local"} {
		p := filepath.Join(configDir, "conf.d", name)
		data, err := os.ReadFile(p) // #nosec G304 -- fixed NFTBan config path
		if err != nil {
			if !os.IsNotExist(err) {
				known = false
			}
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "NFTBAN_ENABLED=") {
				continue
			}
			raw = strings.TrimPrefix(line, "NFTBAN_ENABLED=")
			file = p
			state = ParseSwitch(raw)
		}
	}
	return state, raw, file, known
}
