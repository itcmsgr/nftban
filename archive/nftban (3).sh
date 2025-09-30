
# ========================
# Init Script Delegation
# ========================

INIT_NFTABLES_SCRIPT="${INIT_NFTABLES_SCRIPT:-/usr/local/sbin/nftban_init_nftables_conf.sh}"
INIT_FAIL2BAN_SCRIPT="${INIT_FAIL2BAN_SCRIPT:-/usr/local/sbin/nftban_init_fail2ban_conf.sh}"

delegate_init_nftables() {
  local args="$1"
  if [ ! -x "$INIT_NFTABLES_SCRIPT" ]; then
    if [ -f "$INIT_NFTABLES_SCRIPT" ]; then chmod +x "$INIT_NFTABLES_SCRIPT"; fi
  fi
  if [ ! -f "$INIT_NFTABLES_SCRIPT" ]; then
    echo -e "${RED}Init nftables script not found:${NC} $INIT_NFTABLES_SCRIPT"
    _log_event "delegate" "" "" "ruleset" "init-nftables missing" "fail" "init-nft"
    return 1
  fi
  _log "Delegating to init-nftables: $INIT_NFTABLES_SCRIPT $args"
  run_with_timeout 60s "$INIT_NFTABLES_SCRIPT" ${args:+$args}
  local rc=$?
  if [ $rc -eq 0 ]; then
    _log_event "delegate" "" "" "ruleset" "init-nftables $args" "success" "init-nft"
  else
    _log_event "delegate" "" "" "ruleset" "init-nftables $args" "fail" "init-nft" "rc=$rc"
  fi
  return $rc
}

delegate_init_fail2ban() {
  local args="$1"
  if [ ! -x "$INIT_FAIL2BAN_SCRIPT" ]; then
    if [ -f "$INIT_FAIL2BAN_SCRIPT" ]; then chmod +x "$INIT_FAIL2BAN_SCRIPT"; fi
  fi
  if [ ! -f "$INIT_FAIL2BAN_SCRIPT" ]; then
    echo -e "${RED}Init fail2ban script not found:${NC} $INIT_FAIL2BAN_SCRIPT"
    _log_event "delegate" "" "" "fail2ban" "init-fail2ban missing" "fail" "init-f2b"
    return 1
  fi
  _log "Delegating to init-fail2ban: $INIT_FAIL2BAN_SCRIPT $args"
  run_with_timeout 60s "$INIT_FAIL2BAN_SCRIPT" ${args:+$args}
  local rc=$?
  if [ $rc -eq 0 ]; then
    _log_event "delegate" "" "" "fail2ban" "init-fail2ban $args" "success" "init-f2b"
  else
    _log_event "delegate" "" "" "fail2ban" "init-fail2ban $args" "fail" "init-f2b" "rc=$rc"
  fi
  return $rc
}

# Help text for init delegation
show_help_init_scripts() {
  cat <<EOF
Init-script delegation:
  --init-nft ["args"]          Run the nftables init script (path: \$INIT_NFTABLES_SCRIPT).
  --init-f2b ["args"]          Run the fail2ban init script (path: \$INIT_FAIL2BAN_SCRIPT).
                               If no args are provided, the scripts are called with --help.
Environment overrides:
  INIT_NFTABLES_SCRIPT=/path/to/nftban_init_nftables_conf.sh
  INIT_FAIL2BAN_SCRIPT=/path/to/nftban_init_fail2ban_conf.sh
EOF
}

# Extend help override to include init-script section
orig_show_help_ref_2=$(declare -f show_help)
show_help() {
  eval "${orig_show_help_ref_2#show_help () {"
  echo
  show_help_delegation
  echo
  show_help_init_scripts
}

# Dispatchers for direct calls
if [ "$1" = "--init-nft" ]; then
  shift
  args="${*:---help}"
  delegate_init_nftables "$args"
  exit $?
fi
if [ "$1" = "--init-f2b" ]; then
  shift
  args="${*:---help}"
  delegate_init_fail2ban "$args"
  exit $?
fi

# ========================
# Deep Integration (source init scripts & expose functions)
# ========================

# List functions from a script (filters out leading underscore/private helpers)
init_list_funcs() {
  local script="$1"
  if [ ! -f "$script" ]; then echo "Missing: $script"; return 1; fi
  # Use a subshell to avoid polluting current shell
  bash -c '
    set -e
    source "$0"
    declare -F | awk "{print \$3}" | grep -E "^[A-Za-z_][A-Za-z0-9_]*$" | grep -v "^_" | sort -u
  ' "$script"
}

# Show short docs for a function by printing comment lines immediately above its definition
init_func_docs() {
  local script="$1" func="$2"
  [ -f "$script" ] || { echo "Missing: $script"; return 1; }
  awk -v fn="$func" '
    $0 ~ "^[[:space:]]*"fn"[[:space:]]*\\(\\)[[:space:]]*{" {
      i=NR-1
      # Walk upwards printing contiguous leading comment lines
      while (i>0 && getline l < FILENAME) { }
    }' "$script" 2>/dev/null 1>/dev/null
  # Simpler portable fallback: print function header line + previous up to 5 comment lines
  awk -v fn="$func" '
    { lines[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) {
        if (match(lines[i], "^[[:space:]]*"fn"[[:space:]]*\\(\\)[[:space:]]*{")) {
          # Print up to 5 lines above that start with # or ##
          for (j=i-5;j<i;j++) if (j>0 && match(lines[j], "^[[:space:]]*#")) print lines[j]
          print lines[i]
          exit 0
        }
      }
    }' "$script"
}

