#!/bin/bash
# change-domain.sh — смена домена для инфраструктуры Remnawave, установленной
# скриптом eGamesAPI/remnawave-reverse-proxy (nginx-вариант).
#
# ЧТО ДЕЛАЕТ:
#   1. Проверяет, что новый домен указывает (A-запись) на этот сервер (или на Cloudflare-прокси).
#   2. Выпускает новый сертификат ОДНИМ ИЗ ДВУХ методов на выбор:
#      - Cloudflare DNS-01 (certbot --dns-cloudflare, wildcard *.зона)
#      - ACME HTTP-01 (certbot --standalone на порту 80, без wildcard, без токена,
#        но нужен свободный порт 80 и прямой A-record без Cloudflare-прокси)
#      Оба метода — те же, что CERT_METHOD=1/2 в install_remnawave.sh.
#   3. Делает бэкап .env / docker-compose.yml / nginx.conf в целевой директории.
#   4. Заменяет старую строку домена на новую во всех трёх файлах (grep -rl + sed).
#   5. Показывает diff и просит подтверждения ПЕРЕД применением.
#   6. Перезапускает нужные контейнеры (remnawave-nginx / remnawave / remnanode).
#
# ЧЕГО НЕ ДЕЛАЕТ (проверь руками):
#   - Не трогает Reality serverNames/Host в панели — это меняется через API/UI панели
#     (Config Profile -> Inbound -> Host), см. remnawave.md.
#   - Не удаляет старый сертификат и не чистит старые DNS-записи.
#   - Не проверяет структуру nginx.conf построчно — только замена строки домена.
#   - НЕ угадывает зону Cloudflare по домену (например для curt.vltx.eu.cc последние
#     2 сегмента "eu.cc" НЕ являются зоной) — зону нужно указать явно (--cf-zone-new
#     или в интерактивном вопросе), посмотрев её в дашборде Cloudflare.
#
# ИСПОЛЬЗОВАНИЕ:
#   Интерактивно (спросит, где выполняется — нода или панель+подписка):
#     sudo ./change-domain.sh
#
#   Неинтерактивно (для автоматизации/cron):
#     sudo ./change-domain.sh --role panel|sub|node --old old.domain.com --new new.domain.com \
#          --dir /opt/remnawave [--cf-email you@mail.com] [--cf-token XXXX] [--dry-run]

set -euo pipefail

ROLE=""
OLD_DOMAIN=""
NEW_DOMAIN=""
TARGET_DIR=""
CERT_METHOD=""   # cloudflare | acme
CF_EMAIL=""
CF_TOKEN=""
CF_ZONE_NEW=""
CF_ZONE_OLD=""
ACME_EMAIL=""
DRY_RUN=false

log() { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err() { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

usage() {
    echo "Usage:"
    echo "  Cloudflare DNS-01 (wildcard):"
    echo "    $0 --role panel|sub|node --old OLD_DOMAIN --new NEW_DOMAIN --dir TARGET_DIR \\"
    echo "       --cert-method cloudflare --cf-zone-new NEW_ZONE [--cf-zone-old OLD_ZONE] \\"
    echo "       [--cf-email EMAIL] [--cf-token TOKEN] [--dry-run]"
    echo ""
    echo "  ACME HTTP-01 (без wildcard, требует свободный порт 80 и прямой A-record без Cloudflare-прокси):"
    echo "    $0 --role panel|sub|node --old OLD_DOMAIN --new NEW_DOMAIN --dir TARGET_DIR \\"
    echo "       --cert-method acme --acme-email EMAIL [--dry-run]"
    echo ""
    echo "  --cf-zone-new  Имя зоны в Cloudflare для НОВОГО домена (то, что видно в дашборде Cloudflare,"
    echo "                 например vltx.eu.cc — НЕ обязательно последние 2 сегмента домена)."
    echo ""
    echo "Или запусти без аргументов — скрипт спросит всё интерактивно."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --old) OLD_DOMAIN="$2"; shift 2 ;;
        --new) NEW_DOMAIN="$2"; shift 2 ;;
        --dir) TARGET_DIR="$2"; shift 2 ;;
        --cf-email) CF_EMAIL="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --cf-zone-new) CF_ZONE_NEW="$2"; shift 2 ;;
        --cf-zone-old) CF_ZONE_OLD="$2"; shift 2 ;;
        --cert-method) CERT_METHOD="$2"; shift 2 ;;
        --acme-email) ACME_EMAIL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root (sudo)."; exit 1; }

