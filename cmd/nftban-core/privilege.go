package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// =============================================================================
// NFTBan Privilege Check
// =============================================================================
// Purpose: Check for sufficient privileges to manipulate nftables
//
// Two ways to have privilege:
// 1. Running as root (euid == 0)
// 2. Having CAP_NET_ADMIN capability set on the binary
//
// The second method allows nftban-ui (running as user nftban) to call
// nftban-core without sudo, because:
//   setcap 'cap_net_admin+ep' /usr/lib/nftban/bin/nftban-core
// =============================================================================

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
