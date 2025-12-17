// NFTBan Modern GUI - JavaScript Application

// Global state
let authToken = localStorage.getItem('authToken') || '';
let currentTheme = localStorage.getItem('theme') || 'dark';

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    initTheme();
    if (authToken) {
        showDashboard();
    } else {
        showLogin();
    }
    setupEventListeners();
});

// ============================================================================
// THEME MANAGEMENT
// ============================================================================

function initTheme() {
    document.documentElement.setAttribute('data-theme', currentTheme);
    updateThemeIcons();
}

function toggleTheme() {
    currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
    localStorage.setItem('theme', currentTheme);
    document.documentElement.setAttribute('data-theme', currentTheme);
    updateThemeIcons();
}

function updateThemeIcons() {
    const icons = document.querySelectorAll('#theme-toggle-login i, #theme-toggle-dash i');
    icons.forEach(icon => {
        icon.className = currentTheme === 'dark' ? 'fa-solid fa-sun' : 'fa-solid fa-moon';
    });
}

// ============================================================================
// PAGE NAVIGATION
// ============================================================================

function showLogin() {
    document.getElementById('login-page').style.display = 'flex';
    document.getElementById('dashboard-page').style.display = 'none';
}

function showDashboard() {
    document.getElementById('login-page').style.display = 'none';
    document.getElementById('dashboard-page').style.display = 'flex';
    loadDashboardData();
}

function showPanel(panelName) {
    // Hide all panels
    document.querySelectorAll('.panel').forEach(panel => {
        panel.classList.remove('active');
    });

    // Show selected panel
    const panel = document.getElementById(`panel-${panelName}`);
    if (panel) {
        panel.classList.add('active');
    }

    // Update sidebar active state
    document.querySelectorAll('.sidebar a').forEach(link => {
        link.classList.remove('active');
    });
    event.target.closest('a').classList.add('active');

    // Load panel-specific data
    switch(panelName) {
        case 'dashboard':
            loadDashboardData();
            break;
        case 'ipmgmt':
            loadBannedIPs();
            break;
        case 'fail2ban':
            loadFail2BanStatus();
            break;
        case 'feeds':
            loadFeeds();
            break;
        case 'portscan':
            loadPortScanStatus();
            break;
        case 'geoban':
            loadGeoBanStatus();
            break;
    }
}

// ============================================================================
// AUTHENTICATION
// ============================================================================

function setupEventListeners() {
    // Login form
    const loginForm = document.getElementById('login-form');
    if (loginForm) {
        loginForm.addEventListener('submit', handleLogin);
    }

    // Theme toggles
    document.getElementById('theme-toggle-login')?.addEventListener('click', toggleTheme);
    document.getElementById('theme-toggle-dash')?.addEventListener('click', toggleTheme);

    // Ban form
    const banForm = document.getElementById('form-ban');
    if (banForm) {
        banForm.addEventListener('submit', handleBanIP);
    }
}

async function handleLogin(e) {
    e.preventDefault();
    const formData = new FormData(e.target);

    try {
        const response = await fetch('/api/v1/login', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({
                username: formData.get('username'),
                password: formData.get('password')
            })
        });

        const data = await response.json();

        if (response.ok && data.token) {
            authToken = data.token;
            localStorage.setItem('authToken', authToken);
            showDashboard();
        } else {
            alert('Login failed: ' + (data.message || 'Invalid credentials'));
        }
    } catch (error) {
        console.error('Login error:', error);
        alert('Login failed: ' + error.message);
    }
}

function logout() {
    authToken = '';
    localStorage.removeItem('authToken');
    showLogin();
}

function getAuthHeaders() {
    return {
        'Authorization': `Bearer ${authToken}`,
        'Content-Type': 'application/json'
    };
}

// ============================================================================
// DASHBOARD DATA
// ============================================================================