# Call a function inside a script safely in a subshell with timeout
init_call_func() {
  local script="$1" func="$2"; shift 2
  if [ ! -f "$script" ]; then echo -e "${RED}Missing:${NC} $script"; return 1; fi
  if [ -z "$func" ]; then echo -e "${RED}Usage:${NC} --init-call <nft|f2b> <function> [args...]"; return 1; fi
  local cmd=(bash -c '
    set -e
    source "$0"
    type -t "$1" >/dev/null 2>&1 || { echo "Function not found: $1" >&2; exit 127; }
    shift
    "$@"
  ' "$script" "$func" "$func" "$@")
  _log "Init-call: $script :: $func $*"
  run_with_timeout 90s "${cmd[@]}"
  local rc=$?
  if [ $rc -eq 0 ]; then
    _log_event "delegate" "" "" "init-func" "$script::$func $*" "success" "init"
  else
    _log_event "delegate" "" "" "init-func" "$script::$func $*" "fail" "init" "rc=$rc"
  fi
  return $rc
}

# Convenience: wrappers for nft/f2b selection
init_pick_script() {
  local which="$1"
  case "$which" in
    nft) echo "$INIT_NFTABLES_SCRIPT";;
    f2b) echo "$INIT_FAIL2BAN_SCRIPT";;
    *) echo ""; return 1;;
  esac
}

# Rich help section
show_help_init_functions() {
  cat <<'EOF'
Init-function integration:
  --init-list <nft|f2b>        List exported functions from the init script (filters private _helpers).
  --init-doc  <nft|f2b> <fn>   Show brief docs (comment header) for a function if available.
  --init-call <nft|f2b> <fn> [args...]
                               Source the init script in a clean subshell and call <fn> with args.
                               Execution is time-limited and fully logged to the CSV audit log.

Examples:
  nftban --init-list nft
  nftban --init-doc f2b setup_all
  nftban --init-call nft install_final_config
  nftban --init-call f2b setup_all --dry-run
EOF
}

# Rebuild help to include all sections in one place
show_help() {
  cat <<EOF
${BLUE}NFTBan - unified nftables/Fail2Ban manager${NC}

${YELLOW}Core:${NC}
  -e, --enable                  Enable & start nftables + Fail2Ban (after config check)
  -d, --disable                 Disable & stop both services
  -s, --start                   Start both services (after config check)
  -r, --restart                 Restart both services (after config check)
  -x, --stop                    Stop both services
  -l, --list                    List current nftables rules
  -c, --check                   Check nftables & Fail2Ban configuration
  -a, --add-ip [IP]             Add your IP (or given) to whitelist
  -i, --info                    Show current login IP & whitelist status

${YELLOW}Bans:${NC}
  -tb, --temp-ban IP [COMMENT]  Temp-ban IP ($DEFAULT_TEMP_TIMEOUT) with optional comment
  -pb, --perm-ban IP [COMMENT]  Permanently ban IP with optional comment
      --force                   (use with --perm-ban) override whitelist precedence
  -rb, --remove-ban IP          Remove IP from temp set
  -ri, --remove-ip IP           Remove IP from all (temp/perm/f2b)
  -lt, --list-temp              List temp-banned IPs

${YELLOW}Unified views & ops:${NC}
  -lb, --list-bans              Unified list of bans (perm/temp/fail2ban)
  -sy, --sync-bans              Reload blacklist files, enforce whitelist, reload services
  -si, --search-ip IP           Search IP across whitelist/blacklists/nftables/Fail2Ban

${YELLOW}Delegation (power-user):${NC}
  --nft "<args>"                Run raw \`nft <args>\` (10s timeout)
  --f2b "<args>"                Run raw \`fail2ban-client <args>\` (15s timeout)
  --service SVC ACTION          systemctl for nftables/fail2ban (start|stop|restart|reload|status|enable|disable)

${YELLOW}Init-script delegation:${NC}
  --init-nft ["args"]           Run the nftables init script (path: $INIT_NFTABLES_SCRIPT)
  --init-f2b ["args"]           Run the fail2ban init script (path: $INIT_FAIL2BAN_SCRIPT)

${YELLOW}Init-function integration:${NC}
  --init-list <nft|f2b>         List exported functions from the init script
  --init-doc  <nft|f2b> <fn>    Show short docs for an init function (if comment header exists)
  --init-call <nft|f2b> <fn> [...]  Source and execute a specific init function in a safe subshell

${YELLOW}Validation / Logging:${NC}
      --no-validate             Disable reachability checks before banning
      --enable-logging          Enable stdout+file logging
      --disable-logging         Disable stdout+file logging
      --history                 Show path to unified CSV history log

${YELLOW}Examples:${NC}
  nftban --list-bans
  nftban --search-ip 203.0.113.10
  nftban --nft "list ruleset"
  nftban --f2b "status"
  nftban --init-list nft
  nftban --init-call f2b setup_all --dry-run

EOF
}

# === Dispatchers for deep integration ===
if [ "$1" = "--init-list" ] && [ -n "$2" ]; then
  script=$(init_pick_script "$2") || { echo -e "${RED}Choose nft|f2b${NC}"; exit 1; }
  init_list_funcs "$script"; exit $?
fi
if [ "$1" = "--init-doc" ] && [ -n "$2" ] && [ -n "$3" ]; then
  script=$(init_pick_script "$2") || { echo -e "${RED}Choose nft|f2b${NC}"; exit 1; }
  init_func_docs "$script" "$3"; exit $?
fi
if [ "$1" = "--init-call" ] && [ -n "$2" ] && [ -n "$3" ]; then
  which="$2"; shift 2
  script=$(init_pick_script "$which") || { echo -e "${RED}Choose nft|f2b${NC}"; exit 1; }
  func="$1"; shift
  init_call_func "$script" "$func" "$@"; exit $?
fi
