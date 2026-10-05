// =============================================================================
// NFTBan - System IP Detection without exec (v1.235)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="detect_noexec"
// meta:type="package"
// meta:version="1.235.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-06"
// meta:description="In-process readers for the anti-lockout detection: logged-in remote users from utmp, default gateways from /proc/net/route and /proc/net/ipv6_route. Replaces exec of who/w/ip, which SELinux enforcing denies in the daemon domain (BUG-SAFETY-ADMIN-IP-DETECTION-EXECS-WHO-W-IP-DENIED-AT-STARTUP, lab3 Rocky 10 enforcing). The sources are the same files those tools read, so a denial now surfaces as an explicit read error instead of an AVC on exec."
// meta:input="/run/utmp, /proc/net/route, /proc/net/ipv6_route"
// meta:output="remote user IPs, gateway IPs"
// meta:depends="encoding/binary,net,os"
// meta:inventory.files="/run/utmp,/var/run/utmp,/proc/net/route,/proc/net/ipv6_route"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

// Paths are variables so tests can point them at fixtures.
var (
	utmpPaths     = []string{"/run/utmp", "/var/run/utmp"}
	procRoutePath = "/proc/net/route"
	procRoute6    = "/proc/net/ipv6_route"
)

// glibc struct utmp on Linux (x86_64 and aarch64 share it: ut_tv is two int32
// for 32/64-bit compatibility). 384 bytes per record.
const (
	utmpRecordSize  = 384
	utmpTypeOff     = 0   // int16 ut_type (+2 pad)
	utmpHostOff     = 76  // char ut_host[256]
	utmpHostLen     = 256
	utmpAddrOff     = 348 // int32 ut_addr_v6[4]
	utmpUserProcess = 7   // USER_PROCESS
)

// utmpRemoteIPs returns the remote address of every USER_PROCESS record
// (newest last). ut_addr_v6 is preferred; ut_host is used when it holds a
// literal IP. An unreadable utmp is an error, never an empty success.
func utmpRemoteIPs() ([]net.IP, error) {
	var lastErr error
	for _, p := range utmpPaths {
		data, err := os.ReadFile(p)
		if err != nil {
			lastErr = err
			continue
		}
		return parseUtmp(data), nil
	}
	if lastErr == nil {
		lastErr = errors.New("no utmp path configured")
	}
	return nil, fmt.Errorf("utmp unreadable: %w", lastErr)
}

func parseUtmp(data []byte) []net.IP {
	var ips []net.IP
	for off := 0; off+utmpRecordSize <= len(data); off += utmpRecordSize {
		rec := data[off : off+utmpRecordSize]
		if int16(binary.LittleEndian.Uint16(rec[utmpTypeOff:])) != utmpUserProcess {
			continue
		}
		if ip := utmpAddr(rec[utmpAddrOff : utmpAddrOff+16]); ip != nil {
			ips = append(ips, ip)
			continue
		}
		host := rec[utmpHostOff : utmpHostOff+utmpHostLen]
		if i := strings.IndexByte(string(host), 0); i >= 0 {
			host = host[:i]
		}
		if ip := net.ParseIP(strings.TrimSpace(string(host))); ip != nil && !ip.IsLoopback() {
			ips = append(ips, ip)
		}
	}
	return ips
}

// utmpAddr decodes ut_addr_v6 (network byte order). IPv4 is stored in the
// first word with the other three zero.
func utmpAddr(b []byte) net.IP {
	allZero := true
	for _, c := range b {
		if c != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return nil
	}
	var ip net.IP
	if b[4] == 0 && b[5] == 0 && b[6] == 0 && b[7] == 0 &&
		b[8] == 0 && b[9] == 0 && b[10] == 0 && b[11] == 0 &&
		b[12] == 0 && b[13] == 0 && b[14] == 0 && b[15] == 0 {
		ip = net.IPv4(b[0], b[1], b[2], b[3])
	} else {
		ip = make(net.IP, 16)
		copy(ip, b)
	}
	if ip.IsLoopback() || ip.IsUnspecified() {
		return nil
	}
	return ip
}

// procDefaultGateways reads the IPv4 and IPv6 default routes from procfs.
// Returns an error only when NEITHER table can be read.
func procDefaultGateways() ([]net.IP, error) {
	v4, err4 := readProcRouteV4(procRoutePath)
	v6, err6 := readProcRouteV6(procRoute6)
	if err4 != nil && err6 != nil {
		return nil, fmt.Errorf("route tables unreadable: %v; %v", err4, err6)
	}
	return append(v4, v6...), nil
}

// /proc/net/route: Iface Destination Gateway Flags ... (hex, host byte order
// = little-endian on the supported architectures). Default route: Destination
// 00000000 and Mask 00000000, RTF_GATEWAY (0x2) set.
func readProcRouteV4(path string) ([]net.IP, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var ips []net.IP
	for i, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if i == 0 || len(f) < 8 || f[1] != "00000000" || f[7] != "00000000" {
			continue
		}
		flags, err := strconv.ParseUint(f[3], 16, 32)
		if err != nil || flags&0x2 == 0 { // RTF_GATEWAY
			continue
		}
		gw, err := hex.DecodeString(f[2])
		if err != nil || len(gw) != 4 {
			continue
		}
		ip := net.IPv4(gw[3], gw[2], gw[1], gw[0])
		if !ip.IsUnspecified() {
			ips = append(ips, ip)
		}
	}
	return ips, nil
}

// /proc/net/ipv6_route: dest destlen src srclen nexthop metric refcnt use flags iface
// (32-hex-digit addresses, network order). Default route: dest all-zero, destlen 00.
func readProcRouteV6(path string) ([]net.IP, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var ips []net.IP
	seen := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 10 || f[1] != "00" || strings.Trim(f[0], "0") != "" {
			continue
		}
		nh, err := hex.DecodeString(f[4])
		if err != nil || len(nh) != 16 {
			continue
		}
		ip := net.IP(nh)
		if ip.IsUnspecified() || seen[ip.String()] {
			continue
		}
		seen[ip.String()] = true
		ips = append(ips, ip)
	}
	return ips, nil
}
