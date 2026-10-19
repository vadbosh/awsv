# awsv

**awsv keeps your AWS access keys in an encrypted vault instead of a plain text
file. `aws`, Terraform and the AWS SDKs keep working as before. You type one
passphrase a day.**

Normally an access key sits in `~/.aws/credentials` as plain text. Anything that
reads that file gets the key: a backup, a disk snapshot, a script, an AI
assistant's shell. The key then works until someone revokes it in IAM. Switching
between accounts means commenting sections in and out by hand.

With awsv the key is encrypted on disk, the file `~/.aws/credentials` stays
empty, and one command switches the account.

## How it works

`~/.aws/config` tells the AWS CLI to ask awsv for the key instead of reading a
file. Every `aws` command, every Terraform run and every SDK call goes this way:

```
aws s3 ls
  │  ~/.aws/config: "get the key from: awsv creds work"
  ▼
awsv
  │  opens keys/work.gpg — this needs the passphrase,
  │  which gpg-agent keeps in memory for 8 hours
  │
  ├─ session mode:  trades the key for a one-hour session at AWS STS
  └─ direct mode:   hands out the key itself
  ▼
aws signs the request with what awsv returned
```

Three things follow from this:

- **The key is encrypted on disk.** Without the passphrase the file is
  unreadable bytes.
- **`~/.aws/credentials` stays empty.** That is the correct state, not a fault.
- **When the vault is locked and nobody can type the passphrase, the call
  fails.** A cron job, a script or an AI assistant has no terminal to ask in.
  Access closes by itself instead of staying open.

## Install

```bash
cd awsv              # this repository
./install.sh         # checks gpg, pinentry and AWS CLI v2, then copies awsv to ~/.local/bin
```

`./install.sh --check` only checks and changes nothing. The installer does not
create keys and does not touch `~/.aws`.

## First run

### You already have keys in `~/.aws/credentials`

```bash
awsv init --take-default         # create the vault key; choose a passphrase
awsv import default --as work    # move the [default] section into the vault
awsv import client               # move every other section by its name
awsv status                      # done when it says "no keys left"
```

What each step does:

1. `init` creates a GPG key in `~/.gnupg` and asks you for its passphrase.
   `--take-default` comments out the old `[default]` in `~/.aws/config`,
   because awsv writes its own.
2. `import` reads one section, checks the key against AWS, encrypts it and
   removes the section from `~/.aws/credentials`. A commented-out `#[client]`
   section works too.
3. The section `[default]` needs `--as` with a real name. In awsv, "default" is
   not an account. It is a role: the account that `awsv use NAME` selected.
4. `status` lists what is left. Import every section until it says
   `no keys left`.

Open a new terminal after `init`. It adds `export GPG_TTY=$(tty)` to
`~/.bashrc`, and gpg needs it to ask for the passphrase.

### You start with no keys

```bash
awsv init                              # create the vault key; choose a passphrase
awsv add work --region eu-central-1    # type the key id, then the secret
aws sts get-caller-identity            # shows the account and the user
```

`add` asks for the key in the terminal. The secret does not show on the screen.
AWS checks the key before awsv stores it. The first account becomes `[default]`.

## Everyday use

| You want to | Command |
|---|---|
| see the accounts and which one is `[default]` | `awsv ls` |
| switch the `[default]` account | `awsv use client` |
| run one command as another account | `awsv exec client -- terraform plan` |
| the same for `aws` alone | `aws --profile client s3 ls` |
| add an account | `awsv add NAME --region REGION` |
| remove an account | `awsv rm NAME`, then deactivate the key in IAM |
| replace a key | `awsv rekey NAME`, then deactivate the old key in IAM |
| see a stored key | `awsv show NAME` |
| change the passphrase | `awsv passwd` |
| open the vault now | `awsv unlock` |
| close the vault now | `awsv lock` |
| check that everything is right | `awsv status` |

`NAME`, `SECTION` and `REGION` are yours to fill in: an account name such as
`work`, a section name from `~/.aws/credentials`, an AWS region such as
`eu-central-1`.

`awsv help` prints all commands with examples. `awsv help add` prints one.

## Where things are

```
~/.local/share/awsv/
├── keys/             the keys, one encrypted file per account. The only secrets.
│   ├── work.gpg
│   └── client.gpg
├── meta/             settings of each account: region, mode, account number. Not secret.
│   ├── work
│   └── client
├── active            one word: the name of the [default] account
└── backup/           copies made before each change
```

Outside this directory:

| Path | What it is |
|---|---|
| `~/.gnupg/` | the GPG key that encrypts the vault, locked by your passphrase |
| `~/.gnupg/gpg-agent.conf` | how long the passphrase stays in memory: `max-cache-ttl 28800`, 8 hours |
| `~/.aws/config` | awsv writes a block between `# >>> awsv` and `# <<< awsv <<<`. The rest stays yours |
| `~/.aws/credentials` | empty |
| `$XDG_RUNTIME_DIR/awsv/` | cached one-hour sessions, in memory. A logout or a reboot deletes them |

Each file in `keys/` holds two lines, `AccessKeyId=…` and `SecretAccessKey=…`,
encrypted. The block in `~/.aws/config` has `[default]` and one
`[profile NAME]` per account. Each of them calls `awsv creds NAME`.

## Things that are easy to miss

### Do not put keys into `~/.aws/credentials`

A new key goes into the vault with `awsv add NAME`, which reads it from the
terminal. When some tool writes a key into `~/.aws/credentials` by itself, move
it with `awsv import SECTION`. Until then `awsv status` shows a red `WARNING`.

### An empty `~/.aws/credentials` is correct

The keys are in `keys/`. The AWS CLI gets them through `~/.aws/config`. The empty
file can stay; it does no harm.

