#!/bin/bash
# change-domain.sh — смена домена для инфраструктуры Remnawave, установленной
# скриптом eGamesAPI/remnawave-reverse-proxy (nginx-вариант).

set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/Gemr007/change-domain-panel/main/change-domain.sh"
INSTALL_PATH="/usr/local/bin/changedomen"
SCRIPT_NAME="$(basename "$0")"

# --- Цвета -----------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_MAGENTA='\033[0;35m'
    C_CYAN='\033[0;36m'
    C_WHITE='\033[1;37m'
    C_BRED='\033[1;31m'
    C_BGREEN='\033[1;32m'
    C_BYELLOW='\033[1;33m'
    C_BCYAN='\033[1;36m'
    C_BMAGENTA='\033[1;35m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_WHITE=''; C_BRED=''; C_BGREEN=''
    C_BYELLOW=''; C_BCYAN=''; C_BMAGENTA=''
fi

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

log()  { echo -e "${C_BGREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_BYELLOW}[!]${C_RESET} ${C_YELLOW}$*${C_RESET}"; }
err()  { echo -e "${C_BRED}[x]${C_RESET} ${C_RED}$*${C_RESET}" >&2; exit 1; }
info() { echo -e "${C_BCYAN}[i]${C_RESET} $*"; }
step() { echo -e "\n${C_BMAGENTA}━━━ $* ━━━${C_RESET}"; }

