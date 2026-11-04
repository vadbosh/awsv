# awsv

awsv keeps your AWS access keys in an encrypted vault instead of the plain text
file `~/.aws/credentials`. `aws`, Terraform and the AWS SDKs work as before. You
type a passphrase when you start work: one for every account, or a separate one
for each account.

[![How a key reaches aws](docs/diagrams/flow.png)](docs/diagrams/flow.png)

## Install

Needs Linux, bash 4+, GnuPG 2.2+ with `pinentry-curses`, AWS CLI v2 and the GNU
core tools.

```bash
git clone https://github.com/vadbosh/awsv.git
cd awsv
./install.sh            # checks what is needed, then installs the command into ~/.local/bin
```

| Installer option | What it does |
|---|---|
| `./install.sh --check` | checks the components, changes nothing |
| `./install.sh --dry-run` | checks, then says what it would write |
| `./install.sh --uninstall` | removes the command and its Tab completion; the vault stays |
| `./install.sh --uninstall --force` | the same while `~/.aws/config` still uses awsv |
| `PREFIX=/opt/bin ./install.sh` | installs into another directory |

The installer also adds Tab completion for bash: in a new terminal, Tab after
awsv offers the commands, the account names and the option values.

## Quick start

You already have keys in `~/.aws/credentials`:

```bash
awsv init --take-default         # choose: one passphrase for all accounts, or one for each
awsv import default --as work    # move the [default] section into the vault, name it work
awsv import client               # move the section [client]
awsv status                      # repeat import until it says "no keys left"
```

You start with no keys:

```bash
awsv init                              # choose the passphrase
awsv add work --region eu-central-1    # type the key id, then the secret (it is not shown)
aws sts get-caller-identity            # works: the key comes from the vault
```

Open a new terminal after `init`: it adds `export GPG_TTY=$(tty)` to `~/.bashrc`,
and gpg needs it to ask for the passphrase.

## Commands

`NAME` is an account name such as `work`. `SECTION` is a section of
`~/.aws/credentials`. `REGION` is an AWS region such as `eu-central-1`.
`awsv help COMMAND` shows the same for one command.

### init — set up the vault, once

```bash
awsv init                    # asks: 1 one passphrase for all accounts, 2 one per account
awsv init --lock shared      # answer in advance: one passphrase for all
awsv init --lock own         # answer in advance: each new account gets its own
awsv init --take-default     # ~/.aws/config has its own [default]: comment it out
```

On a vault that exists, `--lock` changes only what new accounts get.

### add — store a new account

```bash
awsv add work                          # us-east-1, session mode, the lock the vault gives new accounts
awsv add prod --region eu-central-1    # another region
awsv add prod --mode direct            # tools get the key itself, not a session
awsv add prod --lock own               # prod gets a passphrase of its own
awsv add prod --lock shared            # prod takes the shared passphrase
awsv add prod --no-verify              # store without asking AWS if the key works
printf '%s\n%s\n' "$KEY_ID" "$SECRET" | awsv add ci --stdin   # key id and secret from stdin
```

Without `--stdin`, add reads the key from the terminal and does not show the
secret.

### import — move a key out of `~/.aws/credentials`

```bash
awsv import client                   # the section [client], or a commented #[client]
awsv import default --as work        # "default" is reserved: give the account a name
awsv import client --keep            # leave the section in ~/.aws/credentials
awsv import client --region eu-west-1 --mode direct --lock own
awsv import client --no-verify       # do not ask AWS if the key works
```

The section leaves the file; an encrypted copy of the file goes to `backup/`.

### ls — list the accounts

```bash
awsv ls       # * marks [default]; then mode, lock, region, account number
```

### use — switch the [default] account

```bash
awsv use client      # plain "aws ..." now runs as client
awsv use sso         # [default] is a profile kept outside the vault, such as an SSO login
```

`sso` here is any `[profile NAME]` that `~/.aws/config` has outside the awsv
block. It keeps its own way of getting keys, and awsv hands them on to plain
`aws`, Terraform and the SDKs through `aws configure export-credentials`. An
account of the vault with the same name wins.

### exec — run one command as another account

```bash
awsv exec client -- terraform plan    # [default] does not change
aws --profile client s3 ls            # the same for aws alone
```

