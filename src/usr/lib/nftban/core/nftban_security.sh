#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Security Hardening Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Whitelist security hardening
#
# meta:name=nftban_security
# meta:type=core
# meta:header=Security Hardening Module
# meta:version=0.10.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Whitelist security hardening with auditd monitoring and interactive confirmation
# meta:input=Whitelist directories and configuration files
# meta:output=Hardened permissions and audit rules
#
# **Inventory & Requirements**
# meta:depends=auditctl,augenrules,chown,chmod
#
# meta:created_date=2025-10-28
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

: "${WL_DIR:=/etc/nftban/whitelist.d}"
: "${AUDITCTL:=/sbin/auditctl}"
: "${AUGENRULES:=/sbin/augenrules}"

# One-time setup to lock down whitelist dir/files
nftban_whitelist_harden() {
  # Ownership root:root, directory 0755 (root-only write), files 0644
  chown -R root:root "$WL_DIR"
  chmod 0755 "$WL_DIR"
  find "$WL_DIR" -maxdepth 1 -type f -name '*.conf' -exec chmod 0644 {} \;

  # Optional: remove group/other write on parent /etc/nftban
  chmod g-w,o-w /etc/nftban

  # SELinux: align context to parent
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$WL_DIR" || true

  echo "[OK] Whitelist directory hardened: root-only write"
}

# auditd rules to track writes/appends & attrib changes
nftban_whitelist_audit_enable() {
  # Volatile (immediate) rules
  ${AUDITCTL} -W "$WL_DIR" -p wa -k nftban_whitelist 2>/dev/null || \
  ${AUDITCTL} -w "$WL_DIR" -p wa -k nftban_whitelist

  # Persistent rules (Debian/RHEL family)
  mkdir -p /etc/audit/rules.d
  cat >/etc/audit/rules.d/nftban_whitelist.rules <<EOF
-w ${WL_DIR} -p wa -k nftban_whitelist
EOF
  # Compile + load
  if command -v ${AUGENRULES} >/dev/null; then
    ${AUGENRULES} --load
  else
    service auditd restart || systemctl restart auditd 2>/dev/null || true
  fi
  echo "[OK] auditd watch enabled for ${WL_DIR}"
  echo "    View with: ausearch -k nftban_whitelist"
}

# Interactive confirmation requiring explicit YES unless --force
confirm_or_exit() {
  local reason="${1:-"This action modifies the whitelist."}"
  shift || true

  for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
      echo "[WARN] --force provided; skipping confirmation."
      return 0
    fi
  done

  if [[ -t 0 && -t 1 ]]; then
    echo "⚠️  $reason"
    echo -n 'Type YES to continue: '
    read -r ans
    [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
  else
    echo "Non-interactive session and no --force provided. Aborted." >&2
    exit 1
  fi
}

# Example command that adds to whitelist with confirmation + logging
# NOTE: This requires nftban_file_ops.sh to be sourced for nftban_atomic_append
nftban_whitelist_add() {
  local ip="$1"; shift || true
  confirm_or_exit "Add $ip to whitelist? This overrides *all* blocks." "$@"

  # Validation should be done earlier by nftban-geoip validate

  # Use atomic append (from nftban_file_ops.sh)
  if declare -f nftban_atomic_append >/dev/null 2>&1; then
    echo "$ip  # added $(date -u +'%F %T%z') by $(id -un)" | \
      nftban_atomic_append "/etc/nftban/whitelist.d/99-manual.conf"
  else
    echo "ERROR: nftban_atomic_append not available. Source nftban_file_ops.sh first." >&2
    return 1
  fi

  # Audit log
  logger -t nftban -p auth.warning "WHITELIST_ADD ip=${ip} user=$(id -un) tty=$(tty 2>/dev/null || echo 'notty')"

  echo "[OK] Whitelisted ${ip}"
  echo "    Review with: ausearch -k nftban_whitelist"
}
