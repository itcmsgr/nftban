// =============================================================================
// NFTBan - API Helper Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="api_helpers_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-19"
// meta:description="Unit tests for API helper functions: validation, sanitization, JSON responses"
// meta:input="None"
// meta:output="None"
// meta:depends="testing,net/http/httptest"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// =============================================================================
// IP VALIDATION TESTS
// =============================================================================

// TestValidateIP_ValidAddresses tests that valid IP addresses pass validation
func TestValidateIP_ValidAddresses(t *testing.T) {
	valid := []string{
		"192.168.1.1",
		"10.0.0.1",
		"255.255.255.255",
		"0.0.0.0",
		"127.0.0.1",
		"8.8.8.8",
		"::1",
		"2001:db8::1",
		"fe80::1",
		"2001:0db8:85a3:0000:0000:8a2e:0370:7334",
	}

	for _, ip := range valid {
		t.Run(ip, func(t *testing.T) {
			if err := validateIP(ip); err != nil {
				t.Errorf("Expected %q to be valid, got error: %v", ip, err)
			}
		})
	}
}

// TestValidateIP_InvalidAddresses tests that invalid IP addresses are rejected
func TestValidateIP_InvalidAddresses(t *testing.T) {
	invalid := []string{
		"",
		"not-an-ip",
		"999.999.999.999",
		"192.168.1",
		"192.168.1.1.1",
		"192.168.1.256",
		"abc.def.ghi.jkl",
		"192.168.1.1/24",      // CIDR not valid for validateIP
		"; rm -rf /",          // injection attempt
		"192.168.1.1; whoami", // injection attempt
	}

	for _, ip := range invalid {
		t.Run(ip, func(t *testing.T) {
			if err := validateIP(ip); err == nil {
				t.Errorf("Expected %q to be invalid, but got no error", ip)
			}
		})
	}
}

// TestValidateIPs_AllValid tests batch validation with all valid IPs
func TestValidateIPs_AllValid(t *testing.T) {
	ips := []string{"192.168.1.1", "10.0.0.1", "::1"}
	if err := validateIPs(ips); err != nil {
		t.Errorf("Expected all IPs to be valid, got error: %v", err)
	}
}

// TestValidateIPs_OneInvalid tests batch validation with one invalid IP
func TestValidateIPs_OneInvalid(t *testing.T) {
	ips := []string{"192.168.1.1", "not-valid", "10.0.0.1"}
	err := validateIPs(ips)
	if err == nil {
		t.Error("Expected error for invalid IP in batch, got nil")
	}
	if !strings.Contains(err.Error(), "not-valid") {
		t.Errorf("Expected error to mention 'not-valid', got: %v", err)
	}
}

// TestValidateIPs_EmptySlice tests batch validation with empty input
func TestValidateIPs_EmptySlice(t *testing.T) {
	if err := validateIPs([]string{}); err != nil {
		t.Errorf("Expected empty slice to be valid, got error: %v", err)
	}
}

// TestValidateIPs_NilSlice tests batch validation with nil input
func TestValidateIPs_NilSlice(t *testing.T) {
	if err := validateIPs(nil); err != nil {
		t.Errorf("Expected nil slice to be valid, got error: %v", err)
	}
}

// =============================================================================
// IP OR CIDR VALIDATION TESTS
// =============================================================================

// TestValidateIPOrCIDR_ValidIPs tests valid plain IP addresses
func TestValidateIPOrCIDR_ValidIPs(t *testing.T) {
	valid := []string{
		"192.168.1.1",
		"10.0.0.1",
		"127.0.0.1",
		"::1",
		"2001:db8::1",
		"8.8.8.8",
	}

	for _, ip := range valid {
		t.Run("ip_"+ip, func(t *testing.T) {
			if !validateIPOrCIDR(ip) {
				t.Errorf("Expected IP %q to be valid", ip)
			}
		})
	}
}

