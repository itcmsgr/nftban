// =============================================================================
// NFTBan - GOTH GUI Handlers (Professional Dashboard)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="goth"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-15"
// meta:description="GOTH GUI handlers - Go + Templ + HTMX dashboard"
// meta:input="HTTP requests"
// meta:output="HTML fragments via Templ"
// meta:depends="github.com/gorilla/mux,github.com/itcmsgr/nftban/internal/ui"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/mux"
	"github.com/itcmsgr/nftban/internal/ui"
	"github.com/itcmsgr/nftban/internal/ui/pages"
	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/netutil"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/session"
	"github.com/itcmsgr/nftban/pkg/state"
	"github.com/itcmsgr/nftban/pkg/util"
)

// GOTHHandlers holds dependencies for GOTH UI handlers
type GOTHHandlers struct {
	Auth         *auth.PAMAuth
	SessionStore *session.Store
}

// Network stats tracking for bandwidth calculation (protected by mutex for thread safety)
var (
	netStatsMu     sync.Mutex
	lastNetRxBytes uint64
	lastNetTxBytes uint64
	lastNetTime    time.Time
)

// =============================================================================
// RBAC GROUP CONSTANTS AND HELPERS (R05)
// =============================================================================
//
// NFTBan 3-Group Security Model for Web UI:
//   - nftban (operator): full access - ban/unban, whitelist, feeds, config, restart
//   - nftban-auditor:    read-only - view pages, stats, logs (NO actions)
//   - nftban-panel:      dashboard + stats only (limited view, NO actions)
//
// All mutating handlers check group membership before proceeding.
// Read-only handlers allow all authenticated users.
// =============================================================================

