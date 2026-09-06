#!/usr/bin/env bash
# =============================================================================
# NFTBan - Lane 3D.5A: the boot projection must carry an nftables-readable label
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="selinux_boot_projection_fcontext_v1229_13_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-06"
# meta:description="v1.229.13 Lane 3D.5A. After Lane 3D.4 moved boot authority to the generated projection, that file became the SECOND artifact the distro nftables.service (iptables_t) must read. Without an fcontext rule it falls to the /etc/nftban(/.*)? catch-all (nftban_conf_t), publication verification fails, render-boot exits 1, bootProjectionReady stays false and the include transition is refused — measured on an EL host. Asserts the rule exists, resolves to nftban_nftables_conf_t, is NARROW (names the file, not the directory), and that the policy actually grants iptables_t read on that type."
# meta:input="install/selinux/nftban.fc, install/selinux/nftban.te"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="install/selinux/nftban.fc,install/selinux/nftban.te"
# meta:inventory.privileges="none"
# meta:ta.id="selinux_boot_projection_fcontext_v1229_13_test"
# meta:ta.owner="firewall"
# meta:ta.module="selinux-policy"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FC="$ROOT/install/selinux/nftban.fc"
TE="$ROOT/install/selinux/nftban.te"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# Strip comments: a documented path is not a policy rule.
rules(){ grep -vE '^\s*#' "$FC"; }

if rules | grep -qE '^/etc/nftban/generated/nftban-boot\\\.nft\s'; then
    ok "an fcontext rule exists for the generated boot projection"
else
    no "NO fcontext rule for /etc/nftban/generated/nftban-boot.nft — the FPA include transition is UNREACHABLE on EL"
fi

if rules | grep -E '^/etc/nftban/generated/nftban-boot\\\.nft\s' | grep -q 'nftban_nftables_conf_t'; then
    ok "it resolves to nftban_nftables_conf_t (readable by the distro nftables.service)"
else
    no "the rule does not resolve to nftban_nftables_conf_t"
fi

# NARROWNESS: the directory must NOT be blanket-relabelled — type separation.
if rules | grep -E '^/etc/nftban/generated\(' | grep -q 'nftban_nftables_conf_t'; then
    no "the whole generated/ directory is labelled nftban_nftables_conf_t — too broad; \
only the boot projection is consumed by iptables_t"
else
    ok "narrow: only the boot projection file carries the nftables-readable type"
fi

# The type is only useful if the policy grants the consumer read on it.
if grep -vE '^\s*#' "$TE" | grep -qE 'allow\s+iptables_t\s+nftban_nftables_conf_t:file.*read'; then
    ok "policy grants iptables_t read on nftban_nftables_conf_t"
else
    no "no allow rule grants iptables_t read on nftban_nftables_conf_t — the label alone would not help"
fi

# ⛔ NON-VACUITY: the assertions above must be capable of failing. Prove the
# matcher does not simply match anything.
if rules | grep -qE '^/etc/nftban/generated/NOT-A-REAL-FILE\\\.nft\s'; then
    no "NEGATIVE CONTROL FAILED — the matcher matches a path that is not in the policy"
else
    ok "NEGATIVE CONTROL: a non-existent path is NOT matched (assertions are real)"
fi

printf '\n  passed=%d failed=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
