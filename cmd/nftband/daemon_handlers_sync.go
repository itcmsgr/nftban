// =============================================================================
// NFTBan v1.0 - nftband Daemon - Feed, whitelist, and geoban sync handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Feed, whitelist, and geoban sync handlers"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"os"
	goruntime "runtime"
	"strings"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/geoban"
	"github.com/itcmsgr/nftban/internal/metrics"
	"github.com/itcmsgr/nftban/internal/opqueue"
	"github.com/itcmsgr/nftban/internal/ports"
	"github.com/itcmsgr/nftban/internal/runtime"
	"github.com/itcmsgr/nftban/internal/safety"
	nftsync "github.com/itcmsgr/nftban/internal/setsync"
)

// handleSyncRequest performs a full differential sync of whitelists/blacklists
// If params["quick"]=true, skips feeds and geoban loading (for fast postinst sync)
func (d *Daemon) handleSyncRequest(params map[string]any) SocketResponse {
	// Prevent concurrent sync operations from racing
	syncMutex.Lock()
	defer syncMutex.Unlock()

	// Check for quick mode (skips feeds/geoban for fast postinst sync)
	quickMode := false
	if params != nil {
		if q, ok := params["quick"].(bool); ok && q {
			quickMode = true
		}
	}

	_, configDir, _, _ := getDaemonPaths()

	// Initialize RuntimeState
	state := runtime.NewRuntimeState(configDir)

	if err := state.LoadWhitelists(); err != nil {
		return SocketResponse{Success: false, Error: "failed to load whitelists: " + err.Error()}
	}

	if err := state.LoadBlacklists(); err != nil {
		return SocketResponse{Success: false, Error: "failed to load blacklists: " + err.Error()}
	}

	// Load ports from ALL sources
	allPorts, err := ports.LoadAllPorts(configDir)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to load ports: " + err.Error()}
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Get or create tables
	tableIPv4, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create IPv4 table: " + err.Error()}
	}

	tableIPv6, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create IPv6 table: " + err.Error()}
	}

	// Create sets
	whitelistIPv4Set, err := nft.GetOrCreateIntervalSet(tableIPv4, "whitelist_ipv4", true)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create whitelist_ipv4 set: " + err.Error()}
	}

	whitelistIPv6Set, err := nft.GetOrCreateIntervalSet(tableIPv6, "whitelist_ipv6", false)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create whitelist_ipv6 set: " + err.Error()}
	}

	blacklistIPv4Set, err := nft.GetOrCreateSet(tableIPv4, "blacklist_ipv4", true)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create blacklist_ipv4 set: " + err.Error()}
	}

	blacklistIPv6Set, err := nft.GetOrCreateSet(tableIPv6, "blacklist_ipv6", false)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create blacklist_ipv6 set: " + err.Error()}
	}

	// Create and populate port sets if we have ports
	if len(allPorts.AllRules) > 0 {
		// Directional port sets (v2.1 schema - NO legacy sets)
		tcpInSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "tcp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_in set: " + err.Error()}
		}
		tcpInSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "tcp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_in set: " + err.Error()}
		}
		tcpOutSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "tcp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_out set: " + err.Error()}
		}
		tcpOutSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "tcp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_out set: " + err.Error()}
		}
		udpInSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "udp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_in set: " + err.Error()}
		}
		udpInSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "udp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_in set: " + err.Error()}
		}
		udpOutSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "udp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_out set: " + err.Error()}
		}
		udpOutSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "udp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_out set: " + err.Error()}
		}

		// Load directional port sets
		if len(allPorts.TCPPortsIn) > 0 {
			if err := nft.AddPortElements(tcpInSetV4, allPorts.TCPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 TCP input ports: " + err.Error()}
			}
			if err := nft.AddPortElements(tcpInSetV6, allPorts.TCPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 TCP input ports: " + err.Error()}
			}
		}
		if len(allPorts.TCPPortsOut) > 0 {
			if err := nft.AddPortElements(tcpOutSetV4, allPorts.TCPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 TCP output ports: " + err.Error()}
			}
			if err := nft.AddPortElements(tcpOutSetV6, allPorts.TCPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 TCP output ports: " + err.Error()}
			}
		}
		if len(allPorts.UDPPortsIn) > 0 {
			if err := nft.AddPortElements(udpInSetV4, allPorts.UDPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 UDP input ports: " + err.Error()}
			}
			if err := nft.AddPortElements(udpInSetV6, allPorts.UDPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 UDP input ports: " + err.Error()}
			}
		}
		if len(allPorts.UDPPortsOut) > 0 {
			if err := nft.AddPortElements(udpOutSetV4, allPorts.UDPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 UDP output ports: " + err.Error()}
			}
			if err := nft.AddPortElements(udpOutSetV6, allPorts.UDPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 UDP output ports: " + err.Error()}
			}
		}
	}

	// Get snapshots from runtime state
	whitelistIPv4, whitelistIPv6 := state.GetWhitelistSnapshot()
	blacklistIPv4, blacklistIPv6 := state.GetBlacklistSnapshot()

	// Perform full sync
	result, err := nftsync.FullSync(
		nft,
		whitelistIPv4Set, whitelistIPv6Set,
		blacklistIPv4Set, blacklistIPv6Set,
		whitelistIPv4, whitelistIPv6,
		blacklistIPv4, blacklistIPv6,
	)

	if err != nil {
		return SocketResponse{Success: false, Error: "sync failed: " + err.Error()}
	}

	// Update counters
	state.IncrementSyncCounter(result.Success)

	// ==========================================================================
	// FEEDS LOADING - Load threat feeds into blacklist sets if enabled
	// Skip in quick mode (postinst sync) to avoid 3-5 minute delay
	// ==========================================================================
	var feedsIPv4Loaded, feedsIPv6Loaded int
	var feedsSkipped, geobanSkipped bool
	var feedsCIDRCount, geobanCIDRCount int
	var feedsMemNeeded, geobanMemNeeded int64
	if !quickMode {
		// Check memory pressure before loading feeds
		if safety.ShouldSkipFeeds() {
			log.Printf("[SYNC] Memory pressure %s: skipping feeds", safety.GetMemoryPressureLevel())
			feedsSkipped = true
		} else {
		_, _, dataDir, _ := getDaemonPaths()
		feedsDir := dataDir + "/feeds"

		// Check if feeds directory exists and has .txt files
		if entries, err := os.ReadDir(feedsDir); err == nil && len(entries) > 0 {
		// Load all feeds
		ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, _, feedErr := feeds.LoadAllFeeds(feedsDir)
		if feedErr == nil {
			// Pre-allocate slices with exact capacity to avoid reallocation overhead
			// With 15,000+ CIDRs, this prevents ~14 slice doublings
			ipv4CIDRs := make([]string, 0, len(ipv4Set)+len(ipv4CIDRSet))
			ipv6CIDRs := make([]string, 0, len(ipv6Set)+len(ipv6CIDRSet))
			for ip := range ipv4Set {
				ipv4CIDRs = append(ipv4CIDRs, ip+"/32")
			}
			for cidr := range ipv4CIDRSet {
				ipv4CIDRs = append(ipv4CIDRs, cidr)
			}
			for ip := range ipv6Set {
				ipv6CIDRs = append(ipv6CIDRs, ip+"/128")
			}
			for cidr := range ipv6CIDRSet {
				ipv6CIDRs = append(ipv6CIDRs, cidr)
			}

			// v1.35.0: Global feed entry cap — reject feeds that would exceed limit
			const maxFeedEntries = 1_000_000 // Safety cap: 1M total CIDRs
			totalFeedCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
			if totalFeedCIDRs > maxFeedEntries {
				log.Printf("[SYNC] WARNING: Feed total %d exceeds cap %d — truncating to cap",
					totalFeedCIDRs, maxFeedEntries)
				if len(ipv4CIDRs) > maxFeedEntries {
					ipv4CIDRs = ipv4CIDRs[:maxFeedEntries]
				}
				remaining := maxFeedEntries - len(ipv4CIDRs)
				if len(ipv6CIDRs) > remaining {
					ipv6CIDRs = ipv6CIDRs[:remaining]
				}
				totalFeedCIDRs = len(ipv4CIDRs) + len(ipv6CIDRs)
			}

			// Memory safety check before loading feeds into nftables
			// CIDR merging can use 3x memory temporarily
			const bytesPerCIDR = 300 // conservative estimate
			estimatedFeedBytes := int64(totalFeedCIDRs) * bytesPerCIDR
			if !safety.CanAllocate(estimatedFeedBytes) {
				log.Printf("[SYNC] Warning: Skipping feeds - insufficient memory for %d CIDRs (need ~%s)",
					totalFeedCIDRs, safety.FormatBytes(estimatedFeedBytes))
				// Track protection trigger for visibility
				feedsSkipped = true
				feedsCIDRCount = totalFeedCIDRs
				feedsMemNeeded = estimatedFeedBytes
				// Skip feeds but continue with sync - don't fail entirely
			} else {
			// v2.1: Load feeds into unified blacklist_ipv4/ipv6 sets (CIDR aggregated)
			// All ban sources now use the same blacklist - daemon tracks source in DB
			if len(ipv4CIDRs) > 0 {
				feedSetV4, err := nft.GetOrCreateIntervalSet(tableIPv4, "blacklist_ipv4", true)
				if err != nil {
					log.Printf("[SYNC] Warning: Failed to get blacklist_ipv4 set: %v", err)
				} else {
					if stats, err := nft.AddCIDRElementsWithStats(feedSetV4, ipv4CIDRs); err != nil {
						log.Printf("[SYNC] Warning: Failed to load feeds IPv4: %v", err)
					} else if stats != nil {
						feedsIPv4Loaded = stats.OutputRanges
						log.Printf("[SYNC] Feeds IPv4: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
					}
				}
			}

			// Load IPv6 feeds into unified blacklist_ipv6 set
			if len(ipv6CIDRs) > 0 {
				feedSetV6, err := nft.GetOrCreateIntervalSet(tableIPv6, "blacklist_ipv6", false)
				if err != nil {
					log.Printf("[SYNC] Warning: Failed to get blacklist_ipv6 set: %v", err)
				} else {
					if stats, err := nft.AddCIDRElementsWithStats(feedSetV6, ipv6CIDRs); err != nil {
						log.Printf("[SYNC] Warning: Failed to load feeds IPv6: %v", err)
					} else if stats != nil {
						feedsIPv6Loaded = stats.OutputRanges
						log.Printf("[SYNC] Feeds IPv6: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
					}
				}
			}
			// Memory cleanup: clear CIDR slices after loading to nftables
			// These slices can hold 100-200MB that's no longer needed
			ipv4CIDRs = nil
			ipv6CIDRs = nil
			} // end else CanAllocate
			// Memory cleanup: clear feed maps to allow garbage collection
			// These maps can hold 400-800MB and are no longer needed after conversion
			ipv4Set = nil
			ipv6Set = nil
			ipv4CIDRSet = nil
			ipv6CIDRSet = nil
		}
		}
		} // end else ShouldSkipFeeds
	} // end if !quickMode (feeds)

	// ==========================================================================
	// GEOBAN LOADING - Load geoban CIDRs if any ban files exist
	// Skip in quick mode (postinst sync) to avoid 3-5 minute delay
	// ==========================================================================
	var geobanIPv4Loaded, geobanIPv6Loaded int
	if !quickMode {
		// Check memory pressure before loading geoban
		if safety.ShouldSkipGeoban() {
			log.Printf("[SYNC] Memory pressure %s: skipping geoban", safety.GetMemoryPressureLevel())
			geobanSkipped = true
		} else {
		geobanDir := configDir + "/geoban.d"

		// Check if geoban directory exists and has ban files (50-ban-*.conf)
		if entries, err := os.ReadDir(geobanDir); err == nil {
		hasBanFiles := false
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), "50-ban-") && strings.HasSuffix(e.Name(), ".conf") {
				hasBanFiles = true
				break
			}
		}

		if hasBanFiles {
			// Load all geoban countries
			geobanData, geoErr := geoban.Build(geobanDir, nil) // nil = load all
			if geoErr == nil && geobanData != nil {
				// Memory safety check before loading geoban into nftables
				// Geoban can have 20K+ CIDRs per country (CN, RU, etc.)
				const bytesPerCIDR = 300 // conservative estimate
				totalGeoCIDRs := len(geobanData.IPv4) + len(geobanData.IPv6)
				estimatedGeoBytes := int64(totalGeoCIDRs) * bytesPerCIDR
				if !safety.CanAllocate(estimatedGeoBytes) {
					log.Printf("[SYNC] Warning: Skipping geoban - insufficient memory for %d CIDRs (need ~%s)",
						totalGeoCIDRs, safety.FormatBytes(estimatedGeoBytes))
					// Track protection trigger for visibility
					geobanSkipped = true
					geobanCIDRCount = totalGeoCIDRs
					geobanMemNeeded = estimatedGeoBytes
					// Skip geoban but continue with sync - don't fail entirely
				} else {
				// v2.1: Load geoban CIDRs into unified blacklist_ipv4/ipv6 sets
				// All ban sources now use the same blacklist - CIDR aggregation prevents duplicates
				if len(geobanData.IPv4) > 0 {
					geoSetV4, err := nft.GetOrCreateIntervalSet(tableIPv4, "blacklist_ipv4", true)
					if err != nil {
						log.Printf("[SYNC] Warning: Failed to get blacklist_ipv4 set: %v", err)
					} else {
						if stats, err := nft.AddCIDRElementsWithStats(geoSetV4, geobanData.IPv4); err != nil {
							log.Printf("[SYNC] Warning: Failed to load geoban IPv4: %v", err)
						} else if stats != nil {
							geobanIPv4Loaded = stats.OutputRanges
							log.Printf("[SYNC] Geoban IPv4: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
						}
					}
				}

				// Load IPv6 geoban CIDRs into unified blacklist_ipv6 set
				if len(geobanData.IPv6) > 0 {
					geoSetV6, err := nft.GetOrCreateIntervalSet(tableIPv6, "blacklist_ipv6", false)
					if err != nil {
						log.Printf("[SYNC] Warning: Failed to get blacklist_ipv6 set: %v", err)
					} else {
						if stats, err := nft.AddCIDRElementsWithStats(geoSetV6, geobanData.IPv6); err != nil {
							log.Printf("[SYNC] Warning: Failed to load geoban IPv6: %v", err)
						} else if stats != nil {
							geobanIPv6Loaded = stats.OutputRanges
							log.Printf("[SYNC] Geoban IPv6: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
						}
					}
				}
				// Memory cleanup: clear geoban data to allow garbage collection
				// Geoban can hold 200-400MB that's no longer needed after loading
				geobanData.IPv4 = nil
				geobanData.IPv6 = nil
				geobanData = nil
				} // end else CanAllocate
			}
		}
		}
		} // end else ShouldSkipGeoban
	} // end if !quickMode (geoban)

	// Force garbage collection after large sync to release memory immediately
	// Without this, ~800MB-1.3GB can remain allocated until next GC cycle
	if !quickMode {
		goruntime.GC()
	}

	// ==========================================================================
	// PROTECTION STATE TRACKING
	// Record if feeds/geoban were skipped for visibility in health/CLI
	// ==========================================================================
	if feedsSkipped || geobanSkipped {
		if err := safety.RecordProtectionTriggered(feedsSkipped, geobanSkipped,
			feedsCIDRCount, geobanCIDRCount, feedsMemNeeded, geobanMemNeeded); err != nil {
			log.Printf("[SYNC] Warning: Failed to record protection state: %v", err)
		}
	} else if !quickMode {
		// Clear protection state if sync completed fully
		_ = safety.ClearProtectionState()
	}

	// v1.89 INV-M-008: Wire safety metrics → Prometheus gauges (call site 1 of 2).
	// These setters were defined in nftban.go but never called from sync.
	metrics.SetProtectionActive(feedsSkipped || geobanSkipped)
	metrics.SetProtectionFeedsSkipped(feedsSkipped)
	metrics.SetProtectionGeobanSkipped(geobanSkipped)
	metrics.SetMemoryPressureLevel(int(safety.GetMemoryPressureLevel()))

	// Build response with protection status
	respData := map[string]any{
		"whitelist_ipv4_added":   result.WhitelistIPv4.IPsAdded,
		"whitelist_ipv4_removed": result.WhitelistIPv4.IPsRemoved,
		"whitelist_ipv6_added":   result.WhitelistIPv6.IPsAdded,
		"whitelist_ipv6_removed": result.WhitelistIPv6.IPsRemoved,
		"blacklist_ipv4_added":   result.BlacklistIPv4.IPsAdded,
		"blacklist_ipv4_removed": result.BlacklistIPv4.IPsRemoved,
		"blacklist_ipv6_added":   result.BlacklistIPv6.IPsAdded,
		"blacklist_ipv6_removed": result.BlacklistIPv6.IPsRemoved,
		"feeds_ipv4_loaded":      feedsIPv4Loaded,
		"feeds_ipv6_loaded":      feedsIPv6Loaded,
		"geoban_ipv4_loaded":     geobanIPv4Loaded,
		"geoban_ipv6_loaded":     geobanIPv6Loaded,
		"tcp_ports_in":           len(allPorts.TCPPortsIn),
		"tcp_ports_out":          len(allPorts.TCPPortsOut),
		"udp_ports_in":           len(allPorts.UDPPortsIn),
		"udp_ports_out":          len(allPorts.UDPPortsOut),
		"pressure_level":         safety.GetMemoryPressureLevel().String(),
	}

	// Add protection status to response for CLI visibility
	if feedsSkipped || geobanSkipped {
		respData["protection_active"] = true
		respData["feeds_skipped"] = feedsSkipped
		respData["geoban_skipped"] = geobanSkipped
		if feedsSkipped {
			respData["feeds_skipped_count"] = feedsCIDRCount
		}
		if geobanSkipped {
			respData["geoban_skipped_count"] = geobanCIDRCount
		}
	}

	return SocketResponse{
		Success: result.Success,
		Data:    respData,
	}
}