// validFeedNameRegex validates feed names to prevent shell metacharacter injection (R-feed)
// Only allows alphanumeric characters, dots, underscores, and hyphens; must start with alphanum
var validFeedNameRegex = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]*$`)

// getSessionFromRequest retrieves the session from the request cookie.
// Returns nil if no valid session exists (caller should have RequireSession middleware).
func (h *GOTHHandlers) getSessionFromRequest(r *http.Request) *session.Session {
	cookie, err := r.Cookie("session_id")
	if err != nil {
		return nil
	}
	sess, err := h.SessionStore.Get(cookie.Value)
	if err != nil {
		return nil
	}
	return sess
}

// requireOperator checks if the authenticated user is in the nftban (operator) group.
// Operators can: ban/unban, manage whitelist, manage feeds, change config, restart services.
// Returns true if authorized, false if not (and sends 403 response).
func (h *GOTHHandlers) requireOperator(w http.ResponseWriter, r *http.Request) bool {
	sess := h.getSessionFromRequest(r)
	if sess == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return false
	}
	if !sess.HasGroup("nftban") {
		log.Printf("[RBAC] User %s denied operator access (groups: %v)", sess.Username, sess.Groups)
		http.Error(w, "Forbidden: operator role required", http.StatusForbidden)
		return false
	}
	return true
}

// requireCanAct checks if the authenticated user can perform runtime actions (ban/unban/whitelist).
// Includes: nftban (admin) and nftban-panel (panel operators).
// Returns true if authorized, false if not (and sends 403 response).
// TODO(v1.19.1): Wire into action handlers (ban, unban, whitelist, flush).
//
//lint:ignore U1000 RBAC guard prepared for v1.19.1 action handler integration
func (h *GOTHHandlers) requireCanAct(w http.ResponseWriter, r *http.Request) bool {
	sess := h.getSessionFromRequest(r)
	if sess == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return false
	}
	if !sess.HasGroup("nftban") && !sess.HasGroup("nftban-panel") {
		log.Printf("[RBAC] User %s denied action access (groups: %v)", sess.Username, sess.Groups)
		http.Error(w, "Forbidden: action role required", http.StatusForbidden)
		return false
	}
	return true
}

// jsonMarshalHXTrigger builds a properly JSON-escaped HX-Trigger header value.
// SECURITY FIX (R35): Prevents XSS via unescaped service/feed names in HTMX trigger headers.
func jsonMarshalHXTrigger(message, msgType string) string {
	payload := map[string]interface{}{
		"showToast": map[string]string{
			"message": message,
			"type":    msgType,
		},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		// Fallback to safe static string on marshal error
		return `{"showToast": {"message": "Operation completed", "type": "info"}}`
	}
	return string(data)
}

// nftReadOnly executes a read-only nft command for status display.
// v1.19.0: Centralizes remaining nft calls (R20). These are read-only queries
// (list tables, list counters) that don't modify firewall state.
// WRITE operations MUST go through daemon IPC — see pkg/api/ handlers.
func nftReadOnly(args ...string) ([]byte, error) {
	return exec.Command("nft", args...).CombinedOutput()
}

// validateFeedName checks that a feed name contains only safe characters (R-feed).
// Returns an error if the name contains shell metacharacters or is invalid.
func validateFeedName(name string) error {
	if name == "" {
		return fmt.Errorf("feed name is required")
	}
	if len(name) > 128 {
		return fmt.Errorf("feed name too long (max 128 characters)")
	}
	if !validFeedNameRegex.MatchString(name) {
		return fmt.Errorf("invalid feed name: must match [a-zA-Z0-9][a-zA-Z0-9._-]*")
	}
	return nil
}

// NewGOTHHandlers creates a new GOTHHandlers instance
func NewGOTHHandlers(authService *auth.PAMAuth, sessionStore *session.Store) *GOTHHandlers {
	return &GOTHHandlers{
		Auth:         authService,
		SessionStore: sessionStore,
	}
}

// =============================================================================
// PAGE HANDLERS
// =============================================================================

// HandleLogin renders the login page
func (h *GOTHHandlers) HandleLogin(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("session_id"); err == nil {
		if _, err := h.SessionStore.Get(cookie.Value); err == nil {
			http.Redirect(w, r, "/ui/", http.StatusSeeOther)
			return
		}
	}
	errorMsg := r.URL.Query().Get("error")
	pages.Login(errorMsg).Render(r.Context(), w)
}

// HandleDashboard renders the dashboard
func (h *GOTHHandlers) HandleDashboard(w http.ResponseWriter, r *http.Request) {
	data := h.getDashboardData()
	pages.Dashboard(data).Render(r.Context(), w)
}

// HandleHealth renders health page
func (h *GOTHHandlers) HandleHealth(w http.ResponseWriter, r *http.Request) {
	data := h.getHealthData()
	pages.Health(data).Render(r.Context(), w)
}

// HandleModules renders modules page
func (h *GOTHHandlers) HandleModules(w http.ResponseWriter, r *http.Request) {
	data := h.getModulesData()
	pages.Modules(data).Render(r.Context(), w)
}

// HandleInventory renders inventory page
func (h *GOTHHandlers) HandleInventory(w http.ResponseWriter, r *http.Request) {
	data := h.getInventoryData()
	pages.Inventory(data).Render(r.Context(), w)
}

// HandleFragInventory renders inventory fragment for HTMX
func (h *GOTHHandlers) HandleFragInventory(w http.ResponseWriter, r *http.Request) {
	data := h.getInventoryData()
	pages.InventoryContent(data).Render(r.Context(), w)
}

// HandleBans renders bans management page
func (h *GOTHHandlers) HandleBans(w http.ResponseWriter, r *http.Request) {
	data := h.getBansData(r)
	pages.Bans(data).Render(r.Context(), w)
}

// HandleWhitelist renders whitelist management page
func (h *GOTHHandlers) HandleWhitelist(w http.ResponseWriter, r *http.Request) {
	data := h.getWhitelistData()
	pages.Whitelist(data).Render(r.Context(), w)
}

// HandleFragBansTable renders bans table fragment for HTMX
func (h *GOTHHandlers) HandleFragBansTable(w http.ResponseWriter, r *http.Request) {
	data := h.getBansData(r)
	pages.BansTableFragment(data).Render(r.Context(), w)
}

// HandleFragWhitelistTable renders whitelist table fragment for HTMX
func (h *GOTHHandlers) HandleFragWhitelistTable(w http.ResponseWriter, r *http.Request) {
	data := h.getWhitelistData()
	pages.WhitelistTableFragment(data).Render(r.Context(), w)
}

// HandleEvents renders the security events page
func (h *GOTHHandlers) HandleEvents(w http.ResponseWriter, r *http.Request) {
	data := h.getEventsData(r)
	pages.Events(data).Render(r.Context(), w)
}

// HandleFragEventsTable renders events table fragment for HTMX
func (h *GOTHHandlers) HandleFragEventsTable(w http.ResponseWriter, r *http.Request) {
	data := h.getEventsData(r)
	pages.EventsTableFragment(data).Render(r.Context(), w)
}

// HandleTools renders the diagnostic tools page
func (h *GOTHHandlers) HandleTools(w http.ResponseWriter, r *http.Request) {
	data := h.getToolsData()
	pages.Tools(data).Render(r.Context(), w)
}

// HandleFeeds renders the threat feeds management page
func (h *GOTHHandlers) HandleFeeds(w http.ResponseWriter, r *http.Request) {
	data := h.getFeedsPageData()
	pages.Feeds(data).Render(r.Context(), w)
}

// HandleFragFeeds renders feeds content fragment for HTMX
func (h *GOTHHandlers) HandleFragFeeds(w http.ResponseWriter, r *http.Request) {
	data := h.getFeedsPageData()
	pages.FeedsContentFragment(data).Render(r.Context(), w)
}

// HandleFragLogs renders log entries fragment for HTMX
func (h *GOTHHandlers) HandleFragLogs(w http.ResponseWriter, r *http.Request) {
	logs := h.getRecentLogs(r.URL.Query().Get("level"))
	pages.LogEntriesFragment(logs).Render(r.Context(), w)
}

// HandleToolsIPCheck handles IP check/emulate requests
func (h *GOTHHandlers) HandleToolsIPCheck(w http.ResponseWriter, r *http.Request) {
	ip := r.FormValue("ip")
	if ip == "" {
		http.Error(w, "IP required", http.StatusBadRequest)
		return
	}

	result := h.checkIP(ip)
	pages.IPCheckResultFragment(result).Render(r.Context(), w)
}

// HandleToolsGeoIP handles GeoIP lookup requests
func (h *GOTHHandlers) HandleToolsGeoIP(w http.ResponseWriter, r *http.Request) {
	ip := r.FormValue("ip")
	if ip == "" {
		http.Error(w, "IP required", http.StatusBadRequest)
		return
	}

	result := h.geoLookup(ip)
	pages.GeoLookupResultFragment(result).Render(r.Context(), w)
}

// HandleToolsSearch handles cross-set IP search requests
func (h *GOTHHandlers) HandleToolsSearch(w http.ResponseWriter, r *http.Request) {
	ip := r.FormValue("ip")
	if ip == "" {
		http.Error(w, "IP required", http.StatusBadRequest)
		return
	}

	result := h.searchIP(ip)
	pages.SearchResultFragment(result).Render(r.Context(), w)
}

// =============================================================================
// FRAGMENT HANDLERS (HTMX)
// =============================================================================

func (h *GOTHHandlers) HandleFragIdentity(w http.ResponseWriter, r *http.Request) {
	pages.IdentityFragment(h.getIdentity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragSecurity(w http.ResponseWriter, r *http.Request) {
	pages.SecurityFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragNetwork(w http.ResponseWriter, r *http.Request) {
	pages.NetworkFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragResources(w http.ResponseWriter, r *http.Request) {
	pages.ResourcesFragment(h.getResources()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragModules(w http.ResponseWriter, r *http.Request) {
	pages.ModulesFragment(h.getModulesList()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragRecent(w http.ResponseWriter, r *http.Request) {
	pages.RecentFragment(h.getRecentBans()).Render(r.Context(), w)
}

// Backwards compat
func (h *GOTHHandlers) HandleFragSummary(w http.ResponseWriter, r *http.Request) {
	pages.SecurityFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragSystem(w http.ResponseWriter, r *http.Request) {
	pages.ResourcesFragment(h.getResources()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragHealth(w http.ResponseWriter, r *http.Request) {
	pages.HealthFragment(h.getHealthItems()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragServicesQuick(w http.ResponseWriter, r *http.Request) {
	pages.HealthFragment(h.getHealthItems()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragBanStats(w http.ResponseWriter, r *http.Request) {
	pages.SecurityFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragWhitelistStats(w http.ResponseWriter, r *http.Request) {
	pages.WhitelistStatsFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragHealthAll(w http.ResponseWriter, r *http.Request) {
	pages.HealthContentFragment(h.getHealthData()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragModulesList(w http.ResponseWriter, r *http.Request) {
	pages.ModulesListFragment(h.getModulesList()).Render(r.Context(), w)
}

// =============================================================================
// ACTION HANDLERS
// =============================================================================

func (h *GOTHHandlers) HandleActionLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
		return
	}

	username := r.FormValue("username")
	password := r.FormValue("password")

	user, err := h.Auth.Authenticate(username, password)
	if err != nil {
		log.Printf("[GOTH] Login failed for user %s: %v", username, err)
		http.Redirect(w, r, "/ui/login?error=Invalid+credentials", http.StatusSeeOther)
		return
	}

	sess, err := h.SessionStore.Create(user.Username, user.Groups, r.RemoteAddr)
	if err != nil {
		log.Printf("[GOTH] Session create failed: %v", err)
		http.Redirect(w, r, "/ui/login?error=Session+error", http.StatusSeeOther)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    sess.Token,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   1800, // 30 minutes - matches session store timeout
	})

	log.Printf("[GOTH] User %s logged in successfully", username)
	http.Redirect(w, r, "/ui/", http.StatusSeeOther)
}

func (h *GOTHHandlers) HandleActionLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("session_id"); err == nil {
		h.SessionStore.Delete(cookie.Value)
	}
	// Clear cookie with all security flags for consistency
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
	http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
}

// HandleIPCheck handles quick IP lookup
func (h *GOTHHandlers) HandleIPCheck(w http.ResponseWriter, r *http.Request) {
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		w.Write([]byte(""))
		return
	}

	// Validate IP format
	ip = strings.TrimSpace(ip)
	if !netutil.IsValidIP(ip) {
		fmt.Fprintf(w, `<span style="color: var(--text-muted);">Invalid IP format</span>`)
		return
	}

	result := ui.IPCheckResult{IP: ip, Status: "clean"}

	// Use nftban check --json for comprehensive status
	if output, err := execNFTBanCommand("check", ip, "--json"); err == nil {
		var checkResult map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &checkResult) == nil {
			// Parse status
			if status, ok := checkResult["status"].(string); ok {
				statusLower := strings.ToLower(status)
				if strings.Contains(statusLower, "blocked") || strings.Contains(statusLower, "banned") {
					result.Status = "banned"
				} else if strings.Contains(statusLower, "whitelisted") || strings.Contains(statusLower, "allowed") {
					result.Status = "whitelisted"
				}
			}
			// Parse additional info
			if reason, ok := checkResult["reason"].(string); ok {
				result.Reason = reason
			}
			if module, ok := checkResult["module"].(string); ok {
				result.Module = module
			}
			if since, ok := checkResult["banned_since"].(string); ok {
				result.BannedSince = since
			}
			if country, ok := checkResult["country"].(string); ok {
				result.Country = country
			}
			// Check matched set for more context
			if matchedSet, ok := checkResult["matched_set"].(string); ok {
				if strings.Contains(matchedSet, "whitelist") {
					result.Status = "whitelisted"
				} else if strings.Contains(matchedSet, "blacklist") {
					result.Status = "banned"
				}
			}
		}
	}

	// Render result
	pages.IPCheckResultFragment(result).Render(r.Context(), w)
}

// HandleFlushTemp flushes temporary bans
func (h *GOTHHandlers) HandleFlushTemp(w http.ResponseWriter, r *http.Request) {
	// RBAC: flush requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	log.Printf("[GOTH] Flush temp bans requested")

	// Execute flush command
	if _, err := execNFTBanCommand("flush", "--temp"); err != nil {
		// Try alternative command
		if _, err := execNFTBanCommand("flush-temp"); err != nil {
			log.Printf("[GOTH] Flush temp failed: %v", err)
			w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Failed to flush temp bans", "error"))
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
	}

	log.Printf("[GOTH] Temp bans flushed successfully")
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Temporary bans cleared", "success"))
	w.WriteHeader(http.StatusOK)
}

// SECURITY FIX: Explicit allowlist of services that can be restarted
// This prevents command injection via service name manipulation
var allowedRestartServices = map[string]bool{
	"nftban-core":      true,
	"nftban-ui":        true,
	"nftban-collector": true,
	"nftban-watchdog":  true,
	"nftband":          true,
}

// HandleRestartService restarts a systemd service
func (h *GOTHHandlers) HandleRestartService(w http.ResponseWriter, r *http.Request) {
	// RBAC: service restart requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	vars := mux.Vars(r)
	serviceName := vars["service"]

	// SECURITY FIX: Use explicit allowlist instead of prefix check
	// Prefix check alone could allow "nftban-../../malicious" type attacks
	if !allowedRestartServices[serviceName] {
		log.Printf("[GOTH] Service not in allowlist: %s", serviceName)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Invalid service", "error"))
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	log.Printf("[GOTH] Restart service requested: %s", serviceName)

	// Execute restart
	if output, err := exec.Command("systemctl", "restart", serviceName).CombinedOutput(); err != nil {
		log.Printf("[GOTH] Restart %s failed: %v - %s", serviceName, err, string(output))
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(fmt.Sprintf("Failed to restart %s", serviceName), "error"))
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	log.Printf("[GOTH] Service %s restarted successfully", serviceName)
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(fmt.Sprintf("%s restarted", serviceName), "success"))
	w.WriteHeader(http.StatusOK)
}

// HandleHealthFix runs auto-heal to fix issues
func (h *GOTHHandlers) HandleHealthFix(w http.ResponseWriter, r *http.Request) {
	// RBAC: health fix requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	log.Printf("[GOTH] Health auto-fix requested")

	// Execute health check with auto-heal flag
	output, err := execNFTBanCommand("health", "check", "--auto-heal")
	if err != nil {
		log.Printf("[GOTH] Health auto-fix failed: %v - %s", err, output)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Auto-heal completed with errors", "warning"))
	} else {
		log.Printf("[GOTH] Health auto-fix completed successfully")
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Auto-heal completed", "success"))
	}

	// Refresh the health content
	data := h.getHealthData()
	pages.HealthContentFragment(data).Render(r.Context(), w)
}

// HandleSyncFeeds syncs all threat feeds
func (h *GOTHHandlers) HandleSyncFeeds(w http.ResponseWriter, r *http.Request) {
	// RBAC: feed sync requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	log.Printf("[GOTH] Sync all feeds requested")

	// Execute feeds sync command
	if _, err := execNFTBanCommand("feeds", "sync"); err != nil {
		log.Printf("[GOTH] Feed sync failed: %v", err)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Feed sync failed", "error"))
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	log.Printf("[GOTH] All feeds synced successfully")
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Feeds synced successfully", "success"))
	w.WriteHeader(http.StatusOK)
}

// HandleSyncFeed syncs a single threat feed
func (h *GOTHHandlers) HandleSyncFeed(w http.ResponseWriter, r *http.Request) {
	// RBAC: feed sync requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	vars := mux.Vars(r)
	feedName := vars["name"]

	// SECURITY FIX (R-feed): Validate feed name to prevent shell metacharacter injection
	if err := validateFeedName(feedName); err != nil {
		log.Printf("[GOTH] Invalid feed name rejected: %s - %v", feedName, err)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Invalid feed name", "error"))
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	log.Printf("[GOTH] Sync feed requested: %s", feedName)

	// Execute feed sync command
	if _, err := execNFTBanCommand("feeds", "sync", feedName); err != nil {
		log.Printf("[GOTH] Feed sync failed for %s: %v", feedName, err)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(fmt.Sprintf("Failed to sync %s", feedName), "error"))
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	log.Printf("[GOTH] Feed %s synced successfully", feedName)
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(fmt.Sprintf("%s synced", feedName), "success"))
	w.WriteHeader(http.StatusOK)
}

// HandleFeedToggle enables or disables a threat feed
func (h *GOTHHandlers) HandleFeedToggle(w http.ResponseWriter, r *http.Request) {
	// RBAC: feed toggle requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	vars := mux.Vars(r)
	feedName := vars["name"]

	// SECURITY FIX (R-feed): Validate feed name to prevent shell metacharacter injection
	if err := validateFeedName(feedName); err != nil {
		log.Printf("[GOTH] Invalid feed name rejected: %s - %v", feedName, err)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger("Invalid feed name", "error"))
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	log.Printf("[GOTH] Feed toggle requested: %s", feedName)

	// Check current status and toggle
	// First try to get current status
	enabled := true
	if output, err := execNFTBanCommand("feeds", "status", feedName, "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
			enabled = getBool(status, "enabled")
		}
	}

	// Toggle
	action := "enable"
	if enabled {
		action = "disable"
	}

	if _, err := execNFTBanCommand("feeds", action, feedName); err != nil {
		log.Printf("[GOTH] Feed %s %s failed: %v", action, feedName, err)
		w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(fmt.Sprintf("Failed to %s %s", action, feedName), "error"))
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	log.Printf("[GOTH] Feed %s %sd successfully", feedName, action)
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(fmt.Sprintf("%s %sd", feedName, action), "success"))
	w.WriteHeader(http.StatusOK)
}

// =============================================================================
// BULK OPERATIONS - Multi-select ban/unban operations
// =============================================================================

// BulkOperationRequest represents the JSON request for bulk operations
type BulkOperationRequest struct {
	IPs []string `json:"ips"`
}

// BulkOperationResponse represents the JSON response for bulk operations
type BulkOperationResponse struct {
	Success      bool     `json:"success"`
	Total        int      `json:"total"`
	SuccessCount int      `json:"success_count"`
	FailedCount  int      `json:"failed_count"`
	FailedIPs    []string `json:"failed_ips,omitempty"`
	Message      string   `json:"message"`
}

// bulkOperationType defines the type of bulk operation
type bulkOperationType string

const (
	bulkOpUnban  bulkOperationType = "unban"
	bulkOpDelete bulkOperationType = "delete"
)

// executeBulkOperation handles the common logic for bulk unban/delete operations
// Returns the response to be sent to the client
func executeBulkOperation(ips []string, opType bulkOperationType) BulkOperationResponse {
	var successCount, failedCount int
	var failedIPs []string

	opName := string(opType)

	for _, ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}

		// Validate IP format
		if !netutil.IsValidIP(ip) {
			failedCount++
			failedIPs = append(failedIPs, ip)
			log.Printf("[GOTH] Bulk %s: invalid IP format: %s", opName, ip)
			continue
		}

		// Execute the appropriate command
		var output string
		var err error
		var hasSuccess bool

		if opType == bulkOpDelete {
			// Try permanent delete first, fall back to regular unban
			output, err = execNFTBanCommand("unban", ip, "--permanent")
			hasSuccess = strings.Contains(output, "removed") ||
				strings.Contains(output, "deleted") ||
				strings.Contains(output, "unbanned") ||
				strings.Contains(output, "success")

			// If permanent flag not supported, try regular unban
			if err != nil && strings.Contains(output, "unknown flag") {
				output, err = execNFTBanCommand("unban", ip)
				hasSuccess = strings.Contains(output, "removed") ||
					strings.Contains(output, "unbanned") ||
					strings.Contains(output, "success")
			}
		} else {
			// Regular unban
			output, err = execNFTBanCommand("unban", ip)
			hasSuccess = strings.Contains(output, "removed") ||
				strings.Contains(output, "unbanned") ||
				strings.Contains(output, "success")
		}

		if err != nil && !hasSuccess {
			failedCount++
			failedIPs = append(failedIPs, ip)
			log.Printf("[GOTH] Bulk %s failed for %s: %v", opName, ip, err)
		} else {
			successCount++
			log.Printf("[GOTH] Bulk %s success: %s", opName, ip)
		}
	}

	// Build appropriate message
	var message string
	if opType == bulkOpDelete {
		message = fmt.Sprintf("Deleted %d of %d bans", successCount, len(ips))
	} else {
		message = fmt.Sprintf("Unbanned %d of %d IPs", successCount, len(ips))
	}

	return BulkOperationResponse{
		Success:      failedCount == 0,
		Total:        len(ips),
		SuccessCount: successCount,
		FailedCount:  failedCount,
		FailedIPs:    failedIPs,
		Message:      message,
	}
}

// HandleBulkUnban handles bulk unban requests
// POST /ui/action/bulk-unban
// Accepts JSON array of IPs and unbans each one
func (h *GOTHHandlers) HandleBulkUnban(w http.ResponseWriter, r *http.Request) {
	// RBAC: bulk unban requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	var req BulkOperationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(BulkOperationResponse{
			Success: false,
			Message: "Invalid request body",
		})
		return
	}

	if len(req.IPs) == 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(BulkOperationResponse{
			Success: false,
			Message: "No IPs provided",
		})
		return
	}

	log.Printf("[GOTH] Bulk unban requested for %d IPs", len(req.IPs))

	response := executeBulkOperation(req.IPs, bulkOpUnban)

	log.Printf("[GOTH] Bulk unban completed: %d success, %d failed", response.SuccessCount, response.FailedCount)

	w.Header().Set("Content-Type", "application/json")
	if response.FailedCount > 0 && response.SuccessCount == 0 {
		w.WriteHeader(http.StatusInternalServerError)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	json.NewEncoder(w).Encode(response)
}

// HandleBulkDelete handles bulk delete (permanent removal) requests
// POST /ui/action/bulk-delete
// Accepts JSON array of IPs and permanently deletes each ban
func (h *GOTHHandlers) HandleBulkDelete(w http.ResponseWriter, r *http.Request) {
	// RBAC: bulk delete requires operator role (R05)
	if !h.requireOperator(w, r) {
		return
	}

	var req BulkOperationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(BulkOperationResponse{
			Success: false,
			Message: "Invalid request body",
		})
		return
	}

	if len(req.IPs) == 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(BulkOperationResponse{
			Success: false,
			Message: "No IPs provided",
		})
		return
	}

	log.Printf("[GOTH] Bulk delete requested for %d IPs", len(req.IPs))

	response := executeBulkOperation(req.IPs, bulkOpDelete)

	log.Printf("[GOTH] Bulk delete completed: %d success, %d failed", response.SuccessCount, response.FailedCount)

	w.Header().Set("Content-Type", "application/json")
	if response.FailedCount > 0 && response.SuccessCount == 0 {
		w.WriteHeader(http.StatusInternalServerError)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	json.NewEncoder(w).Encode(response)
}

// RequireSession middleware
func (h *GOTHHandlers) RequireSession(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_id")
		if err != nil {
			http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
			return
		}
		if _, err := h.SessionStore.Get(cookie.Value); err != nil {
			http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
			return
		}
		next(w, r)
	}
}

// =============================================================================
// DATA FETCHERS - Using existing CLI commands only
// =============================================================================

func (h *GOTHHandlers) getDashboardData() ui.DashboardData {
	return ui.DashboardData{
		Identity:   h.getIdentity(),
		Security:   h.getSecurity(),
		Resources:  h.getResources(),
		Modules:    h.getModulesList(),
		RecentBans: h.getRecentBans(),
		Theme:      "dark",
	}
}

func (h *GOTHHandlers) getIdentity() ui.SystemIdentity {
	id := ui.SystemIdentity{
		Hostname:      "unknown",
		Kernel:        "unknown",
		Uptime:        "N/A",
		UptimeSeconds: 0,
		NFTBanVersion: "1.0.0",
		PanelMode:     "active",
		Heartbeat:     true,
	}

	// Try nftban status --json first for consolidated data
	if output, err := execNFTBanCommand("status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
			if hostname, ok := status["hostname"].(string); ok {
				id.Hostname = hostname
			}
			if version, ok := status["version"].(string); ok {
				id.NFTBanVersion = version
			}
			// System section
			if sys, ok := status["system"].(map[string]interface{}); ok {
				if kernel, ok := sys["kernel"].(string); ok {
					id.Kernel = kernel
				}
				if uptime, ok := sys["uptime"].(string); ok {
					id.Uptime = uptime
				}
			}
		}
	}

	// Fallback for hostname
	if id.Hostname == "unknown" {
		if output, err := exec.Command("hostname").Output(); err == nil {
			id.Hostname = strings.TrimSpace(string(output))
		}
	}

	// Fallback for kernel
	if id.Kernel == "unknown" {
		if output, err := exec.Command("uname", "-r").Output(); err == nil {
			id.Kernel = strings.TrimSpace(string(output))
		}
	}

	// Fallback for uptime
	if id.Uptime == "N/A" {
		if output, err := exec.Command("uptime", "-p").Output(); err == nil {
			id.Uptime = strings.TrimSpace(string(output))
		}
	}

	// Uptime seconds for JS counter (always from /proc)
	if content, err := os.ReadFile("/proc/uptime"); err == nil {
		parts := strings.Fields(string(content))
		if len(parts) > 0 {
			if secs, err := strconv.ParseFloat(parts[0], 64); err == nil {
				id.UptimeSeconds = int64(secs)
			}
		}
	}

	// Fallback for version
	if id.NFTBanVersion == "1.0.0" {
		if output, err := execNFTBanCommand("--version"); err == nil {
			id.NFTBanVersion = strings.TrimSpace(string(output))
		}
	}

	// Panel mode based on service status
	id.PanelMode = h.getPanelMode()

	return id
}

func (h *GOTHHandlers) getPanelMode() string {
	// Primary check: nftables must be working
	output, err := nftReadOnly("list", "tables")
	if err != nil {
		return "error" // nftables not working at all
	}

	// Check if nftban table exists
	hasTable := strings.Contains(string(output), "nftban")
	if !hasTable {
		return "warning" // nftables works but nftban not initialized
	}

	// Optional: check if core daemon is running (degraded if not)
	if err := exec.Command("systemctl", "is-active", "--quiet", "nftban-core").Run(); err != nil {
		// Daemon not running but nftables is configured - still functional
		return "active" // CLI-only mode is fine
	}

	return "active"
}

// getSecurityFromSharedState retrieves ban/whitelist counts from the in-memory shared state.
// This is the fastest path when nftband/watchdog is running and updating state via netlink.
func getSecurityFromSharedState() (sec ui.SecurityKPIs, ok bool) {
	if !state.IsInitialized() || state.IsStale(30*time.Second) {
		return sec, false
	}
	snap := state.Get()
	sec.BansIPv4 = int(snap.BannedIPv4)
	sec.BansIPv6 = int(snap.BannedIPv6)
	sec.BansTotal = int(snap.BannedIPv4 + snap.BannedIPv6)
	sec.WhitelistIPv4 = int(snap.WhitelistIPv4)
	sec.WhitelistIPv6 = int(snap.WhitelistIPv6)
	sec.WhitelistTotal = int(snap.WhitelistIPv4 + snap.WhitelistIPv6)
	return sec, sec.BansTotal > 0 || sec.WhitelistTotal > 0
}

// getSecurityFromStatsCLI retrieves detailed ban/whitelist stats via 'nftban stats --json'.
// Returns populated stats if successful, empty struct otherwise.
func getSecurityFromStatsCLI() ui.SecurityKPIs {
	sec := ui.SecurityKPIs{}
	output, err := execNFTBanCommand("stats", "--json")
	if err != nil {
		return sec
	}
	var stats map[string]interface{}
	if json.Unmarshal([]byte(util.ExtractJSON(output)), &stats) != nil {
		return sec
	}

	// Stats JSON wraps data in "data" field
	data, hasData := stats["data"].(map[string]interface{})
	if !hasData {
		data = stats // Fallback to root level
	}

	// Summary section
	if summary, ok := data["summary"].(map[string]interface{}); ok {
		if active, ok := summary["active_bans"].(float64); ok {
			sec.BansTotal = int(active)
		}
		if total, ok := summary["total_bans"].(float64); ok {
			sec.TotalBansEver = int(total)
		}
	}

	// Breakdown section with IPv4/IPv6 details
	if breakdown, ok := data["breakdown"].(map[string]interface{}); ok {
		// Blacklist (main bans)
		if blacklist, ok := breakdown["blacklist"].(map[string]interface{}); ok {
			if v4, ok := blacklist["ipv4"].(float64); ok {
				sec.BansIPv4 = int(v4)
			}
			if v6, ok := blacklist["ipv6"].(float64); ok {
				sec.BansIPv6 = int(v6)
			}
		}
		// Whitelist
		if whitelist, ok := breakdown["whitelist"].(map[string]interface{}); ok {
			if total, ok := whitelist["total"].(float64); ok {
				sec.WhitelistTotal = int(total)
			}
			if v4, ok := whitelist["ipv4"].(float64); ok {
				sec.WhitelistIPv4 = int(v4)
			}
			if v6, ok := whitelist["ipv6"].(float64); ok {
				sec.WhitelistIPv6 = int(v6)
			}
		}
	}
	return sec
}

// getSecurityFromStatusCLI retrieves basic ban/whitelist counts via 'nftban status --json'.
// Used as a fallback when stats command doesn't provide data.
func getSecurityFromStatusCLI() ui.SecurityKPIs {
	sec := ui.SecurityKPIs{}
	output, err := execNFTBanCommand("status", "--json")
	if err != nil {
		return sec
	}
	var status map[string]interface{}
	if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) != nil {
		return sec
	}
	if fw, ok := status["firewall"].(map[string]interface{}); ok {
		if bans, ok := fw["banned_ips"].(float64); ok {
			sec.BansTotal = int(bans)
		}
		if wl, ok := fw["whitelist_ips"].(float64); ok {
			sec.WhitelistTotal = int(wl)
		}
	}
	return sec
}

// enrichWithNetworkStats adds network bandwidth and packet drop stats to security data.
func enrichWithNetworkStats(sec *ui.SecurityKPIs) {
	sec.NetworkInMbps, sec.NetworkOutMbps = getNetworkBandwidth()

	// Packet drop rate from nftables counters (rough estimate)
	if output, err := nftReadOnly("list", "counters"); err == nil {
		sec.PacketDropRate = strings.Count(string(output), "drop")
	}
}

// normalizeSecurityIPSplit ensures IPv4/IPv6 fields have values when only totals are available.
func normalizeSecurityIPSplit(sec *ui.SecurityKPIs) {
	if sec.BansIPv4 == 0 && sec.BansIPv6 == 0 && sec.BansTotal > 0 {
		sec.BansIPv4 = sec.BansTotal
	}
	if sec.WhitelistIPv4 == 0 && sec.WhitelistTotal > 0 {
		sec.WhitelistIPv4 = sec.WhitelistTotal
	}
}

// getSecurity orchestrates collection of security KPIs from multiple data sources.
// Priority: shared state (fastest) -> stats CLI -> status CLI, with network enrichment.
func (h *GOTHHandlers) getSecurity() ui.SecurityKPIs {
	// Try shared state first (fastest path)
	sec, ok := getSecurityFromSharedState()

	// Fallback to CLI if shared state not available or stale
	if !ok || sec.BansTotal == 0 {
		sec = getSecurityFromStatsCLI()
	}

	// Fallback to status --json if stats didn't work
	if sec.BansTotal == 0 {
		sec = getSecurityFromStatusCLI()
	}

	// Normalize IPv4/IPv6 split and add network stats
	normalizeSecurityIPSplit(&sec)
	enrichWithNetworkStats(&sec)

	return sec
}

// getNetworkBandwidth calculates network bandwidth in Mbps from all interfaces
func getNetworkBandwidth() (inMbps, outMbps float64) {
	var totalRxBytes, totalTxBytes uint64

	// Read /sys/class/net to get all interfaces
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return 0, 0
	}

	for _, entry := range entries {
		iface := entry.Name()
		// Skip loopback and virtual interfaces
		if iface == "lo" || strings.HasPrefix(iface, "veth") ||
			strings.HasPrefix(iface, "docker") || strings.HasPrefix(iface, "br-") ||
			strings.HasPrefix(iface, "virbr") {
			continue
		}

		rxPath := fmt.Sprintf("/sys/class/net/%s/statistics/rx_bytes", iface)
		txPath := fmt.Sprintf("/sys/class/net/%s/statistics/tx_bytes", iface)

		if rxData, err := os.ReadFile(rxPath); err == nil {
			if v, err := strconv.ParseUint(strings.TrimSpace(string(rxData)), 10, 64); err == nil {
				totalRxBytes += v
			}
		}
		if txData, err := os.ReadFile(txPath); err == nil {
			if v, err := strconv.ParseUint(strings.TrimSpace(string(txData)), 10, 64); err == nil {
				totalTxBytes += v
			}
		}
	}

	now := time.Now()

	// Protect shared state with mutex for thread safety
	netStatsMu.Lock()
	defer netStatsMu.Unlock()

	// Calculate rate if we have previous measurement
	if !lastNetTime.IsZero() {
		elapsed := now.Sub(lastNetTime).Seconds()
		if elapsed > 0 {
			// Calculate bytes per second, then convert to Mbps
			rxRate := float64(totalRxBytes-lastNetRxBytes) / elapsed
			txRate := float64(totalTxBytes-lastNetTxBytes) / elapsed
			inMbps = (rxRate * 8) / 1000000  // bits to Mbps
			outMbps = (txRate * 8) / 1000000
		}
	}

	// Store current values for next calculation
	lastNetRxBytes = totalRxBytes
	lastNetTxBytes = totalTxBytes
	lastNetTime = now

	return inMbps, outMbps
}

// fetchWatchdogResources retrieves system resources via 'nftban watchdog check --json'.
// Returns partially filled ResourceStats based on available watchdog data.
func fetchWatchdogResources() ui.ResourceStats {
	res := ui.ResourceStats{DiskPath: "/var/log"}

	output, err := execNFTBanCommand("watchdog", "check", "--json")
	if err != nil {
		return res
	}
	var wd map[string]interface{}
	if json.Unmarshal([]byte(util.ExtractJSON(output)), &wd) != nil {
		return res
	}

	// Load average
	if load, ok := wd["load"].(map[string]interface{}); ok {
		if v, ok := load["1m"].(string); ok {
			res.CPULoadAvg1, _ = strconv.ParseFloat(v, 64)
		}
		if v, ok := load["5m"].(string); ok {
			res.CPULoadAvg5, _ = strconv.ParseFloat(v, 64)
		}
		if v, ok := load["15m"].(string); ok {
			res.CPULoadAvg15, _ = strconv.ParseFloat(v, 64)
		}
	}

	// Memory
	if mem, ok := wd["memory"].(map[string]interface{}); ok {
		if v, ok := mem["used_percent"].(string); ok {
			res.RAMPercent, _ = strconv.ParseFloat(v, 64)
		}
		if v, ok := mem["total_mb"].(string); ok {
			if mb, err := strconv.ParseFloat(v, 64); err == nil {
				res.RAMTotalGB = mb / 1024
			}
		}
		if v, ok := mem["available_mb"].(string); ok {
			if mb, err := strconv.ParseFloat(v, 64); err == nil {
				res.RAMUsedGB = res.RAMTotalGB - (mb / 1024)
			}
		}
	}

	// IO wait as CPU indicator
	if iowait, ok := wd["iowait"].(map[string]interface{}); ok {
		if v, ok := iowait["percent"].(string); ok {
			res.CPUPercent, _ = strconv.ParseFloat(v, 64)
		}
	}

	// Disk
	if disk, ok := wd["disk"].(map[string]interface{}); ok {
		if v, ok := disk["used_percent"].(string); ok {
			res.DiskPercent, _ = strconv.ParseFloat(v, 64)
		}
		if path, ok := disk["path"].(string); ok {
			res.DiskPath = path
		}
	}

	return res
}

// readLoadAverage reads load averages from /proc/loadavg.
// Returns 1m, 5m, 15m load averages.
func readLoadAverage() (load1, load5, load15 float64) {
	content, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, 0
	}
	parts := strings.Fields(string(content))
	if len(parts) >= 3 {
		load1, _ = strconv.ParseFloat(parts[0], 64)
		load5, _ = strconv.ParseFloat(parts[1], 64)
		load15, _ = strconv.ParseFloat(parts[2], 64)
	}
	return load1, load5, load15
}

// readMemoryInfo reads memory statistics from /proc/meminfo.
// Returns usedGB, totalGB, and percent used.
func readMemoryInfo() (usedGB, totalGB, percent float64) {
	content, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0, 0
	}
	var memTotalKB, memAvailKB float64
	lines := strings.Split(string(content), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "MemTotal:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				memTotalKB, _ = strconv.ParseFloat(parts[1], 64)
			}
		}
		if strings.HasPrefix(line, "MemAvailable:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				memAvailKB, _ = strconv.ParseFloat(parts[1], 64)
			}
		}
	}
	totalGB = memTotalKB / 1024 / 1024
	usedGB = totalGB - (memAvailKB / 1024 / 1024)
	if totalGB > 0 {
		percent = (usedGB / totalGB) * 100
	}
	return usedGB, totalGB, percent
}

// readCPUPercent calculates CPU usage from /proc/stat.
func readCPUPercent() float64 {
	output, err := exec.Command("sh", "-c", "grep 'cpu ' /proc/stat | awk '{printf \"%.1f\", ($2+$4)*100/($2+$4+$5)}'").Output()
	if err != nil {
		return 0
	}
	val, _ := strconv.ParseFloat(strings.TrimSpace(string(output)), 64)
	return val
}

// readDiskUsage reads disk usage for a given path using df.
func readDiskUsage(path string) (usedGB, totalGB, percent float64) {
	output, err := exec.Command("df", "-BG", path).Output()
	if err != nil {
		return 0, 0, 0
	}
	lines := strings.Split(string(output), "\n")
	if len(lines) >= 2 {
		fields := strings.Fields(lines[1])
		if len(fields) >= 5 {
			totalGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[1], "G"), 64)
			usedGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[2], "G"), 64)
			percent, _ = strconv.ParseFloat(strings.TrimSuffix(fields[4], "%"), 64)
		}
	}
	return usedGB, totalGB, percent
}

// fetchNFTBanDaemonStats retrieves NFTBan daemon resource usage via watchdog stats.
func fetchNFTBanDaemonStats() (cpuPercent, memMB float64, uptime string) {
	output, err := execNFTBanCommand("watchdog", "stats", "--json")
	if err != nil {
		return 0, 0, ""
	}
	var stats map[string]interface{}
	if json.Unmarshal([]byte(util.ExtractJSON(output)), &stats) != nil {
		return 0, 0, ""
	}
	if cpu, ok := stats["cpu_percent"].(float64); ok {
		cpuPercent = cpu
	}
	if mem, ok := stats["memory_mb"].(float64); ok {
		memMB = mem
	}
	if ut, ok := stats["uptime"].(string); ok {
		uptime = ut
	}
	return cpuPercent, memMB, uptime
}

// fetchNFTBanProcessStats retrieves NFTBan process stats via ps (fallback).
func fetchNFTBanProcessStats() (cpuPercent, memMB float64) {
	output, err := exec.Command("sh", "-c", "ps aux | grep 'nftban' | grep -v grep | head -1 | awk '{print $3, $6}'").Output()
	if err != nil {
		return 0, 0
	}
	parts := strings.Fields(string(output))
	if len(parts) >= 2 {
		cpuPercent, _ = strconv.ParseFloat(parts[0], 64)
		if mem, err := strconv.ParseFloat(parts[1], 64); err == nil {
			memMB = mem / 1024
		}
	}
	return cpuPercent, memMB
}

// getResources orchestrates collection of system resource stats from multiple sources.
// Priority: watchdog CLI -> /proc fallbacks, with NFTBan-specific daemon stats.
func (h *GOTHHandlers) getResources() ui.ResourceStats {
	// Try watchdog first (provides most data in one call)
	res := fetchWatchdogResources()

	// Fallback for CPU from /proc/stat if watchdog didn't provide it
	if res.CPUPercent == 0 {
		res.CPUPercent = readCPUPercent()
	}

	// Fallback for load average from /proc/loadavg
	if res.CPULoadAvg1 == 0 {
		res.CPULoadAvg1, res.CPULoadAvg5, res.CPULoadAvg15 = readLoadAverage()
	}

	// Fallback for RAM from /proc/meminfo
	if res.RAMTotalGB == 0 {
		res.RAMUsedGB, res.RAMTotalGB, res.RAMPercent = readMemoryInfo()
	}

	// Fallback for Disk from df
	if res.DiskPercent == 0 {
		res.DiskUsedGB, res.DiskTotalGB, res.DiskPercent = readDiskUsage("/var/log")
	}

	// NFTBan daemon stats
	res.NFTBanCPU, res.NFTBanMemMB, res.NFTBanUptime = fetchNFTBanDaemonStats()

	// Fallback for NFTBan process stats
	if res.NFTBanCPU == 0 {
		res.NFTBanCPU, res.NFTBanMemMB = fetchNFTBanProcessStats()
	}

	return res
}

func (h *GOTHHandlers) getModulesList() []ui.ModuleStatus {
	modules := []ui.ModuleStatus{}
	now := time.Now().Format("15:04:05")

	// Get comprehensive status from nftban status --json
	if output, err := execNFTBanCommand("status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
			// Parse services section
			if services, ok := status["services"].(map[string]interface{}); ok {
				// nftables
				if svc, ok := services["nftables"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "nftables",
						Description: "Packet filtering firewall",
						LastSync:    now,
					}
					if st, ok := svc["status"].(string); ok {
						mod.Status = st
						mod.Running = st == "active"
						mod.Enabled = true
					}
					modules = append(modules, mod)
				}

				// Login Monitor
				if svc, ok := services["login_monitor"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "login-monitor",
						Description: "SSH/FTP login failure detection",
						ServiceName: "nftban-login-monitor",
						LastSync:    now,
					}
					if st, ok := svc["status"].(string); ok {
						mod.Status = st
						mod.Running = st == "active"
						mod.Enabled = st == "active"
					}
					if pid, ok := svc["pid"].(float64); ok && pid > 0 {
						mod.Running = true
					}
					if mem, ok := svc["memory_mb"].(float64); ok {
						mod.MemoryMB = mem
					}
					modules = append(modules, mod)
				}

				// Metrics Exporter
				if svc, ok := services["metrics_exporter"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "unified-exporter",
						Description: "Unified metrics exporter",
						ServiceName: "nftban-unified-exporter",
						LastSync:    now,
					}
					if st, ok := svc["status"].(string); ok {
						mod.Status = st
						mod.Running = st == "active"
						mod.Enabled = st == "active" || st == "timer"
					}
					modules = append(modules, mod)
				}
			}

			// Parse protection section
			if protection, ok := status["protection"].(map[string]interface{}); ok {
				// Suricata IDS
				if suri, ok := protection["suricata"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "suricata",
						Description: "Network intrusion detection",
						ServiceName: "nftban-suricata",
						LastSync:    now,
					}
					if enabled, ok := suri["enabled"].(bool); ok {
						mod.Enabled = enabled
						if enabled {
							mod.Status = "active"
							mod.Running = true
						} else {
							mod.Status = "inactive"
						}
					}
					modules = append(modules, mod)
				}

				// GeoIP/GeoBan
				if geo, ok := protection["geoip"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "geoban",
						Description: "Country-based IP blocking",
						LastSync:    now,
					}
					if installed, ok := geo["installed"].(bool); ok {
						mod.Enabled = installed
						if installed {
							mod.Status = "active"
							mod.Running = true
						} else {
							mod.Status = "inactive"
						}
					}
					if countries, ok := geo["blocked_countries"].(float64); ok {
						mod.BansProduced = int(countries)
					}
					modules = append(modules, mod)
				}

				// Feeds
				if feeds, ok := protection["feeds"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "threat-feeds",
						Description: "Threat intelligence feeds",
						ServiceName: "nftban-core-feeds",
						LastSync:    now,
					}
					if count, ok := feeds["count"].(float64); ok {
						mod.BansProduced = int(count)
						mod.Enabled = count > 0
						if count > 0 {
							mod.Status = "active"
							mod.Running = true
						} else {
							mod.Status = "inactive"
						}
					}
					modules = append(modules, mod)
				}
			}

			// Check timers for portscan and ddos status
			if timers, ok := status["timers"].(map[string]interface{}); ok {
				// Add portscan module based on config check
				portscanMod := ui.ModuleStatus{
					Name:        "portscan",
					Description: "Port scan detection",
					LastSync:    now,
					Status:      "inactive",
				}
				// Check if portscan is enabled via config
				if output, err := execNFTBanCommand("config", "get", "portscan.enabled"); err == nil {
					if strings.Contains(string(output), "true") || strings.Contains(string(output), "1") {
						portscanMod.Enabled = true
						portscanMod.Status = "active"
						portscanMod.Running = true
					}
				}
				modules = append(modules, portscanMod)

				// Add ddos module
				ddosMod := ui.ModuleStatus{
					Name:        "ddos",
					Description: "DDoS protection",
					LastSync:    now,
					Status:      "inactive",
				}
				if output, err := execNFTBanCommand("config", "get", "ddos.enabled"); err == nil {
					if strings.Contains(string(output), "true") || strings.Contains(string(output), "1") {
						ddosMod.Enabled = true
						ddosMod.Status = "active"
						ddosMod.Running = true
					}
				}
				modules = append(modules, ddosMod)

				// Show timer status
				_ = timers // Used above for reference
			}
		}
	}

	// If no modules found or nftables not in list, add direct nftables check
	hasNftables := false
	for _, m := range modules {
		if m.Name == "nftables" {
			hasNftables = true
			break
		}
	}

	if !hasNftables {
		// Direct nftables check as fallback
		nftMod := ui.ModuleStatus{
			Name:        "nftables",
			Description: "Packet filtering firewall",
			LastSync:    now,
			Status:      "error",
		}

		// Check if nftables service is running
		if err := exec.Command("systemctl", "is-active", "--quiet", "nftables").Run(); err == nil {
			nftMod.Status = "active"
			nftMod.Running = true
			nftMod.Enabled = true

			// Check if nftban table exists
			if output, err := nftReadOnly("list", "tables"); err == nil {
				if !strings.Contains(string(output), "nftban") {
					nftMod.Status = "warning" // nftables running but no nftban table
				}
			}
		} else {
			// Check if nft command works at all
			if _, err := nftReadOnly("list", "tables"); err == nil {
				nftMod.Status = "active" // nft works even if service not "active"
				nftMod.Running = true
			}
		}

		// Prepend nftables to modules list
		modules = append([]ui.ModuleStatus{nftMod}, modules...)
	}

	// If still no modules, add minimal fallback
	if len(modules) == 0 {
		modules = []ui.ModuleStatus{
			{Name: "nftables", Description: "Packet filtering", Status: "unknown", LastSync: now},
		}
	}

	return modules
}

func (h *GOTHHandlers) getRecentBans() []ui.RecentBan {
	bans := []ui.RecentBan{}

	// Try to get recent bans from CLI
	if output, err := execNFTBanCommand("list", "--recent=10", "--json"); err == nil {
		var banData []map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &banData) == nil {
			for _, b := range banData {
				ban := ui.RecentBan{}
				if ip, ok := b["ip"].(string); ok {
					ban.IP = ip
				}
				if country, ok := b["country"].(string); ok {
					ban.Country = country
				}
				if reason, ok := b["reason"].(string); ok {
					ban.Reason = reason
				}
				if module, ok := b["module"].(string); ok {
					ban.Module = module
				}
				if ts, ok := b["timestamp"].(string); ok {
					ban.Timestamp = ts
				} else if ts, ok := b["timestamp"].(float64); ok {
					ban.Timestamp = time.Unix(int64(ts), 0).Format("15:04:05")
				}
				bans = append(bans, ban)
			}
		}
	}

	return bans
}

func (h *GOTHHandlers) getHealthItems() []ui.HealthItem {
	items := []ui.HealthItem{}

	// Service checks
	services := []struct {
		service string
		name    string
	}{
		{"nftban-core", "Core"},
		{"nftban-login-monitor", "Login Monitor"},
		{"nftban-ui", "Web UI"},
	}

	for _, svc := range services {
		status := "error"
		if output, err := exec.Command("systemctl", "is-active", svc.service).Output(); err == nil {
			switch strings.TrimSpace(string(output)) {
			case "active":
				status = "ok"
			case "inactive":
				status = "warning"
			}
		}
		items = append(items, ui.HealthItem{Name: svc.name, Status: status})
	}

	// NFTables check
	if output, err := nftReadOnly("list", "tables"); err == nil {
		if strings.Contains(string(output), "nftban") {
			items = append(items, ui.HealthItem{Name: "NFTables", Status: "ok"})
		} else {
			items = append(items, ui.HealthItem{Name: "NFTables", Status: "warning"})
		}
	} else {
		items = append(items, ui.HealthItem{Name: "NFTables", Status: "error"})
	}

	return items
}

func (h *GOTHHandlers) getHealthData() ui.HealthData {
	data := ui.HealthData{
		Timestamp:     time.Now().Format("2006-01-02 15:04:05"),
		OverallStatus: "ok",
		ExitCode:      0,
	}

	// Use nftban health check --json for comprehensive health data
	if output, err := execNFTBanCommand("health", "check", "--json"); err == nil {
		var healthJSON map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &healthJSON) == nil {
			// Timestamp
			if ts, ok := healthJSON["timestamp"].(string); ok {
				data.Timestamp = ts
			}

			// Overall status
			if status, ok := healthJSON["overall_status"].(string); ok {
				data.OverallStatus = status
			}

			// Exit code
			if exitCode, ok := healthJSON["exit_code"].(float64); ok {
				data.ExitCode = int(exitCode)
			}

			// Summary counts
			if summary, ok := healthJSON["summary"].(map[string]interface{}); ok {
				if errors, ok := summary["errors"].(float64); ok {
					data.ErrorCount = int(errors)
				}
				if warnings, ok := summary["warnings"].(float64); ok {
					data.WarningCount = int(warnings)
				}
			}

			// Parse checks section
			if checks, ok := healthJSON["checks"].(map[string]interface{}); ok {
				for name, checkData := range checks {
					if checkMap, ok := checkData.(map[string]interface{}); ok {
						check := ui.HealthCheck{
							Name: name,
						}
						if status, ok := checkMap["status"].(string); ok {
							check.Status = status
						}
						if exitCode, ok := checkMap["exit_code"].(float64); ok {
							check.ExitCode = int(exitCode)
						}
						if message, ok := checkMap["message"].(string); ok {
							check.Message = message
						}
						data.Checks = append(data.Checks, check)
					}
				}
			}

			// Parse errors array
			if errors, ok := healthJSON["errors"].([]interface{}); ok {
				for _, err := range errors {
					if errStr, ok := err.(string); ok {
						data.Errors = append(data.Errors, errStr)
					}
				}
			}

			// Parse warnings array
			if warnings, ok := healthJSON["warnings"].([]interface{}); ok {
				for _, warn := range warnings {
					if warnStr, ok := warn.(string); ok {
						data.Warnings = append(data.Warnings, warnStr)
					}
				}
			}

			// Parse extended data (from shared check functions)
			if extended, ok := healthJSON["extended"].(map[string]interface{}); ok {
				// Resources
				if resources, ok := extended["resources"].(map[string]interface{}); ok {
					if load, ok := resources["load"].(map[string]interface{}); ok {
						data.Extended.Resources.Load.Load1m = getFloat(load, "1m")
						data.Extended.Resources.Load.Load5m = getFloat(load, "5m")
						data.Extended.Resources.Load.Load15m = getFloat(load, "15m")
						data.Extended.Resources.Load.CPUs = getInt(load, "cpus")
					}
					if memory, ok := resources["memory"].(map[string]interface{}); ok {
						data.Extended.Resources.Memory.UsedPercent = getInt(memory, "used_percent")
						data.Extended.Resources.Memory.TotalMB = getInt(memory, "total_mb")
					}
					if disk, ok := resources["disk"].(map[string]interface{}); ok {
						data.Extended.Resources.Disk.Path = getString(disk, "path")
						data.Extended.Resources.Disk.UsedPercent = getInt(disk, "used_percent")
					}
					data.Extended.Resources.Status = getString(resources, "status")
				}

				// Suricata
				if suricata, ok := extended["suricata"].(map[string]interface{}); ok {
					data.Extended.Suricata.Installed = getBool(suricata, "installed")
					data.Extended.Suricata.ServiceActive = getBool(suricata, "service_active")
					data.Extended.Suricata.EVEExists = getBool(suricata, "eve_exists")
					data.Extended.Suricata.EVEFresh = getBool(suricata, "eve_fresh")
					data.Extended.Suricata.RulesLoaded = getInt(suricata, "rules_loaded")
					data.Extended.Suricata.BanningActive = getBool(suricata, "banning_active")
					data.Extended.Suricata.Status = getString(suricata, "status")
				}

				// DNS
				if dns, ok := extended["dns"].(map[string]interface{}); ok {
					data.Extended.DNS.Hostname = getString(dns, "hostname")
					data.Extended.DNS.Working = getBool(dns, "working")
					data.Extended.DNS.Resolver = getString(dns, "resolver")
					data.Extended.DNS.LatencyMS = getInt(dns, "latency_ms")
					data.Extended.DNS.Status = getString(dns, "status")
				}

				// Firewall conflicts
				if conflicts, ok := extended["firewall_conflicts"].(map[string]interface{}); ok {
					parseFirewallConflict := func(fw map[string]interface{}) ui.HealthFirewall {
						return ui.HealthFirewall{
							Installed:     getBool(fw, "installed"),
							Enabled:       getBool(fw, "enabled"),
							Active:        getBool(fw, "active"),
							ConflictLevel: getString(fw, "conflict_level"),
							Status:        getString(fw, "status"),
						}
					}
					if csf, ok := conflicts["csf"].(map[string]interface{}); ok {
						data.Extended.FirewallConflicts.CSF = parseFirewallConflict(csf)
					}
					if firewalld, ok := conflicts["firewalld"].(map[string]interface{}); ok {
						data.Extended.FirewallConflicts.Firewalld = parseFirewallConflict(firewalld)
					}
					if ufw, ok := conflicts["ufw"].(map[string]interface{}); ok {
						data.Extended.FirewallConflicts.UFW = parseFirewallConflict(ufw)
					}
					if iptables, ok := conflicts["iptables"].(map[string]interface{}); ok {
						data.Extended.FirewallConflicts.IPTables = parseFirewallConflict(iptables)
					}
				}
			}
		}
	} else {
		// Fallback if health check command fails
		data.OverallStatus = "error"
		data.ExitCode = 1
		data.ErrorCount = 1
		data.Errors = append(data.Errors, "Health check command failed: "+err.Error())

		// Still try to get basic service status
		services := []struct {
			service string
			name    string
		}{
			{"nftban-core", "core"},
			{"nftban-login-monitor", "login_monitor"},
			{"nftban-ui", "ui"},
		}

		for _, svc := range services {
			check := ui.HealthCheck{Name: svc.name}
			if output, err := exec.Command("systemctl", "is-active", svc.service).Output(); err == nil {
				switch strings.TrimSpace(string(output)) {
				case "active":
					check.Status = "ok"
				case "inactive":
					check.Status = "warning"
					check.Message = "Service inactive"
				default:
					check.Status = "error"
					check.Message = "Service not running"
				}
			} else {
				check.Status = "error"
				check.Message = "Unable to check service"
			}
			data.Checks = append(data.Checks, check)
		}
	}

	return data
}

func (h *GOTHHandlers) getModulesData() pages.ModulesData {
	modules := h.getModulesList()
	data := pages.ModulesData{Modules: modules}

	for _, mod := range modules {
		data.Summary.Total++
		if mod.Enabled {
			data.Summary.Enabled++
			if mod.Running {
				data.Summary.Running++
			}
		} else {
			data.Summary.Disabled++
		}
	}

	return data
}

// =============================================================================
// BANS DATA FETCHER
// =============================================================================

func (h *GOTHHandlers) getBansData(r *http.Request) ui.BansData {
	data := ui.BansData{
		Page:     1,
		PageSize: 50,
		Filter:   "all",
	}

	// Parse query params
	if page := r.URL.Query().Get("page"); page != "" {
		if p, err := strconv.Atoi(page); err == nil && p > 0 {
			data.Page = p
		}
	}
	if filter := r.URL.Query().Get("filter"); filter != "" {
		data.Filter = filter
	}
	if search := r.URL.Query().Get("search"); search != "" {
		data.SearchQuery = search
	}

	// Get stats from nftban stats --json
	if output, err := execNFTBanCommand("stats", "--json"); err == nil {
		var stats map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &stats) == nil {
			if statsData, ok := stats["data"].(map[string]interface{}); ok {
				// Summary
				if summary, ok := statsData["summary"].(map[string]interface{}); ok {
					if v, ok := summary["active_bans"].(float64); ok {
						data.TotalBans = int(v)
					}
				}
				// Breakdown
				if breakdown, ok := statsData["breakdown"].(map[string]interface{}); ok {
					if bl, ok := breakdown["blacklist"].(map[string]interface{}); ok {
						if v, ok := bl["ipv4"].(float64); ok {
							data.BansIPv4 = int(v)
						}
						if v, ok := bl["ipv6"].(float64); ok {
							data.BansIPv6 = int(v)
						}
					}
					if temp, ok := breakdown["temporary"].(map[string]interface{}); ok {
						if v, ok := temp["total"].(float64); ok {
							data.TempBans = int(v)
						}
					}
					if feeds, ok := breakdown["feeds"].(map[string]interface{}); ok {
						if v, ok := feeds["total"].(float64); ok {
							data.FeedBans = int(v)
						}
					}
					if geo, ok := breakdown["geoban"].(map[string]interface{}); ok {
						if v, ok := geo["total"].(float64); ok {
							data.GeoBans = int(v)
						}
					}
				}
			}
		}
	}

	// Calculate permanent bans
	data.PermBans = data.TotalBans - data.TempBans - data.FeedBans - data.GeoBans
	if data.PermBans < 0 {
		data.PermBans = data.TotalBans
	}

	// Get ban list from nftban list --json
	args := []string{"list", "--json"}
	if data.SearchQuery != "" {
		args = append(args, "--search", data.SearchQuery)
	}
	if data.Filter != "all" {
		args = append(args, "--type", data.Filter)
	}

	if output, err := execNFTBanCommand(args...); err == nil {
		var listResult map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &listResult) == nil {
			// Try to parse bans array
			var bansArray []interface{}
			if bans, ok := listResult["bans"].([]interface{}); ok {
				bansArray = bans
			} else if bans, ok := listResult["data"].([]interface{}); ok {
				bansArray = bans
			}

			for _, b := range bansArray {
				if banMap, ok := b.(map[string]interface{}); ok {
					entry := ui.BanEntry{}
					if ip, ok := banMap["ip"].(string); ok {
						entry.IP = ip
					}
					if t, ok := banMap["type"].(string); ok {
						entry.Type = t
					} else {
						entry.Type = "permanent"
					}
					if reason, ok := banMap["reason"].(string); ok {
						entry.Reason = reason
					}
					if module, ok := banMap["module"].(string); ok {
						entry.Module = module
					} else if source, ok := banMap["source"].(string); ok {
						entry.Module = source
					}
					if country, ok := banMap["country"].(string); ok {
						entry.Country = country
					}
					if cc, ok := banMap["country_code"].(string); ok {
						entry.CountryCode = cc
					}
					if ts, ok := banMap["banned_at"].(string); ok {
						entry.BannedAt = ts
					} else if ts, ok := banMap["timestamp"].(string); ok {
						entry.BannedAt = ts
					}
					if exp, ok := banMap["expires_at"].(string); ok {
						entry.ExpiresAt = exp
					}
					data.Bans = append(data.Bans, entry)
				}
			}
		}
	}

	// Pagination
	data.TotalPages = (len(data.Bans) + data.PageSize - 1) / data.PageSize
	if data.TotalPages == 0 {
		data.TotalPages = 1
	}

	// Apply pagination
	start := (data.Page - 1) * data.PageSize
	end := start + data.PageSize
	if start < len(data.Bans) {
		if end > len(data.Bans) {
			end = len(data.Bans)
		}
		data.Bans = data.Bans[start:end]
	} else {
		data.Bans = []ui.BanEntry{}
	}

	return data
}

// =============================================================================
// WHITELIST DATA FETCHER
// =============================================================================

func (h *GOTHHandlers) getWhitelistData() ui.WhitelistData {
	data := ui.WhitelistData{}

	// Get whitelist from nftban whitelist --json
	if output, err := execNFTBanCommand("whitelist", "list", "--json"); err == nil {
		var result map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &result) == nil {
			// Parse entries
			var entriesArray []interface{}
			if entries, ok := result["entries"].([]interface{}); ok {
				entriesArray = entries
			} else if entries, ok := result["data"].([]interface{}); ok {
				entriesArray = entries
			} else if entries, ok := result["whitelist"].([]interface{}); ok {
				entriesArray = entries
			}

			for _, e := range entriesArray {
				if entryMap, ok := e.(map[string]interface{}); ok {
					entry := ui.WhitelistEntry{}
					if ip, ok := entryMap["ip"].(string); ok {
						entry.IP = ip
					} else if ip, ok := entryMap["address"].(string); ok {
						entry.IP = ip
					}
					if t, ok := entryMap["type"].(string); ok {
						entry.Type = t
					} else {
						// Detect type from IP format
						if strings.Contains(entry.IP, "/") {
							entry.Type = "network"
						} else {
							entry.Type = "ip"
						}
					}
					if comment, ok := entryMap["comment"].(string); ok {
						entry.Comment = comment
					}
					if source, ok := entryMap["source"].(string); ok {
						entry.Source = source
					} else if file, ok := entryMap["file"].(string); ok {
						entry.Source = file
					}
					if added, ok := entryMap["added_at"].(string); ok {
						entry.AddedAt = added
					}

					data.Entries = append(data.Entries, entry)

					// Count by type
					data.TotalEntries++
					if strings.Contains(entry.IP, ":") {
						data.IPv6Count++
					} else {
						data.IPv4Count++
					}
					if strings.Contains(entry.IP, "/") {
						data.NetworkCount++
					}
				}
			}

			// Parse sources
			if sources, ok := result["sources"].([]interface{}); ok {
				for _, s := range sources {
					if srcMap, ok := s.(map[string]interface{}); ok {
						src := ui.WhitelistSource{}
						if name, ok := srcMap["name"].(string); ok {
							src.Name = name
						}
						if path, ok := srcMap["path"].(string); ok {
							src.Path = path
						}
						if count, ok := srcMap["count"].(float64); ok {
							src.EntryCount = int(count)
						}
						if editable, ok := srcMap["editable"].(bool); ok {
							src.Editable = editable
						}
						data.Sources = append(data.Sources, src)
					}
				}
			}
		}
	}

	// Fallback: get count from stats if no entries found
	if data.TotalEntries == 0 {
		if output, err := execNFTBanCommand("status", "--json"); err == nil {
			var status map[string]interface{}
			if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
				if fw, ok := status["firewall"].(map[string]interface{}); ok {
					if wl, ok := fw["whitelist_ips"].(float64); ok {
						data.TotalEntries = int(wl)
						data.IPv4Count = int(wl) // Assume all IPv4 if no breakdown
					}
				}
			}
		}
	}

	return data
}

// =============================================================================
// EVENTS DATA FETCHER
// =============================================================================

func (h *GOTHHandlers) getEventsData(r *http.Request) ui.EventsData {
	data := ui.EventsData{
		Page:     1,
		PageSize: 100,
		Filter:   "all",
	}

	// Parse query params
	if page := r.URL.Query().Get("page"); page != "" {
		if p, err := strconv.Atoi(page); err == nil && p > 0 {
			data.Page = p
		}
	}
	if filter := r.URL.Query().Get("filter"); filter != "" {
		data.Filter = filter
	}
	if search := r.URL.Query().Get("search"); search != "" {
		data.SearchQuery = search
	}
	if dateFrom := r.URL.Query().Get("date_from"); dateFrom != "" {
		data.DateFrom = dateFrom
	}
	if dateTo := r.URL.Query().Get("date_to"); dateTo != "" {
		data.DateTo = dateTo
	}

	// Get events from nftban logs or journal
	args := []string{"logs", "--json", "--limit", "500"}
	if data.Filter != "all" {
		switch data.Filter {
		case "bans":
			args = append(args, "--level", "BAN")
		case "unbans":
			args = append(args, "--level", "UNBAN")
		case "warnings":
			args = append(args, "--level", "WARN")
		case "errors":
			args = append(args, "--level", "ERROR")
		}
	}

	if output, err := execNFTBanCommand(args...); err == nil {
		var result map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &result) == nil {
			var eventsArray []interface{}
			if events, ok := result["events"].([]interface{}); ok {
				eventsArray = events
			} else if events, ok := result["logs"].([]interface{}); ok {
				eventsArray = events
			} else if events, ok := result["data"].([]interface{}); ok {
				eventsArray = events
			}

			for i, e := range eventsArray {
				if eventMap, ok := e.(map[string]interface{}); ok {
					entry := ui.EventEntry{
						ID: fmt.Sprintf("evt-%d", i),
					}
					if ts, ok := eventMap["timestamp"].(string); ok {
						entry.Timestamp = ts
					} else if ts, ok := eventMap["time"].(string); ok {
						entry.Timestamp = ts
					}
					if level, ok := eventMap["level"].(string); ok {
						entry.Level = level
					}
					if module, ok := eventMap["module"].(string); ok {
						entry.Module = module
					} else if source, ok := eventMap["source"].(string); ok {
						entry.Module = source
					}
					if action, ok := eventMap["action"].(string); ok {
						entry.Action = action
					}
					if ip, ok := eventMap["ip"].(string); ok {
						entry.IP = ip
					}
					if country, ok := eventMap["country"].(string); ok {
						entry.Country = country
					}
					if cc, ok := eventMap["country_code"].(string); ok {
						entry.CountryCode = cc
					}
					if msg, ok := eventMap["message"].(string); ok {
						entry.Message = msg
					}
					if details, ok := eventMap["details"].(string); ok {
						entry.Details = details
					}

					// Filter by search query
					if data.SearchQuery != "" {
						searchLower := strings.ToLower(data.SearchQuery)
						if !strings.Contains(strings.ToLower(entry.IP), searchLower) &&
							!strings.Contains(strings.ToLower(entry.Message), searchLower) {
							continue
						}
					}

					data.Events = append(data.Events, entry)

					// Count by level
					switch entry.Level {
					case "BAN":
						data.BanEvents++
					case "UNBAN":
						data.UnbanEvents++
					case "WARN":
						data.WarningEvents++
					case "ERROR":
						data.ErrorEvents++
					}
				}
			}
		}
	}

	// Fallback: parse journalctl if no events from CLI
	if len(data.Events) == 0 {
		events := h.getJournalEvents(data.Filter, 500)
		data.Events = events
		for _, e := range events {
			switch e.Level {
			case "BAN":
				data.BanEvents++
			case "UNBAN":
				data.UnbanEvents++
			case "WARN":
				data.WarningEvents++
			case "ERROR":
				data.ErrorEvents++
			}
		}
	}

	// Calculate totals
	data.TotalEvents = len(data.Events)
	data.EventsToday = data.TotalEvents // Simplified for now
	data.EventsLastHour = min(data.TotalEvents, 50) // Estimate

	// Pagination
	data.TotalPages = (len(data.Events) + data.PageSize - 1) / data.PageSize
	if data.TotalPages == 0 {
		data.TotalPages = 1
	}

	// Apply pagination
	start := (data.Page - 1) * data.PageSize
	end := start + data.PageSize
	if start < len(data.Events) {
		if end > len(data.Events) {
			end = len(data.Events)
		}
		data.Events = data.Events[start:end]
	} else {
		data.Events = []ui.EventEntry{}
	}

	return data
}

// getJournalEvents fetches events from journalctl as fallback
func (h *GOTHHandlers) getJournalEvents(filter string, limit int) []ui.EventEntry {
	var events []ui.EventEntry

	// Try to get nftban logs from journalctl
	cmd := exec.Command("journalctl", "-u", "nftband.service", "-n", strconv.Itoa(limit), "--no-pager", "-o", "json")
	output, err := cmd.Output()
	if err != nil {
		return events
	}

	// Parse JSONL output
	lines := strings.Split(string(output), "\n")
	for i, line := range lines {
		if line == "" {
			continue
		}
		var entry map[string]interface{}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			continue
		}

		event := ui.EventEntry{
			ID: fmt.Sprintf("jrnl-%d", i),
		}

		// Parse systemd journal fields
		if ts, ok := entry["__REALTIME_TIMESTAMP"].(string); ok {
			// Convert microseconds to timestamp
			if usec, err := strconv.ParseInt(ts, 10, 64); err == nil {
				t := time.Unix(usec/1000000, (usec%1000000)*1000)
				event.Timestamp = t.Format("2006-01-02 15:04:05")
			}
		}
		if msg, ok := entry["MESSAGE"].(string); ok {
			event.Message = msg
			// Parse level from message
			if strings.Contains(msg, "[BAN]") || strings.Contains(msg, "Banned") {
				event.Level = "BAN"
				event.Action = "ban"
			} else if strings.Contains(msg, "[UNBAN]") || strings.Contains(msg, "Unbanned") {
				event.Level = "UNBAN"
				event.Action = "unban"
			} else if strings.Contains(msg, "[ERROR]") || strings.Contains(msg, "error") {
				event.Level = "ERROR"
				event.Action = "error"
			} else if strings.Contains(msg, "[WARN]") || strings.Contains(msg, "warning") {
				event.Level = "WARN"
				event.Action = "warning"
			} else {
				event.Level = "INFO"
				event.Action = "info"
			}

			// Extract IP from message if present
			if idx := strings.Index(msg, " IP "); idx != -1 {
				parts := strings.Fields(msg[idx+4:])
				if len(parts) > 0 {
					event.IP = strings.TrimSuffix(parts[0], ",")
				}
			}
		}
		if unit, ok := entry["SYSLOG_IDENTIFIER"].(string); ok {
			event.Module = unit
		}

		// Apply filter
		if filter != "all" {
			switch filter {
			case "bans":
				if event.Level != "BAN" {
					continue
				}
			case "unbans":
				if event.Level != "UNBAN" {
					continue
				}
			case "warnings":
				if event.Level != "WARN" {
					continue
				}
			case "errors":
				if event.Level != "ERROR" {
					continue
				}
			}
		}

		events = append(events, event)
	}

	return events
}

// =============================================================================
// HELPERS
// =============================================================================

func execNFTBanCommand(args ...string) (string, error) {
	// Use central config for CLI path - same as pkg/api/handlers.go
	cfg := nftbanconf.MustLoad()
	cmd := exec.Command(cfg.Bin, args...)
	output, err := cmd.CombinedOutput()

	outputStr := string(output)
	if err != nil {
		// Ignore netlink socket warnings - these are harmless
		if strings.Contains(outputStr, "Unable to initialize Netlink socket") {
			return outputStr, nil
		}
		return outputStr, err
	}
	return outputStr, nil
}


// =============================================================================
// INVENTORY DATA
// =============================================================================

func (h *GOTHHandlers) getInventoryData() ui.InventoryData {
	data := ui.InventoryData{}

	// Get services from systemctl
	data.Services = h.getServicesList()

	// Get timers from systemctl
	data.Timers = h.getTimersList()

	// Get binaries
	data.Binaries = h.getBinariesList()

	// Get config files
	data.Configs = h.getConfigsList()

	// Get FHS data (limited to avoid too much data)
	data.FHS = h.getFHSList()

	return data
}

func (h *GOTHHandlers) getServicesList() []ui.ServiceInfo {
	services := []ui.ServiceInfo{}

	// NFTBan services to check
	svcNames := []struct {
		name string
		desc string
	}{
		{"nftables", "Packet filtering firewall"},
		{"nftban-ui", "Web GUI server"},
		{"nftban-api", "REST API server"},
		{"nftban-login-monitor", "Login failure detection"},
		{"nftban-suricata", "Suricata IDS integration"},
		{"prometheus", "Metrics database"},
		{"node_exporter", "System metrics exporter"},
	}

	for _, s := range svcNames {
		svc := ui.ServiceInfo{
			Name:        s.name,
			Description: s.desc,
			Status:      "inactive",
		}

		// Check if service exists and get status
		if output, err := exec.Command("systemctl", "show", s.name,
			"--property=ActiveState,MainPID,MemoryCurrent,ActiveEnterTimestamp").Output(); err == nil {

			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				key, val := parts[0], parts[1]
				switch key {
				case "ActiveState":
					svc.Status = val
				case "MainPID":
					if pid, err := strconv.Atoi(val); err == nil {
						svc.PID = pid
					}
				case "MemoryCurrent":
					if mem, err := strconv.ParseUint(val, 10, 64); err == nil && mem > 0 {
						svc.MemoryMB = float64(mem) / 1024 / 1024
					}
				case "ActiveEnterTimestamp":
					if val != "" && val != "n/a" {
						// Parse timestamp and calculate uptime
						svc.Uptime = val
					}
				}
			}
		}

		services = append(services, svc)
	}

	return services
}

func (h *GOTHHandlers) getTimersList() []ui.TimerInfo {
	timers := []ui.TimerInfo{}

	// NFTBan timers
	timerNames := []struct {
		name string
		desc string
	}{
		{"nftban-health.timer", "Health checks & auto-heal"},
		{"nftban-maintenance.timer", "Maintenance tasks"},
		{"nftban-unified-exporter.timer", "Unified metrics export"},
		{"nftban-core-feeds.timer", "Threat feed sync"},
		{"nftban-core-geoip.timer", "GeoIP database updates"},
		{"nftban-queue.timer", "Ban queue processing"},
	}

	for _, t := range timerNames {
		timer := ui.TimerInfo{
			Name:        strings.TrimSuffix(t.name, ".timer"),
			Description: t.desc,
			Status:      "inactive",
		}

		// Check timer status
		if output, err := exec.Command("systemctl", "show", t.name,
			"--property=ActiveState,NextElapseUSecRealtime,LastTriggerUSec").Output(); err == nil {

			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				key, val := parts[0], parts[1]
				switch key {
				case "ActiveState":
					timer.Status = val
				case "NextElapseUSecRealtime":
					if val != "" && val != "n/a" {
						timer.NextRun = val
					}
				case "LastTriggerUSec":
					if val != "" && val != "n/a" {
						timer.LastRun = val
					}
				}
			}
		}

		// Check if timer is enabled
		if output, err := exec.Command("systemctl", "is-enabled", t.name).Output(); err == nil {
			if strings.TrimSpace(string(output)) == "enabled" && timer.Status == "inactive" {
				timer.Status = "enabled"
			}
		}

		timers = append(timers, timer)
	}

	return timers
}

func (h *GOTHHandlers) getBinariesList() []ui.BinaryInfo {
	binaries := []ui.BinaryInfo{}

	// NFTBan binaries to check
	binPaths := []struct {
		name string
		path string
	}{
		{"nftban", "/usr/sbin/nftban"},
		{"nftban-ui", "/usr/sbin/nftban-ui"},
		{"nftban-core", "/usr/sbin/nftban-core"},
		{"nftban-api", "/usr/sbin/nftban-api"},
		{"nft", "/usr/sbin/nft"},
	}

	for _, b := range binPaths {
		bin := ui.BinaryInfo{
			Name: b.name,
			Path: b.path,
		}

		// Check if binary exists and get info
		if info, err := os.Stat(b.path); err == nil {
			bin.Size = util.FormatBytes(info.Size())

			// Try to get version
			if output, err := exec.Command(b.path, "--version").Output(); err == nil {
				ver := strings.TrimSpace(string(output))
				if len(ver) > 50 {
					ver = ver[:50]
				}
				bin.Version = ver
			}
		} else {
			bin.Version = "not installed"
		}

		binaries = append(binaries, bin)
	}

	return binaries
}

func (h *GOTHHandlers) getConfigsList() []ui.ConfigInfo {
	configs := []ui.ConfigInfo{}

	// Important config files
	cfgPaths := []struct {
		name string
		path string
	}{
		{"nftban.conf", "/etc/nftban/nftban.conf"},
		{"ui.conf", "/etc/nftban/ui.conf"},
		{"services.conf", "/etc/nftban/conf.d/services.conf"},
		{"trust.conf", "/etc/nftban/conf.d/trust.conf"},
		{"login/main.conf", "/etc/nftban/conf.d/login/main.conf"},
		{"ddos/main.conf", "/etc/nftban/conf.d/ddos/main.conf"},
		{"portscan/main.conf", "/etc/nftban/conf.d/portscan/main.conf"},
	}

	for _, c := range cfgPaths {
		cfg := ui.ConfigInfo{
			Name: c.name,
			Path: c.path,
		}

		if info, err := os.Stat(c.path); err == nil {
			cfg.Size = util.FormatBytes(info.Size())
			cfg.Modified = info.ModTime().Format("2006-01-02 15:04")
		} else {
			cfg.Modified = "not found"
		}

		configs = append(configs, cfg)
	}

	return configs
}

func (h *GOTHHandlers) getFHSList() []ui.FHSItem {
	fhs := []ui.FHSItem{}

	// Load config to get actual paths (supports custom installations)
	cfg := nftbanconf.MustLoad()

	// Key FHS directories - use configured paths, not hardcoded
	dirs := []string{
		cfg.ConfigDir, // /etc/nftban or custom
		cfg.DataDir,   // /var/lib/nftban or custom
		cfg.LogDir,    // /var/log/nftban or custom
		cfg.CacheDir,  // /var/cache/nftban or custom
		cfg.RunDir,    // /run/nftban or custom
		cfg.LibDir,    // /usr/lib/nftban or custom
	}

	for _, dir := range dirs {
		item := ui.FHSItem{
			Path:   dir,
			Status: "ok",
		}

		if info, err := os.Stat(dir); err == nil {
			mode := info.Mode()
			item.Actual = fmt.Sprintf("%04o", mode.Perm())
			item.Expected = "0755"
			if item.Actual != "0755" && item.Actual != "0750" {
				item.Status = "warning"
			}
		} else {
			item.Status = "error"
			item.Actual = "missing"
			item.Notes = "Directory does not exist"
		}

		fhs = append(fhs, item)
	}

	return fhs
}

// =============================================================================
// TOOLS DATA FETCHERS
// =============================================================================

func (h *GOTHHandlers) getToolsData() ui.ToolsData {
	data := ui.ToolsData{}

	// Get quick stats
	sec := h.getSecurity()
	data.TotalBans = sec.BansTotal
	data.TotalWhitelist = sec.WhitelistTotal

	// Count feeds
	out, err := exec.Command("nftban", "feeds", "list", "--json").Output()
	if err == nil {
		var feeds []map[string]interface{}
		if json.Unmarshal(out, &feeds) == nil {
			for _, f := range feeds {
				if enabled, ok := f["enabled"].(bool); ok && enabled {
					data.TotalFeeds++
				}
			}
		}
	}

	// Get recent logs
	data.RecentLogs = h.getRecentLogs("")

	return data
}

func (h *GOTHHandlers) getRecentLogs(levelFilter string) []ui.LogEntry {
	logs := []ui.LogEntry{}

	// Read from ban log
	logFile := "/var/log/nftban/bans.log"
	if content, err := os.ReadFile(logFile); err == nil {
		lines := strings.Split(string(content), "\n")
		// Get last 50 lines
		start := len(lines) - 50
		if start < 0 {
			start = 0
		}

		for i := len(lines) - 1; i >= start; i-- {
			line := strings.TrimSpace(lines[i])
			if line == "" {
				continue
			}

			entry := parseBanLogLine(line)
			if entry.Timestamp != "" {
				if levelFilter == "" || levelFilter == "all" || entry.Level == levelFilter {
					logs = append(logs, entry)
				}
			}
		}
	}

	// Limit to 30 entries
	if len(logs) > 30 {
		logs = logs[:30]
	}

	return logs
}

func parseBanLogLine(line string) ui.LogEntry {
	entry := ui.LogEntry{}

	// Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON
	// Fields: $1  |$2  |$3    |$4|$5     |$6    |$7
	parts := strings.Split(line, "|")
	if len(parts) >= 6 {
		// Combine date and time for timestamp
		entry.Timestamp = parts[0] + " " + parts[1]
		entry.Module = parts[2]
		entry.IP = parts[3]
		// parts[4] is COUNTRY (not used in LogEntry)
		action := strings.ToUpper(parts[5])
		if action == "BAN" || action == "BANNED" {
			entry.Level = "BAN"
		} else if action == "UNBAN" || action == "UNBANNED" {
			entry.Level = "UNBAN"
		} else {
			entry.Level = "INFO"
		}
		if len(parts) >= 7 {
			entry.Message = parts[6]
		}
	}

	return entry
}

func (h *GOTHHandlers) checkIP(ip string) ui.IPCheckResult {
	result := ui.IPCheckResult{IP: ip}

	// Run nftban check command
	out, err := exec.Command("nftban", "check", ip, "--json").Output()
	if err != nil {
		// Try without --json
		out, _ = exec.Command("nftban", "check", ip).Output()
		output := string(out)

		if strings.Contains(output, "BLOCKED") || strings.Contains(output, "banned") {
			result.Status = "banned"
		} else if strings.Contains(output, "WHITELISTED") || strings.Contains(output, "whitelisted") {
			result.Status = "whitelisted"
		} else {
			result.Status = "clean"
		}

		// Try to extract reason
		if idx := strings.Index(output, "Reason:"); idx >= 0 {
			result.Reason = strings.TrimSpace(output[idx+7:])
		}

		return result
	}

	// Parse JSON response
	var checkResult map[string]interface{}
	if json.Unmarshal(out, &checkResult) == nil {
		if status, ok := checkResult["status"].(string); ok {
			result.Status = status
		}
		if reason, ok := checkResult["reason"].(string); ok {
			result.Reason = reason
		}
		if module, ok := checkResult["module"].(string); ok {
			result.Module = module
		}
		if country, ok := checkResult["country"].(string); ok {
			result.Country = country
		}
		if since, ok := checkResult["banned_since"].(string); ok {
			result.BannedSince = since
		}
	}

	return result
}

func (h *GOTHHandlers) geoLookup(ip string) ui.GeoLookupResult {
	result := ui.GeoLookupResult{IP: ip}

	// Run nftban geoip command
	out, err := exec.Command("nftban", "geoip", ip, "--json").Output()
	if err != nil {
		// Try nftban-geoip directly
		out, err = exec.Command("nftban-geoip", "lookup", ip).Output()
		if err != nil {
			result.Country = "Unknown"
			return result
		}
	}

	// Parse JSON response
	var geoResult map[string]interface{}
	if json.Unmarshal(out, &geoResult) == nil {
		if country, ok := geoResult["country"].(string); ok {
			result.Country = country
		}
		if code, ok := geoResult["country_code"].(string); ok {
			result.CountryCode = code
		}
		if city, ok := geoResult["city"].(string); ok {
			result.City = city
		}
		if region, ok := geoResult["region"].(string); ok {
			result.Region = region
		}
		if asn, ok := geoResult["asn"].(string); ok {
			result.ASN = asn
		}
		if asnOrg, ok := geoResult["asn_org"].(string); ok {
			result.ASNOrg = asnOrg
		}
		if blocked, ok := geoResult["is_blocked"].(bool); ok {
			result.IsBlocked = blocked
		}
		if reason, ok := geoResult["block_reason"].(string); ok {
			result.BlockReason = reason
		}
	}

	return result
}

func (h *GOTHHandlers) searchIP(ip string) ui.SearchResult {
	result := ui.SearchResult{IP: ip}

	// Run nftban search command
	out, err := exec.Command("nftban", "search", ip, "--json").Output()
	if err != nil {
		// Try without --json
		out, _ = exec.Command("nftban", "search", ip).Output()
		output := string(out)

		if strings.Contains(output, "Found") || strings.Contains(output, "found") {
			result.Found = true
			result.TotalMatches = 1

			// Parse output for matches
			match := ui.SearchMatch{
				SetName:   "blacklist",
				SetType:   "blacklist",
				EntryType: "exact",
			}

			if strings.Contains(output, "whitelist") {
				match.SetName = "whitelist"
				match.SetType = "whitelist"
			} else if strings.Contains(output, "feed") {
				match.SetType = "feed"
			}

			result.FoundIn = append(result.FoundIn, match)
		}

		return result
	}

	// Parse JSON response
	var searchResult map[string]interface{}
	if json.Unmarshal(out, &searchResult) == nil {
		if found, ok := searchResult["found"].(bool); ok {
			result.Found = found
		}
		if matches, ok := searchResult["matches"].([]interface{}); ok {
			result.TotalMatches = len(matches)
			for _, m := range matches {
				if matchMap, ok := m.(map[string]interface{}); ok {
					match := ui.SearchMatch{}
					if name, ok := matchMap["set_name"].(string); ok {
						match.SetName = name
					}
					if stype, ok := matchMap["set_type"].(string); ok {
						match.SetType = stype
					}
					if etype, ok := matchMap["entry_type"].(string); ok {
						match.EntryType = etype
					}
					if cidr, ok := matchMap["matched_cidr"].(string); ok {
						match.MatchedCIDR = cidr
					}
					if reason, ok := matchMap["reason"].(string); ok {
						match.Reason = reason
					}
					result.FoundIn = append(result.FoundIn, match)
				}
			}
		}
	}

	return result
}

// =============================================================================
// FEEDS DATA FETCHER
// =============================================================================

func (h *GOTHHandlers) getFeedsPageData() ui.FeedsPageData {
	data := ui.FeedsPageData{
		LastCheck: time.Now().Format("2006-01-02 15:04:05"),
	}

	// Get feeds list from CLI
	if output, err := execNFTBanCommand("feeds", "list", "--json"); err == nil {
		var feedList []map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &feedList) == nil {
			var maxIPCount int
			for _, f := range feedList {
				feed := ui.FeedEntry{
					Name:        getString(f, "name"),
					Description: getString(f, "description"),
					URL:         getString(f, "url"),
					Enabled:     getBool(f, "enabled"),
					IPCount:     getInt(f, "ip_count"),
					LastSync:    getString(f, "last_sync"),
					NextSync:    getString(f, "next_sync"),
					SyncErrors:  getInt(f, "errors"),
					LastError:   getString(f, "last_error"),
				}

				// Determine status
				if status := getString(f, "status"); status != "" {
					feed.Status = status
				} else if !feed.Enabled {
					feed.Status = "disabled"
				} else if feed.SyncErrors > 0 {
					feed.Status = "error"
				} else if feed.LastSync == "" || feed.LastSync == "never" {
					feed.Status = "stale"
				} else {
					feed.Status = "active"
				}

				data.Feeds = append(data.Feeds, feed)
				data.TotalFeeds++
				data.TotalIPs += feed.IPCount

				if feed.IPCount > maxIPCount {
					maxIPCount = feed.IPCount
				}

				// Count by status
				switch feed.Status {
				case "active", "syncing":
					data.ActiveFeeds++
				case "stale":
					data.StaleFeeds++
				case "error":
					data.ErrorFeeds++
				}
			}

			// Build top feeds chart data
			for _, feed := range data.Feeds {
				if feed.IPCount > 0 {
					percent := float64(feed.IPCount) / float64(maxIPCount) * 100
					if maxIPCount == 0 {
						percent = 0
					}
					data.TopFeeds = append(data.TopFeeds, ui.FeedChartEntry{
						Name:    feed.Name,
						IPCount: feed.IPCount,
						Percent: percent,
					})
				}
			}
		}
	}

	// Get recent sync activity from logs
	data.RecentActivity = h.getRecentFeedActivity()

	return data
}

// getRecentFeedActivity fetches recent feed sync events
func (h *GOTHHandlers) getRecentFeedActivity() []ui.FeedSyncActivity {
	activity := []ui.FeedSyncActivity{}

	cfg := nftbanconf.MustLoad()
	logFile := cfg.LogDir + "/feeds.log"

	// Read last 30 lines of feeds.log
	if content, err := os.ReadFile(logFile); err == nil {
		lines := strings.Split(string(content), "\n")
		start := len(lines) - 30
		if start < 0 {
			start = 0
		}

		for i := len(lines) - 1; i >= start && len(activity) < 15; i-- {
			line := strings.TrimSpace(lines[i])
			if line == "" {
				continue
			}

			// Parse feed log line (format: timestamp|action|feed_name|details)
			parts := strings.Split(line, "|")
			if len(parts) >= 3 {
				entry := ui.FeedSyncActivity{
					Timestamp: parts[0],
					FeedName:  parts[2],
					Status:    "success",
				}

				action := strings.ToLower(parts[1])
				if strings.Contains(action, "error") || strings.Contains(action, "fail") {
					entry.Status = "error"
					if len(parts) >= 4 {
						entry.Error = parts[3]
					}
				} else if strings.Contains(action, "sync") || strings.Contains(action, "update") {
					entry.Status = "success"
					// Try to parse IPs added/removed
					if len(parts) >= 4 {
						details := parts[3]
						if strings.Contains(details, "+") {
							fmt.Sscanf(details, "+%d", &entry.IPsAdded)
						}
						if strings.Contains(details, "-") {
							fmt.Sscanf(details, "%*s-%d", &entry.IPsRemoved)
						}
					}
				}

				activity = append(activity, entry)
			}
		}
	}

	return activity
}