banner() {
    echo -e "${C_BCYAN}"
    cat <<'EOF'
   ___ _                        ___                        _
  / __\ |__   __ _ _ __   __ _ / __\  ___  _ __ ___   ___ | |_
 / /  | '_ \ / _` | '_ \ / _` / /   / _ \| '_ ` _ \ / _ \| __|
/ /___| | | | (_| | | | | (_| \ \__| (_) | | | | | | (_) | |_
\____/|_| |_|\__,_|_| |_|\__, |\____/\___/|_| |_| |_|\___/ \__|
                         |___/
EOF
    echo -e "${C_RESET}${C_DIM}      смена домена панели / подписки / ноды Remnawave${C_RESET}\n"
}

do_install() {
    [[ $EUID -ne 0 ]] && err "Установка требует root (sudo)."
    banner
    log "Скачиваю актуальную версию скрипта в $INSTALL_PATH..."
    curl -fsSL "$RAW_URL" -o "$INSTALL_PATH" || err "Не удалось скачать скрипт с $RAW_URL"
    chmod +x "$INSTALL_PATH"
    echo -e "\n${C_BGREEN}${C_BOLD}✔ Установлено!${C_RESET} Теперь можно запускать из любой директории:"
    echo -e "    ${C_CYAN}sudo changedomen${C_RESET}"
    echo -e "    ${C_CYAN}sudo changedomen --role panel --old ... --new ... --dir ... --cert-method cloudflare --cf-zone-new ...${C_RESET}"
    exit 0
}

[[ "${1:-}" == "--install" ]] && do_install

usage() {
    echo "Usage:"
    echo "  Cloudflare DNS-01 (wildcard):"
    echo "    $SCRIPT_NAME --role panel|sub|node --old OLD_DOMAIN --new NEW_DOMAIN --dir TARGET_DIR \\"
    echo "       --cert-method cloudflare --cf-zone-new NEW_ZONE [--cf-zone-old OLD_ZONE] \\"
    echo "       [--cf-email EMAIL] [--cf-token TOKEN] [--dry-run]"
    echo ""
    echo "  ACME HTTP-01 (без wildcard, требует свободный порт 80 и прямой A-record без Cloudflare-прокси):"
    echo "    $SCRIPT_NAME --role panel|sub|node --old OLD_DOMAIN --new NEW_DOMAIN --dir TARGET_DIR \\"
    echo "       --cert-method acme --acme-email EMAIL [--dry-run]"
    echo ""
    echo "  --cf-zone-new  Имя зоны в Cloudflare для НОВОГО домена (то, что видно в дашборде Cloudflare,"
    echo "                 например example.co.uk — НЕ обязательно последние 2 сегмента домена)."
    echo ""
    echo "  --install      Установить этот скрипт как глобальную команду 'changedomen' в /usr/local/bin."
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
        --install) do_install ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo -e "\033[1;31m[x]\033[0m Run as root (sudo)."; exit 1; }

[[ -n "$ROLE" ]] && banner

# --- Интерактивный опрос, если роль/домены не переданы флагами -----------
if [[ -z "$ROLE" ]]; then
    banner
    step "Шаг 1/4 — где выполняется скрипт"
    echo -e "  ${C_BOLD}1${C_RESET}) Нода ${C_DIM}(Reality/selfsteal — SELF_STEAL_DOMAIN, обычно /opt/remnanode)${C_RESET}"
    echo -e "  ${C_BOLD}2${C_RESET}) Панель + подписка ${C_DIM}(FRONT_END_DOMAIN / SUB_PUBLIC_DOMAIN, обычно /opt/remnawave)${C_RESET}"
    echo ""
    read -rp "$(echo -e "${C_CYAN}Выбери 1 или 2:${C_RESET} ")" SERVER_KIND

    case "$SERVER_KIND" in
        1)
            ROLE="node"
            DEFAULT_DIR="/opt/remnanode"
            ;;
        2)
            echo ""
            echo -e "  ${C_BOLD}1${C_RESET}) Домен панели ${C_DIM}(FRONT_END_DOMAIN)${C_RESET}"
            echo -e "  ${C_BOLD}2${C_RESET}) Домен подписки ${C_DIM}(SUB_PUBLIC_DOMAIN)${C_RESET}"
            echo -e "  ${C_BOLD}3${C_RESET}) Оба ${C_DIM}(панель и подписка на одном сервере)${C_RESET}"
            echo ""
            read -rp "$(echo -e "${C_CYAN}Что меняем — 1, 2 или 3:${C_RESET} ")" PANEL_SUB_KIND
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

    step "Шаг 2/4 — директория и домены"
    read -rp "$(echo -e "${C_CYAN}Директория установки${C_RESET} ${C_DIM}[$DEFAULT_DIR]${C_RESET}: ")" INPUT_DIR
    TARGET_DIR="${INPUT_DIR:-$DEFAULT_DIR}"

    read -rp "$(echo -e "${C_CYAN}Старый домен (который меняем):${C_RESET} ")" OLD_DOMAIN
    read -rp "$(echo -e "${C_CYAN}Новый домен:${C_RESET} ")" NEW_DOMAIN

    step "Шаг 3/4 — метод сертификата"
    echo -e "  ${C_BOLD}1${C_RESET}) Cloudflare DNS-01 ${C_DIM}(нужен API-токен, поддерживает wildcard)${C_RESET}"
    echo -e "  ${C_BOLD}2${C_RESET}) ACME HTTP-01 ${C_DIM}(без токена, БЕЗ wildcard, нужен свободный порт 80${C_RESET}"
    echo -e "     ${C_DIM}и домен должен указывать напрямую на сервер — без Cloudflare-прокси)${C_RESET}"
    echo ""
    read -rp "$(echo -e "${C_CYAN}Выбери 1 или 2:${C_RESET} ")" CERT_METHOD_CHOICE
    case "$CERT_METHOD_CHOICE" in
        1)
            CERT_METHOD="cloudflare"
            echo ""
            echo -e "${C_DIM}Нужно точно указать имя ЗОНЫ в Cloudflare для нового домена.${C_RESET}"
            echo -e "${C_DIM}Это НЕ всегда последние 2 сегмента домена (например для sub.host.example.co.uk${C_RESET}"
            echo -e "${C_DIM}зона в Cloudflare — example.co.uk, а не co.uk). Посмотри в дашборде Cloudflare.${C_RESET}"
            echo ""
            read -rp "$(echo -e "${C_CYAN}Имя зоны в Cloudflare для НОВОГО домена (${C_WHITE}$NEW_DOMAIN${C_CYAN}):${C_RESET} ")" CF_ZONE_NEW
            if [[ "$NEW_DOMAIN" != "$CF_ZONE_NEW" && "$NEW_DOMAIN" != *".$CF_ZONE_NEW" ]]; then
                err "$NEW_DOMAIN не является поддоменом зоны $CF_ZONE_NEW. Проверь написание."
            fi
            ;;
        2)
            CERT_METHOD="acme"
            read -rp "$(echo -e "${C_CYAN}Email для Let's Encrypt:${C_RESET} ")" ACME_EMAIL
            ;;
        *) err "Некорректный выбор." ;;
    esac

    if [[ "$ROLE" == "both" ]]; then
        step "Шаг 4/4 — подтверждение"
        warn "Для варианта 'оба' скрипт применит одну и ту же замену старый->новый"
        warn "во всех файлах, где встречается старый домен панели или подписки."
        warn "Если у панели и подписки РАЗНЫЕ домены — запусти скрипт дважды (по одному разу на каждый)."
        read -rp "$(echo -e "${C_CYAN}Продолжить с этими old/new для обоих сразу? (y/N):${C_RESET} ")" c
        [[ "$c" != "y" && "$c" != "Y" ]] && err "Отменено. Запусти скрипт отдельно для панели и отдельно для подписки."
        ROLE="panel_and_sub"
    fi