// handleLoadCIDRsRequest loads CIDRs into a blacklist or whitelist set
func (d *Daemon) handleLoadCIDRsRequest(params map[string]any) SocketResponse {
	setType, _ := params["set_type"].(string) // "blacklist" or "whitelist"
	if setType == "" {
		setType = "blacklist"
	}

	// Memory safety pre-check: estimate memory needs before loading
	// Each CIDR in Go uses ~100 bytes for the string + parsing overhead
	// CIDR merging can temporarily 2-3x memory usage during sort/merge
	const bytesPerCIDREstimate = 300 // conservative estimate including merge overhead

	// Get CIDRs from params
	cidrsRaw, ok := params["cidrs"].([]any)
	if !ok || len(cidrsRaw) == 0 {
		// Try to load from feeds/trust directory
		_, _, dataDir, _ := getDaemonPaths()

		var ipv4CIDRs, ipv6CIDRs []string

		if setType == "blacklist" {
			// Load feeds
			feedsDir := dataDir + "/feeds"
			ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, _, err := feeds.LoadAllFeeds(feedsDir)
			if err != nil {
				return SocketResponse{Success: false, Error: "failed to load feeds: " + err.Error()}
			}

			// Pre-allocate slices with exact capacity to avoid reallocation overhead
			ipv4CIDRs = make([]string, 0, len(ipv4Set)+len(ipv4CIDRSet))
			ipv6CIDRs = make([]string, 0, len(ipv6Set)+len(ipv6CIDRSet))
			for ip := range ipv4Set {
				ipv4CIDRs = append(ipv4CIDRs, ip+"/32")
			}
			for cidr := range ipv4CIDRSet {
				ipv4CIDRs = append(ipv4CIDRs, cidr)
			}
			for ip := range ipv6Set {
				ipv6CIDRs = append(ipv6CIDRs, ip+"/128")
			}
			for cidr := range ipv6CIDRSet {
				ipv6CIDRs = append(ipv6CIDRs, cidr)
			}

			// Memory safety check before CIDR merging (which can 3x memory temporarily)
			totalCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
			estimatedBytes := int64(totalCIDRs) * bytesPerCIDREstimate
			if !safety.CanAllocate(estimatedBytes) {
				mem := safety.AvailableMem()
				return SocketResponse{
					Success: false,
					Error: fmt.Sprintf("insufficient memory for %d CIDRs: need ~%s, available %s",
						totalCIDRs, safety.FormatBytes(estimatedBytes), safety.FormatBytes(mem.Avail)),
				}
			}
		} else {
			// Load trust feeds
			trustDir := dataDir + "/trust"
			files, err := os.ReadDir(trustDir)
			if err != nil {
				return SocketResponse{Success: false, Error: "failed to read trust directory: " + err.Error()}
			}

			for _, file := range files {
				if file.IsDir() || !strings.HasSuffix(file.Name(), ".txt") {
					continue
				}

				content, err := os.ReadFile(trustDir + "/" + file.Name())
				if err != nil {
					continue
				}

				lines := strings.Split(string(content), "\n")
				for _, line := range lines {
					line = strings.TrimSpace(line)
					if line == "" || strings.HasPrefix(line, "#") {
						continue
					}

					if strings.Contains(line, ":") {
						// IPv6
						if !strings.Contains(line, "/") {
							line += "/128"
						}
						ipv6CIDRs = append(ipv6CIDRs, line)
					} else {
						// IPv4
						if !strings.Contains(line, "/") {
							line += "/32"
						}
						ipv4CIDRs = append(ipv4CIDRs, line)
					}
				}
			}

			// Memory safety check for trust feeds
			totalCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
			estimatedBytes := int64(totalCIDRs) * bytesPerCIDREstimate
			if !safety.CanAllocate(estimatedBytes) {
				mem := safety.AvailableMem()
				return SocketResponse{
					Success: false,
					Error: fmt.Sprintf("insufficient memory for %d trust CIDRs: need ~%s, available %s",
						totalCIDRs, safety.FormatBytes(estimatedBytes), safety.FormatBytes(mem.Avail)),
				}
			}
		}

		// Load into nftables
		return d.loadCIDRsIntoSets(setType, ipv4CIDRs, ipv6CIDRs)
	}

	// Parse CIDRs from params - pre-allocate to avoid repeated reallocations
	ipv4CIDRs := make([]string, 0, len(cidrsRaw))
	ipv6CIDRs := make([]string, 0, len(cidrsRaw)/10) // IPv6 typically much less common
	for _, cidrRaw := range cidrsRaw {
		cidr, ok := cidrRaw.(string)
		if !ok {
			continue
		}
		if strings.Contains(cidr, ":") {
			ipv6CIDRs = append(ipv6CIDRs, cidr)
		} else {
			ipv4CIDRs = append(ipv4CIDRs, cidr)
		}
	}

	// Memory safety check for direct CIDRs
	totalCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
	estimatedBytes := int64(totalCIDRs) * bytesPerCIDREstimate
	if !safety.CanAllocate(estimatedBytes) {
		mem := safety.AvailableMem()
		return SocketResponse{
			Success: false,
			Error: fmt.Sprintf("insufficient memory for %d CIDRs: need ~%s, available %s",
				totalCIDRs, safety.FormatBytes(estimatedBytes), safety.FormatBytes(mem.Avail)),
		}
	}

	return d.loadCIDRsIntoSets(setType, ipv4CIDRs, ipv6CIDRs)
}

