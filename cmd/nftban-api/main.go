// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/pkg/webapi/auth"
	"github.com/itcmsgr/nftban/pkg/webapi/handlers"
	"github.com/itcmsgr/nftban/pkg/webapi/rbac"
	"github.com/itcmsgr/nftban/pkg/webapi/session"
)

const (
	defaultListenAddr = ":3940"  // NFTBan Web API port
	defaultSessionTTL = 24 * time.Hour
)

func main() {
	// Parse command-line flags
	listenAddr := flag.String("listen", defaultListenAddr, "Listen address")
	sessionTTL := flag.Duration("session-ttl", defaultSessionTTL, "Session TTL")
	tlsCert := flag.String("tls-cert", "/etc/nftban/tls/cert.pem", "TLS certificate")
	tlsKey := flag.String("tls-key", "/etc/nftban/tls/key.pem", "TLS key")
	flag.Parse()

	log.Printf("[nftban-api] Starting NFTBan Web API v2.0")
	log.Printf("[nftban-api] Listen: %s, Session TTL: %v", *listenAddr, *sessionTTL)

	// Initialize components
	sessionStore := session.NewMemoryStore(*sessionTTL)
	pamAuth := auth.NewPAMAuthenticator()
	rbacMiddleware := rbac.NewMiddleware()

	log.Printf("[nftban-api] Initialized: session=memory, auth=PAM, rbac=enabled")

	// Create HTTP server
	handler := handlers.NewServer(sessionStore, pamAuth, rbacMiddleware)
	srv := &http.Server{
		Addr:         *listenAddr,
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server
	go func() {
		log.Printf("[nftban-api] HTTPS server listening on %s", *listenAddr)
		if err := srv.ListenAndServeTLS(*tlsCert, *tlsKey); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[nftban-api] Server error: %v", err)
		}
	}()

	// Wait for shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Printf("[nftban-api] Shutting down...")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("[nftban-api] Shutdown error: %v", err)
	}

	log.Printf("[nftban-api] Stopped")
}
