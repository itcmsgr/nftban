#!/usr/bin/env bash
# =============================================================================
# NFTBan - universal help-inertness sweep test (v1.141 PR-A sweep-all)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="cli_help_inertness_universal_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-A — sweep-all-subcommands help-inertness audit. Every top-level subcommand the dispatcher recognises must satisfy the help contract: `nftban <cmd> --help` returns rc=0, is inert (no nftban-core, nft, systemctl, package-manager mutation in PATH-shadow sandbox), and emits usage/help/Available text. Non-existent subcommands are SKIPPED (operator-chosen 'drop' for feeds add / feeds remove / update apply / update channel — doc-vs-code drift, not aliased). This test is a regression-prevention gate: any future PR that breaks help inertness on any swept subcommand fails CI. v1.234 Part B (BUG-CLI-HELP-FLAG-EXECUTES-DESTRUCTIVE-ACTION): derives every (cmd, verb) from the real dispatch arms and runs `<cmd> [<verb>] --help|-h|help` as uid 0 inside a user+mount+net+pid namespace (sudo -n unshare fallback) with per-case overlays and absolute-path recording stubs; any mutating call, filesystem write, hang or rc!=0 fails. NOT_EXECUTED (no namespace runner) is a FAIL."
# meta:input="cli/sbin/nftban + every cli/lib/nftban/cli/cmd_*.sh + etc/nftban + install/config/nftban.conf + install/systemd/tmpfiles.d/nftban.conf"
# meta:output="Pass/fail assertions per subcommand; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp,awk,unshare,mount,timeout"
# meta:inventory.files="cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,mktemp,awk,unshare,mount,umount,mountpoint,timeout,sudo"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,PATH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_help_inertness_universal_test"
# meta:ta.owner="cli"
# meta:ta.module="help-inertness"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:ta.timeout="1200"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1