// loadCIDRsIntoSets loads CIDRs into the appropriate nftables sets
func (d *Daemon) loadCIDRsIntoSets(setType string, ipv4CIDRs, ipv6CIDRs []string) SocketResponse {
	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Determine set names
	var setNameV4, setNameV6 string
	if setType == "whitelist" {
		setNameV4 = "whitelist_ipv4"
		setNameV6 = "whitelist_ipv6"
	} else {
		setNameV4 = "blacklist_ipv4"
		setNameV6 = "blacklist_ipv6"
	}

	var ipv4Stats, ipv6Stats *nftsync.MergeStats

	// Load IPv4 CIDRs
	if len(ipv4CIDRs) > 0 {
		tableIPv4, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
		}

		setIPv4, err := nft.GetOrCreateIntervalSet(tableIPv4, setNameV4, true)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get " + setNameV4 + " set: " + err.Error()}
		}

		stats, err := nft.AddCIDRElementsWithStats(setIPv4, ipv4CIDRs)
		if err != nil {
			// Check for overlap errors (not fatal)
			// Note: nftables kernel returns this as a string - no typed error available
			if !strings.Contains(err.Error(), "conflicting intervals") {
				return SocketResponse{Success: false, Error: "failed to load IPv4 CIDRs: " + err.Error()}
			}
		}
		ipv4Stats = stats
	}

	// Load IPv6 CIDRs
	if len(ipv6CIDRs) > 0 {
		tableIPv6, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
		}

		setIPv6, err := nft.GetOrCreateIntervalSet(tableIPv6, setNameV6, false)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get " + setNameV6 + " set: " + err.Error()}
		}

		stats, err := nft.AddCIDRElementsWithStats(setIPv6, ipv6CIDRs)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to load IPv6 CIDRs: " + err.Error()}
		}
		ipv6Stats = stats
	}

	// Build response data
	totalInput := len(ipv4CIDRs) + len(ipv6CIDRs)
	data := map[string]any{
		"set_type":    setType,
		"ipv4_input":  len(ipv4CIDRs),
		"ipv6_input":  len(ipv6CIDRs),
		"total_input": totalInput,
	}

	// BUG-008 FIX: Update CIDR metrics for Prometheus
	metrics.SetCIDRCurrentTotal(totalInput)

	if ipv4Stats != nil {
		data["ipv4_output_ranges"] = ipv4Stats.OutputRanges
		data["ipv4_reduction_pct"] = ipv4Stats.ReductionPct
	}
	if ipv6Stats != nil {
		data["ipv6_output_ranges"] = ipv6Stats.OutputRanges
		data["ipv6_reduction_pct"] = ipv6Stats.ReductionPct
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handleReplaceSetRequest handles bulk replace_set operations via file
// This is for feeds/geoban that need atomic flush+bulk-add
func (d *Daemon) handleReplaceSetRequest(params map[string]any) SocketResponse {
	if d.opQueue == nil {
		return SocketResponse{Success: false, Error: "OpQueue not initialized"}
	}

	setName, _ := params["set"].(string)
	filePath, _ := params["file"].(string)
	source, _ := params["source"].(string)
	deleteFile, _ := params["delete_file"].(bool)

	if setName == "" {
		return SocketResponse{Success: false, Error: "missing set parameter"}
	}
	if !validNFTBanSet(setName) {
		return SocketResponse{Success: false, Error: "invalid set: " + setName}
	}
	if filePath == "" {
		return SocketResponse{Success: false, Error: "missing file parameter"}
	}
	if source == "" {
		source = "unknown"
	}

	// Read elements from file with security checks
	result, err := opqueue.SecureReadElementsFile(filePath)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to read file: " + err.Error()}
	}

	// Queue the replace operation
	if err := d.opQueue.EnqueueReplace(setName, result.Elements, source); err != nil {
		return SocketResponse{Success: false, Error: "failed to queue replace: " + err.Error()}
	}

	// Optionally delete the file after reading
	if deleteFile {
		os.Remove(filePath)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"set":      setName,
			"source":   source,
			"elements": result.Count,
			"queued":   true,
		},
	}
}