async function loadDashboardData() {
    try {
        const [traffic, bans, countries] = await Promise.all([
            fetch('/api/v1/stats/traffic', {headers: getAuthHeaders()}).then(r => r.json()),
            fetch('/api/v1/stats/bans', {headers: getAuthHeaders()}).then(r => r.json()),
            fetch('/api/v1/stats/countries', {headers: getAuthHeaders()}).then(r => r.json())
        ]);

        // Update stats
        document.getElementById('stat-bans').textContent = bans.total || 0;
        document.getElementById('stat-countries').textContent = countries.total || 0;
        document.getElementById('stat-traffic').textContent = formatBytes(traffic.total || 0);

        // Update charts
        updateBansChart(bans);
        updateCountriesChart(countries);

    } catch (error) {
        console.error('Failed to load dashboard data:', error);
    }
}

function updateBansChart(data) {
    const ctx = document.getElementById('chart-bans');
    if (!ctx) return;

    new Chart(ctx, {
        type: 'line',
        data: {
            labels: data.labels || ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
            datasets: [{
                label: 'Bans',
                data: data.values || [12, 19, 3, 5, 2, 3, 7],
                borderColor: '#0075ff',
                backgroundColor: 'rgba(0, 117, 255, 0.1)',
                tension: 0.4
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false
        }
    });
}

function updateCountriesChart(data) {
    const ctx = document.getElementById('chart-countries');
    if (!ctx) return;

    new Chart(ctx, {
        type: 'bar',
        data: {
            labels: data.labels || ['CN', 'RU', 'US', 'BR', 'IN'],
            datasets: [{
                label: 'Blocked IPs',
                data: data.values || [45, 32, 28, 15, 12],
                backgroundColor: '#22c55e'
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false
        }
    });
}

// ============================================================================
// IP MANAGEMENT
// ============================================================================

async function handleBanIP(e) {
    e.preventDefault();
    const formData = new FormData(e.target);
    const ip = formData.get('ip');

    try {
        const response = await fetch('/api/v1/ban', {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({ip})
        });

        const data = await response.json();

        if (response.ok) {
            alert(`Successfully banned ${ip}`);
            e.target.reset();
            loadBannedIPs();
        } else {
            alert('Ban failed: ' + (data.message || 'Unknown error'));
        }
    } catch (error) {
        console.error('Ban error:', error);
        alert('Ban failed: ' + error.message);
    }
}

async function loadBannedIPs() {
    try {
        const response = await fetch('/api/v1/ui/list-ips', {
            headers: getAuthHeaders()
        });

        const data = await response.json();
        const container = document.getElementById('banned-ips-list');

        if (!container) return;

        if (data.bans && data.bans.length > 0) {
            container.innerHTML = data.bans.map(ip => `
                <div class="list-item">
                    <span>${ip}</span>
                    <button class="btn-shape bg-red c-white" onclick="unbanIP('${ip}')">
                        <i class="fa-solid fa-trash"></i> Unban
                    </button>
                </div>
            `).join('');
        } else {
            container.innerHTML = '<div class="txt-c c-grey p-20">No banned IPs</div>';
        }
    } catch (error) {
        console.error('Failed to load banned IPs:', error);
    }
}

async function unbanIP(ip) {
    if (!confirm(`Unban ${ip}?`)) return;

    try {
        const response = await fetch('/api/v1/unban', {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({ip})
        });

        if (response.ok) {
            alert(`Successfully unbanned ${ip}`);
            loadBannedIPs();
        } else {
            alert('Unban failed');
        }
    } catch (error) {
        console.error('Unban error:', error);
        alert('Unban failed: ' + error.message);
    }
}

// ============================================================================
// FAIL2BAN
// ============================================================================

async function loadFail2BanStatus() {
    try {
        const response = await fetch('/api/v1/fail2ban/jails', {
            headers: getAuthHeaders()
        });

        const data = await response.json();
        const container = document.getElementById('f2b-jails');

        if (!container) return;

        if (data.jails && data.jails.length > 0) {
            container.innerHTML = data.jails.map(jail => `
                <div class="list-item">
                    <div>
                        <div class="fw-bold">${jail.name}</div>
                        <div class="c-grey fs-13">${jail.banned || 0} banned</div>
                    </div>
                    <span class="badge ${jail.enabled ? 'bg-green' : 'bg-red'} c-white">
                        ${jail.enabled ? 'Active' : 'Inactive'}
                    </span>
                </div>
            `).join('');

            // Update badge
            const totalBanned = data.jails.reduce((sum, j) => sum + (j.banned || 0), 0);
            document.getElementById('f2b-badge').textContent = totalBanned;
        } else {
            container.innerHTML = '<div class="txt-c c-grey p-20">No jails configured</div>';
        }
    } catch (error) {
        console.error('Failed to load Fail2Ban status:', error);
    }
}

// ============================================================================
// FEEDS
// ============================================================================

async function loadFeeds() {
    try {
        const response = await fetch('/api/v1/feeds', {
            headers: getAuthHeaders()
        });

        const data = await response.json();
        const container = document.getElementById('feeds-list');

        if (!container) return;

        if (data.feeds && data.feeds.length > 0) {
            container.innerHTML = data.feeds.map(feed => `
                <div class="list-item">
                    <div>
                        <div class="fw-bold">${feed.name}</div>
                        <div class="c-grey fs-13">${feed.ips || 0} IPs</div>
                    </div>
                    <span class="badge ${feed.enabled ? 'bg-green' : 'bg-red'} c-white">
                        ${feed.enabled ? 'Enabled' : 'Disabled'}
                    </span>
                </div>
            `).join('');

            // Update badge
            document.getElementById('feeds-badge').textContent = data.feeds.length;
        } else {
            container.innerHTML = '<div class="txt-c c-grey p-20">No feeds configured</div>';
        }
    } catch (error) {
        console.error('Failed to load feeds:', error);
    }
}

// ============================================================================
// PORT SCAN
// ============================================================================

async function loadPortScanStatus() {
    try {
        const response = await fetch('/api/v1/config/portscan', {
            headers: getAuthHeaders()
        });

        const data = await response.json();
        const btn = document.getElementById('ps-toggle');

        if (btn && data.enabled !== undefined) {
            btn.className = `btn-shape ${data.enabled ? 'bg-red' : 'bg-green'} c-white`;
            btn.innerHTML = `<i class="fa-solid fa-power-off"></i> ${data.enabled ? 'Disable' : 'Enable'} Detection`;
        }
    } catch (error) {
        console.error('Failed to load port scan status:', error);
    }
}

async function togglePortScan() {
    try {
        const response = await fetch('/api/v1/portscan/control', {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({action: 'toggle'})
        });

        if (response.ok) {
            loadPortScanStatus();
        }
    } catch (error) {
        console.error('Failed to toggle port scan:', error);
    }
}

// ============================================================================
// GEOBAN
// ============================================================================

async function loadGeoBanStatus() {
    try {
        const response = await fetch('/api/v1/geoban/stats', {
            headers: getAuthHeaders()
        });

        const data = await response.json();
        const container = document.getElementById('geoban-list');

        if (!container) return;

        if (data.countries && data.countries.length > 0) {
            container.innerHTML = data.countries.map(country => `
                <div class="list-item">
                    <div>
                        <div class="fw-bold">${country.code} - ${country.name}</div>
                        <div class="c-grey fs-13">${country.count || 0} IPs blocked</div>
                    </div>
                </div>
            `).join('');

            // Update badge
            document.getElementById('geoban-badge').textContent = data.countries.length;
        } else {
            container.innerHTML = '<div class="txt-c c-grey p-20">No countries blocked</div>';
        }
    } catch (error) {
        console.error('Failed to load GeoBan status:', error);
    }
}

// ============================================================================
// LOGS
// ============================================================================

async function loadLogs() {
    const logFile = document.getElementById('log-file').value;
    const container = document.getElementById('logs-viewer');

    if (!container) return;

    container.innerHTML = '<div class="txt-c c-grey p-20">Loading...</div>';

    try {
        const response = await fetch(`/api/v1/logs?type=${logFile}`, {
            headers: getAuthHeaders()
        });

        const data = await response.json();

        if (data.logs) {
            container.innerHTML = `<pre>${data.logs}</pre>`;
        } else {
            container.innerHTML = '<div class="txt-c c-grey p-20">No logs available</div>';
        }
    } catch (error) {
        console.error('Failed to load logs:', error);
        container.innerHTML = '<div class="txt-c c-red p-20">Failed to load logs</div>';
    }
}

// ============================================================================
// UTILITIES
// ============================================================================

function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
}
