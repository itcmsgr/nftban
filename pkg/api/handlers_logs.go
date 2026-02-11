// =============================================================================
// NFTBan - Logs API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_logs"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Log viewing and management API handlers"
// meta:input="HTTP requests for log operations"
// meta:output="JSON responses with log data"
// meta:depends="os/exec"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// SECURITY FIX: Regex to validate search filter input - prevents command injection
// Only allows alphanumeric characters, spaces, and common safe punctuation
var validSearchFilterRegex = regexp.MustCompile(`^[a-zA-Z0-9 ._:-]+$`)

// LogsHandler returns system logs
func LogsHandler(w http.ResponseWriter, r *http.Request) {
	// UPDATED v0.6.5: Now supports log viewer functionality
	// Accepts both 'type' (GUI) and 'log_type' (API standard) parameters

	logType := r.URL.Query().Get("type")
	if logType == "" {
		logType = r.URL.Query().Get("log_type")
	}

	// If type is specified, use LogsViewerHandler logic
	if logType != "" {
		// Delegate to LogsViewerHandler logic inline
		linesStr := r.URL.Query().Get("lines")
		searchFilter := r.URL.Query().Get("search")

		lines := 100
		if linesStr != "" {
			if n, err := strconv.Atoi(linesStr); err == nil && n > 0 && n <= 10000 {
				lines = n
			}
		}

		// Map log types to files - use central config
		logFiles := getLogFiles()

		logFile, ok := logFiles[logType]
		if !ok {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{
				Error: "Invalid log type. Available: nftban, nftban-actions, portscan, ddos, login-alert, feeds, geoban, suricata-eve, suricata-fast, suricata-stats, suricata-log, cron, maintenance, cli-errors",
			})
			return
		}

		// Check if file exists
		if _, err := os.Stat(logFile); os.IsNotExist(err) {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success":       true,
				"log_type":      logType,
				"lines":         []string{},
				"total_lines":   0,
				"visible_lines": 0,
				"message":       "Log file does not exist yet",
			})
			return
		}

		// Read with tail/grep
		var output string
		var err error

		if searchFilter != "" {
			// SECURITY FIX: Validate search filter to prevent command injection
			if !validSearchFilterRegex.MatchString(searchFilter) {
				respondJSON(w, http.StatusBadRequest, ErrorResponse{
					Error: "Invalid search filter: only alphanumeric characters, spaces, and ._:- are allowed",
				})
				return
			}
			// SECURITY FIX: Use safe pipe instead of shell execution to prevent injection
			output, err = execTailGrepSafe(logFile, lines, searchFilter)
		} else {
			output, err = execCommand("tail", "-n", strconv.Itoa(lines), logFile)
		}

		if err != nil && searchFilter != "" && output == "" {
			// No matches
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success":       true,
				"log_type":      logType,
				"lines":         []string{},
				"total_lines":   0,
				"visible_lines": 0,
			})
			return
		}

		if err != nil {
			log.Printf("[ERROR] Failed to read log file %s: %v", logFile, err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: fmt.Sprintf("Failed to read log file: %v", err),
			})
			return
		}

		// Split into lines
		logLines := strings.Split(strings.TrimSpace(output), "\n")
		if len(logLines) == 1 && logLines[0] == "" {
			logLines = []string{}
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success":       true,
			"log_type":      logType,
			"lines":         logLines,
			"total_lines":   len(logLines),
			"visible_lines": len(logLines),
		})
		return
	}

	// Legacy: No type specified, return journalctl logs
	tailStr := r.URL.Query().Get("tail")
	tail := "200"
	if tailStr != "" {
		tail = tailStr
	}

	output, err := execCommand("journalctl", "-u", "nftban", "-n", tail, "--no-pager")
	if err != nil {
		log.Printf("[ERROR] Failed to get logs: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve logs"})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"logs": output,
	})
}