// TestValidateIPOrCIDR_ValidCIDRs tests valid CIDR notation
func TestValidateIPOrCIDR_ValidCIDRs(t *testing.T) {
	valid := []string{
		"192.168.1.0/24",
		"10.0.0.0/8",
		"172.16.0.0/12",
		"0.0.0.0/0",
		"2001:db8::/32",
		"::/0",
	}

	for _, cidr := range valid {
		t.Run("cidr_"+cidr, func(t *testing.T) {
			if !validateIPOrCIDR(cidr) {
				t.Errorf("Expected CIDR %q to be valid", cidr)
			}
		})
	}
}

// TestValidateIPOrCIDR_Invalid tests invalid inputs
func TestValidateIPOrCIDR_Invalid(t *testing.T) {
	invalid := []string{
		"",
		"not-an-ip",
		"999.999.999.999",
		"192.168.1.1/33",  // invalid prefix length
		"192.168.1.1/abc", // non-numeric prefix
		"; rm -rf /",
		"$(whoami)",
		"hello world",
	}

	for _, input := range invalid {
		t.Run(input, func(t *testing.T) {
			if validateIPOrCIDR(input) {
				t.Errorf("Expected %q to be invalid, but it was accepted", input)
			}
		})
	}
}

// =============================================================================
// SANITIZE ERROR TESTS
// =============================================================================

// TestSanitizeError_NilError tests that nil error returns empty string
func TestSanitizeError_NilError(t *testing.T) {
	result := sanitizeError(nil)
	if result != "" {
		t.Errorf("Expected empty string for nil error, got %q", result)
	}
}

// TestSanitizeError_SimpleError tests basic error sanitization
func TestSanitizeError_SimpleError(t *testing.T) {
	err := errors.New("file not found")
	result := sanitizeError(err)
	if result != "file not found" {
		t.Errorf("Expected 'file not found', got %q", result)
	}
}

// TestSanitizeError_HTMLEscaping tests that HTML special characters are escaped
func TestSanitizeError_HTMLEscaping(t *testing.T) {
	testCases := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "script tag",
			input:    "<script>alert('xss')</script>",
			expected: "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;",
		},
		{
			name:     "ampersand",
			input:    "foo & bar",
			expected: "foo &amp; bar",
		},
		{
			name:     "double quotes",
			input:    `error "message"`,
			expected: "error &#34;message&#34;",
		},
		{
			name:     "angle brackets",
			input:    "a < b > c",
			expected: "a &lt; b &gt; c",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			err := errors.New(tc.input)
			result := sanitizeError(err)
			if result != tc.expected {
				t.Errorf("Expected %q, got %q", tc.expected, result)
			}
		})
	}
}

// TestSanitizeError_Truncation tests that long error messages are truncated at 512 chars
func TestSanitizeError_Truncation(t *testing.T) {
	// Create a string longer than 512 characters
	longMsg := strings.Repeat("a", 600)
	err := errors.New(longMsg)
	result := sanitizeError(err)

	// Should be 512 chars + "..."
	if len(result) != 515 {
		t.Errorf("Expected truncated length 515 (512+...), got %d", len(result))
	}
	if !strings.HasSuffix(result, "...") {
		t.Error("Expected truncated message to end with '...'")
	}
}

// TestSanitizeError_ExactlyAtLimit tests a message exactly at the 512 char limit
func TestSanitizeError_ExactlyAtLimit(t *testing.T) {
	msg := strings.Repeat("a", 512)
	err := errors.New(msg)
	result := sanitizeError(err)

	if result != msg {
		t.Error("Expected message exactly at limit to not be truncated")
	}
	if strings.HasSuffix(result, "...") {
		t.Error("Message exactly at 512 should not be truncated")
	}
}

// =============================================================================
// SANITIZE ERROR MSG TESTS
// =============================================================================

