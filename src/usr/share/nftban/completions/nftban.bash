# Bash completion for nftban
# Install to: /usr/share/bash-completion/completions/nftban

_nftban() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Main commands
    opts="status version help init feeds fail2ban geoip whitelist stats reports maintain"

    # Complete based on previous word
    case "${prev}" in
        feeds)
            COMPREPLY=( $(compgen -W "update list enable disable status" -- ${cur}) )
            return 0
            ;;
        fail2ban)
            COMPREPLY=( $(compgen -W "status enable disable jails" -- ${cur}) )
            return 0
            ;;
        geoip)
            COMPREPLY=( $(compgen -W "update status block allow list" -- ${cur}) )
            return 0
            ;;
        whitelist)
            COMPREPLY=( $(compgen -W "add remove list show" -- ${cur}) )
            return 0
            ;;
        stats)
            COMPREPLY=( $(compgen -W "show update export" -- ${cur}) )
            return 0
            ;;
        reports)
            COMPREPLY=( $(compgen -W "daily weekly monthly generate" -- ${cur}) )
            return 0
            ;;
        *)
            ;;
    esac

    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
}

complete -F _nftban nftban
