# awsv

**awsv keeps your AWS access keys in an encrypted vault instead of a plain text
file. `aws`, Terraform and the AWS SDKs keep working as before. You type a
passphrase once a day: one for every account, or a separate one for each
account. You choose.**

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
  │  opens keys/work.gpg — this needs the passphrase of work,
  │  which gpg-agent keeps in memory for the time you chose
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
- **When the account is locked and nobody can type the passphrase, the call
  fails.** A cron job, a script or an AI assistant has no terminal to ask in.
  Access closes by itself instead of staying open.

## What the vault does not protect

While an account is open, nothing asks before its key is read. Any process that
runs as your user can get the key with `gpg --decrypt`, with no passphrase and no
question. That includes scripts, cron jobs and an AI assistant that runs as you.
It is the same thing that lets `aws` and Terraform work without prompts.
gpg-agent has no confirmation for each use of such a key.

| The vault protects | The vault does not protect |
|---|---|
| the keys on disk, in backups and in disk snapshots | the key of an open account from processes of your user |
| the keys from other users of the machine | the keys from a root session |
| the keys after `awsv lock`, at the end of the unlock window, after a reboot | a key someone already printed while its account was open |
| an account with its own passphrase, while you work in another one | |

So keep an account open only for as long as you need it:

```bash
awsv unlock 30m      # a short job: it closes by itself in 30 minutes
awsv unlock 8h       # a working day
awsv lock            # finished early: close everything now
```

## One passphrase, or one for each account

`awsv init` asks which one you want. You can change it later for any account.

| | one passphrase (`shared`) | a passphrase per account (`own`) |
|---|---|---|
| what you type in the morning | one passphrase | one passphrase for each account you need |
| `awsv unlock work 30m` opens | every account on the shared passphrase | `work` only |
| `awsv lock work` closes | every account on the shared passphrase | `work` only |
| an assistant or a script working in one account | can read the keys of all of them | can read the key of the open account only |
| choose it when | the accounts are equally sensitive | one account is more sensitive, such as production |

Both can live in one vault. For example, everyday accounts share one
passphrase, and `prod` has its own:

```bash
awsv set prod --lock own        # step 1: the shared passphrase, step 2: a new one for prod
awsv unlock 8h                  # the passphrase of the [default] account, for the day
awsv unlock prod 30m            # prod only, for half an hour
awsv lock prod                  # close prod; the others stay open
awsv passwd prod                # change the passphrase of prod only
awsv set prod --lock shared     # back to the shared passphrase
```

In step 1 gpg asks nothing when the shared passphrase is already in memory. If
`set --lock` stops or fails half-way, the account stays on its old passphrase.

A new account can get its own passphrase at once:

```bash
awsv add prod --region eu-central-1 --lock own    # type the key, then choose the passphrase of prod, twice
awsv import client --lock own                     # the same for a section of ~/.aws/credentials
```

To give every new account its own passphrase, run `awsv init --lock own`.
Accounts already in the vault keep theirs. One account can still take the
shared passphrase: `awsv add NAME --lock shared`.

### Do I unlock every account?

You unlock every passphrase, not every account. One `awsv unlock` opens all
accounts on the shared passphrase; each account with its own passphrase needs
its own `awsv unlock NAME`. To open everything at the start of the day, run
`awsv unlock all 8h`. It asks for each passphrase once: the shared one first,
then each own one.

In your own terminal you can skip `unlock`: the first `aws` command in a locked
account asks for its passphrase. Cron jobs, scripts and AI assistants have no
terminal to ask in. Open the account for them before they start.

`awsv status` shows two lines in each account's block. `lock` says which
passphrase opens the account. `state` says whether it is open now and gives the
exact command that opens or closes it. The state of the shared passphrase is
also in the `VAULT` block.

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
awsv init --take-default         # one passphrase for all, or one for each? then choose it
awsv import default --as work    # move the [default] section into the vault
awsv import client               # move every other section by its name
awsv status                      # done when it says "no keys left"
```

What each step does:

1. `init` asks one question: `1` one passphrase for every account, or `2` a
   passphrase for each account. With `1` it creates a GPG key in `~/.gnupg`
   and asks you to choose the passphrase. With `2` each account gets its key
   and its passphrase when you add or import it. `--take-default` comments out
   the old `[default]` in `~/.aws/config`, because awsv writes its own.
2. `import` reads one section, checks the key against AWS, encrypts it and
   removes the section from `~/.aws/credentials`. A commented-out `#[client]`
   section works too. With `2`, it asks you to choose the passphrase of this
   account first.
3. The section `[default]` needs `--as` with a real name. In awsv, "default" is
   not an account. It is a role: the account that `awsv use NAME` selected.
4. `status` lists what is left. Import every section until it says
   `no keys left`.

Open a new terminal after `init`. It adds `export GPG_TTY=$(tty)` to
`~/.bashrc`, and gpg needs it to ask for the passphrase.

### You start with no keys

