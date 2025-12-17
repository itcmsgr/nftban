// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2025 NFTBan Development Team
//
// Bandwidth Monitoring Panel - Main JavaScript
// Handles data fetching, chart updates, and UI interactions

/**
 * Bandwidth Panel Controller
 */
class BandwidthPanel {
    constructor() {
        this.charts = {};
        this.sparklines = {};
        this.updateInterval = null;
        this.refreshRate = 10000; // 10 seconds
        this.useMockData = true; // Set to false when API is ready
        this.mockDataPath = 'shared/api_test_data.json';
        this.apiBasePath = '/api/v1/bandwidth';

        this.init();
    }

    /**
     * Initialize the bandwidth panel
     */
    async init() {
        console.log('🚀 Initializing Bandwidth Panel...');

        // Wait for DOM to be ready
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => this.setup());
        } else {
            this.setup();
        }
    }

    /**
     * Setup the panel
     */
    async setup() {
        try {
            // Initialize charts
            this.initializeCharts();

            // Load initial data
            await this.loadData();

            // Start auto-refresh
            this.startAutoRefresh();

            // Setup event listeners
            this.setupEventListeners();

            console.log('✅ Bandwidth Panel initialized successfully');
        } catch (error) {
            console.error('❌ Failed to initialize Bandwidth Panel:', error);
            this.showError('Failed to initialize bandwidth monitoring');
        }
    }

    /**
     * Initialize all charts
     */
    initializeCharts() {
        // Main bandwidth time-series chart
        const bandwidthCanvas = document.getElementById('bandwidthChart');
        if (bandwidthCanvas) {
            const colors = getColors();
            this.charts.bandwidth = createRealtimeChart(bandwidthCanvas, [
                {
                    label: 'Receive (Mbps)',
                    data: [],
                    borderColor: colors.primary,
                    backgroundColor: `${colors.primary}20`,
                    tension: 0.4,
                    fill: true
                },
                {
                    label: 'Transmit (Mbps)',
                    data: [],
                    borderColor: colors.secondary,
                    backgroundColor: `${colors.secondary}20`,
                    tension: 0.4,
                    fill: true
                }
            ]);
        }

        // Interface bar chart
        const interfaceCanvas = document.getElementById('interfaceChart');
        if (interfaceCanvas) {
            this.charts.interface = createInterfaceBarChart(interfaceCanvas, [], [], []);
        }

        // Protocol doughnut chart
        const protocolCanvas = document.getElementById('protocolChart');
        if (protocolCanvas) {
            this.charts.protocol = createProtocolChart(protocolCanvas, {});
        }

        // Sparklines for stat cards
        this.initializeSparklines();
    }

    /**
     * Initialize sparkline charts in stat cards
     */
    initializeSparklines() {
        const sparklineConfigs = [
            { id: 'sparklineRx', color: getColors().primary },
            { id: 'sparklineTx', color: getColors().secondary },
            { id: 'sparklineConnections', color: getColors().success },
            { id: 'sparklinePeak', color: getColors().warning }
        ];

        sparklineConfigs.forEach(config => {
            const canvas = document.getElementById(config.id);
            if (canvas) {
                // Initialize with empty data
                this.sparklines[config.id] = createSparkline(canvas, Array(30).fill(0), config.color);
            }
        });
    }

    /**
     * Load bandwidth data
     */
    async loadData() {
        try {
            this.showLoading(true);

            let data;
            if (this.useMockData) {
                data = await this.loadMockData();
            } else {
                data = await this.loadApiData();
            }

            this.updateUI(data);
            this.showLoading(false);
        } catch (error) {
            console.error('Failed to load data:', error);
            this.showError('Failed to load bandwidth data');
            this.showLoading(false);
        }
    }

    /**
     * Load mock data for development
     */
    async loadMockData() {
        try {
            const response = await fetch(this.mockDataPath);
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return await response.json();
        } catch (error) {
            console.error('Failed to load mock data:', error);
            throw error;
        }
    }

    /**
     * Load data from real API
     */
    async loadApiData() {
        try {
            const [current, history, interfaces] = await Promise.all([
                fetch(`${this.apiBasePath}/current`).then(r => r.json()),
                fetch(`${this.apiBasePath}/history?minutes=5`).then(r => r.json()),
                fetch(`${this.apiBasePath}/interfaces`).then(r => r.json())
            ]);

            return {
                bandwidth_current: current,
                bandwidth_history: history,
                bandwidth_interfaces: interfaces
            };
        } catch (error) {
            console.error('Failed to load API data:', error);
            throw error;
        }
    }

    /**
     * Update UI with new data
     */
    updateUI(data) {
        if (!data) return;

        // Update stat cards
        this.updateStatCards(data.bandwidth_current);

        // Update time-series chart
        this.updateBandwidthChart(data.bandwidth_history);

        // Update interface chart
        this.updateInterfaceChart(data.bandwidth_interfaces);

        // Update protocol chart
        if (data.bandwidth_current?.protocols) {
            this.updateProtocolChart(data.bandwidth_current.protocols);
        }

        // Update connections table
        if (data.bandwidth_connections) {
            this.updateConnectionsTable(data.bandwidth_connections);
        }

        // Update sparklines
        this.updateSparklines(data.bandwidth_history);

        // Update timestamp
        this.updateTimestamp();
    }

    /**
     * Update stat cards with current values
     */
    updateStatCards(current) {
        if (!current) return;

        // RX Bandwidth
        const rxElement = document.getElementById('statRxBandwidth');
        if (rxElement && current.total) {
            rxElement.textContent = formatBandwidth(current.total.rx_mbps);
        }

        // TX Bandwidth
        const txElement = document.getElementById('statTxBandwidth');
        if (txElement && current.total) {
            txElement.textContent = formatBandwidth(current.total.tx_mbps);
        }

        // Active Connections
        const connElement = document.getElementById('statConnections');
        if (connElement && current.connections) {
            connElement.textContent = current.connections.active.toLocaleString();
        }

        // Peak RX
        const peakElement = document.getElementById('statPeakRx');
        if (peakElement && current.peaks_5min) {
            peakElement.textContent = formatBandwidth(current.peaks_5min.rx_mbps);
        }
    }

    /**
     * Update bandwidth time-series chart
     */
    updateBandwidthChart(history) {
        if (!history || !history.data || !this.charts.bandwidth) return;

        const rxData = history.data.map(d => ({
            x: new Date(d.timestamp * 1000),
            y: d.rx_mbps
        }));

        const txData = history.data.map(d => ({
            x: new Date(d.timestamp * 1000),
            y: d.tx_mbps
        }));

        this.charts.bandwidth.data.datasets[0].data = rxData;
        this.charts.bandwidth.data.datasets[1].data = txData;
        this.charts.bandwidth.update('none');
    }

    /**
     * Update interface bar chart
     */
    updateInterfaceChart(interfaceData) {
        if (!interfaceData || !interfaceData.interfaces || !this.charts.interface) return;

        const labels = interfaceData.interfaces.map(i => i.name);
        const rxData = interfaceData.interfaces.map(i => i.rx_mbps);
        const txData = interfaceData.interfaces.map(i => i.tx_mbps);

        this.charts.interface.data.labels = labels;
        this.charts.interface.data.datasets[0].data = rxData;
        this.charts.interface.data.datasets[1].data = txData;
        this.charts.interface.update('none');
    }

    /**
     * Update protocol doughnut chart
     */
    updateProtocolChart(protocols) {
        if (!protocols || !this.charts.protocol) return;

        const data = [
            protocols.tcp?.packets || 0,
            protocols.udp?.packets || 0,
            protocols.icmp?.packets || 0
        ];

        this.charts.protocol.data.datasets[0].data = data;
        this.charts.protocol.update('none');
    }

    /**
     * Update sparklines with historical data
     */
    updateSparklines(history) {
        if (!history || !history.data) return;

        // Get last 30 data points
        const recentData = history.data.slice(-30);

        // RX sparkline
        if (this.sparklines.sparklineRx) {
            const rxData = recentData.map(d => d.rx_mbps);
            this.sparklines.sparklineRx.data.datasets[0].data = rxData;
            this.sparklines.sparklineRx.update('none');
        }

        // TX sparkline
        if (this.sparklines.sparklineTx) {
            const txData = recentData.map(d => d.tx_mbps);
            this.sparklines.sparklineTx.data.datasets[0].data = txData;
            this.sparklines.sparklineTx.update('none');
        }

        // Connections sparkline (use RX as proxy for now)
        if (this.sparklines.sparklineConnections) {
            const connData = recentData.map(d => d.rx_mbps + d.tx_mbps);
            this.sparklines.sparklineConnections.data.datasets[0].data = connData;
            this.sparklines.sparklineConnections.update('none');
        }

        // Peak sparkline
        if (this.sparklines.sparklinePeak) {
            const peakData = recentData.map(d => Math.max(d.rx_mbps, d.tx_mbps));
            this.sparklines.sparklinePeak.data.datasets[0].data = peakData;
            this.sparklines.sparklinePeak.update('none');
        }
    }

    /**
     * Update connections table
     */
    updateConnectionsTable(connectionsData) {
        const tbody = document.getElementById('connectionsTableBody');
        if (!tbody || !connectionsData || !connectionsData.connections) return;

        tbody.innerHTML = '';

        connectionsData.connections.slice(0, 10).forEach(conn => {
            const row = tbody.insertRow();
            row.innerHTML = `
                <td class="px-4 py-2 text-sm">${conn.remote_ip}</td>
                <td class="px-4 py-2 text-sm">${conn.remote_port}</td>
                <td class="px-4 py-2 text-sm uppercase">${conn.protocol}</td>
                <td class="px-4 py-2 text-sm">${conn.state}</td>
                <td class="px-4 py-2 text-sm">${formatBytes(conn.rx_bytes)}</td>
                <td class="px-4 py-2 text-sm">${formatBytes(conn.tx_bytes)}</td>
            `;
        });

        if (connectionsData.connections.length === 0) {
            const row = tbody.insertRow();
            row.innerHTML = '<td colspan="6" class="px-4 py-4 text-center text-sm text-gray-500">No active connections</td>';
        }
    }

    /**
     * Update last updated timestamp
     */
    updateTimestamp() {
        const element = document.getElementById('lastUpdated');
        if (element) {
            const now = new Date();
            element.textContent = now.toLocaleTimeString();
        }
    }

    /**
     * Start auto-refresh interval
     */
    startAutoRefresh() {
        // Clear existing interval
        if (this.updateInterval) {
            clearInterval(this.updateInterval);
        }

        // Set new interval
        this.updateInterval = setInterval(() => {
            this.loadData();
        }, this.refreshRate);

        console.log(`🔄 Auto-refresh started (every ${this.refreshRate / 1000}s)`);
    }

    /**
     * Stop auto-refresh interval
     */
    stopAutoRefresh() {
        if (this.updateInterval) {
            clearInterval(this.updateInterval);
            this.updateInterval = null;
            console.log('⏸️ Auto-refresh stopped');
        }
    }

    /**
     * Setup event listeners
     */
    setupEventListeners() {
        // Refresh button
        const refreshBtn = document.getElementById('refreshBtn');
        if (refreshBtn) {
            refreshBtn.addEventListener('click', () => this.loadData());
        }

        // Pause/Resume button
        const pauseBtn = document.getElementById('pauseBtn');
        if (pauseBtn) {
            pauseBtn.addEventListener('click', () => this.toggleAutoRefresh());
        }

        // Listen for panel visibility changes
        document.addEventListener('visibilitychange', () => {
            if (document.hidden) {
                this.stopAutoRefresh();
            } else {
                this.startAutoRefresh();
                this.loadData();
            }
        });
    }

    /**
     * Toggle auto-refresh on/off
     */
    toggleAutoRefresh() {
        if (this.updateInterval) {
            this.stopAutoRefresh();
        } else {
            this.startAutoRefresh();
        }
    }

    /**
     * Show loading indicator
     */
    showLoading(show) {
        const indicator = document.getElementById('loadingIndicator');
        if (indicator) {
            indicator.style.display = show ? 'block' : 'none';
        }
    }

    /**
     * Show error message
     */
    showError(message) {
        const errorElement = document.getElementById('errorMessage');
        if (errorElement) {
            errorElement.textContent = message;
            errorElement.style.display = 'block';

            // Auto-hide after 5 seconds
            setTimeout(() => {
                errorElement.style.display = 'none';
            }, 5000);
        }
    }

    /**
     * Cleanup when panel is destroyed
     */
    destroy() {
        this.stopAutoRefresh();

        // Destroy charts
        Object.values(this.charts).forEach(chart => {
            if (chart) chart.destroy();
        });

        Object.values(this.sparklines).forEach(chart => {
            if (chart) chart.destroy();
        });

        console.log('🧹 Bandwidth Panel destroyed');
    }
}

// Initialize bandwidth panel when script loads
let bandwidthPanel;

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
        bandwidthPanel = new BandwidthPanel();
    });
} else {
    bandwidthPanel = new BandwidthPanel();
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = BandwidthPanel;
}