// LogsViewerHandler returns logs from specific NFTBan log files
// Supports multiple log types with search filtering and tail mode
func LogsViewerHandler(w http.ResponseWriter, r *http.Request) {
	// Get parameters
	logType := r.URL.Query().Get("log_type")
	linesStr := r.URL.Query().Get("lines")
	searchFilter := r.URL.Query().Get("search")
	tailMode := r.URL.Query().Get("tail") == "true"

	// Default values
	lines := 100
	if linesStr != "" {
		if n, err := strconv.Atoi(linesStr); err == nil && n > 0 && n <= 10000 {
			lines = n
		}
	}

	// Map log types to actual log files - use central config
	logFiles := getLogFiles()

	// Validate log type
	logFile, ok := logFiles[logType]
	if !ok || logType == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error: "Invalid log type. Available: nftban, nftban-actions, portscan, ddos, login-alert, feeds, geoban, suricata-eve, suricata-fast, suricata-stats, suricata-log, cron, maintenance, cli-errors",
		})
		return
	}

	// Check if log file exists
	if _, err := os.Stat(logFile); os.IsNotExist(err) {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success":       true,
			"log_type":      logType,
			"lines":         []string{},
			"total_lines":   0,
			"visible_lines": 0,
			"message":       "Log file does not exist yet",
		})
		return
	}

	// Read log file with tail
	var output string
	var err error

	if searchFilter != "" {
		// SECURITY FIX: Validate search filter to prevent command injection
		if !validSearchFilterRegex.MatchString(searchFilter) {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{
				Error: "Invalid search filter: only alphanumeric characters, spaces, and ._:- are allowed",
			})
			return
		}
		// SECURITY FIX: Use safe pipe instead of shell execution to prevent injection
		output, err = execTailGrepSafe(logFile, lines, searchFilter)
	} else {
		// Just tail
		output, err = execCommand("tail", "-n", strconv.Itoa(lines), logFile)
	}

	if err != nil {
		// If grep returns no matches, it's not an error
		if searchFilter != "" && output == "" {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success":       true,
				"log_type":      logType,
				"lines":         []string{},
				"total_lines":   0,
				"visible_lines": 0,
				"message":       "No matching lines found",
			})
			return
		}

		log.Printf("[ERROR] Failed to read log file %s: %v", logFile, err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to read log file: %v", err),
		})
		return
	}

	// Split into lines
	logLines := strings.Split(strings.TrimSpace(output), "\n")
	if len(logLines) == 1 && logLines[0] == "" {
		logLines = []string{}
	}

	// Response
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success":       true,
		"log_type":      logType,
		"lines":         logLines,
		"total_lines":   len(logLines),
		"visible_lines": len(logLines),
		"tail_mode":     tailMode,
		"search_filter": searchFilter,
	})
}

// LogFileHandler serves individual log files from /var/log/nftban/
func LogFileHandler(w http.ResponseWriter, r *http.Request) {
	// Get log file path from query parameter: /api/v1/logs?path=/var/log/nftban/portscan.log
	logPath := r.URL.Query().Get("path")
	if logPath == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Missing 'path' parameter"})
		return
	}

	// SECURITY FIX: URL-decode path first to prevent encoding bypass attacks
	decodedPath, err := url.QueryUnescape(logPath)
	if err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid path encoding"})
		return
	}

	// SECURITY FIX: Clean and normalize the path to resolve any traversal attempts
	cleanPath := filepath.Clean(decodedPath)

	// Security: Validate log path (must be under configured log dir)
	baseDir := filepath.Clean(getLogDir())
	if !strings.HasPrefix(cleanPath, baseDir+string(filepath.Separator)) {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: fmt.Sprintf("Log file must be under %s", baseDir)})
		return
	}

	// SECURITY FIX: Check for symlink attacks - resolve symlinks and verify final path
	realPath, err := filepath.EvalSymlinks(cleanPath)
	if err != nil {
		// File might not exist yet or is inaccessible
		if !os.IsNotExist(err) {
			log.Printf("[ERROR] Failed to evaluate symlinks for %s: %v", cleanPath, err)
			respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Invalid log path"})
			return
		}
		// File doesn't exist, use the cleaned path
		realPath = cleanPath
	} else {
		// Verify the resolved path is still under base directory
		realBaseDir, _ := filepath.EvalSymlinks(baseDir)
		if realBaseDir == "" {
			realBaseDir = baseDir
		}
		if !strings.HasPrefix(realPath, realBaseDir+string(filepath.Separator)) {
			log.Printf("[SECURITY] Symlink escape attempt detected: %s -> %s", cleanPath, realPath)
			respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Invalid log path"})
			return
		}
	}

	// Security: Only allow .log files (not .conf, .sh, etc.)
	if !strings.HasSuffix(realPath, ".log") {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Only .log files are allowed"})
		return
	}

	// Use the validated real path for file operations
	logPath = realPath

	// Check if file exists
	fileInfo, err := os.Stat(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			respondJSON(w, http.StatusNotFound, ErrorResponse{Error: "Log file not found"})
		} else {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to access log file"})
		}
		return
	}

	// If today's log is empty, try yesterday's compressed log
	if fileInfo.Size() == 0 {
		gzLogPath := logPath + ".1.gz"
		if gzInfo, err := os.Stat(gzLogPath); err == nil {
			// Yesterday's log exists, decompress and read it
			output, err := execCommand("zcat", gzLogPath)
			if err == nil {
				// Get last N lines from decompressed content
				linesParam := r.URL.Query().Get("lines")

				// Split into lines and get last N
				allLines := strings.Split(strings.TrimSpace(output), "\n")
				if linesParam == "all" || len(allLines) <= 100 {
					content := strings.Join(allLines, "\n")
					respondJSON(w, http.StatusOK, map[string]interface{}{
						"success": true,
						"data": map[string]interface{}{
							"content":  content,
							"size":     gzInfo.Size(),
							"modified": gzInfo.ModTime().Unix(),
							"lines":    len(allLines),
							"note":     "Today's log is empty, showing yesterday's log",
						},
					})
					return
				} else {
					// Get last N lines
					lineCount := 100
					if linesParam != "" {
						if n, err := strconv.Atoi(linesParam); err == nil {
							lineCount = n
						}
					}
					start := len(allLines) - lineCount
					if start < 0 {
						start = 0
					}
					content := strings.Join(allLines[start:], "\n")
					respondJSON(w, http.StatusOK, map[string]interface{}{
						"success": true,
						"data": map[string]interface{}{
							"content":  content,
							"size":     gzInfo.Size(),
							"modified": gzInfo.ModTime().Unix(),
							"lines":    lineCount,
							"note":     "Today's log is empty, showing yesterday's log",
						},
					})
					return
				}
			}
		}
	}

	// Get number of lines to return (default: 100, max: all)
	linesParam := r.URL.Query().Get("lines")
	lines := "100"
	if linesParam != "" {
		lines = linesParam
	}

	// Read log file
	var content string
	if lines == "all" {
		// Read entire file
		data, err := os.ReadFile(logPath)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read log file"})
			return
		}
		content = string(data)
	} else {
		// Use tail to get last N lines
		output, err := execCommand("tail", "-n", lines, logPath)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read log file"})
			return
		}
		content = output
	}

	// Return log content in standard response format
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"content":  content,
			"size":     fileInfo.Size(),
			"modified": fileInfo.ModTime().Unix(),
			"lines":    strings.Count(content, "\n"),
		},
	})
}

