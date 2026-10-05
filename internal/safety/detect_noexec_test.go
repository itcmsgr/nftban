// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package safety

import (
	"encoding/binary"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// v1.235 BUG-SAFETY-ADMIN-IP-DETECTION-EXECS-WHO-W-IP-DENIED-AT-STARTUP:
// the anti-lockout detection must read utmp and procfs in-process (no exec of
// who/w/ip, which SELinux enforcing denies in the daemon domain), and an
// unreadable source must be an error, never an empty success.

func utmpRecord(typ int16, host string, addr []byte) []byte {
	r := make([]byte, utmpRecordSize)
	binary.LittleEndian.PutUint16(r[utmpTypeOff:], uint16(typ))
	copy(r[utmpHostOff:utmpHostOff+utmpHostLen], host)
	copy(r[utmpAddrOff:utmpAddrOff+16], addr)
	return r
}

func writeFile(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestUtmpRemoteIPs(t *testing.T) {
	dir := t.TempDir()
	var data []byte
	data = append(data, utmpRecord(2, "", nil)...)                                      // BOOT_TIME: ignored
	data = append(data, utmpRecord(utmpUserProcess, "203.0.113.7", []byte{203, 0, 113, 7})...) // v4 in addr
	data = append(data, utmpRecord(utmpUserProcess, "2001:db8::5", nil)...)             // host text only
	data = append(data, utmpRecord(utmpUserProcess, ":0", nil)...)                      // local X: no IP
	data = append(data, utmpRecord(8, "198.51.100.9", []byte{198, 51, 100, 9})...)      // DEAD_PROCESS: ignored
	old := utmpPaths
	defer func() { utmpPaths = old }()
	utmpPaths = []string{filepath.Join(dir, "absent"), writeFile(t, dir, "utmp", data)}

	ips, err := utmpRemoteIPs()
	if err != nil {
		t.Fatalf("readable utmp returned error: %v", err)
	}
	want := []string{"203.0.113.7", "2001:db8::5"}
	if len(ips) != len(want) {
		t.Fatalf("got %v, want %v", ips, want)
	}
	for i, w := range want {
		if !ips[i].Equal(net.ParseIP(w)) {
			t.Fatalf("ip[%d] = %v, want %v", i, ips[i], w)
		}
	}
}

func TestUtmpUnreadableIsAnError(t *testing.T) {
	old := utmpPaths
	defer func() { utmpPaths = old }()
	utmpPaths = []string{filepath.Join(t.TempDir(), "absent")}
	ips, err := utmpRemoteIPs()
	if err == nil {
		t.Fatalf("unreadable utmp must be an error, got ips=%v", ips)
	}
}

func TestProcDefaultGateways(t *testing.T) {
	dir := t.TempDir()
	// default via 192.0.2.1 (0x010200C0 little-endian), flags 0003; plus a
	// connected (non-default) route that must be ignored.
	v4 := "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" +
		"eth0\t00000000\t010200C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n" +
		"eth0\t000200C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n"
	v6 := "00000000000000000000000000000000 00 00000000000000000000000000000000 00 20010db8000000000000000000000001 00000400 00000001 00000000 00000003 eth0\n" +
		"20010db8000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001 eth0\n"
	oldV4, oldV6 := procRoutePath, procRoute6
	defer func() { procRoutePath, procRoute6 = oldV4, oldV6 }()
	procRoutePath = writeFile(t, dir, "route", []byte(v4))
	procRoute6 = writeFile(t, dir, "ipv6_route", []byte(v6))

	gws, err := procDefaultGateways()
	if err != nil {
		t.Fatalf("readable route tables returned error: %v", err)
	}
	if len(gws) != 2 || !gws[0].Equal(net.ParseIP("192.0.2.1")) || !gws[1].Equal(net.ParseIP("2001:db8::1")) {
		t.Fatalf("gateways = %v, want [192.0.2.1 2001:db8::1]", gws)
	}

	procRoutePath = filepath.Join(dir, "absent4")
	procRoute6 = filepath.Join(dir, "absent6")
	if gws, err := procDefaultGateways(); err == nil {
		t.Fatalf("unreadable route tables must be an error, got %v", gws)
	}
}

// The package must not exec the tools SELinux denies. Read the real sources
// (not a list in this test) so a re-added exec fails here.
func TestDetectionDoesNotExecWhoWIp(t *testing.T) {
	for _, f := range []string{"detect.go", "detect_noexec.go"} {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		for _, bad := range []string{`Command("who"`, `Command("w"`, `Command("ip"`} {
			if strings.Contains(string(src), bad) {
				t.Errorf("%s still execs %s", f, bad)
			}
		}
	}
}
