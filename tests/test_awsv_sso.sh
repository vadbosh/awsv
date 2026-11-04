#!/usr/bin/env bash
# Tests for SSO/awsv-sso.
#
# Runs in a throwaway HOME with a stand-in for aws: nothing reaches AWS, and
# the real ~/.aws is never read or written. The stand-in logs every call and
# answers STS only for profiles listed in $T/live.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
pass=0 fail=0
trap 'rm -rf "$T"' EXIT

export HOME="$T/home" NO_COLOR=1 XDG_STATE_HOME="$T/state"
export AWS_CONFIG_FILE="$HOME/.aws/config" AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/credentials"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN BROWSER
unset XDG_DATA_HOME BASH_COMPLETION_USER_DIR
mkdir -p "$HOME/.aws" "$T/bin" "$T/live"
cp "$SRC/SSO/awsv-sso" "$T/bin/awsv-sso"; chmod 755 "$T/bin/awsv-sso"
ARN='arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_ReadOnly_0123456789abcdef/user@example.com'
cat > "$T/bin/aws" <<EOF
#!/usr/bin/env bash
printf 'BROWSER=%s %s\n' "\${BROWSER:-}" "\$*" >> "$T/aws.log"
case "\$1 \${2:-}" in
    "--version ") echo "aws-cli/2.99.0 Python/3 Linux" ;;
    "sso login")
        case "\$*" in *--sso-session*)   # the AWS CLI caches the token of the session
            mkdir -p "\$HOME/.aws/sso/cache"
            printf '{"startUrl": "%s", "region": "us-east-1", "accessToken": "tok-123", "expiresAt": "2099-01-01T00:00:00Z"}' \
                "\${FAKE_URL:-https://example.awsapps.com/start}" > "\$HOME/.aws/sso/cache/0123.json" ;;
        esac
        exit "\${FAKE_LOGIN_RC:-0}" ;;
    "sso list-accounts"|"sso list-account-roles")
        f=""; for a in "\$@"; do case "\$a" in file://*) f="\${a#file://}" ;; esac; done
        grep -q '"accessToken":"tok-123"' "\$f" || { echo "bad token input" >&2; exit 254; }
        cp "\$f" "$T/last-input.json"
        if [ "\$2" = list-accounts ]; then printf '%b' "\${FAKE_ACCOUNTS-111122223333\\tProd\\n444455556666\\tStage\\n}"
        else printf '%b' "\${FAKE_ROLES-ReadOnly\\nAdmin\\n}"; fi ;;
    "sso logout") echo "Successfully signed out of all SSO profiles." ;;
    "sts get-caller-identity")
        all="\$*" p=""; while (( \$# )); do [ "\$1" = --profile ] && p="\$2"; shift; done
        [ -e "$T/live/\$p" ] || exit 255
        case "\$all" in *Account*) printf '111122223333\t%s\n' "$ARN" ;; *) printf '%s\n' "$ARN" ;; esac ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$T/bin/aws"
export PATH="$T/bin:$PATH"

t() {   # name, expected exit, command...
    local name="$1" want="$2"; shift 2
    "$@" >"$T/out" 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL $name: exit $got, want $want"; sed 's/^/    /' "$T/out"; fi
}
has() {   # name, regex, file
    if grep -qE -- "$2" "$3"; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL $1: /$2/ not in $3"; sed 's/^/    /' "$3" | head -20; fi
}
hasnt() {
    if grep -qE -- "$2" "$3"; then
        fail=$((fail + 1)); echo "FAIL $1: /$2/ is in $3"; sed 's/^/    /' "$3" | head -20
    else pass=$((pass + 1)); fi
}
count() {   # name, regex, file, n
    local n; n="$(grep -cE -- "$2" "$3")"
    if [ "$n" = "$4" ]; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL $1: /$2/ found $n times, want $4"; fi
}

C="$AWS_CONFIG_FILE"
URL=https://example.awsapps.com/start
# The config as awsv leaves it: the user's part, then the awsv block.
cat > "$C" <<'EOF'
# my notes
[profile other]
region = eu-west-1

# >>> awsv: generated, do not edit between these two lines >>>
[default]
region = us-east-1
credential_process = /bin/awsv creds alpha

[profile alpha]
region = us-east-1
credential_process = /bin/awsv creds alpha
# <<< awsv <<<
EOF
cp "$C" "$T/block.orig"
block() { awk '/^# >>> awsv/ {f=1} f; /^# <<< awsv/ {f=0}' "$1"; }

