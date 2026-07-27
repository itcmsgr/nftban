#!/usr/bin/env bash
# =============================================================================
# NFTBan - Suricata Setup Module — RETIRED TOMBSTONE (v1.228.2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: none. This file defines no commands. It exists only as a tombstone.
#
# meta:name="cmd_suricata_setup"
# meta:type="cli"
# meta:header="Suricata Setup Module (retired)"
# meta:version="1.228.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Retired tombstone — the Suricata install/enable/disable/status commands were removed in v1.228.2; this file defines nothing and mutates nothing"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-12-28"
# meta:updated_date="2026-07-28"
#
# =============================================================================
# WHAT WAS HERE, AND WHY IT IS GONE
# -----------------------------------------------------------------------------
# Suricata is retired from the active product surface (owner ruling D1-D4,
# 2026-07-28). It is a DORMANT PLACEHOLDER for a much later release.
#
# This file defined four commands. Three of them mutated the host:
#
#   cmd_suricata_install   installed the external suricata package via dnf/apt
#                          or compiled it from source, pip-installed
#                          suricata-update, wrote ENABLE_IDS_INTEGRATION=1 and
#                          NFTBAN_SURICATA_ENABLED=true into nftban.conf.local,
#                          and enabled nftban-suricata-update.timer.
#   cmd_suricata_enable    ran suricata-update, REWROTE /etc/suricata/suricata.yaml
#                          (rule path, EVE output path, af-packet interface),
#                          added the suricata system user to the nftban group,
#                          chowned/chmodded the EVE log directory, installed
#                          /etc/logrotate.d/nftban-suricata, and enabled + started
#                          suricata.service plus nftban-suricata-update.timer.
#   cmd_suricata_disable   stopped and disabled suricata.service and the timer.
#   cmd_suricata_status    reported on all of the above.
#
# D3: the public surface is `help` + `status` only, and a dormant surface must
# not mutate the host or imply protection exists. All four are therefore gone.
# `status` was rewritten from scratch in cmd_suricata.sh as a declarative,
# read-only dormant reporter — it is NOT this file's status command relocated.
#
# The three retired systemd units these commands enabled
# (nftban-suricata.service, nftban-suricata-update.service/.timer) are no
# longer shipped, and package convergence stops, disables and removes them
# from hosts that already have them. See build/deprecated-units.yaml.
#
# WHY THIS FILE STILL EXISTS INSTEAD OF BEING DELETED
# -----------------------------------------------------------------------------
# scripts/ci/shell-delete-guard.sh CHECK 3 (NO-DROP-RUNTIME-DIRS-CODE) names
# cli/lib/nftban/cli/cmd_suricata_setup.sh explicitly and HARD-LOCKS its
# deletion — marker-independent — until UPSTREAM-UNINSTALL-SHELL-RESIDUE-002
# lands. The lock is substantively right here: this file created runtime
# artifacts on hosts (/etc/logrotate.d/nftban-suricata, the EVE log directory,
# nftban.conf.local keys) that deleting the source file does not clean up.
# Emptying the file removes the behaviour now; deleting the file is a separate
# transaction that belongs with the residue-cleanup work.
#
# Sourcing this file is a no-op. It defines no functions, exports nothing,
# reads no configuration and touches no filesystem path.
# =============================================================================

# Prevent double-loading (kept so a stale caller's guard still behaves).
[[ -n "${_CMD_SURICATA_SETUP_LOADED:-}" ]] && return 0
_CMD_SURICATA_SETUP_LOADED="true"

return 0 2>/dev/null || exit 0