// TestSanitizeErrorMsg_StripsPaths tests that sensitive paths are replaced
func TestSanitizeErrorMsg_StripsPaths(t *testing.T) {
	testCases := []struct {
		name     string
		input    string
		contains string
		excludes string
	}{
		{
			name:     "etc path",
			input:    "failed to read /etc/nftban/main.conf",
			contains: "[nftban]/main.conf",
			excludes: "/etc/nftban/",
		},
		{
			name:     "var lib path",
			input:    "cannot open /var/lib/nftban/state/bans.json",
			contains: "[nftban]/state/bans.json",
			excludes: "/var/lib/nftban/",
		},
		{
			name:     "var log path",
			input:    "log error in /var/log/nftban/nftban.log",
			contains: "[nftban]/nftban.log",
			excludes: "/var/log/nftban/",
		},
		{
			name:     "usr lib path",
			input:    "missing /usr/lib/nftban/core/detect.sh",
			contains: "[nftban]/core/detect.sh",
			excludes: "/usr/lib/nftban/",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := sanitizeErrorMsg(tc.input)
			if !strings.Contains(result, tc.contains) {
				t.Errorf("Expected result to contain %q, got %q", tc.contains, result)
			}
			if strings.Contains(result, tc.excludes) {
				t.Errorf("Expected result to NOT contain %q, got %q", tc.excludes, result)
			}
		})
	}
}

// TestSanitizeErrorMsg_HTMLEscaping tests that HTML is escaped after path stripping
func TestSanitizeErrorMsg_HTMLEscaping(t *testing.T) {
	input := `<script>alert("/etc/nftban/x")</script>`
	result := sanitizeErrorMsg(input)

	// Should escape HTML
	if strings.Contains(result, "<script>") {
		t.Errorf("Expected HTML to be escaped, got %q", result)
	}
	// The /etc/nftban/ should be replaced
	if strings.Contains(result, "/etc/nftban/") {
		t.Errorf("Expected path to be stripped, got %q", result)
	}
}

// TestSanitizeErrorMsg_Truncation tests that long messages are truncated
func TestSanitizeErrorMsg_Truncation(t *testing.T) {
	longMsg := strings.Repeat("x", 600)
	result := sanitizeErrorMsg(longMsg)

	if len(result) != 515 {
		t.Errorf("Expected truncated length 515, got %d", len(result))
	}
	if !strings.HasSuffix(result, "...") {
		t.Error("Expected truncated message to end with '...'")
	}
}

// TestSanitizeErrorMsg_NoSensitivePath tests message without sensitive paths
func TestSanitizeErrorMsg_NoSensitivePath(t *testing.T) {
	input := "connection refused"
	result := sanitizeErrorMsg(input)
	if result != "connection refused" {
		t.Errorf("Expected unchanged message, got %q", result)
	}
}

// =============================================================================
// STRIP SENSITIVE PATHS TESTS
// =============================================================================

// TestStripSensitivePaths tests all four sensitive path patterns
func TestStripSensitivePaths(t *testing.T) {
	testCases := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "etc nftban",
			input:    "error in /etc/nftban/main.conf",
			expected: "error in [nftban]/main.conf",
		},
		{
			name:     "var lib nftban",
			input:    "missing /var/lib/nftban/feeds/list.txt",
			expected: "missing [nftban]/feeds/list.txt",
		},
		{
			name:     "var log nftban",
			input:    "cannot write /var/log/nftban/nftban.log",
			expected: "cannot write [nftban]/nftban.log",
		},
		{
			name:     "usr lib nftban",
			input:    "source /usr/lib/nftban/core/ban.sh",
			expected: "source [nftban]/core/ban.sh",
		},
		{
			name:     "multiple paths",
			input:    "copy /etc/nftban/a to /var/lib/nftban/b",
			expected: "copy [nftban]/a to [nftban]/b",
		},
		{
			name:     "no sensitive paths",
			input:    "normal error message",
			expected: "normal error message",
		},
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "partial path not matched",
			input:    "file at /etc/other/thing",
			expected: "file at /etc/other/thing",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := stripSensitivePaths(tc.input)
			if result != tc.expected {
				t.Errorf("Expected %q, got %q", tc.expected, result)
			}
		})
	}
}

// =============================================================================
// RESPOND JSON TESTS
// =============================================================================

