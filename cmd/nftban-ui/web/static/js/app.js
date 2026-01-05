// /web/static/js/app.js
// NFTBan SPA loader + theme + backend wiring

(() => {
  const root = document.documentElement;
  const navItems = document.querySelectorAll(".nav-item");
  const pageContainer = document.getElementById("page-container");
  const themeToggleBtn = document.getElementById("theme-toggle");
  const themeIcon = themeToggleBtn.querySelector("i");

  // In-memory cache of loaded pages
  const pageCache = {};

  // -----------------------------
  // THEME HANDLING
  // -----------------------------
  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);
    localStorage.setItem("nftban-theme", theme);
    themeIcon.className = theme === "dark" ? "fa fa-moon" : "fa fa-sun";
  }

  function initTheme() {
    const saved = localStorage.getItem("nftban-theme");
    const initial = saved || "dark";
    applyTheme(initial);
  }

  themeToggleBtn.addEventListener("click", () => {
    const current =
      root.getAttribute("data-theme") === "dark" ? "dark" : "light";
    const next = current === "dark" ? "light" : "dark";
    applyTheme(next);
  });

  // -----------------------------
  // PAGE LOADING
  // -----------------------------
  async function loadPage(pageName) {
    // Handle deprecated pages - redirect to replacements
    if (pageName === 'fail2ban') {
      console.warn('[DEPRECATED] Fail2Ban removed in v1.0 - redirecting to Login Monitor');
      pageName = 'login-monitor';
      window.location.hash = 'login-monitor';
    }

    // Mark active menu item
    navItems.forEach((item) => {
      item.classList.toggle("active", item.dataset.page === pageName);
    });

    // Use cache if available
    if (pageCache[pageName]) {
      pageContainer.innerHTML = pageCache[pageName];
      return;
    }

    pageContainer.innerHTML =
      '<div class="loading-message">Loading…</div>';

    try {
      const res = await fetch(`/static/pages/${pageName}.html`, {
        cache: "no-cache",
      });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }
      const html = await res.text();
      pageCache[pageName] = html;
      pageContainer.innerHTML = html;

      // Execute inline scripts (innerHTML doesn't execute them automatically)
      const scripts = pageContainer.querySelectorAll('script');
      scripts.forEach(oldScript => {
        const newScript = document.createElement('script');
        Array.from(oldScript.attributes).forEach(attr => {
          newScript.setAttribute(attr.name, attr.value);
        });
        newScript.textContent = oldScript.textContent;
        oldScript.parentNode.replaceChild(newScript, oldScript);
      });
    } catch (err) {
      console.error("Error loading page", pageName, err);
      pageContainer.innerHTML = `
        <div class="error-message">
          <h3>Failed to load <code>${pageName}.html</code></h3>
          <p>${err.message}</p>
        </div>
      `;
    }
  }

  function initNav() {
    navItems.forEach((item) => {
      item.addEventListener("click", (e) => {
        e.preventDefault();
        const pageName = item.dataset.page;
        if (!pageName) return;
        loadPage(pageName);
        window.location.hash = pageName;
      });
    });
  }

  function initFromHashOrDefault() {
    const hash = window.location.hash.replace("#", "");
    const defaultPage = hash || "dashboard";
    loadPage(defaultPage);
  }

  window.addEventListener("hashchange", () => {
    const hash = window.location.hash.replace("#", "");
    if (!hash) return;
    loadPage(hash);
  });

  // -----------------------------
  // AUTHENTICATION
  // -----------------------------
  function showLogin() {
    document.getElementById("login-screen").style.display = "flex";
    document.getElementById("nftban-app").style.display = "none";
  }

  function showApp() {
    document.getElementById("login-screen").style.display = "none";
    document.getElementById("nftban-app").style.display = "block";
  }

  async function handleLogin(e) {
    e.preventDefault();

    const username = document.getElementById("login-username").value.trim();
    const password = document.getElementById("login-password").value.trim();
    const submitBtn = e.target.querySelector('button[type="submit"]');
    const errorEl = document.getElementById("login-error");

    if (!username || !password) {
      errorEl.textContent = "Please enter username and password";
      errorEl.style.display = "block";
      return;
    }

    // Disable button and show loading
    submitBtn.disabled = true;
    submitBtn.textContent = "Signing in...";
    errorEl.style.display = "none";

    try {
      const response = await fetch("/api/v1/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password })
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(errorText || `Login failed: ${response.status}`);
      }

      const data = await response.json();

      if (data.token) {
        // Save token to localStorage
        localStorage.setItem("token", data.token);
        console.log("[AUTH] Login successful, token saved");

        // Clear password field
        document.getElementById("login-password").value = "";

        // Show app
        showApp();

        // Load initial page
        initFromHashOrDefault();
      } else {
        throw new Error("No token received from server");
      }
    } catch (error) {
      console.error("[AUTH] Login error:", error);
      errorEl.textContent = error.message || "Login failed";
      errorEl.style.display = "block";
      submitBtn.disabled = false;
      submitBtn.textContent = "Sign In";
    }
  }

  async function handleLogout() {
    const token = localStorage.getItem("token") || localStorage.getItem("session_token");

    // Call logout API to invalidate session server-side (key security improvement)
    if (token) {
      try {
        await fetch("/api/v1/logout", {
          method: "POST",
          headers: {
            "X-Session-Token": token,
            "Content-Type": "application/json"
          }
        });
        console.log("[AUTH] Session invalidated on server");
      } catch (err) {
        console.warn("[AUTH] Logout API call failed:", err);
        // Continue with local cleanup even if server call fails
      }
    }

    // Clear all token variants from localStorage
    localStorage.removeItem("token");
    localStorage.removeItem("session_token");
    localStorage.removeItem("nftban-token");
    localStorage.removeItem("jwt_token");
    console.log("[AUTH] Logged out, tokens cleared");
    showLogin();
  }

  async function checkAuth() {
    // Check all possible token storage keys
    const token = localStorage.getItem("token") ||
                  localStorage.getItem("session_token") ||
                  localStorage.getItem("nftban-token") ||
                  localStorage.getItem("jwt_token");

    if (!token) {
      console.log("[AUTH] No token found, showing login");
      showLogin();
      return false;
    }

    // Validate token with backend using session header
    try {
      console.log("[AUTH] Token found, validating with backend...");
      const response = await fetch("/api/v1/health", {
        headers: {
          "X-Session-Token": token,
          "Authorization": "Bearer " + token  // Fallback for backward compatibility
        }
      });

      if (response.ok) {
        console.log("[AUTH] Token valid, auto-login successful");
        showApp();
        return true;
      } else {
        console.log("[AUTH] Token invalid or expired, clearing and showing login");
        localStorage.removeItem("token");
        localStorage.removeItem("session_token");
        localStorage.removeItem("nftban-token");
        localStorage.removeItem("jwt_token");
        showLogin();
        return false;
      }
    } catch (error) {
      console.error("[AUTH] Error validating token:", error);
      showLogin();
      return false;
    }
  }

  // -----------------------------
  // MOBILE MENU TOGGLE
  // -----------------------------
  function initMobileMenu() {
    const menuToggle = document.getElementById('menu-toggle');
    const sidebar = document.querySelector('.sidebar');

    if (menuToggle && sidebar) {
      // Create overlay element
      let overlay = document.querySelector('.sidebar-overlay');
      if (!overlay) {
        overlay = document.createElement('div');
        overlay.className = 'sidebar-overlay';
        document.querySelector('.container').appendChild(overlay);
      }

      // Toggle menu on button click
      menuToggle.addEventListener('click', (e) => {
        e.stopPropagation();
        sidebar.classList.toggle('open');
        overlay.classList.toggle('active');
      });

      // Close menu when clicking overlay
      overlay.addEventListener('click', () => {
        sidebar.classList.remove('open');
        overlay.classList.remove('active');
      });

      // Close menu when clicking a nav item (on mobile)
      navItems.forEach(item => {
        item.addEventListener('click', () => {
          if (window.innerWidth <= 768) {
            sidebar.classList.remove('open');
            overlay.classList.remove('active');
          }
        });
      });
    }
  }

  // -----------------------------
  // INIT
  // -----------------------------
  document.addEventListener("DOMContentLoaded", () => {
    initTheme();
    initNav();
    initMobileMenu();

    // Setup login handler
    const loginForm = document.getElementById("login-form");
    if (loginForm) {
      loginForm.addEventListener("submit", handleLogin);
    }

    // Setup logout handler
    const logoutBtn = document.getElementById("logout-btn");
    if (logoutBtn) {
      logoutBtn.addEventListener("click", handleLogout);
    }

    // Check authentication and show appropriate screen
    checkAuth().then(isAuthenticated => {
      if (isAuthenticated) {
        initFromHashOrDefault();
      }
    });
  });

  // -----------------------------
  // GLOBAL API HELPER
  // -----------------------------
  // Generic helper used by all pages: IP management, ban, unban, etc.
  window.apiRequest = async function (endpoint, options = {}) {
    // API routes are under /api/v1 (see main.go)
    const API_BASE = "/api/v1";

    const url = endpoint.startsWith("http")
      ? endpoint
      : API_BASE + endpoint;

    const {
      method = "GET",
      body = null,
      headers = {},
      ...rest
    } = options;

    const finalHeaders = {
      "Content-Type": "application/json",
      ...headers,
      ...window.getAuthHeaders?.(), // merge auth headers if defined
    };

    const fetchOptions = {
      method,
      headers: finalHeaders,
      ...rest,
    };

    if (body !== null && method !== "GET") {
      fetchOptions.body =
        typeof body === "string" ? body : JSON.stringify(body);
    }

    let res;
    try {
      res = await fetch(url, fetchOptions);
    } catch (err) {
      // Network / connection errors
      throw new Error("Network error: " + err.message);
    }

    let data = null;
    const text = await res.text();

    if (!res.ok) {
      // Try to parse error as JSON first
      try {
        const errorData = text ? JSON.parse(text) : null;
        const msg = (errorData && errorData.error) || res.statusText || "HTTP " + res.status;
        throw new Error(msg);
      } catch (e) {
        // If JSON parse fails, use raw text or status
        throw new Error(text || res.statusText || "HTTP " + res.status);
      }
    }

    // Parse successful response
    try {
      data = text ? JSON.parse(text) : null;
    } catch (parseError) {
      // Not JSON – log warning and return raw text
      console.warn(`[API] Response is not JSON for ${endpoint}:`, text.substring(0, 100));
      throw new Error(`Invalid JSON response: ${parseError.message}`);
    }

    return data;
  };

  // -----------------------------
  // GLOBAL HOOKS FOR OLD HTML
  // -----------------------------
  // Some older HTML uses onclick="showSection('xxx')" – keep it working:
  window.showSection = function (sectionId) {
    // This will trigger the existing hashchange handler,
    // which calls loadPage(sectionId)
    if (!sectionId) return;
    window.location.hash = sectionId;
  };

  // Some elements call validateHierarchy() in onclick.
  // For now just always allow; you can implement real logic later.
  window.validateHierarchy = function () {
    // return false here if you ever want to block navigation
    return true;
  };

  // -----------------------------
  // AUTH HEADER HELPER
  // -----------------------------
  // Returns auth headers for API requests (session-based auth)
  window.getAuthHeaders = function () {
    // Check all possible token storage keys
    const token = localStorage.getItem("token") ||
                  localStorage.getItem("session_token") ||
                  localStorage.getItem("nftban-token") ||
                  localStorage.getItem("jwt_token");
    if (!token) {
      console.warn('[AUTH] No token found');
      return {};
    }
    // Use X-Session-Token header (with Bearer fallback for compatibility)
    return {
      "X-Session-Token": token,
      "Authorization": "Bearer " + token,  // Backward compatibility
    };
  };

  // -----------------------------
  // FAIL2BAN UI HELPER
  // -----------------------------
  // Older inline scripts call updateF2BStatus(data)
  window.updateF2BStatus = function (data) {
    console.log("[F2B] updateF2BStatus called with:", data);

    // Try to render something useful if DOM ids exist
    const statusEl = document.getElementById("f2b-status");
    const jailsEl = document.getElementById("f2b-jails");

    if (statusEl && data) {
      const running = data.running ?? data.enabled ?? null;
      if (running === true) {
        statusEl.textContent = "Running";
        statusEl.classList.add("badge-success");
      } else if (running === false) {
        statusEl.textContent = "Stopped";
        statusEl.classList.add("badge-danger");
      } else {
        statusEl.textContent = "Unknown";
      }
    }

    if (jailsEl && data && Array.isArray(data.jails)) {
      jailsEl.innerHTML = "";
      data.jails.forEach((jail) => {
        const li = document.createElement("li");
        li.textContent = jail.name || String(jail);
        jailsEl.appendChild(li);
      });
    }
  };

  // -----------------------------
  // FEEDS COUNTER HELPER
  // -----------------------------
  // Older HTML uses onchange="updateFeedsCount(...)" or similar
  window.updateFeedsCount = function (count) {
    console.log("[FEEDS] updateFeedsCount:", count);
    const el = document.getElementById("feeds-count");
    if (el) {
      el.textContent = count != null ? String(count) : "-";
    }
  };

  window.loadF2BJails = async function () {
    // DEPRECATED: Fail2Ban removed in v1.0 - replaced by Login Monitor
    console.warn('[DEPRECATED] Fail2Ban removed in v1.0 - use Login Monitor instead');
    // Redirect to login-monitor page
    window.location.hash = 'login-monitor';
  };

  window.loadFeeds = async function () {
    // Load threat feeds from API
    try {
      const data = await apiRequest('/feeds');
      console.log('Feeds loaded:', data);
    } catch (err) {
      console.error('Failed to load feeds:', err);
    }
  };
})();
