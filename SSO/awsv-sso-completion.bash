# Bash completion for awsv-sso: Tab offers the commands, then the SSO profile
# names, the options of login and the region names.
#
# ./install.sh puts this file into ~/.local/share/bash-completion/completions/awsv-sso,
# where bash-completion loads it the first time Tab is pressed after "awsv-sso".
# Without the bash-completion package, source it from ~/.bashrc instead.
#
# Profile names are the [profile NAME] headers of ~/.aws/config outside the awsv
# block; aws is not called.

# The commands under COMMANDS in "awsv-sso help". The tests compare this list
# with awsv-sso, so a new command fails them until it is added here.
_awsv_sso_commands="login status logout help"
_awsv_sso_login_options="--start-url --account --role --region --sso-region --session --browser --help"
_awsv_sso_regions="us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 ca-west-1 mx-central-1
sa-east-1 eu-central-1 eu-central-2 eu-west-1 eu-west-2 eu-west-3 eu-south-1 eu-south-2
eu-north-1 il-central-1 me-south-1 me-central-1 af-south-1 ap-south-1 ap-south-2
ap-east-1 ap-east-2 ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-southeast-1
ap-southeast-2 ap-southeast-3 ap-southeast-4 ap-southeast-5 ap-southeast-7"

_awsv_sso_sections() {   # kind: profile | sso-session — headers outside the awsv block
    local f="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
    [ -r "$f" ] || return 0
    awk -v k="$1" '/^# >>> awsv/ {skip = 1; next} /^# <<< awsv/ {skip = 0; next}
         !skip && $0 ~ "^[[:space:]]*\\[" k "[[:space:]]+[^]]+\\]" {
             s = $0; sub("^[[:space:]]*\\[" k "[[:space:]]+", "", s); sub(/\].*$/, "", s)
             if (s != "default") print s }' "$f" | sort -u
}

_awsv_sso() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cmd="${COMP_WORDS[1]:-}" w o out="" i named=0 skip=0
    COMPREPLY=()

    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "$_awsv_sso_commands --help" -- "$cur")
        return 0
    fi

    case "$cmd" in
        help)
            [ "$COMP_CWORD" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "login status logout" -- "$cur")
            return 0 ;;
        status|logout)
            [ "$COMP_CWORD" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "--help" -- "$cur")
            return 0 ;;
        login) ;;
        *) return 0 ;;
    esac

    case "$prev" in
        --region|--sso-region)
            mapfile -t COMPREPLY < <(compgen -W "$_awsv_sso_regions" -- "$cur"); return 0 ;;
        --session)
            mapfile -t COMPREPLY < <(compgen -W "$(_awsv_sso_sections sso-session)" -- "$cur"); return 0 ;;
        --start-url|--account|--role)
            return 0 ;;   # the portal has the value; nothing to offer
    esac

    # Is the profile name already on the line?
    for ((i = 2; i < COMP_CWORD; i++)); do
        w="${COMP_WORDS[i]}"
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$w" in
            --start-url|--account|--role|--region|--sso-region|--session) skip=1 ;;
            -*) ;;
            *) named=1 ;;
        esac
    done

    if [ "$named" = 0 ] && [[ "$cur" != -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$(_awsv_sso_sections profile)" -- "$cur")
        return 0
    fi
    for o in $_awsv_sso_login_options; do   # the options not yet on the line
        for w in "${COMP_WORDS[@]}"; do [ "$w" = "$o" ] && continue 2; done
        out+=" $o"
    done
    mapfile -t COMPREPLY < <(compgen -W "$out" -- "$cur")
}

complete -F _awsv_sso awsv-sso