# =============================================================================
# Part B inner mode (v1.234, BUG-CLI-HELP-FLAG-EXECUTES-DESTRUCTIVE-ACTION).
# Runs INSIDE a mount+net+pid namespace as uid 0 (a user namespace when the
# host allows it). Every case gets fresh overlays over /etc /usr /var /run
# /opt /srv /home (all writes land in a per-case upper dir) and a fresh tmpfs
# over /root. The seed layer provides the SUBJECT tree at /usr/lib/nftban +
# /usr/sbin/nftban, the packaged /etc/nftban, the packaged tmpfiles.d
# directories, and recording stubs for every mutating tool at its absolute
# path (so `/usr/bin/systemctl` cannot bypass a PATH shadow). Verdict per
# case: stub-recorded mutation, upper-dir state diff, and timeout (hang) are
# each a FAIL.
# =============================================================================
_rs_mount_case() {
    local sb="$1" c="$1/case" d lower
    rm -rf "$c"; mkdir -p "$c/up" "$c/wk" "$c/tmp"
    for d in etc usr var run opt srv home; do
        [[ -d "/$d" && ! -L "/$d" ]] || continue
        mkdir -p "$c/up/$d" "$c/wk/$d"
        lower="/$d"
        [[ -d "$sb/seed/$d" ]] && lower="$sb/seed/$d:/$d"
        # /var and /run are SYNTHETIC (seed only): host /var/lib commonly holds
        # container overlay stores, which overlayfs refuses as a lower layer,
        # and host /run carries live sockets the case must not reach.
        [[ "$d" == var || "$d" == run ]] && lower="$sb/seed/$d"
        mount -n -t overlay overlay -o "lowerdir=$lower,upperdir=$c/up/$d,workdir=$c/wk/$d" "/$d" || return 1
    done
    mount -n -t tmpfs tmpfs /root || return 1
}
_rs_umount_case() {
    local d
    for d in /root /run /home /srv /opt /var /usr /etc; do
        mountpoint -q "$d" 2>/dev/null && umount -n -l "$d" 2>/dev/null
    done
    return 0
}
_rs_inner() {
    set +e +o pipefail
    local sb="$1" cases="$2" results="$3" tmo="$4"
    local line label rc out diffs muts
    local -a argv
    : > "$results"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -ra argv <<< "$line"
        label=$(printf '%s ' "${argv[@]}"); label="${label% }"
        : > "$sb/calls.log"
        _rs_mount_case "$sb" || { printf '%s\tSETUP_FAILED\t-\t-\n' "$label" >> "$results"; _rs_umount_case; continue; }
        rc=0
        # /usr/sbin/nftban is the seeded SUBJECT dispatcher; NFTBAN_LIB_DIR is
        # left to its /usr/lib/nftban default (the seeded subject lib).
        out=$(cd /root && env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                HOME=/root TERM=dumb TMPDIR="$sb/case/tmp" NFTBAN_NONINTERACTIVE=1 NFTBAN_NO_BANNER=1 \
                NFTBAN_RS_CALLS="$sb/calls.log" \
                timeout -k 2 "$tmo" /usr/sbin/nftban "${argv[@]}" </dev/null 2>&1) || rc=$?
        # Reap anything the case left behind (we are pid 1 of this namespace).
        kill -KILL -1 2>/dev/null || true
        # State diff: every upper-dir entry is a write the case performed.
        # One tolerated class, first-use SCAFFOLD: an EMPTY directory or an
        # EMPTY file under the product's own runtime roots (source-time
        # `mkdir -p` of a cache dir, the audit helper's `touch` of its log).
        # Content, any other path, a symlink, or a whiteout (delete) is a FAIL.
        diffs=$(cd "$sb/case/up" && find . -mindepth 2 \( -type f -o -type l -o -type c -o -type d -empty \) 2>/dev/null \
                | sed 's|^\./|/|' | while IFS= read -r p; do
                    case "$p" in
                        /var/lib/nftban|/var/log/nftban|/var/cache/nftban|/run/nftban|/var/lib/nftban/*|/var/log/nftban/*|/var/cache/nftban/*|/run/nftban/*)
                            [[ ! -L "$sb/case/up$p" ]] && [[ -d "$sb/case/up$p" || ( -f "$sb/case/up$p" && ! -s "$sb/case/up$p" ) ]] && continue ;;
                    esac
                    printf '%s\n' "$p"
                done | sort | awk 'NR<=20' | tr '\n' ' ')
        diffs="${diffs}$(find /root -mindepth 1 2>/dev/null | sort | awk 'NR<=10' | tr '\n' ' ')"
        muts=$(grep '^MUTATE ' "$sb/calls.log" 2>/dev/null | cut -c8- | sort -u | awk 'NR<=10' | tr '\n' '|')
        _rs_umount_case
        local hint; hint=$(printf '%s' "$out" | grep -iE 'usage|help|available|commands' | awk 'NR==1' | cut -c1-60)
        printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$rc" "${muts:--}" "${diffs:--}" "${hint:--}" >> "$results"
    done < "$cases"
}
if [[ "${1:-}" == "--__root-sweep-inner" ]]; then
    shift
    _rs_inner "$@"
    exit $?
fi

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
sk(){ printf '  [SKIP] %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }

build_sandbox(){
    local sb="$1"
    mkdir -p "$sb/bin" "$sb/state"
    # Mutating verbs only — the dispatcher legitimately READS (systemctl
    # is-active firewalld, nft list ruleset) on every CLI invocation including
    # help paths. We mark only mutations.
    for binname in nftban-core nftban-validate nftban-installer nft systemctl polkitd policy-rc.d apt-get dnf rpm dpkg yum; do
        cat >"$sb/bin/$binname" <<EOF
#!/usr/bin/env bash
case "$binname \$1 \$2" in
    "nftban-core "*|"nftban-validate "*|"nftban-installer "*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "nft "list*|"nft "show*)      : ;;
    "nft "*)                      echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "systemctl "is-active*|"systemctl "is-enabled*|"systemctl "is-failed*|"systemctl "show*|"systemctl "status*|"systemctl "list-*|"systemctl "cat*) : ;;
    "systemctl "*)                echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "apt-get "install*|"apt-get "remove*|"apt-get "purge*|"apt-get "upgrade*|"apt-get "update*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "dnf "install*|"dnf "remove*|"dnf "upgrade*|"dnf "update*|"yum "install*|"yum "remove*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "rpm "-i*|"rpm "-U*|"rpm "-e*|"rpm "--install*|"rpm "--erase*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "dpkg "-i*|"dpkg "--install*|"dpkg "--remove*|"dpkg "--purge*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "polkitd "*)                  echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "policy-rc.d "*)              echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
esac
exit 0
EOF
        chmod +x "$sb/bin/$binname"
    done
}

# Top-level subcommands the dispatcher in cli/sbin/nftban recognises.
TOP_LEVEL=(
    ban unban search list status health version
    whitelist blacklist feeds watchdog stats
    install uninstall update rebuild rollback
    login metrics export portscan ddos suricata
    config service services timers geoip geoban
    emulate fhs botguard tunnel firewall trust help
)

# Sub-action surfaces PR-A fixed — each must satisfy the contract under sweep.
SUB_ACTIONS=(
    "firewall reload"
    "trust enable"
    "trust disable"
    "trust update"
    "config get"
    "config set"
    "config defaults"
    "config overrides"
    "config reset"
    "config reset-all"
)

assert_help_inert(){
    local label="$1"; shift
    local args=("$@")
    local sb; sb=$(mktemp -d -t nftban-univ.XXXXXX)
    build_sandbox "$sb"
    local rc=0 out
    out=$(PATH="$sb/bin:$PATH" bash "$NFTBAN_SBIN" "${args[@]}" --help 2>&1) || rc=$?
    if (( rc != 0 )); then
        no "$label" "rc=$rc"
    elif [[ -f "$sb/state/marker" ]]; then
        no "$label" "MUTATION on help path: $(tr '\n' '|' < "$sb/state/marker")"
    elif [[ "$out" != *[Uu]sage* && "$out" != *Help* && "$out" != *help* && "$out" != *Available* ]]; then
        no "$label" "rc=0 but output missing usage/help/Available marker"
    else
        ok "$label (rc=0, no mutation, usage text present)"
    fi
    rm -rf "$sb"
}

SKIP_BECAUSE_DROP_PER_OPERATOR=(
    "feeds add"
    "feeds remove"
    "update apply"
    "update channel"
)

echo "=========================================================="
echo "v1.141 PR-A — universal help-inertness sweep"
echo "=========================================================="

echo "--- top-level subcommands ---"
for cmd in "${TOP_LEVEL[@]}"; do
    assert_help_inert "TL: nftban $cmd --help" "$cmd"
done

echo "--- sub-action surfaces (PR-A-fixed paths must satisfy contract) ---"
for sa in "${SUB_ACTIONS[@]}"; do
    # IFS at the top of this file is \n\t (no space), so a vanilla unquoted
    # $sa would not word-split. Use read -ra with explicit IFS=' ' to split.
    IFS=' ' read -ra _sa_parts <<< "$sa"
    assert_help_inert "SA: nftban $sa --help" "${_sa_parts[@]}"
done

echo "--- dropped per operator (doc-vs-code drift; SKIP not FAIL) ---"
for sa in "${SKIP_BECAUSE_DROP_PER_OPERATOR[@]}"; do
    sk "DROP: nftban $sa --help" "operator SELECT_V1_141_0_B9_B10_B13_B14_DROP_OR_ALIAS = drop — non-existent subcommand"
done

# =============================================================================
# Part B (v1.234) — ROOT sweep over the REAL dispatch arms.
# Part A above runs non-root over a hand-written list, so a verb that refuses
# non-root before acting (e.g. `nftables stop`) passes for the wrong reason,
# and verbs missing from the list are never run. Part B derives the population
# from the source, runs every `<cmd> [<verb>] {--help,-h,help}` as uid 0 in an
# isolated namespace, and fails on any recorded mutating command, any
# filesystem write, or a hang. See the inner mode near the top of this file.
# =============================================================================
echo "--- Part B: root sweep over derived dispatch arms (v1.234) ---"
RS_CLI_DIR="$REPO/cli/lib/nftban/cli"
RS_SB=""
_rs_cleanup(){
    [[ -n "$RS_SB" && -d "$RS_SB" && "$RS_SB" == */nftban-rs.* ]] || return 0
    rm -rf -- "$RS_SB" 2>/dev/null || sudo -n rm -rf -- "$RS_SB" 2>/dev/null || true
}
trap _rs_cleanup EXIT
RS_SB=$(mktemp -d -t nftban-rs.XXXXXX)

