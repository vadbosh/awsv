#!/usr/bin/env bash
# Tests for awsv and install.sh.
#
# Everything runs in a throwaway HOME, GNUPGHOME and session directory: the real
# GPG key, ~/.aws and gpg-agent are never touched. The key ids are zeros, AKIA plus
# 12 characters: awsv accepts 12 or more, a real id has 16, and scanners look for
# exactly AKIA plus 16 — so nothing here reads as a leaked key.
# One call to AWS STS with a fake key proves the credentials reach AWS through
# credential_process; AWSV_TEST_NETWORK=0 skips the calls that need the network.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET="${AWSV_TEST_NETWORK:-1}"
T="$(mktemp -d)"
pass=0 fail=0

cleanup() {
    local h
    for h in "$T"/gnupg*; do [ -d "$h" ] && GNUPGHOME="$h" gpgconf --kill gpg-agent 2>/dev/null; done
    for h in "$T"/home/.local/share/awsv/gnupg/* "$T"/vault2/gnupg/*; do
        [ -d "$h" ] && gpgconf --homedir "$h" --kill gpg-agent 2>/dev/null
    done
    rm -rf "$T"
}
trap cleanup EXIT

export HOME="$T/home" GNUPGHOME="$T/gnupg" AWSV_RUN="$T/run" NO_COLOR=1
export AWS_CONFIG_FILE="$HOME/.aws/config" AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/creds.ini"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
# pinentry opens the terminal GPG_TTY names, or a window on DISPLAY: with them set,
# a test that expects "no terminal" drew a passphrase prompt over the terminal
# of whoever ran the tests, and left mouse tracking on in it.
unset GPG_TTY DISPLAY WAYLAND_DISPLAY
unset XDG_DATA_HOME BASH_COMPLETION_USER_DIR
COMP="$HOME/.local/share/bash-completion/completions/awsv"
V="$HOME/.local/share/awsv"
mkdir -p "$HOME/.aws" "$GNUPGHOME" "$T/bin"; chmod 700 "$GNUPGHOME"
cp "$SRC/awsv" "$T/bin/awsv"; chmod 755 "$T/bin/awsv"
# The key of an account with its own passphrase is made by awsv, and gpg asks
# for that passphrase in a terminal. Here gpg takes it from AWSV_TEST_PW instead.
REAL_GPG="$(command -v gpg)"
cat > "$T/bin/gpg" <<EOF
#!/bin/sh
case "\$*" in
    *"--quick-generate-key awsv-"*)
        exec "$REAL_GPG" --batch --pinentry-mode loopback --passphrase "\${AWSV_TEST_PW-}" "\$@" ;;
esac
exec "$REAL_GPG" "\$@"
EOF
chmod 755 "$T/bin/gpg"
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
    if ! grep -qE -- "$2" "$3"; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL $1: /$2/ found in $3"; grep -nE -- "$2" "$3" | sed 's/^/    /'; fi
}
yes_() { if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $*"; fi; }

# A GPG key with no passphrase: everything except the lock can be tested without a terminal.
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "awsv local vault" future-default default never 2>/dev/null

# The layout this machine had: [profile default] plus commented SSO lines in the config,
# an active [default] and a commented #[nexum] in the credentials file.
printf '[profile default]\noutput = json\nregion = us-east-1\n\n#[sso-session thoth]\n#sso_region = us-east-1\n' \
    > "$AWS_CONFIG_FILE"
printf '[default]\naws_access_key_id = AKIA000000000001\naws_secret_access_key = 0000000000\n\n#[nexum]\n#aws_access_key_id = AKIA000000000002\n#aws_secret_access_key = 0000000000\n' \
    > "$AWS_SHARED_CREDENTIALS_FILE"

# ------------------------------------------------------------------ init
t "init" 0 awsv init
has "agent ttl written" '^default-cache-ttl 28800' "$GNUPGHOME/gpg-agent.conf"
has "GPG_TTY in bashrc" 'export GPG_TTY' "$HOME/.bashrc"
t "init twice is harmless" 0 awsv init
yes_ [ "$(grep -c GPG_TTY "$HOME/.bashrc")" = 1 ]   # a second init does not add the line again

# ---------------------------------------------------------------- import
t "default is reserved" 1 awsv import default --no-verify
has "says why" 'reserved' "$T/out"
t "conflict with [profile default] stops the import" 1 awsv import default --as wl --no-verify
has "names the conflict" 'take-default' "$T/out"
has "and the file, as the README quotes it" '~/.aws/config already defines \[default\]' "$T/out"
yes_ [ ! -e "$V/keys/wl.gpg" ]
has "credentials untouched on failure" '^\[default\]' "$AWS_SHARED_CREDENTIALS_FILE"

t "take-default" 0 awsv init --take-default
has "default commented out" '^# awsv: \[profile default\]' "$AWS_CONFIG_FILE"
has "SSO comment left alone" '^#\[sso-session thoth\]' "$AWS_CONFIG_FILE"
hasnt "a blank line is not turned into a comment" '^# awsv: *$' "$AWS_CONFIG_FILE"

t "import active section" 0 awsv import default --as wl --no-verify --mode direct
yes_ [ -s "$V/keys/wl.gpg" ]
hasnt "vault file is not plain text" 'AKIA000000000001' "$V/keys/wl.gpg"
hasnt "section removed from credentials" '^\[default\]' "$AWS_SHARED_CREDENTIALS_FILE"
yes_ ls "$V"/backup/credentials.*.gpg >/dev/null
t "import commented section" 0 awsv import nexum --no-verify --mode direct
hasnt "commented section removed" 'nexum' "$AWS_SHARED_CREDENTIALS_FILE"
t "import missing section" 1 awsv import nosuch --no-verify

# ---------------------------------------------------------------- config
has "[default] calls awsv for wl" 'credential_process = .*/awsv creds wl$' "$AWS_CONFIG_FILE"
has "profile per account" '^\[profile nexum\]' "$AWS_CONFIG_FILE"
yes_ [ "$(grep -c '^\[default\]' "$AWS_CONFIG_FILE")" = 1 ]
t "ls" 0 awsv ls
has "wl is the default" '^wl +\*' "$T/out"

# --------------------------------------------------- the AWS CLI end to end
t "aws sees the vault" 0 aws configure list
has "credentials come from the process" 'custom-process' "$T/out"
has "key of wl" '0001' "$T/out"
t "use nexum" 0 awsv use nexum
t "aws follows use" 0 aws configure list
has "key of nexum" '0002' "$T/out"
if [ "$NET" = 1 ]; then
    t "fake key reaches AWS" 254 aws sts get-caller-identity
    has "AWS rejected exactly that key" 'InvalidClientTokenId' "$T/out"
fi

# ----------------------------------------------------------- creds / exec
t "creds prints JSON" 0 awsv creds nexum
yes_ python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["Version"]==1 and d["AccessKeyId"].endswith("0002")' "$T/out"
env -u NO_COLOR "$T/bin/awsv" creds nexum > "$T/raw" 2>&1
hasnt "no colour in the JSON, even with colour allowed" $'\e' "$T/raw"
t "exec gets the key" 0 awsv exec wl -- sh -c 'printf %s "$AWS_ACCESS_KEY_ID"'
has "exec env" '^AKIA000000000001$' "$T/out"
if [ "$NET" = 1 ]; then
    t "session mode" 0 awsv set nexum --mode session
    t "session refused for a fake key" 1 awsv creds nexum
    has "says STS refused" 'STS refused' "$T/out"
    t "back to direct" 0 awsv set nexum --mode direct
fi

# ------------------------------------------------------------- the checks
t "bad name" 1 awsv add Bad_Name --stdin
t "add default refused" 1 awsv add default --stdin
t "bad region" 1 awsv set nexum --region nowhere
t "bad mode" 1 awsv set nexum --mode open
printf 'NOTAKEY\nsecret\n' > "$T/in"
t "add rejects a malformed key id" 1 sh -c "awsv add other --stdin --no-verify < '$T/in'"
printf 'AKIA000000000003\n0000000000\n' > "$T/in"
t "add from stdin" 0 sh -c "awsv add other --stdin --no-verify --mode direct < '$T/in'"
t "add twice refused" 1 sh -c "awsv add other --stdin --no-verify < '$T/in'"

# show prints a secret, so it must refuse anywhere a log could keep it.
t "show refuses without a terminal" 1 awsv show other
has "and says why" 'only in a terminal' "$T/out"
hasnt "and prints no key" 'AKIA000000000003' "$T/out"
if command -v script >/dev/null 2>&1; then   # script(1) gives the command a real terminal
    script -qc "awsv show other" /dev/null > "$T/out" 2>&1
    has "show prints the key on a terminal" 'aws_access_key_id += AKIA000000000003' "$T/out"
fi
t "unlock: a bad duration" 1 awsv unlock 99x
has "says what is accepted" 'bad duration' "$T/out"
t "unlock: more than 24h refused" 1 awsv unlock 25h
if command -v script >/dev/null 2>&1; then
    script -qc "awsv unlock 30m" /dev/null > "$T/out" 2>&1
    has "unlock 30m opens for 30 minutes" 'unlocked for 30m, until' "$T/out"
    has "the agent keeps it 1800 s" '^max-cache-ttl 1800$' "$GNUPGHOME/gpg-agent.conf"
    has "from the moment it is typed" '^default-cache-ttl 1800$' "$GNUPGHOME/gpg-agent.conf"
    u="$(cat "$V/unlocked-until" 2>/dev/null || echo 0)"; now="$(date +%s)"
    yes_ [ $((u - now)) -gt 1750 ] && yes_ [ $((u - now)) -le 1800 ]   # the end is recorded
    script -qc "awsv unlock 8h" /dev/null > "$T/out" 2>&1
    has "a second unlock replaces the window" '^max-cache-ttl 28800$' "$GNUPGHOME/gpg-agent.conf"
    t "lock" 0 awsv lock
    yes_ [ ! -e "$V/unlocked-until" ]                                   # lock forgets the end
fi
t "passwd needs a terminal" 1 awsv passwd
has "and says so" 'needs a terminal' "$T/out"
t "help" 0 awsv --help
has "help lists init" 'awsv init' "$T/out"
yes_ [ "$(grep -cE '^[a-z]+ — ' "$T/out")" = 15 ]   # every command has its section, and passphrase
t "help passphrase" 0 awsv help passphrase
has "explains both" 'awsv set nexum --lock own' "$T/out"
t "help topic" 0 awsv help import
has "the topic gives its steps" 'awsv import default --as' "$T/out"
hasnt "a topic shows only itself" '^COMMANDS' "$T/out"
t "unknown topic" 1 awsv help nosuch
has "and lists the real ones" 'topics: init add import' "$T/out"

# ----------------------------------------------------------------- status
t "status" 0 awsv status
has "no plain keys" 'no keys left' "$T/out"
has "the [default] account is marked" '^\* nexum +\[default\]' "$T/out"
yes_ [ "$(sed -n '/^ACCOUNTS/,$p' "$T/out" | grep -m1 -E '^(\* |  )[a-z]' | awk '{print $2}')" = nexum ]   # and comes first
has "the default is ACTIVE" '^\* nexum +\[default\] +ACTIVE:(UN)?LOCKED' "$T/out"
has "the others are NOT ACTIVE" '^  wl +NOT ACTIVE:(UN)?LOCKED' "$T/out"
yes_ [ "$(grep -oE 'ACTIVE:(UN)?LOCKED' "$T/out" | sort -u | wc -l)" = 1 ]   # one vault, one state for all
has "every account has its own block" '^  wl +NOT ACTIVE' "$T/out"
has "each block says how to use it" 'aws --profile wl' "$T/out"
printf '[stray]\naws_access_key_id = AKIA000000000004\naws_secret_access_key = x\n' >> "$AWS_SHARED_CREDENTIALS_FILE"
t "status with a stray key" 0 awsv status
has "warns about it" 'WARNING' "$T/out"
has "and names the section" 'still holds a key for: stray' "$T/out"

# ------------------------------------------------- a passphrase of its own
t "set --lock own" 0 awsv set other --lock own
hasnt "no relock_from left" "^relock_from=" "$V/meta/other"
yes_ [ "$(sed -n 's/^lock=//p' "$V/meta/other")" = own ]
yes_ [ -d "$V/gnupg/other" ]
t "the account still gives its key" 0 awsv creds other
has "the same key" 'AKIA000000000003' "$T/out"
t "the shared key cannot open it" 2 gpg --batch --quiet --decrypt "$V/keys/other.gpg"
t "its own GPG home can" 0 gpg --homedir "$V/gnupg/other" --batch --quiet --decrypt "$V/keys/other.gpg"
t "status" 0 awsv status
has "own lock in its block" '^    lock +own passphrase — opens other only' "$T/out"
has "shared lock in the others" '^    lock +shared passphrase — the same for: ' "$T/out"
has "the vault lists it" '^  own +other — each has a passphrase of its own' "$T/out"
has "how to open it" 'awsv unlock other 30m|awsv lock other' "$T/out"
t "ls" 0 awsv ls
has "ls shows the lock" '^other +direct +own ' "$T/out"
t "set --lock own again changes nothing" 0 awsv set other --lock own
has "and says so" 'on the own lock already' "$T/out"
t "back to shared" 0 awsv set other --lock shared
hasnt "none after the way back" "^relock_from=" "$V/meta/other"
yes_ [ ! -e "$V/gnupg/other" ]                        # the unused GPG home is gone
t "readable with the shared key again" 0 gpg --batch --quiet --decrypt "$V/keys/other.gpg"
t "bad lock" 1 awsv set other --lock open
has "says which are valid" "lock is 'shared' or 'own'" "$T/out"

# A relock stopped half-way. relock writes relock_from and the new lock into
# meta/NAME, then moves NAME.gpg.tmp into place, then drops relock_from.
# Stopped before the move, the old file is in place and the old lock must open
# it; stopped after it, the new lock. Never neither.
cp "$V/keys/other.gpg" "$V/keys/other.gpg.tmp"            # sealed, not moved yet
printf 'relock_from=shared\n' >> "$V/meta/other"; sed -i 's/^lock=.*/lock=own/' "$V/meta/other"
t "stopped before the move: ls" 0 awsv ls
has "the old lock" '^other +direct +shared ' "$T/out"
t "and the old lock opens it" 0 awsv creds other
has "the key comes out" 'AKIA000000000003' "$T/out"
rm -f "$V/keys/other.gpg.tmp"                             # moved; relock_from not dropped yet
t "stopped after the move: ls" 0 awsv ls
has "the new lock" '^other +direct +own ' "$T/out"
sed -i '/^relock_from=/d; s/^lock=.*/lock=shared/' "$V/meta/other"   # as it was
printf 'AKIA000000000006\n0000000000\n' > "$T/in"
t "add --lock own" 0 sh -c "awsv add solo --stdin --no-verify --mode direct --lock own < '$T/in'"
has "says how to open it" 'awsv unlock solo' "$T/out"
yes_ [ -d "$V/gnupg/solo" ]
t "rm takes its GPG home too" 0 awsv rm solo --yes
yes_ [ ! -e "$V/gnupg/solo" ]
t "init --lock own" 0 awsv init --lock own
yes_ [ "$(cat "$V/lock")" = own ]
t "a new account gets its own" 0 sh -c "awsv add solo --stdin --no-verify --mode direct < '$T/in'"
yes_ [ "$(sed -n 's/^lock=//p' "$V/meta/solo")" = own ]
t "status says what new accounts get" 0 awsv status
has "own" '^  new +a new account gets a passphrase of its own' "$T/out"
t "init --lock shared" 0 awsv init --lock shared
t "rm solo" 0 awsv rm solo --yes
t "'all' is reserved" 1 sh -c "awsv add all --stdin --no-verify < '$T/in'"
t "unlock: an unknown name" 1 awsv unlock nosuch
has "is read as a duration, and says names work too" 'bad duration .*account name' "$T/out"

# --------------------------------------------------------------------- rm
t "rm wl" 0 awsv rm wl --yes
yes_ [ ! -e "$V/keys/wl.gpg" ]
hasnt "profile gone" '^\[profile wl\]' "$AWS_CONFIG_FILE"
has "nexum still default" 'creds nexum$' "$AWS_CONFIG_FILE"
t "rm nexum" 0 awsv rm nexum --yes
has "no default now" 'no active account' "$AWS_CONFIG_FILE"
t "rm needs a terminal or --yes" 1 awsv rm other < /dev/null

# ------------------------------------------------------- the lock, for real
# A second vault whose key has a passphrase. With the agent forgetting it and no
# terminal to ask on, the credentials must not come out.
export GNUPGHOME="$T/gnupg2" AWSV_HOME="$T/vault2"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase 'pw' \
    --quick-generate-key "awsv local vault" future-default default never 2>/dev/null
printf 'pinentry-program /usr/bin/pinentry-curses\n' > "$GNUPGHOME/gpg-agent.conf"
printf 'AKIA000000000005\n0000000000\n' > "$T/in"
t "add to the locked vault" 0 sh -c "awsv add locked --stdin --no-verify --mode direct < '$T/in'"
gpg --batch --pinentry-mode loopback --passphrase 'pw' --quiet --decrypt "$AWSV_HOME/keys/locked.gpg" >/dev/null 2>&1
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$AWSV_HOME/unlocked-until"   # as awsv unlock 10m would
t "status sees the cached passphrase" 0 awsv status
has "and when it closes" 'UNLOCKED until .*, [0-9]+ min left' "$T/out"
has "unlocked, on its own line" '^  state +UNLOCKED' "$T/out"
t "lock" 0 awsv lock
t "status after lock" 0 awsv status
has "locked, on its own line" '^  state +LOCKED' "$T/out"
t "locked vault gives nothing without a terminal" 1 awsv creds locked
has "and says what to do" 'awsv unlock' "$T/out"
hasnt "no key in the error" 'AKIA000000000005' "$T/out"

# Two locks in one vault: the shared passphrase 'pw', and 'solo' with its own
# 'pw2'. Opening one must leave the other closed, both ways.
printf 'AKIA000000000007\n0000000000\n' > "$T/in"
t "add solo with its own passphrase" 0 env AWSV_TEST_PW=pw2 sh -c "awsv add solo --stdin --no-verify --mode direct --lock own < '$T/in'"
SOLO="$AWSV_HOME/gnupg/solo"
awsv lock >/dev/null 2>&1
gpg --batch --pinentry-mode loopback --passphrase 'pw' --quiet --decrypt "$AWSV_HOME/keys/locked.gpg" >/dev/null 2>&1
t "shared open: its account gives the key" 0 awsv creds locked
t "shared open: solo stays closed" 1 awsv creds solo
has "and names the command for solo" 'awsv unlock solo' "$T/out"
hasnt "no key in the error" 'AKIA000000000007' "$T/out"
t "status" 0 awsv status
has "the shared account is open" '^\* locked +\[default\] +ACTIVE:UNLOCKED' "$T/out"
has "solo is closed" '^  solo +NOT ACTIVE:LOCKED' "$T/out"
has "and says how to open solo" 'open it: awsv unlock solo 30m' "$T/out"
gpg --homedir "$SOLO" --batch --pinentry-mode loopback --passphrase 'pw2' --quiet --decrypt "$AWSV_HOME/keys/solo.gpg" >/dev/null 2>&1
t "solo opened with its own passphrase" 0 awsv creds solo
t "lock solo" 0 awsv lock solo
t "solo is closed again" 1 awsv creds solo
t "the shared account is still open" 0 awsv creds locked
awsv lock locked >/dev/null 2>&1
gpg --homedir "$SOLO" --batch --pinentry-mode loopback --passphrase 'pw2' --quiet --decrypt "$AWSV_HOME/keys/solo.gpg" >/dev/null 2>&1
t "lock the shared one: its account closes" 1 awsv creds locked
t "and solo stays open" 0 awsv creds solo
t "lock everything" 0 awsv lock
t "solo closes too" 1 awsv creds solo
t "passwd NAME needs a terminal" 1 awsv passwd solo

# A first init in a terminal asks the question; answer 2 creates no shared key.
if command -v script >/dev/null 2>&1; then
    export GNUPGHOME="$T/gnupg3" AWSV_HOME="$T/vault3"
    mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    printf '2\n' | script -qc "awsv init" /dev/null > "$T/out" 2>&1
    has "init asks" 'one passphrase for every account' "$T/out"
    has "and takes the answer" 'each new account gets a passphrase of its own' "$T/out"
    yes_ [ "$(cat "$AWSV_HOME/lock" 2>/dev/null)" = own ]
    yes_ [ -z "$(gpg --list-secret-keys --with-colons 2>/dev/null)" ]
    t "status before any account" 0 awsv status
    hasnt "not 'not set up'" 'NOT SET UP' "$T/out"
    t "passwd with no shared key names the way" 1 script -qec "awsv passwd" /dev/null
    has "awsv passwd NAME" 'name one: awsv passwd NAME' "$T/out"
fi
export GNUPGHOME="$T/gnupg" AWSV_HOME="$V"

# ---------------------------------------------- where the session cache goes
# A normal user cannot write to /run. The cache must follow the user, and no
# value of AWSV_RUN may turn into a path under / that rm then deletes.
mkdir -p "$T/xdg"; chmod 700 "$T/xdg"
t "cache under XDG_RUNTIME_DIR" 0 env -u AWSV_RUN XDG_RUNTIME_DIR="$T/xdg" awsv status
has "uses it" "sessions +$T/xdg/awsv" "$T/out"
t "empty AWSV_RUN turns the cache off" 0 env AWSV_RUN= awsv status
has "and says so" 'sessions +not cached' "$T/out"
t "lock with no cache deletes nothing" 0 env AWSV_RUN= awsv lock
t "rm with no cache" 0 env AWSV_RUN= awsv rm other --yes
printf 'AKIA000000000003\n0000000000\n' > "$T/in"
t "add back" 0 sh -c "awsv add other --stdin --no-verify --mode direct < '$T/in'"
t "relative AWSV_RUN refused" 1 env AWSV_RUN=relative awsv status
t "AWSV_RUN=/ refused" 1 env AWSV_RUN=/ awsv status
if [ "$(id -u)" = 0 ]; then
    t "root without XDG_RUNTIME_DIR" 0 env -u AWSV_RUN -u XDG_RUNTIME_DIR awsv status
    has "uses /run/awsv" 'sessions +/run/awsv' "$T/out"
else
    t "a normal user without XDG_RUNTIME_DIR" 0 env -u AWSV_RUN -u XDG_RUNTIME_DIR awsv status
    has "gets no cache, and no error" 'sessions +not cached' "$T/out"
fi


# ------------------------------------------------------------ Tab completion
# The function is called the way bash calls it: COMP_WORDS and COMP_CWORD set,
# COMPREPLY read back. The last argument is the word being completed.
comp() {
    ( . "$SRC/awsv-completion.bash"; COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); _awsv
      printf '%s\n' "${COMPREPLY[@]}" ) | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}
