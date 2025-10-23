#!/usr/bin/env bash

# =============================================================================
# NFTBan Bash Completion Script
# Version: 0.9.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Description: Tab completion for nftban commands
# =============================================================================

_nftban_completion() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Main commands
    local main_commands="
        whitelist blacklist ban unban
        geo feeds cloudflare fail2ban
        stats monitor login
        port rate ddos portscan
        search verify
        init status update sync maintenance
        version help
    "

    # Whitelist subcommands
    local whitelist_cmds="add remove list flush status protect-server detect-server"

    # Blacklist subcommands
    local blacklist_cmds="add remove list flush ban unban temp-ban perm-ban status"

    # GEO subcommands
    local geo_cmds="init status enable disable block allow list update install-db"

    # Feeds subcommands
    local feeds_cmds="list enable disable update status add remove"

    # Cloudflare subcommands
    local cloudflare_cmds="status enable disable update init"

    # Fail2ban subcommands
    local fail2ban_cmds="setup status monitor list enable disable start stop restart service-enable service-disable sync config"

    # Stats subcommands
    local stats_cmds="show dashboard whitelist blacklist bans geo feeds activity"

    # Monitor subcommands
    local monitor_cmds="status start stop logs enable disable"

    # Port subcommands
    local port_cmds="list add remove open close status"

    # Rate subcommands
    local rate_cmds="status enable disable set list"

    # Login subcommands
    local login_cmds="status monitor enable disable list"

    # Search subcommands
    local search_cmds="ip"

    # Update subcommands
    local update_cmds="check perform rollback status"

    # Maintenance subcommands
    local maintenance_cmds="panel backup restore health integrity"

    # DDOS subcommands
    local ddos_cmds="status enable disable protect"

    # Portscan subcommands
    local portscan_cmds="status enable disable protect"

    # Complete main command
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${main_commands}" -- "${cur}") )
        return 0
    fi

    # Complete subcommands based on main command
    local main_cmd="${COMP_WORDS[1]}"

    case "${main_cmd}" in
        whitelist)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${whitelist_cmds}" -- "${cur}") )
            fi
            ;;
        blacklist)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${blacklist_cmds}" -- "${cur}") )
            fi
            ;;
        geo)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${geo_cmds}" -- "${cur}") )
            elif [[ ${COMP_CWORD} -eq 3 && "${prev}" == "block" ]]; then
                # Suggest country codes for geo block
                COMPREPLY=( $(compgen -W "CN RU KP IR" -- "${cur}") )
            fi
            ;;
        feeds)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${feeds_cmds}" -- "${cur}") )
            elif [[ ${COMP_CWORD} -eq 3 && ("${prev}" == "enable" || "${prev}" == "disable") ]]; then
                # Suggest feed IDs (1-10)
                COMPREPLY=( $(compgen -W "1 2 3 4 5 6 7 8 9 10" -- "${cur}") )
            fi
            ;;
        cloudflare|cf)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${cloudflare_cmds}" -- "${cur}") )
            fi
            ;;
        fail2ban|f2b)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${fail2ban_cmds}" -- "${cur}") )
            elif [[ ${COMP_CWORD} -eq 3 && "${prev}" == "config" ]]; then
                COMPREPLY=( $(compgen -W "show set" -- "${cur}") )
            fi
            ;;
        stats)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${stats_cmds}" -- "${cur}") )
            fi
            ;;
        monitor)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${monitor_cmds}" -- "${cur}") )
            fi
            ;;
        port|ports)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${port_cmds}" -- "${cur}") )
            fi
            ;;
        rate)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${rate_cmds}" -- "${cur}") )
            fi
            ;;
        login)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${login_cmds}" -- "${cur}") )
            fi
            ;;
        search)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${search_cmds}" -- "${cur}") )
            fi
            ;;
        update)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${update_cmds}" -- "${cur}") )
            fi
            ;;
        maintenance|maint)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${maintenance_cmds}" -- "${cur}") )
            fi
            ;;
        ddos)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${ddos_cmds}" -- "${cur}") )
            fi
            ;;
        portscan)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "${portscan_cmds}" -- "${cur}") )
            fi
            ;;
        ban)
            # For ban command, suggest --temp or --perm flags
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--temp --perm --reason" -- "${cur}") )
            fi
            ;;
        verify)
            # No subcommands, just complete with IP addresses if available
            return 0
            ;;
        version|help|status|init|sync)
            # These commands have no subcommands
            return 0
            ;;
    esac

    return 0
}

# Register completion function
complete -F _nftban_completion nftban

# Also support 'nft-ban' variant if it exists
complete -F _nftban_completion nft-ban
