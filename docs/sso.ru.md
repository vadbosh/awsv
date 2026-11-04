# awsv-sso: вход через SSO

awsv-sso входит в AWS IAM Identity Center (SSO) и выходит из него. Ключей он не
хранит. Вход держит сам AWS CLI в `~/.aws/sso/cache`, пока не истечёт срок
входа, а awsv-sso записывает в `~/.aws/config` только настройки профиля.

`./install.sh` этого репозитория ставит awsv-sso рядом с awsv, вместе с
автодополнением по Tab для bash. Нужен AWS CLI v2. `awsv-sso --help` показывает
все команды, `awsv-sso help login` — одну команду целиком.

## Первый вход

Четыре настройки нужно взять из AWS access portal организации:

| Настройка | Где взять | Параметр |
|---|---|---|
| start URL | адрес портала, `https://….awsapps.com/start` | `--start-url` |
| аккаунт | 12 цифр под названием аккаунта | `--account` |
| роль | permission set под аккаунтом, например `ReadOnly` | `--role` |
| регион | регион, в котором лежат ресурсы | `--region` |

`--region` становится и регионом IAM Identity Center. Если Identity Center
работает в другом регионе, добавьте `--sso-region` с этим регионом.

```bash
awsv-sso login work --start-url https://example.awsapps.com/start \
    --account 111122223333 --role ReadOnly --region us-east-1
```

awsv-sso печатает адрес и код. Откройте адрес в браузере на любом компьютере,
введите код и подтвердите. На машине, где запущен awsv-sso, браузер не нужен.
Потом awsv-sso покажет, от чьего имени вы вошли:

```
  Identity        arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_ReadOnly_…/you@example.com
  Account         111122223333
  Permission set  ReadOnly
```

В `~/.aws/config` появятся такие строки, остальное в файле не меняется:

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

Профиль, написанный вручную или командой `aws configure sso`, работает так же.
awsv-sso берёт из него все настройки, которые там уже есть. Профилю со всеми
четырьмя параметры не нужны, а профилю без роли нужен только `--role`.

## Следующие входы

```bash
awsv-sso login work
```

Вход истекает через срок, который задала организация. Тогда `aws` отвечает
ошибкой про истёкший токен, и та же команда входит снова. `~/.aws/config` при
этом не меняется.

## Параметры login

| Параметр | Что делает | Пример |
|---|---|---|
| `--start-url URL` | адрес портала; нужен при первом входе | `--start-url https://example.awsapps.com/start` |
| `--account ID` | аккаунт; нужен при первом входе | `--account 111122223333` |
| `--role ROLE` | permission set; если указать позже, заменит прежний | `--role Admin` |
| `--region REGION` | регион профиля; он же регион SSO, если не задан `--sso-region` | `--region eu-central-1` |
| `--sso-region REGION` | регион IAM Identity Center, если он другой | `--sso-region us-east-1` |
| `--session S` | имя секции `[sso-session]`; по умолчанию имя профиля | `--session work` |
| `--browser` | открыть браузер на этой машине вместо кода устройства | `--browser` |

Другой permission set в том же аккаунте:

```bash
awsv-sso login work --role Admin
```

Два профиля могут работать на одном входе, по профилю на каждый permission set.
У обоих сессия `work`, поэтому одного входа хватает на оба:

```bash
awsv-sso login work-admin --session work --account 111122223333 --role Admin
aws --profile work s3 ls          # ReadOnly
aws --profile work-admin s3 ls    # Admin, второй вход не нужен
```

## Вход для простого aws и Terraform

awsv-sso не меняет `[default]`, это делает `awsv use NAME`:

```bash
awsv use work               # [default] теперь SSO-профиль work
aws sts get-caller-identity # AWSReservedSSO_ReadOnly_…
awsv use client             # обратно на аккаунт сейфа
```

Terraform тоже берёт ключи из `[default]`, если в его блоке `provider "aws"` не
указан свой `profile`.

## Проверить входы

```bash
awsv-sso status
```

```
NAME             DEFAULT ACCOUNT        ROLE                     LOGIN
work             *       111122223333   ReadOnly                 live
work-admin               111122223333   Admin                    live
```

`*` стоит у профиля, через который работает `[default]`. `expired or never` в
колонке `LOGIN` значит: выполните `awsv-sso login NAME`.

## Выход

```bash
awsv-sso logout
```

Команда запускает `aws sso logout`. **Выйти из одного профиля AWS CLI не
умеет**, поэтому завершаются все входы SSO. `aws sso logout` удаляет токены и
закэшированные ключи всех SSO-профилей из `~/.aws/sso/cache` и
`~/.aws/cli/cache`.

Если `[default]` был SSO-профилем, простой `aws` после этого не работает, и
awsv-sso об этом скажет. Тогда войдите снова или переключите `[default]`:

```bash
awsv-sso login work
awsv use client
```

Чтобы перестать пользоваться SSO-профилем, не завершая вход, достаточно одной
команды `awsv use client`.

## Где лежат данные

| Путь | Что там | Секрет |
|---|---|---|
| `~/.aws/config` | `[sso-session NAME]` и `[profile NAME]`, вне блока awsv | нет |
| `~/.aws/sso/cache/` | вход SSO, его держит AWS CLI | да, пока не истечёт |
| `~/.aws/cli/cache/` | ключи, которые AWS CLI получил по этому входу | да, пока не истекут |
| `~/.local/state/awsv-sso/` | десять последних копий `~/.aws/config` до правки awsv-sso | нет |

Переменные `AWS_CONFIG_FILE` и `AWS_SHARED_CREDENTIALS_FILE` переносят файлы
AWS, `XDG_STATE_HOME` переносит копии, а `NO_COLOR` отключает цвет.

## Ошибки

| Сообщение | Почему | Что делать |
|---|---|---|
| `the first login of 'work' needs --start-url --account --role --region` | у профиля ещё нет настроек SSO | указать перечисленные параметры |
| `'work' is a vault account of awsv` | это имя есть в блоке awsv | выбрать другое имя |
| `[work] of ~/.aws/credentials holds keys` | эти ключи перекрыли бы вход через SSO | удалить эту секцию или перенести ключи в сейф под другим именем: `awsv import SECTION --as NAME` |
| `[profile work] exists and is not an SSO profile` | профиль получает ключи по-другому | указать четыре параметра, чтобы превратить его в SSO-профиль, или выбрать другое имя |
| `logged in, but STS refused the keys` | этой роли нет в этом аккаунте | сверить `--account` и `--role` с порталом |
| `AWS CLI v2 is needed` | `aws --version` показывает v1 | поставить AWS CLI v2 |

## Тесты

```bash
./tests/test_awsv_sso.sh    # aws подменён заглушкой: в AWS ничего не уходит
```

Тест работает во временном домашнем каталоге и ваш `~/.aws` не читает.
