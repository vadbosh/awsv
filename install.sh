#!/usr/bin/env bash
#
# Install awsv for the current user.
#
#   ./install.sh              check the components, then install
#   ./install.sh --check      check the components only, change nothing
#   ./install.sh --dry-run    check, then say what would change
#   ./install.sh --uninstall  remove the installed command; the vault stays
#
# Four files are installed: awsv and awsv-sso into $PREFIX (default
# ~/.local/bin), and the Tab completion of each into the directory
# bash-completion reads for this user
# (default ~/.local/share/bash-completion/completions/awsv and awsv-sso).
# The installer does not create the GPG key and does not touch ~/.aws.
# Run 'awsv init' after it.

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
DEST="$PREFIX/awsv"
SSO="$PREFIX/awsv-sso"
# bash-completion looks in each directory of BASH_COMPLETION_USER_DIR, else in
# $XDG_DATA_HOME/bash-completion; the first one is where this file goes.
COMPDIR="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}"
COMPDIR="${COMPDIR%%:*}/completions"
COMP="$COMPDIR/awsv"
COMP_SSO="$COMPDIR/awsv-sso"
CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' N=$'\e[0m'
else
    B="" G="" Y="" R="" D="" N=""
fi

MISSING=0
ok()   { printf '  %sok%s    %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %smiss%s  %s\n' "$R$B" "$N" "$*"; MISSING=$((MISSING + 1)); }
soft() { printf '  %swarn%s  %s\n' "$Y" "$N" "$*"; }
hint() { printf '        %s%s%s\n' "$D" "$*" "$N"; }
die()  { printf '%sinstall: %s%s\n' "$R$B" "$*" "$N" >&2; exit 1; }

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0; }

# --------------------------------------------------------- the components

check() {
    printf '%sComponents%s\n' "$B" "$N"

    # bash 4: [[ =~ ]], +=, read -r into several variables
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then ok "bash $BASH_VERSION"
    else bad "bash 4 or newer is needed, this is $BASH_VERSION"; fi

    # gpg 2.2: --quick-generate-key with future-default (ed25519 + cv25519)
    if command -v gpg >/dev/null 2>&1; then
        local v; v="$(gpg --version | head -1 | awk '{print $NF}')"
        case "$v" in
            2.[2-9]*|2.[1-9][0-9]*|[3-9].*) ok "gpg $v" ;;
            *) bad "gpg 2.2 or newer is needed, this is $v"; hint "apt install gnupg" ;;
        esac
    else
        bad "gpg"; hint "apt install gnupg"
    fi

    local t
    for t in gpg-agent gpgconf gpg-connect-agent; do
        if command -v "$t" >/dev/null 2>&1; then ok "$t"
        else bad "$t"; hint "apt install gnupg"; fi
    done

    # The passphrase prompt in a text terminal. A graphical pinentry cannot
    # draw on a server without a desktop, so the curses one is the one needed.
    if [ -x /usr/bin/pinentry-curses ] || command -v pinentry-curses >/dev/null 2>&1; then
        ok "pinentry-curses"
    elif command -v pinentry-tty >/dev/null 2>&1; then
        ok "pinentry-tty"
        soft "awsv init writes pinentry-curses into gpg-agent.conf; edit it to pinentry-tty"
    else
        bad "pinentry-curses — gpg cannot ask for the passphrase without it"
        hint "apt install pinentry-curses"
    fi

    # AWS CLI v2. credential_process and --query exist in v1 too, but v1 is
    # what 'apt install awscli' gives on many systems and it is end of life.
    if command -v aws >/dev/null 2>&1; then
        local a; a="$(aws --version 2>&1 | awk '{print $1}')"
        case "$a" in
            aws-cli/2.*) ok "$a" ;;
            *) bad "AWS CLI v2 is needed, this is ${a:-unknown}"
               hint "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
        esac
    else
        bad "aws"; hint "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi

    # GNU tools: date -d reads the STS expiry, xargs -r, readlink -f
    if date -d '2026-01-01T00:00:00+00:00' +%s >/dev/null 2>&1; then ok "GNU date"
    else bad "GNU date (date -d)"; hint "apt install coreutils"; fi
    if echo | xargs -r true 2>/dev/null; then ok "GNU xargs"
    else bad "GNU xargs (xargs -r)"; hint "apt install findutils"; fi
    if readlink -f / >/dev/null 2>&1; then ok "readlink -f"
    else bad "readlink -f"; hint "apt install coreutils"; fi
    for t in awk sed grep mktemp; do
        if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t"; fi
    done

    # Where awsv will cache STS sessions — the same choice awsv itself makes:
    # AWSV_RUN, else $XDG_RUNTIME_DIR/awsv, else /run/awsv for root, else none.
    # A normal user cannot write to /run, so no cache is a valid outcome, not an
    # error: awsv then asks STS on every call.
    local run parent fs
    if [ -n "${AWSV_RUN+x}" ]; then run="$AWSV_RUN"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
        run="$XDG_RUNTIME_DIR/awsv"
    elif [ "$(id -u)" = 0 ]; then run=/run/awsv
    else run=""; fi
    if [ -z "$run" ]; then
        soft "no session cache: XDG_RUNTIME_DIR is not set, so every aws call asks STS"
        hint "a normal login (ssh, console) sets it; or set AWSV_RUN to a private directory"
    else
        parent="$(dirname "$run")"
        if [ -w "$parent" ] || [ -w "$run" ]; then
            fs="$(df --output=fstype "$parent" 2>/dev/null | tail -1)"
            if [ "$fs" = tmpfs ]; then ok "session cache in $run (tmpfs)"
            else soft "session cache in $run is on $fs, not tmpfs — sessions survive a reboot"; fi
        else
            bad "cannot write to $parent for the session cache"
            hint "set AWSV_RUN to a writable directory, ideally on tmpfs"
        fi
    fi

    # Tab completion. Without the package the file is still installed, but
    # nothing loads it: it has to be sourced from ~/.bashrc.
    if [ -r /usr/share/bash-completion/bash_completion ] || [ -r /etc/bash_completion ]; then
        ok "bash-completion"
    else
        soft "no bash-completion — Tab after 'awsv' will not offer commands"
        hint "apt install bash-completion, or add to ~/.bashrc: . $COMP"
    fi

    case ":$PATH:" in
        *":$PREFIX:"*) ok "$PREFIX is in PATH" ;;
        *) soft "$PREFIX is not in PATH — 'awsv' will not be found by name"
           hint "add to ~/.bashrc: export PATH=\"$PREFIX:\$PATH\"" ;;
    esac

    if [ "$MISSING" -gt 0 ]; then
        printf '\n%s%d component(s) missing.%s Install them and run again.\n' "$R$B" "$MISSING" "$N"
        return 1
    fi
    printf '\n%sall components present%s\n' "$G" "$N"
}