# B1 — population. Every case-arm literal inside nftban_cmd_<x>() of every
# cli/cmd_<x>.sh that defines that entrypoint (the router's auto-load contract),
# plus the router's alias arms (service, cloudflare, enable|disable|restart,
# verify|explain, rollback, export) derived from cli/sbin/nftban.
RS_PAIRS="$RS_SB/pairs.tsv"; : > "$RS_PAIRS"
RS_TOKENS="$RS_SB/tokens.txt"; : > "$RS_TOKENS"
for f in "$RS_CLI_DIR"/cmd_*.sh; do
    x=$(basename "$f" .sh); x="${x#cmd_}"
    grep -qE "^nftban_cmd_${x}\(\)" "$f" || continue
    tok="${x//_/-}"
    echo "$tok" >> "$RS_TOKENS"
    awk -v fn="nftban_cmd_${x}" -v tok="$tok" '
        $0 ~ "^"fn"\\(\\)" { in_fn=1; next }
        in_fn && /^}/ { exit }
        in_fn && /^[[:space:]]+[a-z][a-zA-Z0-9_|"-]*\)/ {
            line=$0; sub(/\).*$/, "", line); sub(/^[[:space:]]+/, "", line)
            n=split(line, p, "|")
            for (i=1;i<=n;i++){ a=p[i]; gsub(/^"|"$/,"",a); if (a ~ /^[a-z][a-z0-9_-]*$/ && a != "help") print tok "\t" a }
        }' "$f" >> "$RS_PAIRS"