same() {   # name, want, got
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL $1: got '$3', want '$2'"; fi
}
words() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }
names="$(for f in "$V"/keys/*.gpg; do f="${f##*/}"; echo "${f%.gpg}"; done | words)"
n1="${names%% *}"
same "commands: the ones listed under COMMANDS in help" \
    "$(awsv help | sed -n '/^COMMANDS$/,/^$/p' | awk '$1 == "awsv" {print $2}' | words)" "$(comp awsv '')"
same "help topics: the ones awsv knows" \
    "$(awsv help nosuch 2>&1 | sed -n 's/.*topics: //p' | words)" "$(comp awsv help '')"
same "a prefix narrows the commands" "status" "$(comp awsv sta)"
same "account names come from keys/" "$names" "$(comp awsv use '')"
same "and for show, rm, set, lock" "$names" "$(comp awsv show '')"
same "add takes a new name: nothing to offer" "" "$(comp awsv add '')"
same "options after the name" "--lock --mode --region" "$(comp awsv set "$n1" '')"
same "an option given is not offered again" "--lock --region" "$(comp awsv set "$n1" --mode direct '')"
same "--lock values" "own shared" "$(comp awsv set "$n1" --lock '')"
same "--mode values" "direct session" "$(comp awsv add new --mode '')"
same "--region values" "eu-central-1 eu-central-2" "$(comp awsv add new --region eu-cent)"
same "rm offers --yes" "--yes" "$(comp awsv rm "$n1" '')"
same "unlock: names, all and durations" "$(echo "$names all 30m 1h 8h" | words)" "$(comp awsv unlock '')"
same "unlock after a duration: names and all" "$(echo "$names all" | words)" "$(comp awsv unlock 8h '')"
same "unlock after all: durations" "1h 30m 8h" "$(comp awsv unlock all '')"
same "exec after the name: --" "--" "$(comp awsv exec "$n1" '')"
case " $(comp awsv exec "$n1" -- aw) " in
    *" awsv "*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); echo "FAIL exec after --: a command name is not offered" ;;
