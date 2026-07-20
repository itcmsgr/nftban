// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-loadconf"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Reads the operator override authority /etc/nftban/conf.d/logs.conf (shell KEY=\"value\" convention) into the Overrides model. An absent file means fully automatic (safe default). Only uncommented keys are treated as overrides. Malformed numeric values and out-of-contract values FAIL (via Overrides.Validate) — they are never silently ignored. The generated logrotate file is NOT read as config; this file is the sole operator authority."
// meta:depends="os,strconv"
// meta:inventory.files="internal/logretention/loadconf.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="etc/nftban/conf.d/logs.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// DefaultConfPath is the operator override authority for log retention.
const DefaultConfPath = "/etc/nftban/conf.d/logs.conf"

// LoadOverrides reads logs.conf into an Overrides. An absent file yields the
// zero value (fully automatic). Present-but-uncommented keys become overrides.
// The result is validated; invalid values return an error (no silent fallback).
func LoadOverrides(path string) (Overrides, error) {
	var o Overrides
	data, err := os.ReadFile(path) // #nosec G304 -- operator config path (conf.d/logs.conf), fixed by DefaultConfPath
	if err != nil {
		if os.IsNotExist(err) {
			return o, nil
		}
		return o, fmt.Errorf("logretention: read %s: %w", path, err)
	}
	kv := parseShellConf(string(data))

	o.Mode = kv["LOG_RETENTION_MODE"]
	o.Profile = kv["LOG_RETENTION_PROFILE"]

	if v := kv["LOG_RETENTION_MAX_PERCENT"]; v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return o, fmt.Errorf("logretention: invalid LOG_RETENTION_MAX_PERCENT %q: %w", v, err)
		}
		o.MaxPercent = n
	}
	if v := kv["LOG_RETENTION_MIN_DAYS"]; v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return o, fmt.Errorf("logretention: invalid LOG_RETENTION_MIN_DAYS %q: %w", v, err)
		}
		o.MinDays = n
	}
	if v := kv["LOG_RETENTION_MAX_DAYS"]; v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return o, fmt.Errorf("logretention: invalid LOG_RETENTION_MAX_DAYS %q: %w", v, err)
		}
		o.MaxDays = n
	}
	if v := kv["LOG_RETENTION_MAX_BYTES"]; v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return o, fmt.Errorf("logretention: invalid LOG_RETENTION_MAX_BYTES %q (want bytes): %w", v, err)
		}
		o.MaxBytes = n
	}

	if err := o.Validate(); err != nil {
		return o, err
	}
	return o, nil
}

// parseShellConf extracts uncommented KEY=value pairs from shell-style config,
// stripping surrounding single/double quotes. Only UPPER_SNAKE keys are read.
func parseShellConf(s string) map[string]string {
	out := map[string]string{}
	for _, raw := range strings.Split(s, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		if !isUpperSnake(key) {
			continue
		}
		val := strings.TrimSpace(line[eq+1:])
		// strip a trailing inline comment only when the value is unquoted
		if len(val) > 0 && val[0] != '"' && val[0] != '\'' {
			if h := strings.IndexByte(val, '#'); h >= 0 {
				val = strings.TrimSpace(val[:h])
			}
		}
		val = strings.Trim(val, "\"'")
		out[key] = val
	}
	return out
}

func isUpperSnake(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !(r == '_' || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return s[0] == '_' || (s[0] >= 'A' && s[0] <= 'Z')
}
