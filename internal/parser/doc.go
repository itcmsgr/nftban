// =============================================================================
// NFTBan - Parser Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="parser"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-16"
// meta:description="Security fuzz tests for parsing functions"
//
// Package parser contains fuzz tests for security-critical parsing functions
// in NFTBan. This package does not export any functions; it exists solely
// to house fuzz tests that exercise parsing code from other packages.
//
// Covered Parsing Functions:
//
// 1. Log Line Parsing (pkg/loginmon/detector/):
//   - SSH authentication failures
//   - Mail server auth failures (Dovecot, Postfix, Exim)
//   - FTP auth failures (Pure-FTPd, vsftpd, ProFTPD)
//   - Control panel auth failures (DirectAdmin, cPanel, Plesk)
//
// 2. Feed/Config Parsing (pkg/feeds/, pkg/netutil/):
//   - IP address parsing and validation
//   - CIDR notation parsing
//   - Feed file line parsing (IPs with comments, whitespace)
//
// 3. Utility Parsing (pkg/util/, pkg/timeutil/):
//   - Boolean string parsing
//   - Integer/float parsing
//   - Duration parsing with day/week support
//
// Running Fuzz Tests:
//
// Run all fuzz tests for 30 seconds each:
//
//	go test -fuzz=. -fuzztime=30s ./pkg/parser/
//
// Run a specific fuzz test:
//
//	go test -fuzz=FuzzParseLogLine -fuzztime=60s ./pkg/parser/
//
// Run with coverage:
//
//	go test -fuzz=FuzzParseLogLine -fuzztime=30s -coverprofile=fuzz.out ./pkg/parser/
//
// meta:inventory.files="doc.go,fuzz_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package parser
