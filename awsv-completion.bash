# Bash completion for awsv: Tab after "awsv" offers the commands, then the
# account names, the options and their values.
#
# ./install.sh puts this file into ~/.local/share/bash-completion/completions/awsv,
# where bash-completion loads it the first time Tab is pressed after "awsv".
# Without the bash-completion package, source it from ~/.bashrc instead.
#
# Account names are the file names in keys/, section names are the [headers]
# of ~/.aws/credentials. Nothing is decrypted, and no key line is read.

# The commands listed under COMMANDS in "awsv help". The tests compare this
# list and the topics with awsv, so a new command fails them until it is added.
_awsv_commands="init add import ls use exec set rekey rm show passwd unlock lock status help"
_awsv_topics="init add import ls use exec set rekey rm show passwd unlock lock status passphrase"
# The commercial regions known when this was written. Any region awsv accepts
# can still be typed in full.
_awsv_regions="us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 ca-west-1 mx-central-1
sa-east-1 eu-central-1 eu-central-2 eu-west-1 eu-west-2 eu-west-3 eu-south-1 eu-south-2
eu-north-1 il-central-1 me-south-1 me-central-1 af-south-1 ap-south-1 ap-south-2
ap-east-1 ap-east-2 ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-southeast-1
ap-southeast-2 ap-southeast-3 ap-southeast-4 ap-southeast-5 ap-southeast-7"

_awsv_names() {
    local f
    for f in "${AWSV_HOME:-$HOME/.local/share/awsv}"/keys/*.gpg; do
        [ -e "$f" ] || continue
        f="${f##*/}"
        printf '%s\n' "${f%.gpg}"
    done
}

_awsv_sections() {   # [name] and commented #[name]: import takes both
    local f="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
    [ -r "$f" ] || return 0
    sed -n 's/^[[:space:]]*#\{0,1\}[[:space:]]*\[\([^]]*\)\].*/\1/p' "$f" | sort -u
}

_awsv_profiles() {   # [profile NAME] outside the awsv block: use takes those too
    local f="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
    [ -r "$f" ] || return 0
    awk '/^# >>> awsv/ {skip = 1; next} /^# <<< awsv/ {skip = 0; next}
         !skip && /^[[:space:]]*\[profile[[:space:]]+[^]]+\]/ {
             s = $0; sub(/^[[:space:]]*\[profile[[:space:]]+/, "", s); sub(/\].*$/, "", s)
             if (s != "default") print s }' "$f" | sort -u
}

_awsv_reply() {   # words — the ones that start with the current word
    mapfile -t COMPREPLY < <(compgen -W "$1" -- "$cur")
}

_awsv_options() {   # options — the ones not yet on the line
    local o w out=""
    for o in $1; do
        for w in "${COMP_WORDS[@]}"; do [ "$w" = "$o" ] && continue 2; done
        out+=" $o"
    done
    _awsv_reply "$out"
}

_awsv() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cmd="${COMP_WORDS[1]:-}" w i skip=0 dashes=0
    local -a args=()
    COMPREPLY=()

    if [ "$COMP_CWORD" -eq 1 ]; then _awsv_reply "$_awsv_commands"; return 0; fi

    # The words between the command and the cursor: arguments, not options.
    for ((i = 2; i < COMP_CWORD; i++)); do
        w="${COMP_WORDS[i]}"
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$w" in
            --) dashes=$i; break ;;
            --lock|--mode|--region|--as|--mfa) skip=1 ;;
            -*) ;;
            *) args+=("$w") ;;
        esac
    done

    # awsv exec NAME -- CMD ...: from here on, complete CMD as bash would.
    if [ "$cmd" = exec ] && [ "$dashes" -gt 0 ]; then
        if [ "$COMP_CWORD" -eq $((dashes + 1)) ]; then
            mapfile -t COMPREPLY < <(compgen -c -- "$cur")
        elif declare -F _comp_command_offset >/dev/null; then
            _comp_command_offset $((dashes + 1))
        elif declare -F _command_offset >/dev/null; then
            _command_offset $((dashes + 1))
        else
            compopt -o default 2>/dev/null
        fi
        return 0
    fi

    case "$prev" in
        --lock)   _awsv_reply "shared own"; return 0 ;;
        --mode)   _awsv_reply "session direct"; return 0 ;;
        --region) _awsv_reply "$_awsv_regions"; return 0 ;;
        --as)     return 0 ;;   # a new name: nothing to offer
        --mfa)    _awsv_reply "none arn:aws:iam::"; return 0 ;;   # an ARN, or none to drop it
    esac

    case "$cmd" in
        init)
            _awsv_options "--take-default --lock" ;;
        add)   # the first argument is a new name
            [ "${#args[@]}" -ge 1 ] && _awsv_options "--region --mode --lock --mfa --no-verify --stdin" ;;
        import)
            if [ "${#args[@]}" -eq 0 ]; then _awsv_reply "$(_awsv_sections)"
            else _awsv_options "--as --keep --region --mode --lock --mfa --no-verify"; fi ;;
        set)
            if [ "${#args[@]}" -eq 0 ]; then _awsv_reply "$(_awsv_names)"
            else _awsv_options "--region --mode --lock --mfa"; fi ;;
        rekey)
            if [ "${#args[@]}" -eq 0 ]; then _awsv_reply "$(_awsv_names)"
            else _awsv_options "--stdin --no-verify"; fi ;;
        rm|remove)
            if [ "${#args[@]}" -eq 0 ]; then _awsv_reply "$(_awsv_names)"
            else _awsv_options "--yes"; fi ;;
        exec)
            if [ "${#args[@]}" -eq 0 ]; then _awsv_reply "$(_awsv_names)"
            else _awsv_reply "--"; fi ;;
        use)   # an account of the vault, or a profile kept outside it
            [ "${#args[@]}" -eq 0 ] && _awsv_reply "$(_awsv_names) $(_awsv_profiles)" ;;
        show|passwd|lock)
            [ "${#args[@]}" -eq 0 ] && _awsv_reply "$(_awsv_names)" ;;
        unlock)   # [NAME|all] [DURATION], in either order
            local target=0 dur=0 names words=""
            names="$(_awsv_names)"
            for w in "${args[@]}"; do
                if [ "$w" = all ] || printf '%s\n' "$names" | grep -qxF -- "$w"; then target=1
                else dur=1; fi
            done
            [ "$target" = 0 ] && words+=" all $names"
            [ "$dur" = 0 ] && words+=" 30m 1h 8h"
            _awsv_reply "$words" ;;
        help)
            [ "${#args[@]}" -eq 0 ] && _awsv_reply "$_awsv_topics" ;;
    esac
    return 0
}

complete -F _awsv awsv
