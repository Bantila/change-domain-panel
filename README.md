# change-domain.sh

Смена домена панели, страницы подписки или ноды в инфраструктуре
[Remnawave](https://remna.st) — одной командой, вместе с сертификатом, конфигами,
перезапуском контейнеров и записями в самой панели.

Скрипт закрывает три установки:

- [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) — nginx-вариант;
- он же в caddy-варианте;
- официальный макет [docs.rw](https://remna.st) (панель, reverse-proxy и подписка в разных каталогах).

Перед изменением файлов **всегда** делается бэкап и показывается `diff` с явным
подтверждением (`y/N`). Откат — одной командой.

---

## Содержание

- [Что делает скрипт](#что-делает-скрипт)
- [Чего скрипт НЕ делает](#чего-скрипт-не-делает)
- [Поддерживаемые установки](#поддерживаемые-установки)
- [Требования](#требования)
- [Установка](#установка)
- [Быстрый старт](#быстрый-старт)
- [Флаги](#флаги)
- [Сертификаты](#сертификаты)
- [Смена домена в панели через API](#смена-домена-в-панели-через-api)
- [Секретная cookie в установке eGamesAPI](#секретная-cookie-в-установке-egamesapi)
- [Примеры](#примеры)
- [Как работает замена домена в файлах](#как-работает-замена-домена-в-файлах)
- [Домен ноды и Reality](#домен-ноды-и-reality)
- [Бэкап и откат](#бэкап-и-откат)
- [Известные ограничения](#известные-ограничения)
- [Диагностика проблем](#диагностика-проблем)

---

## Что делает скрипт

1. **Определяет установку** — какой reverse-proxy (nginx или Caddy) и какой макет
   каталогов, по файлам на диске. Угадывать руками ничего не нужно.
2. **Проверяет DNS** нового домена: резолвит A-запись и сравнивает с внешним IP
   сервера. Для ACME HTTP-01 несовпадение — ошибка, для Cloudflare-режима — предупреждение.
3. **Выпускает сертификат** тем способом, который подходит установке: `certbot`
   (Cloudflare DNS-01 или ACME HTTP-01), `acme.sh` (docs.rw) — либо не выпускает
   вовсе, если сертификатом занимается сам Caddy.
4. **Делает бэкап** всех затрагиваемых файлов в `<TARGET_DIR>/domain-change-backup-<timestamp>/`
   с манифестом исходных путей.
5. **Показывает `diff`** по каждому файлу и **спрашивает подтверждение** — без него
   ничего не применяется.
6. **Заменяет домен** в `.env`, `docker-compose.yml`, `nginx.conf` / `Caddyfile`,
   а также правит пути к смонтированным сертификатам старого домена.
7. **Перезапускает** нужные контейнеры (в docs.rw — все затронутые compose-проекты).
8. **Меняет домен в самой панели по API**: Config Profile (`serverNames`, `dest`,
   `host`), Hosts (`address`, `sni`, `host`) и адрес ноды (Nodes → `address`).
9. **Проверяет результат**: HTTP-код нового домена и то, что нужные контейнеры подняты.

## Чего скрипт НЕ делает

- **Не удаляет старый сертификат** и не чистит старые DNS-записи.
- **Не парсит `nginx.conf` / `Caddyfile` построчно** — замена домена идёт заменой
  строки, а не через понимание синтаксиса. Поэтому `diff` перед подтверждением
  обязателен к прочтению.
- **Не угадывает зону Cloudflare** по количеству сегментов домена: `sub.host.example.co.uk`
  ломает наивную эвристику «последние 2 сегмента» (реальная зона — `example.co.uk`).
  Зона указывается явно через `--cf-zone-new`.
- **Не откатывает панель**: `--rollback` возвращает файлы, но записи в Config Profile /
  Hosts / Nodes, если они уже изменены, придётся вернуть вручную.
- **Не ставит acme.sh** сам — если его нет в docs.rw-макете, скрипт останавливается
  с инструкцией, а не тянет установщик из интернета.

## Поддерживаемые установки

| `--layout` | Что это | Где лежат конфиги | Чем выпускается сертификат |
|---|---|---|---|
| `egamesapi` (по умолчанию) | eGamesAPI/remnawave-reverse-proxy, nginx-вариант | `.env`, `docker-compose.yml`, `nginx.conf` в одном `--dir` | `certbot` (Cloudflare DNS-01 или ACME HTTP-01) |
| `egamesapi` + `--proxy caddy` | тот же установщик, caddy-вариант | `.env`, `docker-compose.yml`, `Caddyfile` в одном `--dir` | Caddy сам, скрипт сертификат не трогает |
| `docsrw` | официальный макет docs.rw | панель, reverse-proxy и подписка в **разных** каталогах | `acme.sh` (nginx) или Caddy сам |

`--proxy` определяется автоматически: в `egamesapi` — по наличию `Caddyfile` или
`nginx.conf` в `--dir`, в `docsrw` — по каталогам `<panel-dir>/nginx` и `<panel-dir>/caddy`.
Флагом его задают только когда автоопределение невозможно (например, оба каталога есть).

Роли (`--role`): `panel`, `sub`, `node`, а в интерактивном режиме ещё и «оба»
(панель и подписка сразу, если у них одинаковый домен).

## Требования

- Ubuntu/Debian, `bash`, `docker`, `docker compose` (v2), root-доступ.
- `jq` — обязателен, если скрипт будет менять домен в панели по API:
  ```bash
  apt-get install -y jq
  ```
- Для `--cert-method cloudflare`: `certbot` + плагин DNS-Cloudflare:
  ```bash
  apt-get install -y certbot python3-certbot-dns-cloudflare
  ```
- Для `--cert-method acme`: `certbot` и свободный порт 80 на время выпуска.
- Для макета `docsrw` за nginx: установленный `acme.sh`.
- Утилиты `dig`, `curl`, `awk`, `sed`, `grep` — обычно уже есть.

## Установка

### Вариант A — разовый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gemr007/change-domain-panel/main/change-domain.sh)
```

Флаги дописываются после закрывающей скобки:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gemr007/change-domain-panel/main/change-domain.sh) \
  --role panel --old old.domain.com --new new.domain.com \
  --cert-method cloudflare --cf-zone-new new.domain.com \
  --dir /opt/remnawave --dry-run
```

### Вариант B — установить как команду (рекомендуется)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gemr007/change-domain-panel/main/change-domain.sh) --install
```

Скрипт скачается в `/usr/local/bin/changedomain`; старое имя `changedomen`
остаётся симлинком, чтобы не ломать уже настроенные алиасы и cron.

```bash
changedomain                     # интерактивный режим
changedomain --role panel ...    # с флагами
changedomain --help              # справка
```

Обновление — повторный запуск с `--install`.

### Вариант C — скачать вручную

```bash
curl -o change-domain.sh https://raw.githubusercontent.com/Gemr007/change-domain-panel/main/change-domain.sh
chmod +x change-domain.sh
```

## Быстрый старт

```bash
changedomain
```

Без флагов скрипт идёт по шагам и спрашивает всё сам:

```
На каком сервере выполняется скрипт?
  1. Нода (Reality/selfsteal)
  2. Панель + подписка

Что меняем?
  1. Домен панели
  2. Домен подписки
  3. Оба

Директория установки [/opt/remnawave]:
Старый домен (который меняем):
Новый домен:

Каким методом выпускать сертификат?
  1. Cloudflare DNS-01
  2. ACME HTTP-01

Поменять домен в панели тоже? (y/N):
```

Интерактивный мастер описывает макет `egamesapi`. Для `docsrw` каталогов и
подвариантов слишком много — там роль и пути задаются флагами.

**Всегда начинай с `--dry-run`**: он проходит все проверки, показывает команду
выпуска сертификата и `diff` по файлам, но ничего не применяет.

## Флаги

| Флаг | Обязателен | Описание |
|---|---|---|
| `--role panel\|sub\|node` | да (для неинтерактивного запуска) | Что меняем. |
| `--old OLD_DOMAIN` | да | Текущий домен. |
| `--new NEW_DOMAIN` | да | Новый домен. |
| `--dir TARGET_DIR` | да для `egamesapi` | Каталог установки (`/opt/remnawave` или `/opt/remnanode`). |
| `--cert-method cloudflare\|acme` | да для `egamesapi` + nginx | Метод выпуска сертификата. |
| `--cf-zone-new ZONE` | да, если `--cert-method cloudflare` | Точное имя зоны в Cloudflare для нового домена. |
| `--cf-email EMAIL` | нет | Email аккаунта Cloudflare, иначе спросится. |
| `--cf-token TOKEN` | нет | API Token или Global API Key, иначе спросится скрытым вводом. |
| `--cf-zone-old ZONE` | нет | Зарезервирован, сейчас не используется. |
| `--cf-update-dns` | нет | Обновить A-запись нового домена в Cloudflare тем же токеном. |
| `--acme-email EMAIL` | да, если `--cert-method acme` | Email для Let's Encrypt. |
| `--layout egamesapi\|docsrw` | нет | Макет установки, по умолчанию `egamesapi`. |
| `--proxy nginx\|caddy` | нет | Reverse-proxy, если автоопределение не сработало. |
| `--panel-dir DIR` | нет (`docsrw`) | Каталог панели, по умолчанию `/opt/remnawave`. |
| `--proxy-dir DIR` | нет (`docsrw`) | Каталог reverse-proxy, по умолчанию `<panel-dir>/<proxy>`. |
| `--sub-dir DIR` | нет (`docsrw`) | Каталог subscription-page, если подписка на отдельном сервере. |
| `--panel-url URL` | нет | URL панели без `/api`. Включает смену домена в панели по API. |
| `--panel-token KEY` | нет | API-ключ панели. Не передан — спросится скрытым вводом. |
| `--panel-cookie ИМЯ=ЗНАЧЕНИЕ` | нет | Секретная cookie установки eGamesAPI (см. ниже). |
| `--no-panel` | нет | Не трогать панель вообще, только файлы на диске. |
| `--rollback DIR` | нет | Откатить файлы из каталога бэкапа и перезапустить контейнеры. |
| `--dry-run` | нет | Ничего не применять, только показать. **Запускай первым.** |
| `--install` | нет | Установить скрипт как команду `changedomain`. |
| `-h`, `--help` | нет | Справка по флагам. |

### Как определяется тип ключа Cloudflare

Если в `--cf-token` есть заглавные буквы — это считается API Token (Bearer,
`dns_cloudflare_api_token`). Если заглавных нет — Global API Key
(`dns_cloudflare_email` + `dns_cloudflare_api_key`). Эвристика не железобетонная:
при сомнениях проверь получившийся `~/.secrets/certbot/cloudflare.ini`.

## Сертификаты

### Cloudflare DNS-01 (wildcard)

```bash
changedomain --role panel \
  --old panel.example.com --new new-panel.example.org \
  --cert-method cloudflare --cf-zone-new example.org \
  --dir /opt/remnawave --dry-run
```

- `certbot certonly --dns-cloudflare`, временная TXT-запись через Cloudflare API.
- Выпускает **wildcard** сразу на `<zone>` и `*.<zone>` — хватит на любые поддомены зоны.
- Не требует свободного порта 80 и прямой A-записи: работает и за оранжевым облаком.

**`--cf-zone-new` — это имя зоны из дашборда Cloudflare, а не последние два сегмента домена:**

| Домен | Зона в Cloudflare | «Последние 2 сегмента» |
|---|---|---|
| `sub.example.com` | `example.com` | `example.com` (совпало случайно) |
| `sub.host.example.co.uk` | `example.co.uk` | `co.uk` ❌ публичный суффикс, а не зона |

### ACME HTTP-01

```bash
changedomain --role node \
  --old node.example.com --new new-node.example.org \
  --cert-method acme --acme-email you@example.com \
  --dir /opt/remnanode --dry-run
```

- `certbot certonly --standalone --http-01-port 80`.
- Cloudflare-токен не нужен, **wildcard не выпускается**.
- Требует свободный порт 80: скрипт сам временно гасит `remnawave-nginx` и
  поднимает его обратно, а также открывает и закрывает `ufw allow 80/tcp`.
- Требует **прямую A-запись** без Cloudflare-прокси. Несовпадение IP — ошибка, не предупреждение.

### acme.sh (макет docs.rw за nginx)

- Панель: `acme.sh --issue --standalone` + `--install-cert` в каталог reverse-proxy.
- Подписка: challenge по **TLS-ALPN на 8443**, файлы `subdomain_fullchain.pem` / `subdomain_privkey.key`.
- Порт открывается на время challenge и закрывается после.

### Caddy

Сертификат получает сам Caddy после перезапуска с новым доменом — скрипт в этот
процесс не вмешивается и `--cert-method` в этом случае не нужен.

## Смена домена в панели через API

Домен живёт не только в файлах на диске, но и в базе панели. Если передан
`--panel-url`, скрипт меняет его и там:

| Что | Endpoint | Поля |
|---|---|---|
| Config Profile (Xray-конфиг) | `PATCH /api/config-profiles` | `serverNames`, `dest`, `target`, `host`, `serverName` |
| Hosts | `PATCH /api/hosts` | `address`, `sni`, `host` |
| Ноды | `PATCH /api/nodes` | `address` |

Особенности:

- **Авторизация только по API-ключу.** Ключ создаётся в панели: **Настройки → API Tokens**.
  Передаётся флагом `--panel-token` или вводится скрыто по запросу. Логин и пароль не
  используются — при включённом 2FA они всё равно не дают токен.
- **Правка идёт через `jq`, а не заменой строки по JSON.** Домен меняется только там,
  где он реально домен, и не может задеть `shortId`, ремарку или чужое поле, внутри
  которого оказался подстрокой. У `dest` сохраняется порт: `old:9443` → `new:9443`.
- **Что не найдено — то не меняется.** Если домена нет ни в одном Config Profile
  или адресе ноды, скрипт просто сообщит об этом.
- **Панель обновляется последней**, уже после перезапуска локальных контейнеров.
  Иначе панель раздала бы клиентам новый `serverNames`, пока нода ещё отдаёт старый сертификат.
- Если менялся домен самой панели, скрипт сам переключает адрес API на новый домен.
- `--no-panel` полностью отключает эту часть.

## Секретная cookie в установке eGamesAPI

Установщик eGamesAPI прячет панель за секретной cookie: в его `nginx.conf`
блок `location /` отдаёт `444`, а в `Caddyfile` срабатывает `abort` — **на любой
запрос без неё, включая `/api`**. Снаружи это выглядит не как 401, а как пустой
ответ, поэтому скрипт распознаёт такой случай и говорит об этом прямо.

Откуда он берёт пару `ИМЯ=ЗНАЧЕНИЕ`:

1. Из `--panel-cookie ИМЯ=ЗНАЧЕНИЕ`.
2. Из query в `--panel-url` — можно вставить ту самую ссылку, которую напечатал
   установщик, целиком:
   ```bash
   --panel-url 'https://panel.example.com/auth/login?abcdEFGH=ijklMNOP'
   ```
   Скрипт сам отрежет `?...` и `/auth/login`.
3. Автоматически из конфигов на этом же сервере: `nginx.conf` (`map $http_cookie`)
   или `Caddyfile` (`header +Set-Cookie`). Работает, когда скрипт запущен на сервере панели.

На сервере **ноды** конфигов панели нет — там нужен пункт 1 или 2.

## Примеры

### Домен панели, Cloudflare, и сразу правки в панели

```bash
changedomain --role panel \
  --old panel.old-domain.ru --new panel.new-domain.com \
  --cf-zone-new new-domain.com --cert-method cloudflare \
  --dir /opt/remnawave \
  --panel-url https://panel.old-domain.ru --panel-token 'API_KEY' \
  --dry-run
```

Убрать `--dry-run`, когда `diff` устраивает.

### Домен подписки на ту же зону

```bash
changedomain --role sub \
  --old sub.old-domain.ru --new sub.new-domain.com \
  --cf-zone-new new-domain.com --cert-method cloudflare \
  --dir /opt/remnawave
```

Если зона уже покрыта wildcard-сертификатом с прошлого шага, certbot переиспользует его.

### Домен ноды через ACME, с обновлением Config Profile и Hosts

```bash
changedomain --role node \
  --old old-node.ru --new new-node.io \
  --cert-method acme --acme-email admin@new-node.io \
  --dir /opt/remnanode \
  --panel-url 'https://panel.example.com/auth/login?abcdEFGH=ijklMNOP' \
  --panel-token 'API_KEY'
```

### Официальный макет docs.rw

```bash
# панель за nginx (сертификат через acme.sh)
changedomain --layout docsrw --proxy nginx --role panel \
  --old old.example.com --new new.example.com --acme-email you@example.com

# подписка, bundled в тот же nginx-каталог (TLS-ALPN на 8443)
changedomain --layout docsrw --proxy nginx --role sub \
  --old sub.old.com --new sub.new.com

# нода: домен меняется в панели, локальный конфиг маскировки — если найдётся
changedomain --layout docsrw --role node \
  --old old-node.ru --new new-node.io --panel-url https://panel.example.com
```

## Как работает замена домена в файлах

Скрипт находит файлы, где встречается строка `OLD_DOMAIN`, и заменяет её через `sed`.
Синтаксис конфигов при этом не разбирается: домен — просто строка, встречающаяся в
`server_name`, `FRONT_END_DOMAIN=`, `SUB_PUBLIC_DOMAIN=` и т.д. Это работает
одинаково для nginx, Caddy и `.env`, но означает, что **`diff` надо смотреть**.

Список файлов зависит от макета:

- `egamesapi` + nginx: `.env`, `docker-compose.yml`, `nginx.conf` (или `nginx/nginx.conf`);
- `egamesapi` + caddy: `.env` и `docker-compose.yml` — в `Caddyfile` этой установки
  доменов нет, там плейсхолдеры вида `{$SELF_STEAL_DOMAIN}`, а значения лежат в
  `environment` внутри `docker-compose.yml`;
- `docsrw`: `.env` панели, `nginx.conf`/`Caddyfile` и `docker-compose.yml` из
  каталогов reverse-proxy и подписки.

Отдельным шагом обновляются пути к сертификатам в `docker-compose.yml`: скрипт ищет
смонтированные каталоги вида `/etc/letsencrypt/live/<домен>`, проверяет, что
`OLD_DOMAIN` — это он сам или его поддомен, и переключает монтирование на новый сертификат.

## Домен ноды и Reality

Домен, который клиенты видят в `vless://`-ссылках, хранится в панели, а сертификат
и сайт-заглушка — на самой ноде. Обе половины теперь закрываются одним запуском,
если передан `--panel-url`: скрипт правит `serverNames`, `dest`, Hosts и адрес ноды.

Что остаётся проверить руками:

1. `SELF_STEAL_DOMAIN` в `.env` ноды должен совпадать с `serverNames` дословно.
2. Домен selfsteal-ноды обязан быть **DNS-only** (серое облако). Cloudflare-прокси
   ломает и ACME, и сам Reality.
3. Config Profile после правки нужно запушить на ноду из панели.

Без `--panel-url` скрипт меняет только файлы на ноде и прямо предупреждает, что
панель осталась со старым доменом.

## Бэкап и откат

Перед любыми изменениями создаётся каталог:

```
<TARGET_DIR>/domain-change-backup-<YYYYMMDD-HHMMSS>/
  manifest          # <сохранённое имя> <TAB> <исходный путь>
  .env.bak
  nginx.conf.bak
  docker-compose.yml.bak
```

`manifest` нужен потому, что в макете `docs.rw` одинаково названные файлы приходят
из разных каталогов — по одному basename их не разложить обратно.

Откат:

```bash
changedomain --rollback /opt/remnawave/domain-change-backup-20260801-090700
```

Скрипт вернёт файлы по манифесту и перезапустит контейнеры. Роль и каталог
определяются по пути бэкапа, при необходимости их можно уточнить (`--role`, `--layout`).

⚠️ **Откат не трогает панель.** Если домен уже изменён в Config Profile / Hosts /
Nodes, вернуть его там нужно вручную.

Старые бэкапы скрипт не удаляет — чисти сам.

## Известные ограничения

- Caddy-вариант eGamesAPI поддержан для замены доменов и перезапуска, но выпуск
  сертификатов там полностью на стороне Caddy — если он не смог получить
  сертификат, скрипт об этом не узнает, смотри `docker logs`.
- В макете `docs.rw` у ноды нет штатной структуры каталогов: локальный конфиг
  маскировки ищется по известным местам (`/opt`, `/etc/caddy`, `/etc/nginx`, два
  уровня вглубь). Если найдено несколько кандидатов, скрипт не гадает — правит
  только панель и просит поправить файл вручную.
- `--role both` в интерактивном режиме предполагает, что у панели и подписки
  **одинаковый** старый и новый домен. Для разных доменов запускай скрипт дважды.
- `--cf-zone-old` разобран, но не используется: старый сертификат ищется по
  подстроке пути в `docker-compose.yml`.
- Эвристика распознавания типа ключа Cloudflare (Token vs Global API Key) по
  наличию заглавных букв не железобетонна.

## Диагностика проблем

**Панель отвечает пустотой, домен в Config Profile не меняется**
Установка eGamesAPI закрыта секретной cookie — nginx отдаёт `444`, Caddy обрывает
соединение. Передай cookie: `--panel-cookie ИМЯ=ЗНАЧЕНИЕ` или вставь ссылку с
`?ИМЯ=ЗНАЧЕНИЕ` в `--panel-url`.

**`Панель не приняла API-ключ`**
Ключ отозван, скопирован не полностью, либо в `--panel-url` попал `/api`.
Ключ создаётся в панели: Настройки → API Tokens.

**`certbot: connection refused` / `Address already in use` (ACME HTTP-01)**
Порт 80 занят чем-то, что скрипт не смог остановить (не `remnawave-nginx`, а другой
веб-сервер). Останови вручную:
```bash
docker compose stop <имя-контейнера>
systemctl stop nginx apache2
```

**`Invalid response from ... 404` (ACME HTTP-01)**
DNS ещё не обновился (`dig +short A NEW_DOMAIN`) либо домен идёт через
Cloudflare-прокси — для HTTP-01 нужна прямая (серая) запись.

**`NEW_DOMAIN не является поддоменом зоны CF_ZONE_NEW`**
Проверь точное имя зоны в дашборде Cloudflare — оно может не совпадать с
«последними двумя сегментами» домена.

**Сертификат выпустился, но браузер жалуется на TLS**
Проверь, что `docker-compose.yml` монтирует новый путь к сертификату (в логах шаг
«Найден смонтированный сертификат старого домена…»). Если путь не совпал
автоматически — пропиши вручную и `docker compose up -d`.

**`Не нашёл ни одного конфигурационного файла`**
Неверный `--dir` (или `--panel-dir` / `--proxy-dir` в `docsrw`). Проверь, где
реально лежат `.env` и `docker-compose.yml`.

---

## Дисклеймер

Скрипт меняет продовую конфигурацию: домены, сертификаты, панель, подписку и ноды.
Всегда запускай сначала с `--dry-run`. Автор не несёт ответственности за даунтайм
или потерю данных.
