// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2025 NFTBan Development Team
//
// Chart.js Utilities for NFTBan Bandwidth Monitoring
// Provides reusable chart configurations and helpers

/**
 * Chart color schemes for dark and light themes
 */
const ChartColors = {
    dark: {
        primary: 'rgb(59, 130, 246)',      // Blue
        secondary: 'rgb(249, 115, 22)',    // Orange
        success: 'rgb(34, 197, 94)',       // Green
        warning: 'rgb(251, 146, 60)',      // Amber
        danger: 'rgb(239, 68, 68)',        // Red
        text: 'rgb(248, 249, 250)',        // Light gray
        grid: 'rgba(45, 49, 57, 0.5)',     // Dark gray
        background: 'rgba(26, 29, 35, 0.8)'
    },
    light: {
        primary: 'rgb(59, 130, 246)',
        secondary: 'rgb(249, 115, 22)',
        success: 'rgb(34, 197, 94)',
        warning: 'rgb(251, 146, 60)',
        danger: 'rgb(239, 68, 68)',
        text: 'rgb(11, 12, 14)',
        grid: 'rgba(229, 231, 235, 0.5)',
        background: 'rgba(255, 255, 255, 0.8)'
    }
};

/**
 * Current theme ('dark' or 'light')
 */
let currentTheme = document.documentElement.classList.contains('light') ? 'light' : 'dark';

/**
 * Get colors for current theme
 */
function getColors() {
    return ChartColors[currentTheme];
}

/**
 * Update Chart.js global defaults for theme
 */
function updateChartDefaults() {
    const colors = getColors();

    Chart.defaults.color = colors.text;
    Chart.defaults.borderColor = colors.grid;
    Chart.defaults.backgroundColor = colors.background;

    Chart.defaults.plugins.legend.labels.color = colors.text;
    Chart.defaults.plugins.tooltip.backgroundColor = colors.background;
    Chart.defaults.plugins.tooltip.titleColor = colors.text;
    Chart.defaults.plugins.tooltip.bodyColor = colors.text;
    Chart.defaults.plugins.tooltip.borderColor = colors.grid;
    Chart.defaults.plugins.tooltip.borderWidth = 1;

    Chart.defaults.scale.grid.color = colors.grid;
    Chart.defaults.scale.ticks.color = colors.text;
}

/**
 * Create base chart configuration
 * @param {string} type - Chart type (line, bar, doughnut, etc.)
 * @param {Object} options - Additional options to merge
 * @returns {Object} Chart configuration
 */
function createChartConfig(type, options = {}) {
    const colors = getColors();

    const baseConfig = {
        type: type,
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                intersect: false,
                mode: 'index'
            },
            plugins: {
                legend: {
                    display: true,
                    position: 'top',
                    labels: {
                        usePointStyle: true,
                        padding: 15,
                        font: {
                            size: 12,
                            family: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
                        }
                    }
                },
                tooltip: {
                    enabled: true,
                    backgroundColor: colors.background,
                    titleColor: colors.text,
                    bodyColor: colors.text,
                    borderColor: colors.grid,
                    borderWidth: 1,
                    padding: 12,
                    displayColors: true,
                    callbacks: {
                        label: function(context) {
                            let label = context.dataset.label || '';
                            if (label) {
                                label += ': ';
                            }
                            if (context.parsed.y !== null) {
                                label += context.parsed.y.toFixed(2);
                            }
                            return label;
                        }
                    }
                }
            },
            scales: {
                x: {
                    grid: {
                        display: true,
                        color: colors.grid
                    },
                    ticks: {
                        color: colors.text
                    }
                },
                y: {
                    grid: {
                        display: true,
                        color: colors.grid
                    },
                    ticks: {
                        color: colors.text
                    }
                }
            }
        }
    };

    // Deep merge options
    return deepMerge(baseConfig, options);
}

/**
 * Create real-time line chart for bandwidth monitoring
 * @param {HTMLCanvasElement} canvas - Canvas element
 * @param {Array} datasets - Dataset configurations
 * @returns {Chart} Chart instance
 */
function createRealtimeChart(canvas, datasets = []) {
    const colors = getColors();

    const config = createChartConfig('line', {
        data: {
            datasets: datasets
        },
        options: {
            scales: {
                x: {
                    type: 'time',
                    time: {
                        unit: 'second',
                        displayFormats: {
                            second: 'HH:mm:ss'
                        },
                        tooltipFormat: 'HH:mm:ss'
                    },
                    title: {
                        display: true,
                        text: 'Time',
                        color: colors.text
                    }
                },
                y: {
                    beginAtZero: true,
                    title: {
                        display: true,
                        text: 'Bandwidth (Mbps)',
                        color: colors.text
                    }
                }
            },
            animation: {
                duration: 300
            }
        }
    });

    return new Chart(canvas, config);
}

/**
 * Create sparkline chart (minimal chart for stat cards)
 * @param {HTMLCanvasElement} canvas - Canvas element
 * @param {Array} data - Data points
 * @param {string} color - Line color
 * @returns {Chart} Chart instance
 */