# --- Интерактивный опрос, если роль/домены не переданы флагами -----------
if [[ -z "$ROLE" ]]; then
    echo ""
    echo "На каком сервере выполняется скрипт?"
    echo ""
    echo "  1. Нода (Reality/selfsteal — SELF_STEAL_DOMAIN, обычно /opt/remnanode)"
    echo "  2. Панель + подписка (FRONT_END_DOMAIN / SUB_PUBLIC_DOMAIN, обычно /opt/remnawave)"
    echo ""
    read -rp "Выбери 1 или 2: " SERVER_KIND

    case "$SERVER_KIND" in
        1)
            ROLE="node"
            DEFAULT_DIR="/opt/remnanode"
            ;;
        2)
            echo ""
            echo "Что меняем?"
            echo "  1. Домен панели (FRONT_END_DOMAIN)"
            echo "  2. Домен подписки (SUB_PUBLIC_DOMAIN)"
            echo "  3. Оба (панель и подписка на одном сервере)"
            echo ""
            read -rp "Выбери 1, 2 или 3: " PANEL_SUB_KIND
            case "$PANEL_SUB_KIND" in
                1) ROLE="panel" ;;
                2) ROLE="sub" ;;
                3) ROLE="both" ;;
                *) err "Некорректный выбор." ;;
            esac
            DEFAULT_DIR="/opt/remnawave"
            ;;
        *) err "Некорректный выбор." ;;
    esac

    read -rp "Директория установки [$DEFAULT_DIR]: " INPUT_DIR
    TARGET_DIR="${INPUT_DIR:-$DEFAULT_DIR}"

    read -rp "Старый домен (который меняем): " OLD_DOMAIN
    read -rp "Новый домен: " NEW_DOMAIN

    echo ""
    echo "Каким методом выпускать сертификат?"
    echo "  1. Cloudflare DNS-01 (нужен API-токен, поддерживает wildcard)"
    echo "  2. ACME HTTP-01 (без токена, но БЕЗ wildcard, нужен свободный порт 80"
    echo "     и домен должен указывать напрямую на сервер — без Cloudflare-прокси)"
    echo ""
    read -rp "Выбери 1 или 2: " CERT_METHOD_CHOICE
    case "$CERT_METHOD_CHOICE" in
        1)
            CERT_METHOD="cloudflare"
            echo ""
            echo "Теперь нужно точно указать имя ЗОНЫ в Cloudflare для нового домена."
            echo "Это НЕ всегда последние 2 сегмента домена (например для curt.vltx.eu.cc"
            echo "зона в Cloudflare — vltx.eu.cc, а не eu.cc). Посмотри в дашборде Cloudflare."
            echo ""
            read -rp "Имя зоны в Cloudflare для НОВОГО домена ($NEW_DOMAIN): " CF_ZONE_NEW
            if [[ "$NEW_DOMAIN" != "$CF_ZONE_NEW" && "$NEW_DOMAIN" != *".$CF_ZONE_NEW" ]]; then
                err "$NEW_DOMAIN не является поддоменом зоны $CF_ZONE_NEW. Проверь написание."
            fi
            ;;
        2)
            CERT_METHOD="acme"
            read -rp "Email для Let's Encrypt (уведомления об истечении): " ACME_EMAIL
            ;;
        *) err "Некорректный выбор." ;;
    esac

    if [[ "$ROLE" == "both" ]]; then
        echo "Для варианта 'оба' скрипт применит одну и ту же замену старый->новый"
        echo "во всех файлах, где встречается старый домен панели или подписки."
        echo "Если у панели и подписки РАЗНЫЕ домены — запусти скрипт дважды (по одному разу на каждый)."
        read -rp "Продолжить с этими old/new для обоих сразу? (y/N): " c
        [[ "$c" != "y" && "$c" != "Y" ]] && err "Отменено. Запусти скрипт отдельно для панели и отдельно для подписки."
        ROLE="panel_and_sub"
    fi
