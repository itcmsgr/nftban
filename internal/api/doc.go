// =============================================================================
// NFTBan v1.0 - API Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-21"
// meta:description="Package documentation for NFTBan API handlers"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package api provides HTTP handlers for the NFTBan web interface and REST API.
//
// # Overview
//
// This package implements all HTTP endpoints for the NFTBan UI, providing
// real-time monitoring, configuration, and control of the firewall system.
//
// # Endpoints
//
// The API provides handlers for:
//
//   - /api/status - System status and health
//   - /api/blacklist - IP blacklist management
//   - /api/whitelist - IP whitelist management
//   - /api/feeds - Threat feed status and control
//   - /api/geoban - Geographic blocking configuration
//   - /api/portscan - Port scan detection status
//   - /api/ddos - DDoS protection settings
//   - /api/suricata - Suricata IDS integration
//   - /api/nftables - Raw nftables view
//
// # Authentication
//
// All endpoints require authentication via the auth package.
// Session management is handled by the session package.
//
// # Response Format
//
// All responses use JSON format with standard structure:
//
//	{
//	    "success": true,
//	    "data": {...},
//	    "error": ""
//	}
//
// # Usage
//
// Handlers are registered with the web server in cmd/nftban-ui:
//
//	mux.HandleFunc("/api/status", api.HandleStatus)
//	mux.HandleFunc("/api/blacklist", api.HandleBlacklist)
package api