# ------------------------------------------------------------- arguments
t "no command shows help" 0 awsv-sso
has "help names login" 'login NAME \[OPTIONS\]' "$T/out"
has "help says logout ends every session" 'cannot log out of one profile' "$T/out"
for s in USAGE 'START HERE' COMMANDS 'LOG OUT' FILES ENVIRONMENT 'EXIT STATUS'; do
    has "help has $s" "^$s( |\$)" "$T/out"
done
t "--help" 0 awsv-sso --help
has "--help is the same page" '^COMMANDS$' "$T/out"
t "-h" 0 awsv-sso -h
t "help login" 0 awsv-sso help login
has "help login lists --start-url" '--start-url URL' "$T/out"
for s in OPTIONS EXAMPLES REFUSED; do has "help login has $s" "^$s\$" "$T/out"; done
t "login --help" 0 awsv-sso login --help
has "login --help is help login" '^OPTIONS$' "$T/out"
t "help status" 0 awsv-sso help status
has "help status has COLUMNS" '^COLUMNS$' "$T/out"
t "status -h" 0 awsv-sso status -h
has "status -h is help status" '^COLUMNS$' "$T/out"
t "help logout" 0 awsv-sso help logout
has "help logout says every login" 'every SSO' "$T/out"
t "logout --help" 0 awsv-sso logout --help
has "logout --help is help logout" 'has no logout of one profile' "$T/out"
t "unknown help topic" 1 awsv-sso help frob
has "it lists the topics" 'topics: login status logout' "$T/out"
t "unknown command" 1 awsv-sso frobnicate
t "login needs a name" 1 awsv-sso login
t "bad name" 1 awsv-sso login 'bad name'
t "default is refused" 1 awsv-sso login default --start-url "$URL" --account 111122223333 --role R --region us-east-1
t "a vault account is refused" 1 awsv-sso login alpha --start-url "$URL" --account 111122223333 --role R --region us-east-1
has "it says why" 'vault account of awsv' "$T/out"
t "unknown option" 1 awsv-sso login work --frob
t "first login needs the settings" 1 awsv-sso login work
has "it names what is missing" 'needs --start-url --region' "$T/out"
t "http start URL refused" 1 awsv-sso login work --start-url http://x --account 111122223333 --role R --region us-east-1
t "short account refused" 1 awsv-sso login work --start-url "$URL" --account 1234 --role R --region us-east-1
t "bad region refused" 1 awsv-sso login work --start-url "$URL" --account 111122223333 --role R --region useast
t "a non-SSO profile needs the settings" 1 awsv-sso login other
has "it says it is not an SSO profile" 'not an SSO profile' "$T/out"
hasnt "refused logins never reach aws sso login" 'sso login' "$T/aws.log"

# ------------------------------------------------------------- first login
touch "$T/live/work"
t "first login" 0 awsv-sso login work --start-url "$URL" --account 111122223333 --role ReadOnly --region eu-central-1
has "identity shown" "Identity +$ARN" "$T/out"
has "permission set shown" 'Permission set +ReadOnly' "$T/out"
has "hint: awsv use" 'awsv use work' "$T/out"
has "sso-session written" '^\[sso-session work\]$' "$C"
has "start URL" "^sso_start_url = $URL$" "$C"
has "sso region follows --region" '^sso_region = eu-central-1$' "$C"
has "profile written" '^\[profile work\]$' "$C"
has "account" '^sso_account_id = 111122223333$' "$C"
has "role" '^sso_role_name = ReadOnly$' "$C"
has "session link" '^sso_session = work$' "$C"
has "user notes kept" '^# my notes$' "$C"
diff <(block "$T/block.orig") <(block "$C") >/dev/null && pass=$((pass + 1)) \
    || { fail=$((fail + 1)); echo "FAIL the awsv block changed"; }