### set — change the region, the mode or the passphrase

```bash
awsv set client --region us-east-2
awsv set client --mode direct        # tools get the key itself; use it for Terraform
awsv set client --mode session       # tools get a one-hour session (the default)
awsv set client --lock own           # asks the current passphrase, then a new one
awsv set client --lock shared        # back to the shared passphrase
```

### rekey — replace the key of an account

```bash
awsv rekey work                                              # type the new key from IAM
printf '%s\n%s\n' "$KEY_ID" "$SECRET" | awsv rekey work --stdin
awsv rekey work --no-verify                                  # do not ask AWS first
```

Then deactivate the old key in IAM: AWS still accepts it.

### rm — remove an account

```bash
awsv rm old          # asks to confirm
awsv rm old --yes    # no question
```

Then deactivate the key in IAM. Removing it from the vault does not revoke it.

### show — print a stored key

```bash
awsv show work       # key id and secret; runs only in your own terminal
```

### passwd — change a passphrase

```bash
awsv passwd          # the shared passphrase
awsv passwd prod     # the passphrase that opens prod
```

### unlock — open for a time you choose

```bash
awsv unlock              # the passphrase of the [default] account, for 8 hours
awsv unlock 30m          # for 30 minutes
awsv unlock 1h30m        # hours and minutes, up to 24h
awsv unlock prod 30m     # the passphrase that opens prod
awsv unlock all 8h       # every passphrase, one after another
```

In your own terminal unlock is optional: the first `aws` command in a locked
account asks for the passphrase. Cron jobs, scripts and AI assistants cannot
ask. Open the account for them first.

### lock — close now

```bash
awsv lock            # every passphrase, and every cached session
awsv lock prod       # only the passphrase that opens prod
```

### status — check everything

```bash
awsv status          # the vault, each account, what is open, keys left in ~/.aws/credentials
```

### Environment variables

| Variable | Default | What it changes |
|---|---|---|
| `AWSV_HOME` | `~/.local/share/awsv` | where the vault is |
| `AWSV_RUN` | `$XDG_RUNTIME_DIR/awsv`; for root without it, `/run/awsv` | where sessions are cached; empty turns the cache off |
| `AWSV_SESSION_SECONDS` | `3600` | how long a session lasts |
| `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` | `~/.aws/config`, `~/.aws/credentials` | the AWS files awsv reads and writes |
| `NO_COLOR` | not set | set it to turn colour off |

## Where secrets and data are

[![Where awsv keeps secrets and data](docs/diagrams/storage.png)](docs/diagrams/storage.png)

| Path | What it holds | Secret |
|---|---|---|
| `~/.local/share/awsv/keys/NAME.gpg` | the key of one account, encrypted | yes, encrypted |
| `~/.local/share/awsv/gnupg/NAME/` | the GPG key of an account with its own passphrase | yes, passphrase-protected |
| `~/.local/share/awsv/backup/` | `credentials.*.gpg` (old keys, encrypted); plain copies of `config` and `.bashrc` | yes, encrypted |
| `~/.local/share/awsv/meta/NAME` | region, mode, lock, account number | no |
| `~/.local/share/awsv/active`, `lock`, `unlocked-until` | the `[default]` name, the lock for new accounts, the end of the unlock window | no |
| `~/.gnupg/` | the GPG key of the shared passphrase; `gpg-agent.conf` | the key: yes, passphrase-protected |
| `~/.aws/config` | profiles that call `awsv creds NAME`, between two marker lines | no |
| `~/.aws/credentials` | nothing: it stays empty | no |
| `$XDG_RUNTIME_DIR/awsv/NAME` | a one-hour session, plain text, in memory | yes, until it expires |

## What the vault does not protect

While an account is open, any process of your user can read its key, and
nothing asks first. That includes scripts, cron jobs and an AI assistant that
runs as you. Keep an account open only as long as you need it
(`awsv unlock 30m`), and close it when done (`awsv lock`).

When the unlock window ends, awsv stops handing out the cached session, and
`awsv lock` deletes it at once. A process that already got the session can use
it until it expires.

More: [docs/details.md](docs/details.md) — how it works, one passphrase or one per
account, session and direct mode, traps, recovery, error messages, tests.

## License

[MIT](LICENSE)