done
# Alias arms: `<alias>)` blocks in the router that call a module entrypoint.
# `<module> "$@"` forwards verbs, so the alias inherits the module's verbs.
awk '
    /^        [a-z][a-z|-]*\)[[:space:]]*$/ { arm=$1; sub(/\)$/, "", arm); next }
    arm != "" && /(_nftban_dispatch_module |nftban_cmd_)[a-z_]+/ {
        m=$0; sub(/.*(_nftban_dispatch_module |nftban_cmd_)/, "", m)
        mod=m; sub(/[^a-z_].*$/, "", mod)
        fwd = (m ~ /^[a-z_]+ "\$@"/) ? 1 : 0
        n=split(arm, p, "|"); for (i=1;i<=n;i++) print p[i] "\t" mod "\t" fwd
        arm=""
    }' "$NFTBAN_SBIN" | sort -u > "$RS_SB/aliases.tsv"
while IFS=$'\t' read -r al mod fwd; do
    echo "$al" >> "$RS_TOKENS"
    if [[ "$fwd" == 1 ]]; then
        awk -F'\t' -v m="${mod//_/-}" -v al="$al" '$1==m { print al "\t" $2 }' "$RS_PAIRS" >> "$RS_SB/alias_pairs.tsv"
    fi
done < "$RS_SB/aliases.tsv"
[[ -f "$RS_SB/alias_pairs.tsv" ]] && cat "$RS_SB/alias_pairs.tsv" >> "$RS_PAIRS"
sort -u -o "$RS_PAIRS" "$RS_PAIRS"
sort -u -o "$RS_TOKENS" "$RS_TOKENS"
rs_npairs=$(wc -l < "$RS_PAIRS"); rs_ntok=$(wc -l < "$RS_TOKENS")
rs_nalias=$(wc -l < "$RS_SB/aliases.tsv")

