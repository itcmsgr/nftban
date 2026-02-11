// =============================================================================
// NFTBan v1.0 - IPC Integration Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ipc_integration_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Integration tests for IPC client ↔ daemon communication"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Tests for IPC client ↔ daemon communication
// Verifies: socket creation, permissions, request/response format, error handling
// =============================================================================

package ipc_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/pkg/ipc"
)

// =============================================================================
// Mock Server Implementation
// =============================================================================

// MockServer simulates the nftband daemon for testing
type MockServer struct {
	socketPath string
	ln         net.Listener
	ctx        context.Context
	cancel     context.CancelFunc
	t          *testing.T
}

// NewMockServer creates a mock IPC server for testing
func NewMockServer(t *testing.T) *MockServer {
	ctx, cancel := context.WithCancel(context.Background())

	// Use temp directory for test socket
	tmpDir := t.TempDir()
	socketPath := filepath.Join(tmpDir, "test.sock")

	return &MockServer{
		socketPath: socketPath,
		ctx:        ctx,
		cancel:     cancel,
		t:          t,
	}
}

// Start starts the mock server
func (s *MockServer) Start() error {
	ln, err := net.Listen("unix", s.socketPath)
	if err != nil {
		return fmt.Errorf("failed to create socket: %w", err)
	}
	s.ln = ln

	// Set socket permissions
	if err := os.Chmod(s.socketPath, 0660); err != nil {
		return fmt.Errorf("failed to chmod socket: %w", err)
	}

	// Accept connections
	go s.acceptConnections()

	return nil
}

// Stop stops the mock server
func (s *MockServer) Stop() {
	s.cancel()
	if s.ln != nil {
		s.ln.Close()
	}
	os.Remove(s.socketPath)
}

// acceptConnections handles incoming connections
func (s *MockServer) acceptConnections() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			select {
			case <-s.ctx.Done():
				return
			default:
				s.t.Logf("Accept error: %v", err)
				continue
			}
		}

		go s.handleConnection(conn)
	}
}

// handleConnection processes a single connection
func (s *MockServer) handleConnection(conn net.Conn) {
	defer conn.Close()

	// Set timeout
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	// Read request
	var req ipc.Request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		s.t.Logf("Failed to decode request: %v", err)
		return
	}

	// Handle request
	resp := s.handleRequest(req)

	// Write response
	if err := json.NewEncoder(conn).Encode(resp); err != nil {
		s.t.Logf("Failed to encode response: %v", err)
	}
}

