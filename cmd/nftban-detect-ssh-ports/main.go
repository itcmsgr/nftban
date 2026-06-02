// =============================================================================
// NFTBan v1.145 - SSH Port Union Detector Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-detect-ssh-ports"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-02"
// meta:description="Prints the conservative union of all detected SSH listener/config ports, one per line, for runtime/timer consumption (PR-B)"
// meta:inventory.files="cmd/nftban-detect-ssh-ports/main.go"
// meta:inventory.binaries="nftban-detect-ssh-ports"
// meta:inventory.env_vars="SSH_CLIENT"
// meta:inventory.config_files="/etc/ssh/sshd_config,/etc/nftban/nftban.conf.local"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Usage:
//
//	nftban-detect-ssh-ports        # one sorted-unique SSH port per line on stdout
//	nftban-detect-ssh-ports --help # usage
//
// Exit codes:
//
//	0 = at least one valid SSH port detected (printed to stdout)
//	1 = no SSH port detected from any source
//
// v1.145 PR-B: this is the single Go detector authority shared by the installer
// and the runtime/timer shell paths (via cli/lib/nftban/lib/ssh_port_detect.sh),
// so scalar `head -1` parsers cannot reintroduce drift. Sources unioned:
// `ss` listeners (IPv4/IPv6/dual-stack), sshd_config `Port` + `ListenAddress`
// (host:port and [ipv6]:port, plus drop-ins), the install state file, and
// conf.local SSH_PORT. The union is conservative (over-broad across address
// families, applied to both ip/ip6 sets) and lockout-safe: it never drops a
// real listener port. ZERO-SIDE-EFFECT: reads only; never writes files or nft.
package main

import (
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func main() {
	for _, a := range os.Args[1:] {
		switch a {
		case "-h", "--help", "help":
			fmt.Fprintln(os.Stderr, "nftban-detect-ssh-ports — print the conservative union of all detected SSH ports, one per line.")
			fmt.Fprintln(os.Stderr, "Sources: ss listeners, sshd_config Port + ListenAddress (+drop-ins), state file, conf.local SSH_PORT.")
			fmt.Fprintln(os.Stderr, "Exit: 0 if >=1 port (printed to stdout), 1 if none.")
			os.Exit(0)
		}
	}

	exec := &executor.RealExecutor{}
	// Quiet logger: detection diagnostics go to /dev/null so stdout carries
	// only the port list for the shell wrapper to consume.
	log := logging.New("/dev/null", false)
	defer log.Close()

	ports := detect.DetectSSHPortsUnion(exec, log)
	if len(ports) == 0 {
		fmt.Fprintln(os.Stderr, "nftban-detect-ssh-ports: no SSH port detected from any source (ss, sshd_config, state, conf.local)")
		os.Exit(1)
	}
	for _, p := range ports {
		fmt.Println(p)
	}
}