esac
printf '[client]\naws_access_key_id = AKIA000000000009\n\n#[nexum]\n# x\n[odd] # c\n' > "$T/c.ini"
same "import offers sections, commented ones too" "client nexum odd" \
    "$(AWS_SHARED_CREDENTIALS_FILE="$T/c.ini" comp awsv import '')"
same "no key line reaches the reply" "" \
    "$(AWS_SHARED_CREDENTIALS_FILE="$T/c.ini" comp awsv import AKIA)"
same "import options after the section" "--as --keep --lock --mode --no-verify --region" \
    "$(AWS_SHARED_CREDENTIALS_FILE="$T/c.ini" comp awsv import client '')"
same "no vault: no names, no error" "" "$(AWSV_HOME="$T/none" comp awsv use '')"
# --------------------------------------------------------------- install.sh
P="$T/prefix"
t "install --check" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh" --check
t "install --dry-run writes nothing" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh" --dry-run
yes_ [ ! -e "$P/awsv" ]
yes_ [ ! -e "$COMP" ]
t "install" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh"
yes_ cmp -s "$SRC/awsv" "$P/awsv"
yes_ cmp -s "$SRC/awsv-completion.bash" "$COMP"
t "BASH_COMPLETION_USER_DIR: its first directory" 0 env PATH="$P:$PATH" PREFIX="$P" BASH_COMPLETION_USER_DIR="$T/bcu:$T/bcu2" "$SRC/install.sh"
yes_ cmp -s "$SRC/awsv-completion.bash" "$T/bcu/completions/awsv"
t "install again is a no-op" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh"
has "up to date" 'up to date' "$T/out"
t "uninstall refused while the config uses awsv" 1 env PREFIX="$P" "$SRC/install.sh" --uninstall
awsv use other >/dev/null
t "still refused" 1 env PREFIX="$P" "$SRC/install.sh" --uninstall
t "uninstall --force" 0 env PREFIX="$P" "$SRC/install.sh" --uninstall --force
yes_ [ ! -e "$P/awsv" ]
yes_ [ ! -e "$COMP" ]
yes_ [ -s "$V/keys/other.gpg" ]   # the vault survives the uninstall

echo "awsv: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
