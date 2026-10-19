#!/usr/bin/env bash
# Every "awsv ..." that a reader can see — in the help, the README files, the
# status output and the messages of awsv — must be a command awsv accepts.
#
# Why: status once printed the GPG key's name, "awsv local vault". A reader
# typed it, and awsv answered "unknown command 'local'". Anything that looks
# like a command will be typed as one.
#
# Each candidate is classified:
#   a known command     run it in a sandbox; awsv must not reject its syntax
#   a sentence          "awsv keeps your keys ..." — listed in PROSE below
#   anything else       a failure: it looks like a command and is not one
# Runtime refusals are fine here — "needs a terminal", "already in the vault":
# the command was understood. Syntax refusals are not.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
pass=0 fail=0
kill_own_agents() {   # the gpg-agent of every account with its own passphrase
    local h
    for h in "$T"/home/.local/share/awsv/gnupg/*; do
        [ -d "$h" ] && gpgconf --homedir "$h" --kill gpg-agent 2>/dev/null
    done
    return 0
}
cleanup() { kill_own_agents; GNUPGHOME="$T/gnupg" gpgconf --kill gpg-agent 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

KNOWN=" init add import ls list use set rekey rm remove exec show passwd unlock lock status creds help "
# Words that follow "awsv" in a sentence about the tool, not in a command.
PROSE=" keeps writes stores uses then is hands reads checks returned asks pick works creates trades block repository to "
# Syntax refusals: the command, as printed, is wrong.
BAD='unknown command|unknown option|^awsv: usage:|bad name|bad region|bad duration|mode is|no help topic|nothing to change'

export HOME="$T/home" GNUPGHOME="$T/gnupg" AWSV_RUN="$T/run" NO_COLOR=1
export AWS_CONFIG_FILE="$HOME/.aws/config" AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/creds.ini"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
mkdir -p "$HOME/.aws" "$GNUPGHOME" "$T/bin"; chmod 700 "$GNUPGHOME"
cp "$SRC/awsv" "$T/bin/awsv"; chmod 755 "$T/bin/awsv"
# The key of an account with its own passphrase: gpg would ask in a terminal; here it is empty.
REAL_GPG="$(command -v gpg)"
cat > "$T/bin/gpg" <<EOF
#!/bin/sh
case "\$*" in
    *"--quick-generate-key awsv-"*) exec "$REAL_GPG" --batch --pinentry-mode loopback --passphrase '' "\$@" ;;
esac
exec "$REAL_GPG" "\$@"
EOF
chmod 755 "$T/bin/gpg"; export PATH="$T/bin:$PATH"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "awsv local vault" future-default default never 2>/dev/null
awsv init >/dev/null 2>&1

# Every account name the documents use, so that commands naming them find one.
i=1
for n in work client nexum old prod other; do
    printf 'AKIA00000000000%d\n0000000000\n' "$i" | awsv add "$n" --stdin --no-verify --mode direct >/dev/null 2>&1
    i=$((i + 1))
done
printf 'AKIA000000000008\n0000000000\n' | awsv add solo --stdin --no-verify --mode direct --lock own >/dev/null 2>&1
kill_own_agents
printf '[client]\naws_access_key_id = AKIA000000000009\naws_secret_access_key = 0000000000\n' \
    > "$AWS_SHARED_CREDENTIALS_FILE"
tar -C "$HOME" -cf "$T/pristine.tar" .        # each command starts from this state

# ---------------------------------------------------------------- collect
{
    awsv --help
    awsv status
    # README: only what a reader is meant to type — code blocks and `inline code`
    awk '/^```/ {f = !f; next} f' "$SRC/README.md" "$SRC/README.RU.md"
    grep -ohE '`[^`]+`' "$SRC/README.md" "$SRC/README.RU.md"
    # messages: the string literals of awsv
    grep -ohE '"[^"]*awsv [^"]*"|'"'"'[^'"'"']*awsv [^'"'"']*'"'" "$SRC/awsv"
} | grep -v 'usage: awsv' > "$T/text"   # a usage line describes syntax; it is not a command to copy

# "awsv word ..." not preceded by a quote, a slash or a letter: inside "awsv
# local vault" or a path it is a name, not a command.
grep -oP '(?<![\w"«/.$-])awsv [a-z][\w-]*(?: (?:--?[\w-]+|[A-Za-z$][\w.$-]*))*' "$T/text" \
    | sed -E 's/[.,:]+$//' | sort -u > "$T/candidates"

# ------------------------------------------------------------------- check
fill() {   # placeholders and shell variables → real values from the sandbox
    sed -E 's/\$name|\$n\b|NAME/work/g; s/\$sec|SECTION/client/g; s/OTHER/client/g;
            s/REGION/eu-central-1/g; s/COMMAND|TOPIC/add/g'
}

while IFS= read -r c; do
    w="$(printf '%s' "$c" | awk '{print $2}')"
    case "$KNOWN" in *" $w "*) ;; *)
        case "$PROSE" in *" $w "*) continue ;; esac
        fail=$((fail + 1)); echo "FAIL looks like a command, is not one: $c"; continue ;;
    esac
    cmd="$(printf '%s' "$c" | fill)"
    kill_own_agents
    rm -rf "$HOME"; mkdir -p "$HOME"; tar -C "$HOME" -xf "$T/pristine.tar"
    timeout 30 sh -c "$cmd" < /dev/null > "$T/out" 2>&1
    if grep -qE "$BAD" "$T/out"; then
        fail=$((fail + 1)); echo "FAIL rejected as written: $c"; sed 's/^/    /' "$T/out" | head -3
    else
        pass=$((pass + 1))
    fi
done < "$T/candidates"

# ------------------------------------------- the other commands the docs give
kill_own_agents
rm -rf "$HOME"; mkdir -p "$HOME"; tar -C "$HOME" -xf "$T/pristine.tar"
check() {   # name, command — must exit 0
    if sh -c "$2" > "$T/out" 2>&1; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL $1: $2"; sed 's/^/    /' "$T/out" | head -3; fi
}
check "the gpg command that shows a key" 'gpg --quiet --decrypt ~/.local/share/awsv/keys/work.gpg'
check "the same for an own passphrase" 'gpg --homedir ~/.local/share/awsv/gnupg/solo --quiet --decrypt ~/.local/share/awsv/keys/solo.gpg'
check "the gpg name in the recovery steps" 'gpg --list-secret-keys "awsv local vault"'
check "gpg has the recovery option" 'gpg --dump-options | grep -qx -- --delete-secret-and-public-keys'
check "gpg has the passphrase option" 'gpg --dump-options | grep -qx -- --change-passphrase'
check "aws configure list" 'aws configure list'
for n in work client nexum old prod; do   # every profile the docs name exists
    check "profile $n is in the config" "aws configure list --profile $n"
done
for o in --check --dry-run; do
    check "install.sh $o" "PREFIX='$T/prefix' '$SRC/install.sh' $o"
done
check "install.sh --help" "'$SRC/install.sh' --help"

echo "docs commands: $(wc -l < "$T/candidates") found, $pass passed, $fail failed"
[ "$fail" -eq 0 ]