// PortScanLogsHandler fetches PortScan detection logs with pagination
func PortScanLogsHandler(w http.ResponseWriter, r *http.Request) {
	lines := r.URL.Query().Get("lines")
	if lines == "" {
		lines = "100"
	}

	// Fetch portscan logs from nftban
	output, err := execNFTBanCommand("logs", "--lines", lines, "--json")
	if err != nil {
		// Try systemd journal if direct logs fail
		cmd := exec.Command("journalctl", "-u", "nftban-portscan", "-n", lines, "--no-pager", "-o", "json")
		journalOutput, jErr := cmd.Output()
		if jErr != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to fetch portscan logs"})
			return
		}

		var logs []map[string]interface{}
		for _, line := range strings.Split(string(journalOutput), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var entry map[string]interface{}
			if err := json.Unmarshal([]byte(line), &entry); err == nil {
				logs = append(logs, entry)
			}
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"logs":  logs,
			"count": len(logs),
		})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse portscan logs"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// SystemLogsHandler provides unified system logs viewer
func SystemLogsHandler(w http.ResponseWriter, r *http.Request) {
	// Get query parameters
	service := r.URL.Query().Get("service") // nftban, fail2ban, sshd, etc
	lines := r.URL.Query().Get("lines")
	priority := r.URL.Query().Get("priority") // emerg, alert, crit, err, warning, notice, info, debug

	if lines == "" {
		lines = "100"
	}

	// Build journalctl command
	args := []string{
		"-n", lines,
		"--no-pager",
		"-o", "json",
	}

	if service != "" {
		args = append(args, "-u", service)
	}

	if priority != "" {
		args = append(args, "-p", priority)
	}

	cmd := exec.Command("journalctl", args...)
	output, err := cmd.Output()
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to fetch system logs"})
		return
	}

	// Parse JSON output
	var logs []map[string]interface{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]interface{}
		if err := json.Unmarshal([]byte(line), &entry); err == nil {
			logs = append(logs, entry)
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"logs":  logs,
		"count": len(logs),
		"filters": map[string]string{
			"service":  service,
			"lines":    lines,
			"priority": priority,
		},
	})
}

// execTailGrepSafe executes tail and grep commands safely using Go pipes
// SECURITY FIX: This replaces shell execution to prevent command injection
// The search filter is passed as a direct argument to grep, not through shell interpolation
func execTailGrepSafe(logFile string, lines int, searchFilter string) (string, error) {
	// Create tail command
	tailCmd := exec.Command("tail", "-n", strconv.Itoa(lines), logFile)

	// Create grep command with -i for case-insensitive search
	// Search filter is passed as argument, not shell-interpolated
	grepCmd := exec.Command("grep", "-i", searchFilter)

	// Connect tail stdout to grep stdin using a pipe
	tailOut, err := tailCmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create tail pipe: %w", err)
	}

	grepCmd.Stdin = tailOut

	// Capture grep output
	grepOut, err := grepCmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create grep pipe: %w", err)
	}

	// Start both commands
	if err := tailCmd.Start(); err != nil {
		return "", fmt.Errorf("failed to start tail: %w", err)
	}

	if err := grepCmd.Start(); err != nil {
		tailCmd.Process.Kill()
		return "", fmt.Errorf("failed to start grep: %w", err)
	}

	// Read grep output
	output, err := io.ReadAll(grepOut)
	if err != nil {
		return "", fmt.Errorf("failed to read grep output: %w", err)
	}

	// Wait for commands to complete
	tailCmd.Wait()
	grepErr := grepCmd.Wait()

	// grep returns exit code 1 when no matches found - this is not an error
	if grepErr != nil {
		if exitErr, ok := grepErr.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			// No matches found
			return "", nil
		}
		return "", grepErr
	}

	return string(output), nil
}