fi

[[ -z "$OLD_DOMAIN" || -z "$NEW_DOMAIN" || -z "$TARGET_DIR" ]] && usage
[[ "$ROLE" != "panel" && "$ROLE" != "sub" && "$ROLE" != "node" && "$ROLE" != "panel_and_sub" ]] && { echo "role must be panel|sub|node"; exit 1; }
[[ ! -d "$TARGET_DIR" ]] && { echo "Directory $TARGET_DIR not found."; exit 1; }
[[ "$CERT_METHOD" != "cloudflare" && "$CERT_METHOD" != "acme" ]] && err "Укажи --cert-method cloudflare или acme."

if [[ "$CERT_METHOD" == "cloudflare" ]]; then
    [[ -z "$CF_ZONE_NEW" ]] && err "Не указана зона Cloudflare для нового домена (--cf-zone-new)."
    if [[ "$NEW_DOMAIN" != "$CF_ZONE_NEW" && "$NEW_DOMAIN" != *".$CF_ZONE_NEW" ]]; then
        err "$NEW_DOMAIN не является поддоменом зоны $CF_ZONE_NEW."
    fi
else
    [[ -z "$ACME_EMAIL" ]] && err "Для --cert-method acme нужен --acme-email."
fi

# --- 1. Проверка DNS нового домена --------------------------------------
log "Проверяю DNS для $NEW_DOMAIN..."
DOMAIN_IP=$(dig +short A "$NEW_DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || true)

if [[ -z "$DOMAIN_IP" ]]; then
    warn "Не удалось разрешить $NEW_DOMAIN в A-запись. Убедись, что DNS уже прописан, иначе ACME (HTTP/DNS-01) не пройдёт."
    read -rp "Продолжить всё равно? (y/N): " c
    [[ "$c" != "y" && "$c" != "Y" ]] && exit 1
elif [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    if [[ "$CERT_METHOD" == "acme" ]]; then
        err "$NEW_DOMAIN -> $DOMAIN_IP, а IP этого сервера -> $SERVER_IP. Для ACME HTTP-01 A-запись ДОЛЖНА указывать напрямую на сервер (без Cloudflare-прокси/оранжевого облака) — иначе challenge не пройдёт. Либо исправь DNS, либо используй --cert-method cloudflare."
    fi
    warn "$NEW_DOMAIN -> $DOMAIN_IP, а IP этого сервера -> $SERVER_IP."
    warn "Это нормально, если домен идёт через Cloudflare-прокси (оранжевое облако) для панели/подписки."
    warn "Для домена selfsteal-ноды (Reality) IP ДОЛЖЕН совпадать напрямую — прокси Cloudflare сломает Reality."
    read -rp "Продолжить? (y/N): " c
    [[ "$c" != "y" && "$c" != "Y" ]] && exit 1
else
    log "OK: $NEW_DOMAIN указывает на этот сервер ($SERVER_IP)."
fi

# --- 2. Выпуск сертификата ------------------------------------------------
if ! command -v certbot >/dev/null 2>&1; then
    err "certbot не установлен. Установи: apt-get install -y certbot python3-certbot-dns-cloudflare"
fi

if [[ "$CERT_METHOD" == "cloudflare" ]]; then
    # --- Cloudflare DNS-01 (wildcard) --------------------------------------
    if [[ -z "$CF_EMAIL" ]]; then read -rp "Cloudflare email: " CF_EMAIL; fi
    if [[ -z "$CF_TOKEN" ]]; then read -rsp "Cloudflare API token/key: " CF_TOKEN; echo; fi

    BASE_DOMAIN="$CF_ZONE_NEW"
    WILDCARD_DOMAIN="*.$BASE_DOMAIN"

    mkdir -p ~/.secrets/certbot
    if [[ "$CF_TOKEN" =~ [A-Z] ]]; then
        # похоже на API Token (Bearer)
        cat > ~/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_TOKEN
EOF
    else
        cat > ~/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_email = $CF_EMAIL
dns_cloudflare_api_key = $CF_TOKEN
EOF
    fi
    chmod 600 ~/.secrets/certbot/cloudflare.ini

    if $DRY_RUN; then
        log "[dry-run] certbot certonly --dns-cloudflare -d $BASE_DOMAIN -d $WILDCARD_DOMAIN"
    else
        log "Выпускаю сертификат для $BASE_DOMAIN + $WILDCARD_DOMAIN через Cloudflare DNS-01..."
        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 60 \
            -d "$BASE_DOMAIN" \
            -d "$WILDCARD_DOMAIN" \
            --email "$CF_EMAIL" \
            --agree-tos \
            --non-interactive \
            --key-type ecdsa \
            --elliptic-curve secp384r1
        [[ -d "/etc/letsencrypt/live/$BASE_DOMAIN" ]] || err "Сертификат не выпустился, смотри лог certbot выше."
        log "Сертификат готов: /etc/letsencrypt/live/$BASE_DOMAIN/"
    fi
else
    # --- ACME HTTP-01 (без wildcard, certbot --standalone на порту 80) -----
    # Такой же метод, как CERT_METHOD=2 в install_remnawave.sh: certonly --standalone,
    # порт 80 должен быть свободен на момент запроса, поэтому временно останавливаем
    # веб-контейнер (remnawave-nginx), если он уже слушает 80/443 в TARGET_DIR.
    BASE_DOMAIN="$NEW_DOMAIN"

    if $DRY_RUN; then
        log "[dry-run] certbot certonly --standalone -d $NEW_DOMAIN --http-01-port 80"
    else
        NGINX_WAS_RUNNING=false
        if [[ -f "$TARGET_DIR/docker-compose.yml" ]]; then
            if (cd "$TARGET_DIR" && docker compose ps --status running 2>/dev/null | grep -q nginx); then
                NGINX_WAS_RUNNING=true
                log "Временно останавливаю remnawave-nginx, чтобы освободить порт 80 для ACME HTTP-01..."
                (cd "$TARGET_DIR" && docker compose stop remnawave-nginx) || warn "Не удалось остановить remnawave-nginx автоматически — если certbot упадёт с 'Address already in use', останови веб-сервер вручную."
            fi
        fi

        ufw allow 80/tcp comment 'HTTP for ACME challenge' >/dev/null 2>&1 || true

        set +e
        certbot certonly \
            --standalone \
            -d "$NEW_DOMAIN" \
            --email "$ACME_EMAIL" \
            --agree-tos \
            --non-interactive \
            --http-01-port 80 \
            --key-type ecdsa \
            --elliptic-curve secp384r1
        CERTBOT_EXIT=$?
        set -e

        ufw delete allow 80/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true

        if $NGINX_WAS_RUNNING; then
            log "Возвращаю remnawave-nginx обратно (сейчас, а не после общего рестарта на шаге 5)..."
            (cd "$TARGET_DIR" && docker compose start remnawave-nginx) || true
        fi

        [[ $CERTBOT_EXIT -ne 0 ]] && err "certbot завершился с ошибкой (код $CERTBOT_EXIT), смотри лог выше."
        [[ -d "/etc/letsencrypt/live/$NEW_DOMAIN" ]] || err "Сертификат не выпустился, смотри лог certbot выше."
        log "Сертификат готов: /etc/letsencrypt/live/$NEW_DOMAIN/"
        warn "ACME HTTP-01 не выпускает wildcard — сертификат только на $NEW_DOMAIN. Если позже добавишь ещё поддомены, для каждого нужен отдельный сертификат (или переходи на Cloudflare DNS-01)."
    fi
fi

# --- 3. Бэкап и замена домена в конфигах ---------------------------------
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${TARGET_DIR}/domain-change-backup-${TS}"
mkdir -p "$BACKUP_DIR"

FILES_TO_PATCH=()
for f in "$TARGET_DIR/.env" "$TARGET_DIR/docker-compose.yml" "$TARGET_DIR/nginx/nginx.conf" "$TARGET_DIR/nginx.conf"; do
    [[ -f "$f" ]] && FILES_TO_PATCH+=("$f")
done

if [[ ${#FILES_TO_PATCH[@]} -eq 0 ]]; then
    err "Не нашёл ни .env, ни docker-compose.yml, ни nginx.conf в $TARGET_DIR — проверь путь."
fi

log "Файлы, где встречается $OLD_DOMAIN:"
MATCHED_FILES=()
for f in "${FILES_TO_PATCH[@]}"; do
    if grep -q "$OLD_DOMAIN" "$f"; then
        echo "   - $f"
        MATCHED_FILES+=("$f")
    fi
done

if [[ ${#MATCHED_FILES[@]} -eq 0 ]]; then
    warn "Строка $OLD_DOMAIN не найдена ни в одном файле. Проверь, что домен указан правильно (без https://, с/без www)."
    exit 1
fi

for f in "${MATCHED_FILES[@]}"; do
    cp "$f" "$BACKUP_DIR/$(basename "$f").bak"
done
log "Бэкап сохранён в $BACKUP_DIR"

for f in "${MATCHED_FILES[@]}"; do
    echo "----- diff для $f -----"
    diff -u "$f" <(sed "s/${OLD_DOMAIN//./\\.}/${NEW_DOMAIN}/g" "$f") || true
done

if $DRY_RUN; then
    log "[dry-run] Изменения не применены."
    exit 0
fi

read -rp "Применить эти изменения? (y/N): " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; exit 1; }

for f in "${MATCHED_FILES[@]}"; do
    sed -i "s/${OLD_DOMAIN//./\\.}/${NEW_DOMAIN}/g" "$f"
done
log "Домен заменён в: ${MATCHED_FILES[*]}"

# --- 4. Если docker-compose.yml монтирует сертификаты по старому домену (base или
#        сам OLD_DOMAIN, в зависимости от того как ставился сертификат) — подставим
#        пути на новый сертификат. Ищем ЛЮБУЮ строку /etc/letsencrypt/live/<что-то>,
#        где <что-то> является префиксом OLD_DOMAIN (т.е. OLD_DOMAIN совпадает с ним
#        или является его поддоменом) — без угадывания по количеству точек.
COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
    OLD_CERT_DIRS=$(grep -oE "/etc/letsencrypt/live/[A-Za-z0-9.*-]+" "$COMPOSE_FILE" | sed 's#/etc/letsencrypt/live/##' | sort -u)
    for cand in $OLD_CERT_DIRS; do
        if [[ "$OLD_DOMAIN" == "$cand" || "$OLD_DOMAIN" == *".$cand" ]]; then
            log "Найден смонтированный сертификат старого домена: $cand -> заменяю на $BASE_DOMAIN"
            sed -i "s#/etc/letsencrypt/live/${cand//./\\.}#/etc/letsencrypt/live/${BASE_DOMAIN}#g" "$COMPOSE_FILE"
            sed -i "s#/etc/nginx/ssl/${cand//./\\.}#/etc/nginx/ssl/${BASE_DOMAIN}#g" "$COMPOSE_FILE"
        fi
    done
fi

# --- 5. Перезапуск ---------------------------------------------------------
cd "$TARGET_DIR"
case "$ROLE" in
    panel)
        log "Перезапускаю remnawave-nginx и remnawave..."
        docker compose down remnawave-nginx remnawave 2>/dev/null || docker compose down
        docker compose up -d
        ;;
    sub)
        log "Перезапускаю remnawave-nginx и remnawave-subscription-page..."
        docker compose down remnawave-nginx remnawave-subscription-page 2>/dev/null || docker compose down
        docker compose up -d
        ;;
    panel_and_sub)
        log "Перезапускаю все контейнеры compose-проекта (панель + подписка на одном сервере)..."
        docker compose down
        docker compose up -d
        ;;
    node)
        log "Перезапускаю ноду (remnanode) и её nginx/caddy..."
        docker compose down
        docker compose up -d
        warn "Не забудь: SELF_STEAL_DOMAIN/serverNames в Config Profile панели меняются ОТДЕЛЬНО, через панель, не этим скриптом."
        ;;
esac

log "Готово. Проверь: curl -Iv https://$NEW_DOMAIN и docker compose logs -f"