// handleRequest processes a request and returns a response
func (s *MockServer) handleRequest(req ipc.Request) ipc.Response {
	switch req.Method {
	case "ping":
		return ipc.Response{Success: true, Data: "pong"}

	case "ban":
		ip, ok := req.Params["ip"].(string)
		if !ok || ip == "" {
			return ipc.Response{Success: false, Error: "missing ip parameter"}
		}
		return ipc.Response{
			Success: true,
			Data: map[string]any{
				"ip":     ip,
				"status": "banned",
			},
		}

	case "unban":
		ip, ok := req.Params["ip"].(string)
		if !ok || ip == "" {
			return ipc.Response{Success: false, Error: "missing ip parameter"}
		}
		return ipc.Response{
			Success: true,
			Data: map[string]any{
				"ip":     ip,
				"status": "unbanned",
			},
		}

	case "check":
		ip, ok := req.Params["ip"].(string)
		if !ok || ip == "" {
			return ipc.Response{Success: false, Error: "missing ip parameter"}
		}
		return ipc.Response{
			Success: true,
			Data: map[string]any{
				"ip":     ip,
				"banned": false,
			},
		}

	case "status":
		return ipc.Response{
			Success: true,
			Data: map[string]any{
				"version": "1.0.0-test",
				"uptime":  "5m",
				"modules": 3,
			},
		}

	case "modules":
		return ipc.Response{
			Success: true,
			Data: []map[string]any{
				{"name": "ddos", "status": "active"},
				{"name": "portscan", "status": "active"},
				{"name": "login", "status": "active"},
			},
		}

	case "add_element":
		table, _ := req.Params["table"].(string)
		set, _ := req.Params["set"].(string)
		element, _ := req.Params["element"].(string)
		if table == "" || set == "" || element == "" {
			return ipc.Response{Success: false, Error: "missing required parameters"}
		}
		return ipc.Response{Success: true}

	case "delete_element":
		table, _ := req.Params["table"].(string)
		set, _ := req.Params["set"].(string)
		element, _ := req.Params["element"].(string)
		if table == "" || set == "" || element == "" {
			return ipc.Response{Success: false, Error: "missing required parameters"}
		}
		return ipc.Response{Success: true}

	case "flush_set":
		table, _ := req.Params["table"].(string)
		set, _ := req.Params["set"].(string)
		if table == "" || set == "" {
			return ipc.Response{Success: false, Error: "missing required parameters"}
		}
		return ipc.Response{Success: true}

	case "sync":
		return ipc.Response{
			Success: true,
			Data: map[string]any{
				"synced": true,
				"stats": map[string]int{
					"whitelist": 10,
					"blacklist": 5,
					"ports":     20,
				},
			},
		}

	case "load_ports":
		return ipc.Response{
			Success: true,
			Data:    map[string]any{"loaded": 20},
		}

	case "load_cidrs":
		setType, _ := req.Params["set_type"].(string)
		if setType == "" {
			return ipc.Response{Success: false, Error: "missing set_type parameter"}
		}
		return ipc.Response{
			Success: true,
			Data:    map[string]any{"loaded": 15},
		}

	default:
		return ipc.Response{
			Success: false,
			Error:   fmt.Sprintf("unknown method: %s", req.Method),
		}
	}
}

// =============================================================================
// Integration Tests
// =============================================================================

func TestClient_Ping(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	if err := client.Ping(); err != nil {
		t.Errorf("Ping() failed: %v", err)
	}
}

func TestClient_Ban(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	tests := []struct {
		name    string
		ip      string
		timeout int
		reason  string
		source  string
		wantErr bool
	}{
		{
			name:    "ban valid IP",
			ip:      "1.2.3.4",
			timeout: 3600,
			reason:  "test ban",
			source:  "test",
			wantErr: false,
		},
		{
			name:    "ban with no timeout",
			ip:      "5.6.7.8",
			timeout: 0,
			reason:  "permanent ban",
			source:  "test",
			wantErr: false,
		},
		{
			name:    "ban empty IP",
			ip:      "",
			timeout: 0,
			reason:  "",
			source:  "",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := client.Ban(tt.ip, tt.timeout, tt.reason, tt.source)
			if (err != nil) != tt.wantErr {
				t.Errorf("Ban() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && !resp.Success {
				t.Errorf("Ban() response not successful: %s", resp.Error)
			}
		})
	}
}