// TestRespondJSON_StatusCode tests that respondJSON sets the correct status code
func TestRespondJSON_StatusCode(t *testing.T) {
	testCases := []struct {
		name   string
		status int
	}{
		{"ok", http.StatusOK},
		{"bad request", http.StatusBadRequest},
		{"internal error", http.StatusInternalServerError},
		{"not found", http.StatusNotFound},
		{"unauthorized", http.StatusUnauthorized},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			respondJSON(w, tc.status, map[string]string{"test": "data"})

			if w.Code != tc.status {
				t.Errorf("Expected status %d, got %d", tc.status, w.Code)
			}
		})
	}
}

// TestRespondJSON_ContentType tests that respondJSON sets JSON content type
func TestRespondJSON_ContentType(t *testing.T) {
	w := httptest.NewRecorder()
	respondJSON(w, http.StatusOK, map[string]string{"key": "value"})

	ct := w.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("Expected Content-Type 'application/json', got %q", ct)
	}
}

// TestRespondJSON_EncodesData tests that respondJSON correctly encodes data as JSON
func TestRespondJSON_EncodesData(t *testing.T) {
	w := httptest.NewRecorder()
	data := map[string]interface{}{
		"success": true,
		"message": "test message",
		"count":   float64(42),
	}
	respondJSON(w, http.StatusOK, data)

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response body as JSON: %v", err)
	}

	if result["success"] != true {
		t.Errorf("Expected success=true, got %v", result["success"])
	}
	if result["message"] != "test message" {
		t.Errorf("Expected message='test message', got %v", result["message"])
	}
	if result["count"] != float64(42) {
		t.Errorf("Expected count=42, got %v", result["count"])
	}
}

// TestRespondJSON_ErrorResponse tests encoding an ErrorResponse struct
func TestRespondJSON_ErrorResponse(t *testing.T) {
	w := httptest.NewRecorder()
	respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "invalid input"})

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if result["error"] != "invalid input" {
		t.Errorf("Expected error='invalid input', got %v", result["error"])
	}
}

// TestRespondJSON_SuccessResponse tests encoding a SuccessResponse struct
func TestRespondJSON_SuccessResponse(t *testing.T) {
	w := httptest.NewRecorder()
	respondJSON(w, http.StatusOK, SuccessResponse{Success: true, Message: "done"})

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if result["success"] != true {
		t.Errorf("Expected success=true, got %v", result["success"])
	}
	if result["message"] != "done" {
		t.Errorf("Expected message='done', got %v", result["message"])
	}
}

// =============================================================================
// RESPOND ERROR TESTS
// =============================================================================

// TestRespondError_Format tests the structure of error responses
func TestRespondError_Format(t *testing.T) {
	w := httptest.NewRecorder()
	respondError(w, http.StatusInternalServerError, "something broke")

	if w.Code != http.StatusInternalServerError {
		t.Errorf("Expected status 500, got %d", w.Code)
	}

	ct := w.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("Expected Content-Type 'application/json', got %q", ct)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if result["success"] != false {
		t.Errorf("Expected success=false, got %v", result["success"])
	}
	if result["error"] != "something broke" {
		t.Errorf("Expected error='something broke', got %v", result["error"])
	}
}

// TestRespondError_DifferentStatuses tests respondError with various HTTP status codes
func TestRespondError_DifferentStatuses(t *testing.T) {
	testCases := []struct {
		status  int
		message string
	}{
		{http.StatusBadRequest, "bad request"},
		{http.StatusUnauthorized, "unauthorized"},
		{http.StatusForbidden, "forbidden"},
		{http.StatusNotFound, "not found"},
		{http.StatusConflict, "conflict"},
	}

	for _, tc := range testCases {
		t.Run(tc.message, func(t *testing.T) {
			w := httptest.NewRecorder()
			respondError(w, tc.status, tc.message)

			if w.Code != tc.status {
				t.Errorf("Expected status %d, got %d", tc.status, w.Code)
			}

			var result map[string]interface{}
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
				t.Fatalf("Failed to parse response body: %v", err)
			}
			if result["error"] != tc.message {
				t.Errorf("Expected error=%q, got %v", tc.message, result["error"])
			}
		})
	}
}