```bash
awsv init                              # answer 1 or 2, then choose the passphrase
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
| change the shared passphrase | `awsv passwd` |
| change the passphrase that opens one account | `awsv passwd NAME` |
| give an account its own passphrase | `awsv set NAME --lock own` |
| put it back on the shared passphrase | `awsv set NAME --lock shared` |
| open the [default] account for a while | `awsv unlock 30m`, `awsv unlock 8h` |
| open one account | `awsv unlock NAME 30m` |
| open every account | `awsv unlock all 8h` |
| close one account now | `awsv lock NAME` |
| close everything now | `awsv lock` |
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
├── meta/             settings of each account: region, mode, lock, account number. Not secret.
│   ├── work
│   └── client
├── gnupg/            only for accounts with their own passphrase
│   └── client/       the GPG key of client, its gpg-agent.conf and its unlocked-until
├── active            one word: the name of the [default] account
├── lock              what a new account gets: shared or own
├── backup/           copies made before each change
└── unlocked-until    when the window of the shared passphrase ends; awsv status reads it
```

Outside this directory:

| Path | What it is |
|---|---|
| `~/.gnupg/` | the GPG key of the shared passphrase |
| `~/.gnupg/gpg-agent.conf` | how long the shared passphrase stays in memory; `awsv unlock 30m` sets it |
| `~/.aws/config` | awsv writes a block between `# >>> awsv` and `# <<< awsv <<<`. The rest stays yours |
| `~/.aws/credentials` | empty |
| `$XDG_RUNTIME_DIR/awsv/` | cached one-hour sessions, in memory. A logout or a reboot deletes them |

Each file in `keys/` holds two lines, `AccessKeyId=…` and `SecretAccessKey=…`,
encrypted. The block in `~/.aws/config` has `[default]` and one
`[profile NAME]` per account. Each of them calls `awsv creds NAME`.

An account with its own passphrase has its own GPG directory, so gpg starts a
separate gpg-agent for it. That is why its passphrase is remembered, forgotten
and timed apart from the others.

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
| a run longer than an hour | renews itself, but needs the account open at that moment | not affected |

Use `direct` for an account that Terraform uses. Terraform often changes IAM
roles and policies, and long runs are common. Use `session` for work by hand.

### Long Terraform runs in session mode

The session renews itself when it expires: the AWS SDK calls awsv again. That
call needs the account open. The passphrase stays in memory for the window you
chose, counted from the moment you typed it, whether you use it or not. A run
that outlasts the window fails in the middle. Before a long run, either switch
the account to `direct`, or open a window long enough for it:
`awsv unlock NAME 8h`.

### When the passphrase is asked

The first `aws` command in a locked account asks for the passphrase in your
terminal: the shared one, or the account's own. After that it is quiet for the
window you chose last time with `awsv unlock`; 8 hours if you never chose one.
Each own passphrase has its own window.

A command without a terminal cannot ask. It fails with
`Error when retrieving credentials from custom-process`. This happens to cron
jobs, scripts and AI assistants. The error names the account. Run
`awsv unlock NAME` with that name in your own terminal, and they work again.

### After a reboot

Nothing to do. Every account starts locked and the session cache is empty. The
first `aws` command in a terminal asks for the passphrase.

### Seeing a stored key

```bash
awsv show work
```

It prints the key id and the secret. It runs only in a real terminal. In a pipe,
a script or an assistant's shell it refuses, so the secret stays out of logs.
The same without awsv:

```bash
gpg --decrypt ~/.local/share/awsv/keys/work.gpg                                     # shared passphrase
gpg --homedir ~/.local/share/awsv/gnupg/work --decrypt ~/.local/share/awsv/keys/work.gpg   # own passphrase
```

Never ask an AI assistant to run either of them. Everything it runs stays in its
session history on disk, and the key would have to be revoked.

### Changing the passphrase

```bash
awsv passwd              # the shared passphrase
awsv passwd nexum        # the passphrase that opens nexum: its own, or the shared one
```

It asks for the current passphrase, then the new one twice. The files in
`keys/` do not change: a passphrase locks a GPG key, not each file.

### A forgotten passphrase

Nothing opens an account without its passphrase. The way back is a new key from
IAM for every account that the passphrase opened.

The shared passphrase:

```bash
awsv rm work --yes                                     # for each shared account; needs no passphrase
gpg --delete-secret-and-public-keys "awsv local vault"  # the old GPG key
awsv init                                              # a new GPG key, a new passphrase
awsv add work --region eu-central-1                    # with a new key from IAM
```

The own passphrase of one account; the other accounts are not affected:

```bash
awsv rm nexum --yes                                    # deletes its GPG key too
awsv add nexum --region us-east-2 --lock own           # a new key from IAM, a new passphrase
```

Then deactivate the old keys in IAM. A backup of the GPG key is not needed for
this reason: a new IAM key is the recovery.

### How many accounts

The number of accounts has no limit. Each one is a file in `keys/`.

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
| `Error when retrieving credentials from custom-process: awsv: cannot open 'NAME'` | the account is locked, and the command had no terminal | `awsv unlock NAME` in your terminal |
| `awsv unlock work` opened other accounts too | they are all on the shared passphrase | give the account its own: `awsv set NAME --lock own` |
| `every account has its own passphrase — name one` | `awsv passwd` with no name, and there is no shared passphrase | `awsv passwd NAME` |
| `lock is 'shared' or 'own'` | a typo after `--lock` | `--lock own` or `--lock shared` |
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