// handleFlushSourceRequest removes all elements from a source
// Uses SourceIndex to find elements belonging to a source, then unbans them
// v1.18.1 FIX: Uses sourceIndex for ALL sources using shared blacklist_* sets
// to prevent coexistence bugs (feeds flush wiping geoban entries)
func (d *Daemon) handleFlushSourceRequest(params map[string]any) SocketResponse {
	if d.opQueue == nil || d.sourceIndex == nil {
		return SocketResponse{Success: false, Error: "OpQueue/SourceIndex not initialized"}
	}

	source, _ := params["source"].(string)
	if source == "" {
		return SocketResponse{Success: false, Error: "missing source parameter"}
	}

	// Get source configuration to determine target sets
	cfg, found := opqueue.GetSourceConfig(source)
	if !found {
		return SocketResponse{Success: false, Error: "unknown source: " + source}
	}

	// v1.18.1 FIX: Check if source uses shared blacklist sets
	// In unified blacklist architecture, feeds/geoban/manual all share blacklist_ipv4/ipv6
	// We must use sourceIndex-based removal to avoid wiping other sources' entries
	isSharedSet := cfg.IPv4Set == "blacklist_ipv4" || cfg.IPv6Set == "blacklist_ipv6"

	// Only use full flush for truly dedicated sets (not blacklist_*)
	if cfg.AllowBulk && !cfg.AllowBan && !isSharedSet {
		// Queue flush for dedicated IPv4 and IPv6 sets (e.g., feeds_ipv4, geoban_ipv4)
		if err := d.opQueue.EnqueueFlush(cfg.IPv4Set); err != nil {
			log.Printf("[FlushSource] Warning: failed to queue flush %s: %v", cfg.IPv4Set, err)
		}
		if err := d.opQueue.EnqueueFlush(cfg.IPv6Set); err != nil {
			log.Printf("[FlushSource] Warning: failed to queue flush %s: %v", cfg.IPv6Set, err)
		}

		return SocketResponse{
			Success: true,
			Data: map[string]any{
				"source": source,
				"sets":   []string{cfg.IPv4Set, cfg.IPv6Set},
				"action": "flush_set",
				"queued": true,
			},
		}
	}

	// For shared sets (blacklist_*), use source index to find and unban only this source's elements
	// This prevents feeds flush from wiping geoban/manual entries (coexistence bug fix)
	unbanned := 0
	for _, setName := range []string{cfg.IPv4Set, cfg.IPv6Set} {
		elements := d.sourceIndex.GetElementsBySource(setName, source)
		for _, elem := range elements {
			// Remove from source index
			d.sourceIndex.Remove(setName, elem, source)

			// Only unban if no other sources remain
			if d.sourceIndex.ShouldDelete(setName, elem) {
				if err := d.opQueue.EnqueueUnban(setName, elem, source); err != nil {
					log.Printf("[FlushSource] Warning: failed to queue unban %s: %v", elem, err)
					continue
				}
				unbanned++
			}
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"source":   source,
			"unbanned": unbanned,
			"action":   "source_unban",
			"queued":   true,
		},
	}
}

// handleQueueStatusRequest returns OpQueue statistics
func (d *Daemon) handleQueueStatusRequest() SocketResponse {
	if d.opQueue == nil {
		return SocketResponse{Success: false, Error: "OpQueue not initialized"}
	}

	stats := d.opQueue.Stats()

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"pending_count":   stats.PendingCount,
			"total_queued":    stats.TotalQueued,
			"total_applied":   stats.TotalApplied,
			"total_dropped":   stats.TotalDropped,
			"last_flush_time": stats.LastFlushTime.Format(time.RFC3339),
			"queue_depth":     d.opQueue.QueueDepth(),
		},
	}
}