has "device code by default" '^BROWSER=echo sso login --profile work --use-device-code$' "$T/aws.log"
[ "$(stat -c %a "$C")" = 600 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL config mode $(stat -c %a "$C")"; }
ls "$T/state/awsv-sso"/config.* >/dev/null 2>&1 && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL no backup"; }

# ------------------------------------------------------------- repeat and change
cp "$C" "$T/after1"
nb="$(ls "$T/state/awsv-sso" | wc -l)"
t "repeat login needs no flags" 0 awsv-sso login work
cmp -s "$C" "$T/after1" && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL repeat login changed the config"; }
[ "$(ls "$T/state/awsv-sso" | wc -l)" = "$nb" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL repeat login made a backup"; }
t "role switch" 0 awsv-sso login work --role Admin
has "role changed" '^sso_role_name = Admin$' "$C"
count "one role line" '^sso_role_name' "$C" 1
count "one profile section" '^\[profile work\]$' "$C" 1
count "one session section" '^\[sso-session work\]$' "$C" 1
t "browser flow" 0 awsv-sso login work --browser
has "no device code with --browser" '^BROWSER= sso login --profile work$' "$T/aws.log"

# A second profile on the same session: one login serves both.
touch "$T/live/work-admin"
t "shared session" 0 awsv-sso login work-admin --session work --account 111122223333 --role Admin
has "linked to the session" '^sso_session = work$' "$C"
count "still one session section" '^\[sso-session work\]$' "$C" 1

# ------------------------------------------------------------- pick the account and the role
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
touch "$T/live/pick1" "$T/live/pick2" "$T/live/pick3"
: > "$T/aws.log"
printf '2\n1\n' > "$T/answers"
t "login with only the portal address" 0 env AWSV_SSO_NO_TTY=1 awsv-sso login pick1 --start-url "$URL" --region us-east-1 < "$T/answers"
has "the session logs in, not the profile" '^BROWSER=echo sso login --sso-session pick1 --use-device-code$' "$T/aws.log"
has "accounts are listed" 'Pick the account' "$T/out"
has "the second account is picked" '^sso_account_id = 444455556666$' "$C"
has "the first role is picked" '^sso_role_name = ReadOnly$' "$C"
has "roles asked for the picked account" '"accountId":"444455556666"' "$T/last-input.json"
hasnt "the token is not on any command line" 'tok-123' "$T/aws.log"
hasnt "the token is not printed" 'tok-123' "$T/out"
[ -z "$(ls -A "$TMPDIR")" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL a temporary file is left: $(ls -A "$TMPDIR")"; }
has "identity after the pick" 'Permission set +ReadOnly' "$T/out"

t "one account and one role: no questions" 0 env AWSV_SSO_NO_TTY=1 FAKE_ACCOUNTS='111122223333\tProd\n' FAKE_ROLES='Admin\n' \
    awsv-sso login pick2 --start-url "$URL" --region us-east-1 < /dev/null
has "the only account taken" 'account: 111122223333  Prod' "$T/out"
hasnt "no question asked" 'Pick the' "$T/out"

t "--account given: only the role is picked" 0 env AWSV_SSO_NO_TTY=1 awsv-sso login pick3 --start-url "$URL" --region us-east-1 --account 111122223333 < <(printf '2\n')
hasnt "accounts not listed then" 'Pick the account' "$T/out"
has "the second role picked" 'Admin' "$T/out"

t "no answer: refused" 1 env AWSV_SSO_NO_TTY=1 awsv-sso login pick4 --start-url "$URL" --region us-east-1 < /dev/null
has "it names the option" 'no account picked — give it with --account VALUE' "$T/out"
hasnt "no profile without an account" '^\[profile pick4\]$' "$C"
t "an answer out of range: refused" 1 env AWSV_SSO_NO_TTY=1 awsv-sso login pick4 --start-url "$URL" --region us-east-1 < <(printf '9\n')
t "the portal lists nothing" 1 env AWSV_SSO_NO_TTY=1 FAKE_ACCOUNTS='' awsv-sso login pick4 --start-url "$URL" --region us-east-1 < /dev/null
has "it says so" 'lists no account' "$T/out"
unset TMPDIR

# ------------------------------------------------------------- failures
t "login fails" 1 env FAKE_LOGIN_RC=1 awsv-sso login work
rm "$T/live/work"
t "STS refuses after login" 1 awsv-sso login work
has "it says STS refused" 'STS refused' "$T/out"
touch "$T/live/work"
printf '[work]\naws_access_key_id = AKIA000000000000\naws_secret_access_key = x\n' > "$AWS_SHARED_CREDENTIALS_FILE"
t "static keys shadow the profile" 1 awsv-sso login work
has "it names the credentials file" 'credentials holds keys' "$T/out"
has "the keys are left alone" '^aws_access_key_id' "$AWS_SHARED_CREDENTIALS_FILE"
rm "$AWS_SHARED_CREDENTIALS_FILE"

# ------------------------------------------------------------- status
t "status" 0 awsv-sso status
has "status lists work" '^work +111122223333 +Admin +live' "$T/out"
has "status lists work-admin" '^work-admin ' "$T/out"
hasnt "status skips non-SSO profiles" '^other ' "$T/out"
hasnt "status skips vault accounts" '^alpha ' "$T/out"
rm "$T/live/work-admin"
t "status with an expired login" 0 awsv-sso status
has "expired shown" '^work-admin .*expired or never' "$T/out"

# ------------------------------------------------------------- [default] via awsv
sed -i 's#^credential_process = /bin/awsv creds alpha$#credential_process = /bin/awsv creds @work#' "$C"
t "login when [default] is this profile" 0 awsv-sso login work
has "it says [default] uses it" '\[default\] is work' "$T/out"
t "status marks the default" 0 awsv-sso status
has "default star" '^work +\* +111122223333' "$T/out"

# ------------------------------------------------------------- logout
: > "$T/aws.log"
t "logout takes no name" 1 awsv-sso logout work
t "logout" 0 awsv-sso logout
has "aws sso logout called" '^BROWSER= sso logout$' "$T/aws.log"
has "logout says all sessions" 'every SSO login' "$T/out"
has "logout warns about [default]" '\[default\] is work, so plain aws now fails' "$T/out"
sed -i 's#creds @work$#creds alpha#' "$C"
t "logout with a vault [default]" 0 awsv-sso logout
hasnt "no warning then" 'plain aws now fails' "$T/out"

# ------------------------------------------------------------- a fresh machine
rm -f "$C"; touch "$T/live/fresh"
t "login with no config at all" 0 awsv-sso login fresh --start-url "$URL" --account 111122223333 --role R --region us-east-1 --sso-region eu-west-1
has "sso region kept apart" '^sso_region = eu-west-1$' "$C"
has "profile region" '^region = us-east-1$' "$C"
t "status with no live login" 0 awsv-sso status

# ------------------------------------------------------------- Tab completion
tab() {   # words... → the offers, one per line; the last word is being completed
    ( . "$SRC/SSO/awsv-sso-completion.bash"; COMP_WORDS=(awsv-sso "$@"); COMP_CWORD=$#; _awsv_sso
      printf '%s\n' "${COMPREPLY[@]}" ) > "$T/tab"
}
AWS_CONFIG_FILE="$T/block.orig"; printf '\n[profile other2]\n[sso-session corp]\n' >> "$T/block.orig"
tab ""
want="$(awsv-sso --help | awk '/^COMMANDS$/ {f=1; next} f && NF==0 {exit} f {print $2}' | tr '\n' ' ')"
[ "$(grep -v -- '^--' "$T/tab" | tr '\n' ' ')" = "$want" ] && pass=$((pass + 1)) \
    || { fail=$((fail + 1)); echo "FAIL Tab commands differ from help: $(tr '\n' ' ' < "$T/tab") vs $want"; }
tab login ""
has "Tab after login: a profile outside the block" '^other$' "$T/tab"
hasnt "Tab after login: no vault account" '^alpha$' "$T/tab"
hasnt "Tab after login: no default" '^default$' "$T/tab"
tab login work --
has "Tab after the name: options" '^--start-url$' "$T/tab"
tab login work --browser --
hasnt "Tab: an option given once is not offered again" '^--browser$' "$T/tab"
tab login work --region eu-c
has "Tab after --region: regions" '^eu-central-1$' "$T/tab"
tab login work --session ""
has "Tab after --session: sessions" '^corp$' "$T/tab"
tab help ""
has "Tab after help: topics" '^logout$' "$T/tab"
AWS_CONFIG_FILE="$HOME/.aws/config"

# ------------------------------------------------------------- install.sh
P="$T/prefix"
t "install puts awsv-sso next to awsv" 0 env PREFIX="$P" "$SRC/install.sh"
cmp -s "$SRC/SSO/awsv-sso" "$P/awsv-sso" && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL installed awsv-sso differs"; }
CS="$HOME/.local/share/bash-completion/completions/awsv-sso"
cmp -s "$SRC/SSO/awsv-sso-completion.bash" "$CS" && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL completion of awsv-sso not installed"; }
t "uninstall" 0 env PREFIX="$P" "$SRC/install.sh" --uninstall
[ ! -e "$P/awsv-sso" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL awsv-sso left after uninstall"; }
[ ! -e "$CS" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL awsv-sso completion left after uninstall"; }

echo "awsv-sso: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