// =============================================================================
// DECODE JSON BODY TESTS
// =============================================================================

// TestDecodeJSONBody_ValidJSON tests successful JSON body decoding
func TestDecodeJSONBody_ValidJSON(t *testing.T) {
	body := strings.NewReader(`{"ip": "192.168.1.1", "reason": "test ban"}`)
	r := httptest.NewRequest("POST", "/api/v1/ban", body)
	w := httptest.NewRecorder()

	var req struct {
		IP     string `json:"ip"`
		Reason string `json:"reason"`
	}

	ok := DecodeJSONBody(w, r, &req)

	if !ok {
		t.Fatal("Expected DecodeJSONBody to return true for valid JSON")
	}
	if req.IP != "192.168.1.1" {
		t.Errorf("Expected IP='192.168.1.1', got %q", req.IP)
	}
	if req.Reason != "test ban" {
		t.Errorf("Expected Reason='test ban', got %q", req.Reason)
	}
}

// TestDecodeJSONBody_InvalidJSON tests that invalid JSON returns false and error response
func TestDecodeJSONBody_InvalidJSON(t *testing.T) {
	body := strings.NewReader(`{invalid json`)
	r := httptest.NewRequest("POST", "/api/v1/ban", body)
	w := httptest.NewRecorder()

	var req struct {
		IP string `json:"ip"`
	}

	ok := DecodeJSONBody(w, r, &req)

	if ok {
		t.Fatal("Expected DecodeJSONBody to return false for invalid JSON")
	}
	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse error response: %v", err)
	}
	errMsg, ok := result["error"].(string)
	if !ok || !strings.Contains(errMsg, "Invalid request body") {
		t.Errorf("Expected error containing 'Invalid request body', got %v", result["error"])
	}
}

// TestDecodeJSONBody_EmptyBody tests that empty body returns false
func TestDecodeJSONBody_EmptyBody(t *testing.T) {
	body := strings.NewReader("")
	r := httptest.NewRequest("POST", "/api/v1/ban", body)
	w := httptest.NewRecorder()

	var req struct {
		IP string `json:"ip"`
	}

	ok := DecodeJSONBody(w, r, &req)

	if ok {
		t.Fatal("Expected DecodeJSONBody to return false for empty body")
	}
	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}
}

// TestDecodeJSONBody_ExtraFields tests that extra JSON fields are ignored
func TestDecodeJSONBody_ExtraFields(t *testing.T) {
	body := strings.NewReader(`{"ip": "10.0.0.1", "unknown_field": "ignored"}`)
	r := httptest.NewRequest("POST", "/api/v1/ban", body)
	w := httptest.NewRecorder()

	var req struct {
		IP string `json:"ip"`
	}

	ok := DecodeJSONBody(w, r, &req)

	if !ok {
		t.Fatal("Expected DecodeJSONBody to return true with extra fields")
	}
	if req.IP != "10.0.0.1" {
		t.Errorf("Expected IP='10.0.0.1', got %q", req.IP)
	}
}

// =============================================================================
// PARSE WHITELIST OUTPUT TESTS
// =============================================================================

// TestParseWhitelistOutput_BasicOutput tests parsing whitelist CLI output
func TestParseWhitelistOutput_BasicOutput(t *testing.T) {
	output := "192.168.1.1\n10.0.0.1\n172.16.0.1\n"
	result := parseWhitelistOutput(output)

	if len(result) != 3 {
		t.Fatalf("Expected 3 IPs, got %d", len(result))
	}
	if result[0] != "192.168.1.1" {
		t.Errorf("Expected first IP '192.168.1.1', got %q", result[0])
	}
	if result[1] != "10.0.0.1" {
		t.Errorf("Expected second IP '10.0.0.1', got %q", result[1])
	}
	if result[2] != "172.16.0.1" {
		t.Errorf("Expected third IP '172.16.0.1', got %q", result[2])
	}
}

