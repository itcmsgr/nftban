// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="privilege"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Privilege and capability checks for nftables operations"
// meta:input="None"
// meta:output="Boolean privilege status"
// meta:depends="go"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="cap_net_admin"

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// CAP_NET_ADMIN is capability to perform various network operations
const CAP_NET_ADMIN = 12

// hasNetAdminCapability checks if the current process has CAP_NET_ADMIN
func hasNetAdminCapability() bool {
	// Use capget syscall to check effective capabilities
	// This works on Linux only

	type capHeader struct {
		version uint32
		pid     int32
	}

	type capData struct {
		effective   uint32
		permitted   uint32
		inheritable uint32
	}

	// Version 3 header for Linux 2.6.25+
	const LINUX_CAPABILITY_VERSION_3 = 0x20080522

	hdr := capHeader{
		version: LINUX_CAPABILITY_VERSION_3,
		pid:     0, // 0 = current process
	}

	// We need 2 capData structs for 64 capabilities
	data := [2]capData{}

	// SYS_CAPGET = 125 on amd64
	_, _, errno := syscall.Syscall(
		syscall.SYS_CAPGET,
		uintptr(unsafe.Pointer(&hdr)),
		uintptr(unsafe.Pointer(&data[0])),
		0,
	)

	if errno != 0 {
		return false
	}

	// CAP_NET_ADMIN is capability 12, which is in the first 32 bits
	capBit := uint32(1 << CAP_NET_ADMIN)
	return (data[0].effective & capBit) != 0
}

// checkPrivilege verifies the process has sufficient privileges for nftables operations.
// Returns nil if privileged (root OR CAP_NET_ADMIN), error otherwise.
func checkPrivilege() error {
	// Method 1: Running as root
	if os.Geteuid() == 0 {
		return nil
	}

	// Method 2: Has CAP_NET_ADMIN capability
	if hasNetAdminCapability() {
		return nil
	}

	return fmt.Errorf("must run as root or with CAP_NET_ADMIN capability (setcap 'cap_net_admin+ep' on binary)")
}