# B2 — the derived population must contain every verb the v1.234 CLI audit
# proved acts on help as root (RUNTIME_FINDINGS §1a/1b/1c/1f, F6-02). This is a
# FLOOR on the derivation, not the population: a parser change that shrinks the
# population below the known-bad set fails here instead of passing emptier.
RS_ANCHORS=(
    "nftables stop" "nftables disable" "nftables start" "nftables enable"
    "nftables restart" "nftables reload" "services fix" "rbl disable" "rbl enable"
    "tunnel disable" "tunnel enable" "botguard enable" "botguard disable"
    "botscan enable" "botscan disable" "portscan enable" "firewall-logs disable"
    "firewall-logs enable" "zabbix enable" "zabbix disable" "zabbix setup"
    "zabbix reload" "geoip ban" "geoip update" "geoip refresh" "login restart"
    "login run" "login install" "metrics enable" "metrics disable" "pro disable"
    "portscan disable" "portscan reload" "portscan sync" "snapshot create"
    "stats cleanup" "stats clear-cache" "selftest run" "trust load"
    "queue process" "whitelist-system sync" "update recommit" "update auto-apply"
    "update github" "update force" "update repair" "update git" "update local"
    "watchdog run" "config apply" "wizard install"
)
rs_missing=()
for a in "${RS_ANCHORS[@]}"; do
    grep -qxF "${a/ /$'\t'}" "$RS_PAIRS" || rs_missing+=("$a")