// TestParseWhitelistOutput_WithComments tests that comments are filtered out
func TestParseWhitelistOutput_WithComments(t *testing.T) {
	output := "# This is a comment\n192.168.1.1\n# Another comment\n10.0.0.1\n"
	result := parseWhitelistOutput(output)

	if len(result) != 2 {
		t.Fatalf("Expected 2 IPs (comments filtered), got %d", len(result))
	}
	if result[0] != "192.168.1.1" {
		t.Errorf("Expected '192.168.1.1', got %q", result[0])
	}
	if result[1] != "10.0.0.1" {
		t.Errorf("Expected '10.0.0.1', got %q", result[1])
	}
}

// TestParseWhitelistOutput_EmptyLines tests that empty lines are filtered
func TestParseWhitelistOutput_EmptyLines(t *testing.T) {
	output := "\n192.168.1.1\n\n\n10.0.0.1\n\n"
	result := parseWhitelistOutput(output)

	if len(result) != 2 {
		t.Fatalf("Expected 2 IPs (empty lines filtered), got %d", len(result))
	}
}

// TestParseWhitelistOutput_WhitespaceHandling tests trimming of whitespace
func TestParseWhitelistOutput_WhitespaceHandling(t *testing.T) {
	output := "  192.168.1.1  \n\t10.0.0.1\t\n"
	result := parseWhitelistOutput(output)

	if len(result) != 2 {
		t.Fatalf("Expected 2 IPs, got %d", len(result))
	}
	if result[0] != "192.168.1.1" {
		t.Errorf("Expected trimmed '192.168.1.1', got %q", result[0])
	}
	if result[1] != "10.0.0.1" {
		t.Errorf("Expected trimmed '10.0.0.1', got %q", result[1])
	}
}

// TestParseWhitelistOutput_EmptyInput tests parsing empty string
func TestParseWhitelistOutput_EmptyInput(t *testing.T) {
	result := parseWhitelistOutput("")
	if len(result) != 0 {
		t.Errorf("Expected 0 IPs for empty input, got %d", len(result))
	}
}

// TestParseWhitelistOutput_OnlyComments tests input with only comments
func TestParseWhitelistOutput_OnlyComments(t *testing.T) {
	output := "# comment 1\n# comment 2\n"
	result := parseWhitelistOutput(output)

	if len(result) != 0 {
		t.Errorf("Expected 0 IPs for comments-only input, got %d", len(result))
	}
}

// =============================================================================
// API RESPONSE CONSTRUCTOR TESTS
// =============================================================================

// TestNewSuccessResponse tests the success response constructor
func TestNewSuccessResponse_Structure(t *testing.T) {
	resp := NewSuccessResponse("operation complete", map[string]int{"count": 5})

	if !resp.Success {
		t.Error("Expected Success=true")
	}
	if resp.Message != "operation complete" {
		t.Errorf("Expected Message='operation complete', got %q", resp.Message)
	}
	if resp.Error != "" {
		t.Errorf("Expected empty Error, got %q", resp.Error)
	}
	if resp.Timestamp == 0 {
		t.Error("Expected non-zero Timestamp")
	}
	if resp.Data == nil {
		t.Error("Expected non-nil Data")
	}
}

// TestNewSuccessResponse_NilData tests success response with nil data
func TestNewSuccessResponse_NilData(t *testing.T) {
	resp := NewSuccessResponse("done", nil)

	if !resp.Success {
		t.Error("Expected Success=true")
	}
	if resp.Data != nil {
		t.Errorf("Expected nil Data, got %v", resp.Data)
	}
}