### A key left in `~/.aws/credentials` wins

The AWS CLI reads `~/.aws/credentials` first and asks awsv only when the file
has nothing for the profile. A key left there is used instead of the vault, and
nothing tells you. Check it with `aws configure list`: the `access_key` line must
say `custom-process`.

### Removing an account does not revoke its key

`awsv rm NAME` deletes the encrypted file and the profile. The key itself still works
in AWS. Deactivate it in IAM when you no longer need it. The same holds for the
old key after `awsv rekey NAME`.

### Session mode or direct mode

Each account has a mode. `awsv ls` shows it, `awsv set NAME --mode direct` or `--mode session` changes it.

| | session (the default) | direct |
|---|---|---|
| what tools get | a one-hour session, key id starts with `ASIA` | the stored key, starts with `AKIA` |
| a leaked credential | expires within an hour | works until revoked in IAM |
| IAM API calls | refused: a session made without MFA cannot make them | work |
| a run longer than an hour | renews itself, but needs the vault open at that moment | not affected |

Use `direct` for an account that Terraform uses. Terraform often changes IAM
roles and policies, and long runs are common. Use `session` for work by hand.

### Long Terraform runs in session mode

The session renews itself when it expires: the AWS SDK calls awsv again. That
call needs the vault open. The passphrase stays in memory for 8 hours from the
moment you typed it, whether you use it or not. A run that starts in the last
half hour of that window can fail in the middle. Before a long run, either
switch the account to `direct`, or restart the window with
`awsv lock && awsv unlock`.

### When the passphrase is asked

The first `aws` command after the vault locks asks for the passphrase in your
terminal. After that it is quiet for 8 hours.

A command without a terminal cannot ask. It fails with
`Error when retrieving credentials from custom-process`. This happens to cron
jobs, scripts and AI assistants. Run `awsv unlock` in your own terminal, and
they work again.

### After a reboot

Nothing to do. The vault starts locked and the session cache is empty. The
first `aws` command in a terminal asks for the passphrase.

### Seeing a stored key

```bash
awsv show work
```

It prints the key id and the secret. It runs only in a real terminal. In a pipe,
a script or an assistant's shell it refuses, so the secret stays out of logs.
The same without awsv:

```bash
gpg --decrypt ~/.local/share/awsv/keys/work.gpg
```

Never ask an AI assistant to run either of them. Everything it runs stays in its
session history on disk, and the key would have to be revoked.

### Changing the passphrase

```bash
awsv passwd
```

It asks for the current passphrase, then the new one twice. The files in
`keys/` do not change: the passphrase locks the GPG key, not each file.

### A forgotten passphrase

Nothing opens the vault without it. The way back is a new key for every account:

```bash
awsv rm work --yes                                     # for each account; needs no passphrase
gpg --delete-secret-and-public-keys "awsv local vault"  # the old GPG key
awsv init                                              # a new GPG key, a new passphrase
awsv add work --region eu-central-1                    # with a new key from IAM
```

Then deactivate the old keys in IAM. A backup of the GPG key is not needed for
this reason: a new IAM key is the recovery.

### One passphrase for every account

The number of accounts has no limit. Each one is a file in `keys/`, and all of
them open with the same passphrase.

### Each user has their own vault

Everything lives in the home directory of the user who runs awsv. Two users on
one machine have two vaults, two passphrases and two `[default]` accounts. Do
not run awsv through `sudo`: sudo can change `HOME`, and awsv then works with
another user's files.

An AI assistant uses the vault of the user it runs as. When it runs as root and
you work as yourself, it cannot use your vault.

### The backup directory holds your old keys

Each `import` saves a copy of `~/.aws/credentials` to
`backup/credentials.<time>.gpg` before it changes the file. The copy is
encrypted, but it contains the same keys. Delete these files when the migration
is complete and everything works.

## When something goes wrong

| You see | Why | What to do |
|---|---|---|
| `Error when retrieving credentials from custom-process: awsv: cannot open 'NAME'` | the vault is locked, and the command had no terminal | `awsv unlock` in your terminal |
| `STS refused a session for 'NAME'` | AWS does not accept the stored key | check the key in IAM; `awsv rekey NAME` |
| `AccessDenied` on IAM calls, often from Terraform | the account is in session mode | `awsv set NAME --mode direct` |
| a red `WARNING` in `awsv status` | a key is still in `~/.aws/credentials` | `awsv import SECTION` |
| `aws configure list` shows `shared-credentials-file` | a key is still in `~/.aws/credentials`, and it wins over the vault | `awsv import SECTION` |
| `~/.aws/config already defines [default] outside the awsv block` | the config has its own `[default]` | `awsv init --take-default` |
| `show prints a secret, so it runs only in a terminal` | `show` ran in a pipe or a script | run it in your own terminal |
| `no session cache` from `./install.sh` | `XDG_RUNTIME_DIR` is not set | nothing; every call asks STS, a little slower |

## Tests

```bash
./tests/test_awsv.sh             # the commands themselves
./tests/test_docs_commands.sh    # every command the help and this file show you
```

The second test collects every `awsv …` from the help, this file, the status
output and the messages of awsv, and runs each one. A text that looks like a
command but is not one fails the test.

It runs in a temporary home directory with fake keys. Your vault, `~/.aws` and
gpg-agent are not touched. One check calls AWS STS with a fake key;
`AWSV_TEST_NETWORK=0` skips it. A good run ends with `0 failed`.

## Uninstall

```bash
./install.sh --uninstall
```

It refuses while `~/.aws/config` still calls awsv, because every `aws` command
would then fail. Remove the accounts first, or add `--force`. The vault in
`~/.local/share/awsv` stays; delete it yourself.