fi

[[ -z "$OLD_DOMAIN" || -z "$NEW_DOMAIN" || -z "$TARGET_DIR" ]] && usage
[[ "$ROLE" != "panel" && "$ROLE" != "sub" && "$ROLE" != "node" && "$ROLE" != "panel_and_sub" ]] && err "role must be panel|sub|node"
[[ ! -d "$TARGET_DIR" ]] && err "Directory $TARGET_DIR not found."
[[ "$CERT_METHOD" != "cloudflare" && "$CERT_METHOD" != "acme" ]] && err "Укажи --cert-method cloudflare или acme."

if [[ "$CERT_METHOD" == "cloudflare" ]]; then
    [[ -z "$CF_ZONE_NEW" ]] && err "Не указана зона Cloudflare для нового домена (--cf-zone-new)."
    if [[ "$NEW_DOMAIN" != "$CF_ZONE_NEW" && "$NEW_DOMAIN" != *".$CF_ZONE_NEW" ]]; then
        err "$NEW_DOMAIN не является поддоменом зоны $CF_ZONE_NEW."
    fi
else
    [[ -z "$ACME_EMAIL" ]] && err "Для --cert-method acme нужен --acme-email."
fi

echo -e "${C_DIM}${OLD_DOMAIN} → ${C_RESET}${C_WHITE}${NEW_DOMAIN}${C_RESET}  ${C_DIM}[${ROLE} / ${CERT_METHOD}]${C_RESET}\n"

step "Шаг 1/3 — проверка DNS и выпуск сертификата"
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

# --- Выпуск сертификата ------------------------------------------------
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

# --- Бэкап и замена домена в конфигах ---------------------------------
step "Шаг 2/3 — бэкап и подготовка изменений"
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
        echo -e "   ${C_CYAN}-${C_RESET} $f"
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
    echo -e "\n${C_BOLD}${C_WHITE}── diff для $f ──${C_RESET}"
    diff -u "$f" <(sed "s/${OLD_DOMAIN//./\\.}/${NEW_DOMAIN}/g" "$f") \
        | sed -E "s/^(\+.*)/$(printf '%b' "${C_GREEN}")\1$(printf '%b' "${C_RESET}")/; s/^(-.*)/$(printf '%b' "${C_RED}")\1$(printf '%b' "${C_RESET}")/; s/^(@@.*@@)/$(printf '%b' "${C_CYAN}")\1$(printf '%b' "${C_RESET}")/" \
        || true
done

if $DRY_RUN; then
    log "[dry-run] Изменения не применены."
    exit 0
fi

echo ""
read -rp "$(echo -e "${C_BYELLOW}Применить эти изменения? (y/N):${C_RESET} ")" confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; exit 1; }

for f in "${MATCHED_FILES[@]}"; do
    sed -i "s/${OLD_DOMAIN//./\\.}/${NEW_DOMAIN}/g" "$f"
done
log "Домен заменён в: ${MATCHED_FILES[*]}"

# --- Если docker-compose.yml монтирует сертификаты по старому домену (base или
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

# --- Перезапуск ---------------------------------------------------------
step "Шаг 3/3 — перезапуск контейнеров"
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

echo -e "\n${C_BGREEN}${C_BOLD}✔ Готово!${C_RESET} ${C_WHITE}${NEW_DOMAIN}${C_RESET} настроен."
echo -e "${C_DIM}Проверь:${C_RESET} ${C_CYAN}curl -Iv https://$NEW_DOMAIN${C_RESET}  ${C_DIM}и${C_RESET}  ${C_CYAN}docker compose logs -f${C_RESET}\n"