// TestNewErrorResponse tests the error response constructor
func TestNewErrorResponse_Structure(t *testing.T) {
	resp := NewErrorResponse("something failed")

	if resp.Success {
		t.Error("Expected Success=false")
	}
	if resp.Error != "something failed" {
		t.Errorf("Expected Error='something failed', got %q", resp.Error)
	}
	if resp.Message != "" {
		t.Errorf("Expected empty Message, got %q", resp.Message)
	}
	if resp.Timestamp == 0 {
		t.Error("Expected non-zero Timestamp")
	}
	if resp.Data != nil {
		t.Errorf("Expected nil Data, got %v", resp.Data)
	}
}

// TestNewDataResponse tests the data-only response constructor
func TestNewDataResponse_Structure(t *testing.T) {
	data := map[string]string{"key": "value"}
	resp := NewDataResponse(data)

	if !resp.Success {
		t.Error("Expected Success=true")
	}
	if resp.Message != "" {
		t.Errorf("Expected empty Message, got %q", resp.Message)
	}
	if resp.Error != "" {
		t.Errorf("Expected empty Error, got %q", resp.Error)
	}
	if resp.Timestamp == 0 {
		t.Error("Expected non-zero Timestamp")
	}
	if resp.Data == nil {
		t.Error("Expected non-nil Data")
	}
}

// =============================================================================
// JSON RESPONSE WRITER TESTS
// =============================================================================

// TestJSON_WrapsInAPIResponse tests that JSON() wraps data in APIResponse envelope
func TestJSON_WrapsInAPIResponse(t *testing.T) {
	w := httptest.NewRecorder()
	JSON(w, http.StatusOK, map[string]string{"key": "value"})

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	ct := w.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("Expected Content-Type 'application/json', got %q", ct)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	if result["success"] != true {
		t.Errorf("Expected success=true, got %v", result["success"])
	}
	if result["timestamp"] == nil {
		t.Error("Expected timestamp to be present")
	}
	if result["data"] == nil {
		t.Error("Expected data to be present")
	}
}

// TestJSON_CustomStatusCode tests that JSON() uses the provided status code
func TestJSON_CustomStatusCode(t *testing.T) {
	w := httptest.NewRecorder()
	JSON(w, http.StatusCreated, "created")

	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}
}

// TestJSONSuccess_Format tests JSONSuccess response structure
func TestJSONSuccess_Format(t *testing.T) {
	w := httptest.NewRecorder()
	JSONSuccess(w, "IP banned", map[string]string{"ip": "1.2.3.4"})

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	if result["success"] != true {
		t.Errorf("Expected success=true, got %v", result["success"])
	}
	if result["message"] != "IP banned" {
		t.Errorf("Expected message='IP banned', got %v", result["message"])
	}
}

// TestJSONError_Format tests JSONError response structure
func TestJSONError_Format(t *testing.T) {
	w := httptest.NewRecorder()
	JSONError(w, http.StatusBadRequest, "invalid IP")

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	if result["success"] != false {
		t.Errorf("Expected success=false, got %v", result["success"])
	}
	if result["error"] != "invalid IP" {
		t.Errorf("Expected error='invalid IP', got %v", result["error"])
	}
}

// TestJSONRaw_PassesThrough tests that JSONRaw sends the object as-is
func TestJSONRaw_PassesThrough(t *testing.T) {
	w := httptest.NewRecorder()
	raw := map[string]interface{}{
		"custom_field": "custom_value",
		"count":        float64(7),
	}
	JSONRaw(w, http.StatusOK, raw)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response: %v", err)
	}

	// JSONRaw does NOT wrap in APIResponse - it sends the object directly
	if result["custom_field"] != "custom_value" {
		t.Errorf("Expected custom_field='custom_value', got %v", result["custom_field"])
	}
	// Should NOT have success/timestamp from APIResponse wrapper
	if _, hasSuccess := result["success"]; hasSuccess {
		t.Error("JSONRaw should not wrap in APIResponse (should not have 'success' key)")
	}
}

// =============================================================================
// EDGE CASE TESTS
// =============================================================================