done
if (( ${#rs_missing[@]} == 0 )) && (( rs_npairs >= 400 )) && (( rs_nalias >= 5 )); then
    ok "B1/B2: derived $rs_npairs (cmd, verb) pairs over $rs_ntok tokens ($rs_nalias alias arms); all ${#RS_ANCHORS[@]} F6-02 verbs present"
else
    no "B1/B2: derived population" "pairs=$rs_npairs aliases=$rs_nalias missing F6-02 verbs: ${rs_missing[*]:-none}"
fi

# B3 — isolation runner. Unprivileged user namespace first (fake uid 0, no host
# privilege); passwordless sudo into a mount+net+pid namespace second. Neither
# available => the root sweep is NOT_EXECUTED, which is a FAIL, never a PASS.
RS_RUNNER=()
RS_NS=(--mount --net --pid --fork --mount-proc)
if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user "${RS_NS[@]}" true >/dev/null 2>&1; then
    RS_RUNNER=(unshare --user --map-root-user "${RS_NS[@]}")
elif command -v sudo >/dev/null 2>&1 && sudo -n unshare "${RS_NS[@]}" true >/dev/null 2>&1; then
    RS_RUNNER=(sudo -n unshare "${RS_NS[@]}")
fi

# B4 — seed layer: the SUBJECT tree installed at its FHS paths, plus stubs.
RS_SEED="$RS_SB/seed"
RS_SBIN_DIR="usr/sbin"; [[ -d /usr/sbin && ! -L /usr/sbin ]] || RS_SBIN_DIR="usr/bin"
mkdir -p "$RS_SEED/usr/lib" "$RS_SEED/usr/bin" "$RS_SEED/$RS_SBIN_DIR" "$RS_SEED/etc" \
         "$RS_SEED/var/lib/nftban" "$RS_SEED/var/log/nftban" "$RS_SEED/var/cache/nftban" \
         "$RS_SEED/var/tmp" "$RS_SEED/var/lib/misc" "$RS_SEED/var/backups"
ln -sfn ../run "$RS_SEED/var/run"
ln -sfn ../run/lock "$RS_SEED/var/lock"
cp -a "$REPO/cli/lib/nftban" "$RS_SEED/usr/lib/nftban"
cp "$REPO/VERSION" "$RS_SEED/usr/lib/nftban/VERSION"
mkdir -p "$RS_SEED/usr/lib/nftban/bin"
cp "$NFTBAN_SBIN" "$RS_SEED/$RS_SBIN_DIR/nftban"; chmod 0755 "$RS_SEED/$RS_SBIN_DIR/nftban"
[[ -d "$REPO/etc/nftban" ]] && cp -a "$REPO/etc/nftban" "$RS_SEED/etc/nftban"
# The packaged main config and the packaged tmpfiles.d directory set, as a
# package install lays them down (build_nftban.sh installs install/config/
# nftban.conf as /etc/nftban/nftban.conf; systemd-tmpfiles creates the `d`
# entries). Without them the sandbox would count the package's own
# directories as writes, or crash modules on unset paths before they act.
[[ -f "$REPO/install/config/nftban.conf" ]] && cp "$REPO/install/config/nftban.conf" "$RS_SEED/etc/nftban/nftban.conf"
if [[ -f "$REPO/install/systemd/tmpfiles.d/nftban.conf" ]]; then
    while read -r _t _p _rest; do
        case "$_t:$_p" in [dD]:/var/*|[dD]:/run/*) mkdir -p "$RS_SEED$_p" ;; esac
    done < "$REPO/install/systemd/tmpfiles.d/nftban.conf"
fi
mkdir -p "$RS_SEED/run/lock"
rs_write_stub(){
    local dest="$1" name="$2"
    cat > "$dest" <<EOF
#!/bin/bash
# nftban-rs recording stub for '$name' — never performs the real operation.
t='$name'; ro=0; w=""
for x in "\$@"; do case "\$x" in -*) ;; *) w="\$x"; break ;; esac; done
case "\$t" in
  systemctl) case "\$w" in is-active|is-enabled|is-failed|show|status|list-*|cat|is-system-running|get-default|show-environment|"") ro=1 ;; esac ;;
  nft) case " \$* " in *" -c "*|*" --check "*) ro=1 ;; esac
       case "\$w" in list|describe) ro=1 ;; esac ;;
  rpm) case "\$1" in -q*|--query|--version|--eval|-E) ro=1 ;; esac ;;
  dpkg) case "\$1" in -l|-L|-s|-S|--status|--list|--listfiles|--search|--print-architecture|--compare-versions|--version|--get-selections|--audit) ro=1 ;; esac ;;
  dnf|yum) case "\$w" in list|info|repolist|repoquery|search|provides|--version) ro=1 ;; esac ;;
  apt) case "\$w" in list|show|policy|search) ro=1 ;; esac ;;
  apt-get) case "\$1" in -s|--simulate|--version) ro=1 ;; esac ;;
  ip) case " \$* " in *" add "*|*" del "*|*" delete "*|*" flush "*|*" set "*|*" replace "*|*" change "*|*" append "*) ro=0 ;; *) ro=1 ;; esac ;;
  sysctl) case " \$* " in *" -w "*|*"="*|*" -p"*|*" --system "*|*" --load"*) ro=0 ;; *) ro=1 ;; esac ;;
  crontab) case "\$1" in -l) ro=1 ;; esac ;;
  # A help request DELEGATED to the Go CLI (e.g. \`nftban smoke --help\`
  # forwards to \`nftban-core smoke --help\`) is a read.
  nftban-core|nftban-validate|nftban-installer)
       case " \$* " in *" --help "*|*" -h "*|*" help "*) ro=1 ;; esac ;;
esac
case "\$1" in --version|-V) ro=1 ;; esac
if [[ \$ro == 1 ]]; then echo "READ \$t \$*" >> '$RS_SB/calls.log'; else echo "MUTATE \$t \$*" >> '$RS_SB/calls.log'; fi
# Queries answer "not running / not enabled", so an arm gated on "already
# active" still reaches its action and cannot hide it from the sweep.
if [[ "\$t" == systemctl ]]; then
    case "\$w" in
        is-active) echo inactive; exit 3 ;;
        is-enabled) echo disabled; exit 1 ;;
        is-failed) echo inactive; exit 1 ;;
    esac
fi
exit 0
EOF
    chmod 0755 "$dest"
}
for t in systemctl nft chattr dnf yum apt-get apt dpkg rpm curl wget ip sysctl modprobe rmmod \
         semanage semodule setsebool restorecon setenforce useradd userdel usermod groupadd \
         crontab shutdown reboot nftband nftban-core nftban-validate nftban-installer; do
    rs_write_stub "$RS_SEED/usr/bin/$t" "$t"
    [[ "$RS_SBIN_DIR" == usr/sbin ]] && rs_write_stub "$RS_SEED/usr/sbin/$t" "$t"
done
for t in nftban-core nftban-validate nftban-installer nftband; do
    rs_write_stub "$RS_SEED/usr/lib/nftban/bin/$t" "$t"
done

# B5 — cases: every token alone and every (token, verb), each in all 3 forms.
RS_CASES="$RS_SB/cases.tsv"; : > "$RS_CASES"
for form in --help -h help; do
    while IFS= read -r tok; do printf '%s\t%s\n' "$tok" "$form"; done < "$RS_TOKENS" >> "$RS_CASES"
    while IFS=$'\t' read -r tok verb; do printf '%s\t%s\t%s\n' "$tok" "$verb" "$form"; done < "$RS_PAIRS" >> "$RS_CASES"
done
rs_ncases=$(wc -l < "$RS_CASES")

if (( ${#RS_RUNNER[@]} == 0 )); then
    no "B3: root sweep executed" "NOT_EXECUTED — neither 'unshare --user --map-root-user' nor 'sudo -n unshare' is available; the root half cannot be claimed"
else
    RS_RESULTS="$RS_SB/results.tsv"
    rs_start=$SECONDS
    "${RS_RUNNER[@]}" bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" --__root-sweep-inner \
        "$RS_SB" "$RS_CASES" "$RS_RESULTS" "${NFTBAN_RS_CASE_TIMEOUT:-20}" || true
    rs_nres=$(awk 'END { print NR }' "$RS_RESULTS" 2>/dev/null || true); rs_nres=${rs_nres:-0}
    rs_runner_name="${RS_RUNNER[0]} ${RS_RUNNER[1]}"
    # A truncated run is UNMEASURED, not a pass.
    if (( rs_nres != rs_ncases )); then
        no "B3: root sweep executed" "results=$rs_nres of cases=$rs_ncases (runner: $rs_runner_name)"
    else
        ok "B3: root sweep executed $rs_ncases cases as uid 0 in $((SECONDS - rs_start))s (runner: $rs_runner_name)"
    fi
    # Positive control: the harness must SEE a mutation. Run one case whose
    # action is a known systemctl mutation (not help) through the same runner.
    printf 'nftables\tstop\n' > "$RS_SB/control.tsv"
    "${RS_RUNNER[@]}" bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" --__root-sweep-inner \
        "$RS_SB" "$RS_SB/control.tsv" "$RS_SB/control.out" 20 || true
    if [[ -n "$(awk -F'\t' '$3 ~ /systemctl stop/' "$RS_SB/control.out" 2>/dev/null)" ]]; then
        ok "B4: positive control — 'nftables stop' (no help) records the systemctl mutation"
    else
        no "B4: positive control" "'nftables stop' as root recorded no mutation — the harness cannot see mutations: $(cat "$RS_SB/control.out" 2>/dev/null)"
    fi
    rs_fail=0; rs_setup=0; rs_hang=0; rs_mut=0; rs_diff=0; rs_rc=0
    declare -A RS_BAD_VERB=()
    while IFS=$'\t' read -r label rc muts diffs hint; do
        v=""
        if [[ "$rc" == SETUP_FAILED ]]; then v="SETUP_FAILED"; rs_setup=$((rs_setup+1))
        elif [[ "$rc" == 124 || "$rc" == 137 ]]; then v="HANG(timeout rc=$rc)"; rs_hang=$((rs_hang+1))
        elif [[ "$muts" != "-" ]]; then v="MUTATION: $muts"; rs_mut=$((rs_mut+1))
        elif [[ "$diffs" != "-" ]]; then v="STATE_DIFF: $diffs"; rs_diff=$((rs_diff+1))
        elif [[ "$rc" != 0 ]]; then v="rc=$rc (help must exit 0)"; rs_rc=$((rs_rc+1))
        fi
        if [[ -n "$v" ]]; then
            rs_fail=$((rs_fail+1))
            RS_BAD_VERB["${label% *}"]=1
            printf '  [FAIL] ROOT: nftban %s (%s)\n' "$label" "$v"
        fi
    done < "$RS_RESULTS"
    if (( rs_fail == 0 )); then
        ok "B5: all $rs_ncases help cases inert as root (no mutation, no state diff, no hang, rc=0)"
    else
        no "B5: root help sweep" "$rs_fail/$rs_ncases cases failed over ${#RS_BAD_VERB[@]} verbs (setup=$rs_setup hang=$rs_hang mutation=$rs_mut state_diff=$rs_diff rc=$rs_rc)"
    fi
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS (regression-prevention gate)"
