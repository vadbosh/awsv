#!/usr/bin/env bash
#
# Install awsv for the current user.
#
#   ./install.sh              check the components, then install
#   ./install.sh --check      check the components only, change nothing
#   ./install.sh --dry-run    check, then say what would change
#   ./install.sh --uninstall  remove the installed command; the vault stays
#
# One file is installed: awsv into $PREFIX (default ~/.local/bin).
# The installer does not create the GPG key and does not touch ~/.aws.
# Run 'awsv init' after it.

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
DEST="$PREFIX/awsv"
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

    # Cached STS sessions live in $AWSV_RUN, by default /run/awsv. A tmpfs is
    # what makes them disappear on reboot.
    local run="${AWSV_RUN:-/run/awsv}" parent fs
    parent="$(dirname "$run")"
    if [ -w "$parent" ] || [ -w "$run" ]; then
        fs="$(df --output=fstype "$parent" 2>/dev/null | tail -1)"
        if [ "$fs" = tmpfs ]; then ok "session cache in $run (tmpfs)"
        else soft "session cache in $run is on $fs, not tmpfs — sessions survive a reboot"; fi
    else
        bad "cannot write to $parent for the session cache"
        hint "set AWSV_RUN to a writable directory, ideally on tmpfs"
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

install_it() {
    local dry="$1"
    printf '\n%sInstall%s\n' "$B" "$N"
    if [ -f "$DEST" ] && cmp -s "$SRC/awsv" "$DEST"; then
        ok "$DEST is up to date"
        return 0
    fi
    if [ "$dry" = 1 ]; then
        printf '  would write %s\n' "$DEST"
        return 0
    fi
    mkdir -p "$PREFIX"
    install -m 0755 "$SRC/awsv" "$DEST" || die "could not write $DEST"
    cmp -s "$SRC/awsv" "$DEST" || die "$DEST differs from the source after copying"
    ok "installed $DEST"
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
                   "$B" "$N" "$B" "$N" "$B" "$N" ;;
    uninstall) uninstall_it "$force" ;;
esac
