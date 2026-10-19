#!/usr/bin/env bash
# Tests for awsv and install.sh.
#
# Everything runs in a throwaway HOME, GNUPGHOME and session directory: the real
# GPG key, ~/.aws and gpg-agent are never touched. The keys are fake.
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
    rm -rf "$T"
}
trap cleanup EXIT

export HOME="$T/home" GNUPGHOME="$T/gnupg" AWSV_RUN="$T/run" NO_COLOR=1
export AWS_CONFIG_FILE="$HOME/.aws/config" AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/creds.ini"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
V="$HOME/.local/share/awsv"
mkdir -p "$HOME/.aws" "$GNUPGHOME" "$T/bin"; chmod 700 "$GNUPGHOME"
cp "$SRC/awsv" "$T/bin/awsv"; chmod 755 "$T/bin/awsv"
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
printf '[default]\naws_access_key_id = AKIAFAKEDEFAULT00001\naws_secret_access_key = fake-secret-default\n\n#[nexum]\n#aws_access_key_id = AKIAFAKENEXUM000002\n#aws_secret_access_key = fake-secret-nexum\n' \
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
yes_ [ ! -e "$V/keys/wl.gpg" ]
has "credentials untouched on failure" '^\[default\]' "$AWS_SHARED_CREDENTIALS_FILE"

t "take-default" 0 awsv init --take-default
has "default commented out" '^# awsv: \[profile default\]' "$AWS_CONFIG_FILE"
has "SSO comment left alone" '^#\[sso-session thoth\]' "$AWS_CONFIG_FILE"

t "import active section" 0 awsv import default --as wl --no-verify --mode direct
yes_ [ -s "$V/keys/wl.gpg" ]
hasnt "vault file is not plain text" 'AKIAFAKEDEFAULT' "$V/keys/wl.gpg"
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
has "exec env" '^AKIAFAKEDEFAULT00001$' "$T/out"
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
printf 'AKIAFAKEOTHER0000003\nfake-secret-other\n' > "$T/in"
t "add from stdin" 0 sh -c "awsv add other --stdin --no-verify --mode direct < '$T/in'"
t "add twice refused" 1 sh -c "awsv add other --stdin --no-verify < '$T/in'"
t "help" 0 awsv --help
has "help lists init" 'awsv init' "$T/out"

# ----------------------------------------------------------------- status
t "status" 0 awsv status
has "no plain keys" 'no keys left' "$T/out"
printf '[stray]\naws_access_key_id = AKIAFAKESTRAY0000004\naws_secret_access_key = x\n' >> "$AWS_SHARED_CREDENTIALS_FILE"
t "status with a stray key" 0 awsv status
has "warns about it" 'WARNING' "$T/out"

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
printf 'AKIAFAKELOCKED000005\nfake-secret-locked\n' > "$T/in"
t "add to the locked vault" 0 sh -c "awsv add locked --stdin --no-verify --mode direct < '$T/in'"
gpg --batch --pinentry-mode loopback --passphrase 'pw' --quiet --decrypt "$AWSV_HOME/keys/locked.gpg" >/dev/null 2>&1
t "status sees the cached passphrase" 0 awsv status
has "unlocked" 'unlocked' "$T/out"
t "lock" 0 awsv lock
t "status after lock" 0 awsv status
has "locked" 'agent: +locked' "$T/out"
t "locked vault gives nothing without a terminal" 1 awsv creds locked
has "and says what to do" 'awsv unlock' "$T/out"
hasnt "no key in the error" 'AKIAFAKELOCKED' "$T/out"
export GNUPGHOME="$T/gnupg" AWSV_HOME="$V"

# --------------------------------------------------------------- install.sh
P="$T/prefix"
t "install --check" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh" --check
t "install --dry-run writes nothing" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh" --dry-run
yes_ [ ! -e "$P/awsv" ]
t "install" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh"
yes_ cmp -s "$SRC/awsv" "$P/awsv"
t "install again is a no-op" 0 env PATH="$P:$PATH" PREFIX="$P" "$SRC/install.sh"
has "up to date" 'up to date' "$T/out"
t "uninstall refused while the config uses awsv" 1 env PREFIX="$P" "$SRC/install.sh" --uninstall
awsv use other >/dev/null
t "still refused" 1 env PREFIX="$P" "$SRC/install.sh" --uninstall
t "uninstall --force" 0 env PREFIX="$P" "$SRC/install.sh" --uninstall --force
yes_ [ ! -e "$P/awsv" ]
yes_ [ -s "$V/keys/other.gpg" ]   # the vault survives the uninstall

echo "awsv: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
