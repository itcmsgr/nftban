# =============================================================================
# Bash Completion for NFTBan v0.32.6
# =============================================================================
# Install to: /usr/share/bash-completion/completions/nftban
# This file provides TAB completion for all nftban commands and subcommands

_nftban() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Main commands (keep in sync with nftban help output)
    local main_commands="status check health version help hello \
        firewall ban unban search whitelist profile panel permissions \
        ddos portscan login fail2ban feeds cloudflare \
        stats report port module services fhs nftables geoip mail menu"

    # Complete based on previous word (subcommands)
    case "${prev}" in
        # FIREWALL & SECURITY
        firewall)
            COMPREPLY=( $(compgen -W "init reload status reset start stop enable disable" -- ${cur}) )
            return 0
            ;;
        whitelist)
            COMPREPLY=( $(compgen -W "add remove list show enable disable" -- ${cur}) )
            return 0
            ;;
        profile)
            COMPREPLY=( $(compgen -W "list apply show web-server mail-server" -- ${cur}) )
            return 0
            ;;
        panel)
            COMPREPLY=( $(compgen -W "directadmin da help" -- ${cur}) )
            return 0
            ;;
        directadmin|da)
            if [[ "${COMP_WORDS[1]}" == "panel" ]]; then
                COMPREPLY=( $(compgen -W "enable disable status report repair test help" -- ${cur}) )
                return 0
            fi
            ;;
        permissions)
            COMPREPLY=( $(compgen -W "check fix audit" -- ${cur}) )
            return 0
            ;;

        # PROTECTION MODULES
        ddos)
            COMPREPLY=( $(compgen -W "enable disable status test" -- ${cur}) )
            return 0
            ;;
        portscan)
            COMPREPLY=( $(compgen -W "enable disable status check history test" -- ${cur}) )
            return 0
            ;;
        login)
            COMPREPLY=( $(compgen -W "enable disable status test" -- ${cur}) )
            return 0
            ;;
        fail2ban)
            COMPREPLY=( $(compgen -W "status jails available recommended jail enable disable reload banned ban unban cloudflare health-fix start stop restart help" -- ${cur}) )
            return 0
            ;;
        health-fix)
            if [[ "${COMP_WORDS[1]}" == "fail2ban" ]]; then
                COMPREPLY=( $(compgen -W "--save-report --mail" -- ${cur}) )
                return 0
            fi
            ;;
        feeds)
            COMPREPLY=( $(compgen -W "select list enable disable update status" -- ${cur}) )
            return 0
            ;;
        cloudflare)
            COMPREPLY=( $(compgen -W "enable disable update status" -- ${cur}) )
            return 0
            ;;

        # MONITORING & REPORTING
        stats)
            COMPREPLY=( $(compgen -W "dashboard top ip recent monitor export" -- ${cur}) )
            return 0
            ;;
        report)
            COMPREPLY=( $(compgen -W "generate email schedule run list" -- ${cur}) )
            return 0
            ;;
        port)
            COMPREPLY=( $(compgen -W "scan list summary add remove html-report mail-report detailed status allow-panel help" -- ${cur}) )
            return 0
            ;;
        module)
            COMPREPLY=( $(compgen -W "list summary html-report mail-report help" -- ${cur}) )
            return 0
            ;;
        services)
            COMPREPLY=( $(compgen -W "status list" -- ${cur}) )
            return 0
            ;;
        fhs)
            COMPREPLY=( $(compgen -W "check list summary html-report mail-report help" -- ${cur}) )
            return 0
            ;;
        nftables)
            COMPREPLY=( $(compgen -W "start stop restart reload enable disable status check list help" -- ${cur}) )
            return 0
            ;;
        geoip)
            COMPREPLY=( $(compgen -W "lookup bulk status test update help" -- ${cur}) )
            return 0
            ;;
        mail)
            COMPREPLY=( $(compgen -W "test status config" -- ${cur}) )
            return 0
            ;;

        # CORE
        health)
            COMPREPLY=( $(compgen -W "check --auto-heal" -- ${cur}) )
            return 0
            ;;

        *)
            ;;
    esac

    # Complete main commands
    COMPREPLY=( $(compgen -W "${main_commands}" -- ${cur}) )
    return 0
}

complete -F _nftban nftban