function createSparkline(canvas, data, color) {
    const colors = getColors();

    return new Chart(canvas, {
        type: 'line',
        data: {
            labels: data.map((_, i) => i),
            datasets: [{
                data: data,
                borderColor: color || colors.primary,
                backgroundColor: `${color || colors.primary}20`,
                borderWidth: 2,
                fill: true,
                pointRadius: 0,
                tension: 0.4
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { display: false },
                tooltip: { enabled: false }
            },
            scales: {
                x: { display: false },
                y: { display: false }
            },
            elements: {
                line: {
                    borderWidth: 2
                }
            }
        }
    });
}

/**
 * Create horizontal bar chart for interface comparison
 * @param {HTMLCanvasElement} canvas - Canvas element
 * @param {Array} labels - Interface names
 * @param {Array} rxData - Receive data
 * @param {Array} txData - Transmit data
 * @returns {Chart} Chart instance
 */
function createInterfaceBarChart(canvas, labels, rxData, txData) {
    const colors = getColors();

    const config = createChartConfig('bar', {
        data: {
            labels: labels,
            datasets: [
                {
                    label: 'Receive (Mbps)',
                    data: rxData,
                    backgroundColor: `${colors.primary}80`,
                    borderColor: colors.primary,
                    borderWidth: 1
                },
                {
                    label: 'Transmit (Mbps)',
                    data: txData,
                    backgroundColor: `${colors.secondary}80`,
                    borderColor: colors.secondary,
                    borderWidth: 1
                }
            ]
        },
        options: {
            indexAxis: 'y',
            scales: {
                x: {
                    beginAtZero: true,
                    title: {
                        display: true,
                        text: 'Bandwidth (Mbps)',
                        color: colors.text
                    }
                },
                y: {
                    title: {
                        display: true,
                        text: 'Interface',
                        color: colors.text
                    }
                }
            }
        }
    });

    return new Chart(canvas, config);
}

/**
 * Create doughnut chart for protocol breakdown
 * @param {HTMLCanvasElement} canvas - Canvas element
 * @param {Object} protocolData - Protocol data {tcp, udp, icmp}
 * @returns {Chart} Chart instance
 */
function createProtocolChart(canvas, protocolData) {
    const colors = getColors();

    const labels = ['TCP', 'UDP', 'ICMP'];
    const data = [
        protocolData.tcp?.packets || 0,
        protocolData.udp?.packets || 0,
        protocolData.icmp?.packets || 0
    ];

    const backgroundColors = [
        `${colors.primary}80`,
        `${colors.secondary}80`,
        `${colors.success}80`
    ];

    const borderColors = [
        colors.primary,
        colors.secondary,
        colors.success
    ];

    return new Chart(canvas, {
        type: 'doughnut',
        data: {
            labels: labels,
            datasets: [{
                data: data,
                backgroundColor: backgroundColors,
                borderColor: borderColors,
                borderWidth: 2
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: {
                    display: true,
                    position: 'right'
                },
                tooltip: {
                    callbacks: {
                        label: function(context) {
                            const label = context.label || '';
                            const value = context.parsed || 0;
                            const total = context.dataset.data.reduce((a, b) => a + b, 0);
                            const percentage = total > 0 ? ((value / total) * 100).toFixed(1) : 0;
                            return `${label}: ${value.toLocaleString()} (${percentage}%)`;
                        }
                    }
                }
            }
        }
    });
}

/**
 * Update all charts when theme changes
 * @param {string} theme - New theme ('dark' or 'light')
 */
function updateChartsTheme(theme) {
    currentTheme = theme;
    updateChartDefaults();

    // Update all existing chart instances
    Chart.instances.forEach(chart => {
        chart.update('none'); // Update without animation
    });
}

/**
 * Format bytes to human readable format
 * @param {number} bytes - Bytes
 * @param {number} decimals - Decimal places
 * @returns {string} Formatted string
 */
function formatBytes(bytes, decimals = 2) {
    if (bytes === 0) return '0 Bytes';

    const k = 1024;
    const dm = decimals < 0 ? 0 : decimals;
    const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];

    const i = Math.floor(Math.log(bytes) / Math.log(k));

    return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}

/**
 * Format Mbps with appropriate unit
 * @param {number} mbps - Megabits per second
 * @returns {string} Formatted string
 */
function formatBandwidth(mbps) {
    if (mbps < 1) {
        return (mbps * 1000).toFixed(0) + ' Kbps';
    } else if (mbps < 1000) {
        return mbps.toFixed(2) + ' Mbps';
    } else {
        return (mbps / 1000).toFixed(2) + ' Gbps';
    }
}

/**
 * Deep merge two objects
 * @param {Object} target - Target object
 * @param {Object} source - Source object
 * @returns {Object} Merged object
 */
function deepMerge(target, source) {
    const output = Object.assign({}, target);

    if (isObject(target) && isObject(source)) {
        Object.keys(source).forEach(key => {
            if (isObject(source[key])) {
                if (!(key in target)) {
                    Object.assign(output, { [key]: source[key] });
                } else {
                    output[key] = deepMerge(target[key], source[key]);
                }
            } else {
                Object.assign(output, { [key]: source[key] });
            }
        });
    }

    return output;
}

/**
 * Check if value is an object
 * @param {*} item - Value to check
 * @returns {boolean} True if object
 */
function isObject(item) {
    return item && typeof item === 'object' && !Array.isArray(item);
}

// Initialize Chart.js defaults
updateChartDefaults();

// Export functions (if using modules)
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        createChartConfig,
        createRealtimeChart,
        createSparkline,
        createInterfaceBarChart,
        createProtocolChart,
        updateChartsTheme,
        formatBytes,
        formatBandwidth,
        getColors
    };
}