// TestValidateIPOrCIDR_Whitespace tests that whitespace is not accepted
func TestValidateIPOrCIDR_Whitespace(t *testing.T) {
	testCases := []struct {
		name  string
		input string
		valid bool
	}{
		// net.ParseIP and net.ParseCIDR do NOT trim whitespace
		{"leading space", " 192.168.1.1", false},
		{"trailing space", "192.168.1.1 ", false},
		{"leading space cidr", " 10.0.0.0/8", false},
		{"trailing space cidr", "10.0.0.0/8 ", false},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := validateIPOrCIDR(tc.input)
			if result != tc.valid {
				t.Errorf("validateIPOrCIDR(%q) = %v, want %v", tc.input, result, tc.valid)
			}
		})
	}
}

// TestDecodeJSONBody_NestedStruct tests decoding a nested JSON structure
func TestDecodeJSONBody_NestedStruct(t *testing.T) {
	body := strings.NewReader(`{"add": ["1.2.3.4", "5.6.7.8"], "remove": ["9.10.11.12"]}`)
	r := httptest.NewRequest("POST", "/api/v1/batch", body)
	w := httptest.NewRecorder()

	var req BatchRequest
	ok := DecodeJSONBody(w, r, &req)

	if !ok {
		t.Fatal("Expected DecodeJSONBody to return true")
	}
	if len(req.Add) != 2 {
		t.Errorf("Expected 2 Add entries, got %d", len(req.Add))
	}
	if len(req.Remove) != 1 {
		t.Errorf("Expected 1 Remove entry, got %d", len(req.Remove))
	}
}

// TestRespondJSON_NilData tests respondJSON with nil data
func TestRespondJSON_NilData(t *testing.T) {
	w := httptest.NewRecorder()
	respondJSON(w, http.StatusOK, nil)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	// null is valid JSON
	body := strings.TrimSpace(w.Body.String())
	if body != "null" {
		t.Errorf("Expected 'null' for nil data, got %q", body)
	}
}

// TestSanitizeError_HTMLAndTruncation tests combined HTML escaping + truncation
func TestSanitizeError_HTMLAndTruncation(t *testing.T) {
	// HTML entities expand the string. Create a message that is under 512 chars
	// raw but over 512 after escaping, to verify truncation applies to escaped output.
	// Each '<' becomes '&lt;' (4 chars), so 200 angle brackets = 800 escaped chars
	longHTML := strings.Repeat("<", 200)
	err := errors.New(longHTML)
	result := sanitizeError(err)

	// After escaping, each '<' becomes '&lt;' = 4 chars, total = 800 > 512
	// So it should be truncated to 512 + "..."
	if len(result) != 515 {
		t.Errorf("Expected truncated length 515, got %d", len(result))
	}
	if !strings.HasSuffix(result, "...") {
		t.Error("Expected truncated message to end with '...'")
	}
}

// =============================================================================
// BENCHMARKS
// =============================================================================

func BenchmarkValidateIP_Valid(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateIP("192.168.1.1")
	}
}

func BenchmarkValidateIP_Invalid(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateIP("not-an-ip")
	}
}

func BenchmarkValidateIPOrCIDR_IP(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateIPOrCIDR("192.168.1.1")
	}
}

func BenchmarkValidateIPOrCIDR_CIDR(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateIPOrCIDR("192.168.1.0/24")
	}
}

func BenchmarkSanitizeError(b *testing.B) {
	err := errors.New("<script>alert('xss')</script> in /etc/nftban/main.conf")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		sanitizeError(err)
	}
}

func BenchmarkStripSensitivePaths(b *testing.B) {
	msg := "error reading /etc/nftban/main.conf and /var/lib/nftban/state.json"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		stripSensitivePaths(msg)
	}
}

func BenchmarkRespondJSON(b *testing.B) {
	data := map[string]interface{}{"success": true, "message": "ok", "count": 42}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		w := httptest.NewRecorder()
		respondJSON(w, http.StatusOK, data)
	}
}

func BenchmarkParseWhitelistOutput(b *testing.B) {
	output := "192.168.1.1\n10.0.0.1\n# comment\n172.16.0.1\n\n8.8.8.8\n"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		parseWhitelistOutput(output)
	}
}