# ------------------------------------------------------------ the actions

install_file() {   # dry source destination mode
    local dry="$1" src="$2" dest="$3" mode="$4"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        ok "$dest is up to date"
        return 0
    fi
    if [ "$dry" = 1 ]; then
        printf '  would write %s\n' "$dest"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    install -m "$mode" "$src" "$dest" || die "could not write $dest"
    cmp -s "$src" "$dest" || die "$dest differs from the source after copying"
    ok "installed $dest"
}

install_it() {
    local dry="$1"
    printf '\n%sInstall%s\n' "$B" "$N"
    install_file "$dry" "$SRC/awsv" "$DEST" 0755
    install_file "$dry" "$SRC/SSO/awsv-sso" "$SSO" 0755
    install_file "$dry" "$SRC/SSO/awsv-sso-completion.bash" "$COMP_SSO" 0644
    install_file "$dry" "$SRC/awsv-completion.bash" "$COMP" 0644
}

uninstall_it() {
    local force="$1"
    [ -e "$DEST" ] || { printf 'nothing to remove: %s does not exist\n' "$DEST"; return 0; }
    # Removing the command while ~/.aws/config still calls it breaks every aws
    # call at once, with an error that does not name awsv.
    if [ "$force" = 0 ] && grep -q 'credential_process = .*awsv creds' "$CONFIG" 2>/dev/null; then
        die "$CONFIG still calls awsv for credentials. Every aws command would fail.
         Move the accounts out first, or run with --uninstall --force."
    fi
    rm -f "$DEST"
    ok "removed $DEST"
    if [ -e "$SSO" ]; then rm -f "$SSO"; ok "removed $SSO"; fi
    if [ -e "$COMP" ]; then rm -f "$COMP"; ok "removed $COMP"; fi
    if [ -e "$COMP_SSO" ]; then rm -f "$COMP_SSO"; ok "removed $COMP_SSO"; fi
    printf '%sThe vault is still in %s: keys, settings and backups are untouched.%s\n' \
        "$Y" "${AWSV_HOME:-$HOME/.local/share/awsv}" "$N"
}

# ------------------------------------------------------------------- main

mode=install force=0
for a in "$@"; do
    case "$a" in
        --check)     mode=check ;;
        --dry-run)   mode=dry ;;
        --uninstall) mode=uninstall ;;
        --force)     force=1 ;;
        -h|--help)   usage ;;
        *)           die "unknown option '$a' (try --help)" ;;
    esac
done

case "$mode" in
    check)     check ;;
    dry)       check || exit 1; install_it 1 ;;
    install)   check || exit 1; install_it 0
               printf '\nNext: %sawsv init%s, then %sawsv import SECTION --as NAME%s or %sawsv add NAME%s\n' \
                   "$B" "$N" "$B" "$N" "$B" "$N"
               printf 'Tab after awsv offers commands and account names in a new terminal.\n' ;;
    uninstall) uninstall_it "$force" ;;
esac
