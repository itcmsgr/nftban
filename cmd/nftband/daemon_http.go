// =============================================================================
// NFTBan v1.0 - nftband Daemon - HTTP and pprof server setup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="HTTP and pprof server setup"
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
	"encoding/json"
	"log"
	"net"
	"net/http"
	nethttpprof "net/http/pprof" // BUG-H4 FIX: explicit import instead of blank import to avoid polluting DefaultServeMux

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// startHTTP starts the HTTP API server
func (d *Daemon) startHTTP() error {
	mux := http.NewServeMux()

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status":  "ok",
			"version": version.Version,
		})
	})

	// Prometheus metrics endpoint
	// BUG-H5 FIX: Restrict /metrics to localhost only (prevents information disclosure)
	mux.Handle("/metrics", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if host != "127.0.0.1" && host != "::1" {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		promhttp.Handler().ServeHTTP(w, r)
	}))

	// Status endpoint
	mux.HandleFunc("/api/v1/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		stats := d.bus.Stats()
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"version":      version.Version,
				"modules":      len(d.registry.All()),
				"events_total": stats.Published,
			},
		})
	})

	// Modules endpoint
	mux.HandleFunc("/api/v1/modules", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		statuses := d.registry.StatusAll()
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data":    statuses,
		})
	})

	// TODO: Mount existing internal/api handlers here
	// mux.Handle("/api/v1/", api.NewRouter())

	addr := getAPIAddr()

	// v1.52.0: Pre-check if port is available — if not, skip HTTP API gracefully
	// This prevents noisy errors when Apache/DA/cPanel/nginx is on the same port
	testLn, err := net.Listen("tcp", addr)
	if err != nil {
		log.Printf("[WARN] HTTP API port %s unavailable (%v) — API disabled, IPC socket still works", addr, err)
		return nil
	}
	testLn.Close()

	d.httpSrv = &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	go func() {
		if err := d.httpSrv.ListenAndServe(); err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	return nil
}

// startPprof starts a pprof HTTP server for profiling
// The server listens on localhost only (127.0.0.1:6060) for security
// SECURITY: pprof exposes sensitive runtime information - only enable for debugging
// BUG-H4 FIX: Uses a dedicated ServeMux instead of DefaultServeMux
func (d *Daemon) startPprof() {
	pprofMux := http.NewServeMux()
	pprofMux.HandleFunc("/debug/pprof/", nethttpprof.Index)
	pprofMux.HandleFunc("/debug/pprof/cmdline", nethttpprof.Cmdline)
	pprofMux.HandleFunc("/debug/pprof/profile", nethttpprof.Profile)
	pprofMux.HandleFunc("/debug/pprof/symbol", nethttpprof.Symbol)
	pprofMux.HandleFunc("/debug/pprof/trace", nethttpprof.Trace)

	// Create server with timeouts to prevent resource exhaustion (CodeQL fix)
	pprofServer := &http.Server{
		Addr:         PprofAddr,
		Handler:      pprofMux,
		ReadTimeout:  constants.HTTPReadTimeout,
		WriteTimeout: constants.HTTPWriteTimeout, // Profile endpoint may take longer
		IdleTimeout:  constants.HTTPIdleTimeout,
	}

	go func() {
		log.Println("WARNING: pprof profiling enabled - disable in production (unset NFTBAN_ENABLE_PPROF or remove --profile)")
		log.Printf("pprof server listening on http://%s/debug/pprof/", PprofAddr)
		if err := pprofServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("pprof server error: %v", err)
		}
	}()
}
