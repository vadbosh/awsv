# awsv-sso: SSO logins

awsv-sso logs in to AWS IAM Identity Center (SSO) and logs out. It stores no
keys. The AWS CLI keeps the login in `~/.aws/sso/cache` until it expires, and
awsv-sso writes only the settings of the profile to `~/.aws/config`.

`./install.sh` of this repository installs it next to awsv, with Tab completion
for bash. It needs AWS CLI v2. `awsv-sso --help` shows every command,
`awsv-sso help login` one command in full.

## The first login

The first login needs two settings: the address of your AWS access portal,
`https://….awsapps.com/start`, and a region. `work` is the name of the new
profile; choose any name.

```bash
awsv-sso login work --start-url https://example.awsapps.com/start --region us-east-1
```

1. awsv-sso prints a URL and a code. Open the URL in a browser on any computer,
   type the code and approve. The machine you run awsv-sso on needs no browser.
2. awsv-sso asks the portal which accounts and roles you have and prints them
   as numbered lists. Type the number of the account, then of the role. When
   there is only one, awsv-sso takes it without asking.

```
Pick the account:
   1  111122223333  Prod
   2  444455556666  Stage
number: 1

Pick the role:
   1  ReadOnly
   2  Admin
number: 1
```

3. awsv-sso shows who you are:

```
  Identity        arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_ReadOnly_…/you@example.com
  Account         111122223333
  Permission set  ReadOnly
```

A script cannot answer the questions: give it `--account` and `--role`. Then
awsv-sso asks nothing:

```bash
awsv-sso login work --start-url https://example.awsapps.com/start --region us-east-1 \
    --account 111122223333 --role ReadOnly
```

`--region` is also taken as the region of IAM Identity Center. When Identity
Center is in another region, add `--sso-region` with that region.

These lines appear in `~/.aws/config`. The rest of the file stays as it was:

```ini
[sso-session work]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile work]
sso_session = work
sso_account_id = 111122223333
sso_role_name = ReadOnly
region = us-east-1
```

A profile written by hand, or by `aws configure sso`, works the same way.
awsv-sso takes from it every setting it already has and asks only for the rest.

## Every next login

```bash
awsv-sso login work
```

The login expires after the time your organization set. Then `aws` answers
with an error about an expired token, and the same command logs in again.
`~/.aws/config` does not change.

## Options of login

| Option | What it does | Example |
|---|---|---|
| `--start-url URL` | the portal address; needed at the first login | `--start-url https://example.awsapps.com/start` |
| `--account ID` | the account; without it, pick from the list of the portal | `--account 111122223333` |
| `--role ROLE` | the permission set; without it, pick from the list; given later, it replaces the old one | `--role Admin` |
| `--region REGION` | the region of the profile, and of SSO unless `--sso-region` is given | `--region eu-central-1` |
| `--sso-region REGION` | the region of IAM Identity Center, when it differs | `--sso-region us-east-1` |
| `--session S` | the name of the `[sso-session]` section; default is the profile name | `--session work` |
| `--browser` | open a browser on this machine instead of the device code | `--browser` |

Another permission set in the same account:

```bash
awsv-sso login work --role Admin
```

Two profiles can share one login, one profile per permission set. Both use the
session `work`, so one login serves both:

```bash
awsv-sso login work-admin --session work --account 111122223333 --role Admin
aws --profile work s3 ls          # ReadOnly
aws --profile work-admin s3 ls    # Admin, no second login
```

## Use the login in plain aws and Terraform

awsv-sso does not change `[default]`; `awsv use NAME` changes it:

```bash
awsv use work               # [default] is now the SSO profile work
aws sts get-caller-identity # AWSReservedSSO_ReadOnly_…
awsv use client             # back to an account of the vault
```

Terraform follows `[default]` too, unless its `provider "aws"` block names a
`profile` of its own.

## Check the logins

```bash
awsv-sso status
```

```
NAME             DEFAULT ACCOUNT        ROLE                     LOGIN
work             *       111122223333   ReadOnly                 live, token until 15:02 UTC (renews itself)
work-admin               111122223333   Admin                    live, token until 15:02 UTC (renews itself)
```

`*` marks the profile `[default]` uses. `expired or never` in `LOGIN` means:
run `awsv-sso login NAME`.

The time in `LOGIN` is when the current access token ends. The AWS CLI renews
the token by itself while the portal session lasts. When that session ends,
the next login is needed. Its length is set in IAM Identity Center, and the
AWS CLI does not keep it, so awsv-sso cannot show it.

## Log out

```bash
awsv-sso logout
```

It runs `aws sso logout`. **The AWS CLI cannot log out of one profile**, so
every SSO login ends. `aws sso logout` deletes the tokens and cached keys of all
SSO profiles from `~/.aws/sso/cache` and `~/.aws/cli/cache`.

When `[default]` was an SSO profile, plain `aws` fails after that. awsv-sso
says so. Then either log in again or switch `[default]`:

```bash
awsv-sso login work
awsv use client
```

To stop using an SSO profile and keep its login, `awsv use client` alone is
enough.

## Where data is

| Path | What it holds | Secret |
|---|---|---|
| `~/.aws/config` | `[sso-session NAME]` and `[profile NAME]`, outside the awsv block | no |
| `~/.aws/sso/cache/` | the SSO login, kept by the AWS CLI | yes, until it expires |
| `~/.aws/cli/cache/` | keys the AWS CLI got with that login | yes, until they expire |
| `~/.local/state/awsv-sso/` | the last ten copies of `~/.aws/config` before awsv-sso changed it | no |

The variables `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` move the AWS
files, `XDG_STATE_HOME` moves the copies, and `NO_COLOR` turns colour off.

## Errors

| Message | Why | What to do |
|---|---|---|
| `the first login of 'work' needs --start-url --region` | the profile has no SSO settings yet | give the options it lists |
| `no account picked — give it with --account VALUE` | no number was typed, or there is no terminal | type a number from the list, or give `--account` |
| `'work' is a vault account of awsv` | the awsv block has this name | pick another name |
| `[work] of ~/.aws/credentials holds keys` | those keys would win over the SSO login | remove that section, or move the keys into the vault under another name: `awsv import SECTION --as NAME` |
| `[profile work] exists and is not an SSO profile` | the profile gets its keys another way | give `--start-url` and `--region` to convert it, or pick another name |
| `logged in, but STS refused the keys` | the role is not in that account | check `--account` and `--role` in the portal |
| `AWS CLI v2 is needed` | `aws --version` is v1 | install AWS CLI v2 |

## Tests

```bash
./tests/test_awsv_sso.sh    # a stand-in replaces aws: nothing reaches AWS
```

The test runs in a temporary home directory and never reads your `~/.aws`.