func TestClient_Unban(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.Unban("1.2.3.4")
	if err != nil {
		t.Fatalf("Unban() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("Unban() response not successful: %s", resp.Error)
	}
}

func TestClient_Check(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.Check("1.2.3.4")
	if err != nil {
		t.Fatalf("Check() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("Check() response not successful: %s", resp.Error)
	}
}

func TestClient_Status(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.Status()
	if err != nil {
		t.Fatalf("Status() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("Status() response not successful: %s", resp.Error)
	}

	// Verify response data structure
	data, ok := resp.Data.(map[string]any)
	if !ok {
		t.Errorf("Status() data is not a map")
		return
	}
	if _, ok := data["version"]; !ok {
		t.Errorf("Status() response missing 'version' field")
	}
}

func TestClient_Modules(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.Modules()
	if err != nil {
		t.Fatalf("Modules() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("Modules() response not successful: %s", resp.Error)
	}
}

func TestClient_AddElement(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.AddElement("ip nftban", "blacklist4", "1.2.3.4", 3600)
	if err != nil {
		t.Fatalf("AddElement() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("AddElement() response not successful: %s", resp.Error)
	}
}

func TestClient_DeleteElement(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.DeleteElement("ip nftban", "blacklist4", "1.2.3.4")
	if err != nil {
		t.Fatalf("DeleteElement() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("DeleteElement() response not successful: %s", resp.Error)
	}
}

func TestClient_FlushSet(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.FlushSet("ip nftban", "blacklist4")
	if err != nil {
		t.Fatalf("FlushSet() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("FlushSet() response not successful: %s", resp.Error)
	}
}

func TestClient_Sync(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.Sync(false) // false = full sync, not quick mode
	if err != nil {
		t.Fatalf("Sync() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("Sync() response not successful: %s", resp.Error)
	}
}

func TestClient_LoadPorts(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	resp, err := client.LoadPorts()
	if err != nil {
		t.Fatalf("LoadPorts() failed: %v", err)
	}
	if !resp.Success {
		t.Errorf("LoadPorts() response not successful: %s", resp.Error)
	}
}

func TestClient_LoadCIDRs(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	tests := []struct {
		name    string
		setType string
		cidrs   []string
		wantErr bool
	}{
		{
			name:    "load blacklist",
			setType: "blacklist",
			cidrs:   []string{"1.2.3.0/24", "5.6.7.0/24"},
			wantErr: false,
		},
		{
			name:    "load whitelist",
			setType: "whitelist",
			cidrs:   []string{"10.0.0.0/8"},
			wantErr: false,
		},
		{
			name:    "load from feeds (no cidrs)",
			setType: "blacklist",
			cidrs:   nil,
			wantErr: false,
		},
		{
			name:    "missing set_type",
			setType: "",
			cidrs:   []string{"1.2.3.0/24"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := client.LoadCIDRs(tt.setType, tt.cidrs)
			if (err != nil) != tt.wantErr {
				t.Errorf("LoadCIDRs() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && !resp.Success {
				t.Errorf("LoadCIDRs() response not successful: %s", resp.Error)
			}
		})
	}
}

func TestClient_Timeout(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)
	client.SetTimeout(100 * time.Millisecond)

	// This should work fine (ping is fast)
	err := client.Ping()
	if err != nil {
		t.Errorf("Ping() with short timeout failed: %v", err)
	}
}

func TestClient_SocketNotFound(t *testing.T) {
	client := ipc.NewClientWithSocket("/tmp/nonexistent_socket_123456789.sock")

	err := client.Ping()
	if err == nil {
		t.Error("Expected error when socket does not exist, got nil")
	}
}

func TestClient_InvalidSocket(t *testing.T) {
	// Create a regular file instead of a socket
	tmpFile := filepath.Join(t.TempDir(), "not_a_socket")
	if err := os.WriteFile(tmpFile, []byte("test"), 0644); err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	client := ipc.NewClientWithSocket(tmpFile)
	err := client.Ping()
	if err == nil {
		t.Error("Expected error when connecting to non-socket file, got nil")
	}
}

func TestClient_IsConnected(t *testing.T) {
	server := NewMockServer(t)
	if err := server.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	if !client.IsConnected() {
		t.Error("IsConnected() = false, want true")
	}

	// Stop server
	server.Stop()

	if client.IsConnected() {
		t.Error("IsConnected() = true after server stopped, want false")
	}
}

// =============================================================================
// Benchmark Tests
// =============================================================================

func BenchmarkClient_Ping(b *testing.B) {
	server := NewMockServer(&testing.T{})
	if err := server.Start(); err != nil {
		b.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := client.Ping(); err != nil {
			b.Fatalf("Ping() failed: %v", err)
		}
	}
}

func BenchmarkClient_Ban(b *testing.B) {
	server := NewMockServer(&testing.T{})
	if err := server.Start(); err != nil {
		b.Fatalf("Failed to start server: %v", err)
	}
	defer server.Stop()

	client := ipc.NewClientWithSocket(server.socketPath)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ip := fmt.Sprintf("1.2.3.%d", i%255)
		if _, err := client.Ban(ip, 3600, "bench", "test"); err != nil {
			b.Fatalf("Ban() failed: %v", err)
		}
	}
}
