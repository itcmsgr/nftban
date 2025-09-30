
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
