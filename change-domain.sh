#!/bin/bash
# change-domain.sh — смена домена для инфраструктуры Remnawave, установленной
# скриптом eGamesAPI/remnawave-reverse-proxy (nginx-вариант).

set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/Gemr007/change-domain-panel/main/change-domain.sh"
INSTALL_PATH="/usr/local/bin/changedomain"
# Раньше команда ставилась как 'changedomen' (опечатка). Оставляем симлинк,
# чтобы не сломать уже установленные вызовы и cron/алиасы у пользователей.
LEGACY_INSTALL_PATH="/usr/local/bin/changedomen"
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
PANEL_URL=""       # https://panel.example.com, без /api
PANEL_TOKEN=""     # API-ключ панели (Настройки -> API Tokens)
PANEL_COOKIE=""    # секретная cookie eGamesAPI вида ИМЯ=ЗНАЧЕНИЕ
SKIP_PANEL=false   # --no-panel: не трогать Panel API вообще
CF_UPDATE_DNS=false
ROLLBACK_DIR=""
# egamesapi — исходный макет: .env + docker-compose.yml + nginx.conf в одном --dir,
#             сертификат через certbot. Значение по умолчанию, поведение не меняется.
# docsrw     — официальный макет docs.rw: панель, reverse-proxy и subscription-page
#             в РАЗНЫХ каталогах, сертификат через acme.sh (nginx) или сам Caddy.
LAYOUT="egamesapi"
PROXY_KIND=""      # nginx | caddy (только для docsrw)
PANEL_DIR=""
PROXY_DIR=""
SUB_DIR=""

log()  { echo -e "${C_BGREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_BYELLOW}[!]${C_RESET} ${C_YELLOW}$*${C_RESET}"; }
err()  { echo -e "${C_BRED}[x]${C_RESET} ${C_RED}$*${C_RESET}" >&2; exit 1; }
info() { echo -e "${C_BCYAN}[i]${C_RESET} $*"; }
step() { echo -e "\n${C_BMAGENTA}━━━ $* ━━━${C_RESET}"; }

banner() {
    echo -e "${C_BCYAN}"
    cat <<'EOF'
   _____ _                          _____                        _       
  / ____| |                        |  __ \                      (_)      
 | |    | |__   __ _ _ __   __ _  ___| |  | | ___  _ __ ___   __ _ _ _ __  
 | |    | '_ \ / _` | '_ \ / _` |/ _ \ |  | |/ _ \| '_ ` _ \ / _` | | '_ \ 
 | |____| | | | (_| | | | | (_| |  __/ |__| | (_) | | | | | | (_| | | | | |
  \_____|_| |_|\__,_|_| |_|\__, |\___|_____/ \___/|_| |_| |_|\__,_|_|_| |_|
                            __/ |                                           
                           |___/                                            
EOF
    echo -e "${C_RESET}${C_DIM}      смена домена панели / подписки / ноды Remnawave${C_RESET}\n"
}

need_jq() {
    command -v jq >/dev/null 2>&1 || err "Нужен jq: apt-get install -y jq"
}

# --- Имя сервиса reverse-proxy в макете egamesapi ----------------------------
# nginx-вариант всегда remnawave-nginx. У caddy-варианта имя СЕРВИСА разное:
# комбинированная установка (панель+нода) объявляет remnawave-caddy, отдельная
# нода — caddy (с container_name caddy-remnawave). Читаем из реального файла,
# а не угадываем.
egamesapi_proxy_service() {
    if [[ "$PROXY_KIND" != "caddy" ]]; then
        echo "remnawave-nginx"
        return 0
    fi
    if grep -qE '^[[:space:]]*remnawave-caddy:[[:space:]]*$' "$TARGET_DIR/docker-compose.yml" 2>/dev/null; then
        echo "remnawave-caddy"
    else
        echo "caddy"
    fi
}

# Определяет reverse-proxy для макета egamesapi по содержимому --dir.
egamesapi_detect_proxy() {
    if [[ -n "$PROXY_KIND" ]]; then
        log "Reverse-proxy: $PROXY_KIND (задан флагом --proxy)"
        return 0
    fi

    if [[ -f "$TARGET_DIR/Caddyfile" ]]; then
        PROXY_KIND="caddy"
    elif [[ -f "$TARGET_DIR/nginx.conf" || -f "$TARGET_DIR/nginx/nginx.conf" ]]; then
        PROXY_KIND="nginx"
    else
        warn "В $TARGET_DIR нет ни Caddyfile, ни nginx.conf — определить reverse-proxy по файлам нельзя."
        if [[ -t 0 ]]; then
            read -rp "$(echo -e "${C_CYAN}Reverse-proxy — nginx или caddy:${C_RESET} ")" PROXY_KIND
        fi
        # Без терминала спрашивать некого: берём документированный default, чтобы
        # не ломать неинтерактивные вызовы, которые работали до появления --proxy.
        if [[ -z "$PROXY_KIND" ]]; then
            PROXY_KIND="nginx"
            warn "Беру значение по умолчанию --proxy nginx. Если это caddy-установка, укажи --proxy caddy явно."
        fi
    fi

    [[ "$PROXY_KIND" != "nginx" && "$PROXY_KIND" != "caddy" ]] && err "--proxy должен быть nginx или caddy."
    log "Reverse-proxy: $PROXY_KIND"
    return 0
}

# --- Перезапуск контейнеров по роли -----------------------------------------
# Вынесено в функцию, потому что этим же занимается --rollback.
restart_stack() {
    cd "$TARGET_DIR"
    local proxy_svc
    proxy_svc="$(egamesapi_proxy_service)"
    case "$ROLE" in
        panel)
            log "Перезапускаю $proxy_svc и remnawave..."
            docker compose down "$proxy_svc" remnawave 2>/dev/null || docker compose down
            docker compose up -d
            ;;
        sub)
            log "Перезапускаю $proxy_svc и remnawave-subscription-page..."
            docker compose down "$proxy_svc" remnawave-subscription-page 2>/dev/null || docker compose down
            docker compose up -d
            ;;
        panel_and_sub)
            log "Перезапускаю все контейнеры compose-проекта (панель + подписка на одном сервере)..."
            docker compose down
            docker compose up -d
            ;;
        node)
            # Полный down/up без имён сервисов — работает и для nginx, и для caddy.
            log "Перезапускаю ноду (remnanode) и её nginx/caddy..."
            docker compose down
            docker compose up -d
            ;;
    esac
}

expected_services() {
    if [[ "$LAYOUT" == "docsrw" ]]; then
        docsrw_expected_containers
        return 0
    fi
    local proxy_svc
    proxy_svc="$(egamesapi_proxy_service)"
    case "$ROLE" in
        panel)         echo "remnawave $proxy_svc" ;;
        sub)           echo "remnawave-subscription-page $proxy_svc" ;;
        panel_and_sub) echo "remnawave remnawave-subscription-page $proxy_svc" ;;
        node)          echo "remnanode $proxy_svc" ;;
    esac
}

# --- Автопроверка после применения ------------------------------------------
verify_deployment() {
    step "Проверка результата"

    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 15 "https://$NEW_DOMAIN" 2>/dev/null || echo "000")
    if [[ "$code" == "000" ]]; then
        echo -e "  ${C_BRED}FAIL${C_RESET} https://$NEW_DOMAIN — ответа нет (проверь DNS, сертификат, фаервол)"
    else
        echo -e "  ${C_BGREEN}OK${C_RESET}   https://$NEW_DOMAIN — HTTP $code"
    fi

    local running svc
    if [[ "$LAYOUT" == "docsrw" ]]; then
        # В docs.rw контейнеры разложены по нескольким compose-проектам, поэтому
        # смотрим весь хост, а не один каталог.
        running=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    else
        running=$(cd "$TARGET_DIR" && docker compose ps --status running 2>/dev/null || true)
    fi
    for svc in $(expected_services); do
        if grep -qE "(^|[[:space:]/])${svc}([[:space:]]|$)" <<< "$running"; then
            echo -e "  ${C_BGREEN}OK${C_RESET}   контейнер $svc запущен"
        else
            echo -e "  ${C_BRED}FAIL${C_RESET} контейнер $svc не запущен"
        fi
    done
}

# --- Panel API ---------------------------------------------------------------
panel_api() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-s --max-time 25 -X "$method" "${PANEL_URL%/}${path}"
                -H "Content-Type: application/json"
                -H "X-Remnawave-Client-Type: browser")
    [[ -n "$PANEL_TOKEN" ]] && args+=(-H "Authorization: Bearer $PANEL_TOKEN")
    [[ -n "$PANEL_COOKIE" ]] && args+=(-H "Cookie: $PANEL_COOKIE")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" || true
}

# eGamesAPI прячет панель за секретной cookie: в его nginx.conf `location /`
# отдаёт 444, а в Caddyfile блок @unauthorized делает abort — на ЛЮБОЙ запрос без
# неё, включая /api. Наружу это выглядит не как 401, а как пустой ответ curl.
# Пара ИМЯ=ЗНАЧЕНИЕ лежит в самом конфиге прокси, поэтому на сервере панели её
# можно достать оттуда, а не спрашивать у человека.
panel_cookie_files() {
    echo "$TARGET_DIR/nginx.conf"
    echo "$TARGET_DIR/nginx/nginx.conf"
    echo "$TARGET_DIR/Caddyfile"
    if [[ -n "$PROXY_DIR" ]]; then
        echo "$PROXY_DIR/nginx.conf"
        echo "$PROXY_DIR/Caddyfile"
    fi
}

resolve_panel_cookie() {
    [[ -n "$PANEL_COOKIE" ]] && return 0

    # Ссылку вида https://panel.example.com/auth/login?abc=def установщик печатает
    # в конце установки — её можно вставить в --panel-url как есть.
    if [[ "$PANEL_URL" == *"?"* ]]; then
        PANEL_COOKIE="${PANEL_URL#*\?}"
        PANEL_URL="${PANEL_URL%%\?*}"
        PANEL_URL="${PANEL_URL%/auth/login}"
        log "Cookie авторизации взята из --panel-url, URL панели: $PANEL_URL"
        return 0
    fi

    local f pair
    while read -r f; do
        [[ -f "$f" ]] || continue
        # nginx:  map $http_cookie $auth_cookie { "~*ИМЯ=ЗНАЧЕНИЕ" 1; }
        pair=$(grep -oE '"~\*[A-Za-z0-9_]+=[A-Za-z0-9_]+"' "$f" | head -n1 | tr -d '"' | sed 's/^~\*//' || true)
        # caddy:  header +Set-Cookie "ИМЯ=ЗНАЧЕНИЕ; Path=/; ..."
        [[ -z "$pair" ]] && pair=$(grep -oE 'Set-Cookie "[A-Za-z0-9_]+=[A-Za-z0-9_]+' "$f" | head -n1 | sed 's/^Set-Cookie "//' || true)
        if [[ -n "$pair" ]]; then
            PANEL_COOKIE="$pair"
            log "Секретная cookie панели найдена в $f."
            return 0
        fi
    done < <(panel_cookie_files)
    return 1
}

# Авторизация только по API-ключу панели (в панели: Настройки -> API Tokens).
# Логин/пароль не используем: у суперадмина обычно включён 2FA, и /api/auth/login
# в этом случае возвращает не токен, а запрос кода — интерактива для этого здесь нет.
# API-ключ шлётся тем же заголовком Authorization: Bearer, что и сессионный токен.
panel_auth() {
    if [[ -z "$PANEL_TOKEN" ]]; then
        if [[ ! -t 0 ]]; then
            warn "Нет --panel-token и нет терминала, чтобы спросить API-ключ панели."
            return 1
        fi
        read -rsp "$(echo -e "${C_CYAN}API-ключ панели (Настройки -> API Tokens):${C_RESET} ")" PANEL_TOKEN; echo
    fi
    [[ -z "$PANEL_TOKEN" ]] && { warn "API-ключ панели не задан."; return 1; }

    resolve_panel_cookie || true

    # Один дешёвый GET, чтобы неверный ключ падал с понятным сообщением здесь,
    # а не выглядел как «панель сломалась» на первом же PATCH.
    local resp
    resp=$(panel_api GET /api/config-profiles)
    if [[ -z "$resp" ]]; then
        warn "Панель ${PANEL_URL%/} не ответила вообще (пустой ответ)."
        warn "Так ведёт себя защита eGamesAPI: без секретной cookie nginx отдаёт 444, а Caddy — abort,"
        warn "и это касается всех путей, включая /api."
        warn "Передай её флагом --panel-cookie ИМЯ=ЗНАЧЕНИЕ, либо вставь в --panel-url ссылку целиком:"
        warn "  --panel-url 'https://panel.example.com/auth/login?ИМЯ=ЗНАЧЕНИЕ'"
        warn "Пара лежит на сервере панели: nginx.conf (map \$http_cookie) или Caddyfile (header +Set-Cookie)."
        return 1
    fi
    if ! echo "$resp" | jq -e '.response' >/dev/null 2>&1; then
        warn "Панель ${PANEL_URL%/} не приняла API-ключ: $resp"
        warn "Проверь: ключ не отозван, --panel-url указан без /api, ключ создан в Настройки -> API Tokens."
        return 1
    fi
    log "API-ключ принят."
    return 0
}

# Меняет домен внутри Xray-конфига каждого Config Profile.
# Правка идёт через jq walk по дереву, а не sed по сериализованному JSON:
# так домен заменяется только там, где он реально является доменом
# (serverNames / host / serverName), и не может задеть shortId или ремарку,
# внутри которой он оказался подстрокой.
panel_patch_config_profiles() {
    local list uuid full config new resp changed=0
    list=$(panel_api GET /api/config-profiles)
    if ! echo "$list" | jq -e '.response.configProfiles' >/dev/null 2>&1; then
        warn "Не удалось получить список Config Profile: ${list:-<пустой ответ>}"
        return 1
    fi

    while read -r uuid; do
        [[ -z "$uuid" ]] && continue
        full=$(panel_api GET "/api/config-profiles/$uuid")
        config=$(echo "$full" | jq -c '.response.config' 2>/dev/null || true)
        if [[ -z "$config" || "$config" == "null" ]]; then
            warn "Config Profile $uuid: пустой config, пропускаю."
            continue
        fi

        new=$(echo "$config" | jq -c --arg old "$OLD_DOMAIN" --arg new "$NEW_DOMAIN" '
            # dest/target у Reality — это "домен:порт" либо голый домен, поэтому
            # порт надо сохранить, а не затереть заменой строки целиком.
            def fixdest:
                if . == $old then $new
                elif startswith($old + ":") then $new + .[($old | length):]
                else . end;
            walk(
                if type == "object" then
                      (if (.serverNames? | type) == "array"
                          then .serverNames |= map(if . == $old then $new else . end)
                          else . end)
                    | (if (.host? // "") == $old then .host = $new else . end)
                    | (if (.serverName? // "") == $old then .serverName = $new else . end)
                    | (if (.dest? | type) == "string" then .dest |= fixdest else . end)
                    | (if (.target? | type) == "string" then .target |= fixdest else . end)
                else . end
            )')

        [[ "$new" == "$config" ]] && continue

        # PATCH перезаписывает config целиком, поэтому отправляем весь конфиг.
        resp=$(panel_api PATCH /api/config-profiles \
            "$(jq -n --arg uuid "$uuid" --argjson config "$new" '{uuid: $uuid, config: $config}')")
        if echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            log "Config Profile $uuid обновлён."
            changed=$((changed + 1))
        else
            warn "Не удалось обновить Config Profile $uuid: ${resp:-<пустой ответ>}"
            return 1
        fi
    done < <(echo "$list" | jq -r '.response.configProfiles[]?.uuid')

    if [[ $changed -eq 0 ]]; then
        info "В Config Profile домен $OLD_DOMAIN не встретился — менять нечего."
    fi
    return 0
}

panel_patch_hosts() {
    local host body resp changed=0
    local list
    list=$(panel_api GET /api/hosts)
    if ! echo "$list" | jq -e '.response' >/dev/null 2>&1; then
        warn "Не удалось получить список Hosts: ${list:-<пустой ответ>}"
        return 1
    fi

    while read -r host; do
        [[ -z "$host" ]] && continue
        body=$(echo "$host" | jq -c --arg old "$OLD_DOMAIN" --arg new "$NEW_DOMAIN" '
            {uuid: .uuid}
            + (if .address == $old then {address: $new} else {} end)
            + (if .sni     == $old then {sni: $new}     else {} end)
            + (if .host    == $old then {host: $new}    else {} end)')
        resp=$(panel_api PATCH /api/hosts "$body")
        if echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            log "Host $(echo "$host" | jq -r '.remark // .uuid') обновлён."
            changed=$((changed + 1))
        else
            warn "Не удалось обновить Host $(echo "$host" | jq -r '.uuid'): ${resp:-<пустой ответ>}"
            return 1
        fi
    done < <(echo "$list" | jq -c --arg old "$OLD_DOMAIN" \
        '.response[]? | select(.address == $old or .sni == $old or .host == $old)')

    if [[ $changed -eq 0 ]]; then
        info "В Hosts домен $OLD_DOMAIN не встретился — менять нечего."
    fi
    return 0
}

# Адрес самой ноды в панели (Nodes -> address). Часто там IP, а не домен —
# тогда менять нечего, поэтому фильтруем по точному совпадению, как и в Hosts.
panel_patch_nodes() {
    local node resp changed=0 list
    list=$(panel_api GET /api/nodes)
    if ! echo "$list" | jq -e '.response' >/dev/null 2>&1; then
        warn "Не удалось получить список нод: ${list:-<пустой ответ>}"
        return 1
    fi

    while read -r node; do
        [[ -z "$node" ]] && continue
        resp=$(panel_api PATCH /api/nodes \
            "$(echo "$node" | jq -c --arg new "$NEW_DOMAIN" '{uuid: .uuid, address: $new}')")
        if echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            log "Нода $(echo "$node" | jq -r '.name // .uuid') переведена на $NEW_DOMAIN."
            changed=$((changed + 1))
        else
            warn "Не удалось обновить ноду $(echo "$node" | jq -r '.uuid'): ${resp:-<пустой ответ>}"
            return 1
        fi
    done < <(echo "$list" | jq -c --arg old "$OLD_DOMAIN" '.response[]? | select(.address == $old)')

    if [[ $changed -eq 0 ]]; then
        info "В адресах нод домен $OLD_DOMAIN не встретился — менять нечего."
    fi
    return 0
}

sync_panel() {
    step "Обновление домена в панели Remnawave ($PANEL_URL)"
    need_jq
    panel_auth || return 1
    local rc=0
    panel_patch_config_profiles || rc=1
    panel_patch_hosts || rc=1
    panel_patch_nodes || rc=1
    return $rc
}

# --- Cloudflare: обновление A-записи тем же токеном, что и для DNS-01 --------
cf_update_dns() {
    need_jq
    local hdr=()
    if [[ "$CF_TOKEN" =~ [A-Z] ]]; then
        hdr=(-H "Authorization: Bearer $CF_TOKEN")
    else
        hdr=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_TOKEN")
    fi

    local zone_id rec rec_id rec_proxied target body resp
    zone_id=$(curl -s --max-time 20 "${hdr[@]}" \
        "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NEW" | jq -r '.result[0].id // empty')
    if [[ -z "$zone_id" ]]; then
        warn "Зона $CF_ZONE_NEW в Cloudflare не найдена — DNS не тронут."
        return 1
    fi

    read -rp "$(echo -e "${C_CYAN}IP для A-записи $NEW_DOMAIN${C_RESET} ${C_DIM}[${SERVER_IP:-не определён}]${C_RESET}: ")" target
    target="${target:-${SERVER_IP:-}}"
    if [[ -z "$target" ]]; then
        warn "IP не указан — DNS не тронут."
        return 1
    fi

    rec=$(curl -s --max-time 20 "${hdr[@]}" \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$NEW_DOMAIN")
    rec_id=$(echo "$rec" | jq -r '.result[0].id // empty')
    # Флаг proxied у существующей записи сохраняем: для selfsteal-домена ноды
    # оранжевое облако ломает Reality, а для панели оно может быть нужно.
    rec_proxied=$(echo "$rec" | jq -r '.result[0].proxied // false')

    body=$(jq -n --arg name "$NEW_DOMAIN" --arg ip "$target" --argjson proxied "$rec_proxied" \
        '{type: "A", name: $name, content: $ip, ttl: 60, proxied: $proxied}')

    if [[ -n "$rec_id" ]]; then
        resp=$(curl -s --max-time 20 -X PUT "${hdr[@]}" -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" -d "$body")
    else
        resp=$(curl -s --max-time 20 -X POST "${hdr[@]}" -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" -d "$body")
    fi

    if echo "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
        log "A-запись $NEW_DOMAIN -> $target обновлена в Cloudflare (proxied=$rec_proxied)."
        return 0
    fi
    warn "Cloudflare не принял изменение DNS: ${resp:-<пустой ответ>}"
    return 1
}

# =============================================================================
# Макет docs.rw
# =============================================================================

# Определяет, какой reverse-proxy стоит перед панелью, по наличию каталога.
docsrw_detect_proxy() {
    [[ -n "$PROXY_KIND" ]] && return 0

    local has_nginx=false has_caddy=false
    [[ -f "$PANEL_DIR/nginx/docker-compose.yml" ]] && has_nginx=true
    [[ -f "$PANEL_DIR/caddy/docker-compose.yml" ]] && has_caddy=true

    if $has_nginx && ! $has_caddy; then
        PROXY_KIND="nginx"
    elif $has_caddy && ! $has_nginx; then
        PROXY_KIND="caddy"
    else
        if $has_nginx && $has_caddy; then
            warn "В $PANEL_DIR есть и nginx/, и caddy/ — какой из них реально обслуживает домен?"
        else
            warn "Не нашёл ни $PANEL_DIR/nginx/docker-compose.yml, ни $PANEL_DIR/caddy/docker-compose.yml."
        fi
        read -rp "$(echo -e "${C_CYAN}Reverse-proxy — nginx или caddy:${C_RESET} ")" PROXY_KIND
    fi

    [[ "$PROXY_KIND" != "nginx" && "$PROXY_KIND" != "caddy" ]] && err "--proxy должен быть nginx или caddy."
    log "Reverse-proxy: $PROXY_KIND"
    return 0
}

docsrw_resolve_dirs() {
    PANEL_DIR="${PANEL_DIR:-/opt/remnawave}"

    # Для ноды официального макета не существует, каталоги панели ей не нужны.
    if [[ "$ROLE" != "node" ]]; then
        docsrw_detect_proxy
        PROXY_DIR="${PROXY_DIR:-$PANEL_DIR/$PROXY_KIND}"
        SUB_DIR="${SUB_DIR:-$PROXY_DIR}"
        [[ -d "$PANEL_DIR" ]] || err "Каталог панели $PANEL_DIR не найден (--panel-dir)."
        [[ -d "$PROXY_DIR" ]] || err "Каталог reverse-proxy $PROXY_DIR не найден (--proxy-dir)."
    fi

    # TARGET_DIR в docsrw используется только как место для каталога бэкапа.
    TARGET_DIR="${TARGET_DIR:-$PANEL_DIR}"
    [[ -d "$TARGET_DIR" ]] || err "Каталог $TARGET_DIR не найден."
}

# Каталоги compose-проектов, которые надо перезапустить, без повторов.
docsrw_restart_dirs() {
    case "$ROLE" in
        panel)         echo "$PANEL_DIR"; echo "$PROXY_DIR" ;;
        sub)           echo "$PANEL_DIR"; echo "$SUB_DIR"; echo "$PROXY_DIR" ;;
        panel_and_sub) echo "$PANEL_DIR"; echo "$PROXY_DIR"; echo "$SUB_DIR" ;;
        node)
            # У ноды каталог известен только если что-то реально нашлось на диске.
            local f
            for f in "${MATCHED_FILES[@]:-}"; do
                [[ -n "$f" ]] && echo "$(dirname "$f")"
            done
            ;;
    esac | awk 'NF && !seen[$0]++'
}

docsrw_restart() {
    local d
    while read -r d; do
        [[ -f "$d/docker-compose.yml" ]] || continue
        log "Перезапускаю compose-проект в $d..."
        (cd "$d" && docker compose down && docker compose up -d)
    done < <(docsrw_restart_dirs)
}

docsrw_expected_containers() {
    local proxy_ctr
    [[ "$PROXY_KIND" == "caddy" ]] && proxy_ctr="caddy" || proxy_ctr="remnawave-nginx"
    case "$ROLE" in
        panel)         echo "remnawave $proxy_ctr" ;;
        sub)           echo "remnawave-subscription-page $proxy_ctr" ;;
        panel_and_sub) echo "remnawave remnawave-subscription-page $proxy_ctr" ;;
        node)          echo "remnanode" ;;
    esac
}

# Файлы-кандидаты на замену домена. Несуществующие отсеет общий цикл ниже.
docsrw_candidate_files() {
    if [[ "$ROLE" == "node" ]]; then
        docsrw_node_candidates | awk 'NF && !seen[$0]++'
        return 0
    fi

    echo "$PANEL_DIR/.env"
    if [[ "$PROXY_KIND" == "nginx" ]]; then
        echo "$PROXY_DIR/nginx.conf"
    else
        echo "$PROXY_DIR/Caddyfile"
    fi
    echo "$PROXY_DIR/docker-compose.yml"

    # subscription-page на отдельном сервере — свой каталог и свой proxy рядом.
    if [[ "$SUB_DIR" != "$PROXY_DIR" ]]; then
        echo "$SUB_DIR/docker-compose.yml"
        echo "$SUB_DIR/nginx.conf"
        echo "$SUB_DIR/Caddyfile"
        echo "$SUB_DIR/.env"
    fi
}

# У ноды в docs.rw единого макета нет вообще: базовая установка — это только
# docker-compose.yml с remnanode, без домена и TLS. Маскировка (selfsteal)
# ставится сторонними скриптами со своей структурой, поэтому здесь только
# перебор известных мест, без догадок.
DOCSRW_NODE_SEARCH_ROOTS="${DOCSRW_NODE_SEARCH_ROOTS:-/opt /etc/caddy /etc/nginx}"

docsrw_node_candidates() {
    local root p
    shopt -s nullglob
    for root in $DOCSRW_NODE_SEARCH_ROOTS; do
        # Два уровня вглубь покрывают /opt/remnanode, /opt/caddy, /opt/selfsteal
        # и /opt/remnawave/caddy, но не превращаются в обход всего диска.
        for p in \
            "$root"/Caddyfile      "$root"/nginx.conf      "$root"/docker-compose.yml \
            "$root"/*/Caddyfile    "$root"/*/nginx.conf    "$root"/*/docker-compose.yml \
            "$root"/*/*/Caddyfile  "$root"/*/*/nginx.conf  "$root"/*/*/docker-compose.yml
        do
            [[ -f "$p" ]] && echo "$p"
        done
    done
    shopt -u nullglob
}

# --- Выпуск сертификата в docsrw-макете --------------------------------------
# acme.sh и certbot намеренно живут в отдельных функциях: разный CLI, разные
# имена выходных файлов, разный способ перезагрузки веб-сервера.

issue_cert_acmesh_panel() {
    # --install-cert только раскладывает УЖЕ выпущенный сертификат, поэтому для
    # нового домена сначала нужен --issue.
    local rc
    ufw allow 80/tcp comment 'HTTP for acme.sh challenge' >/dev/null 2>&1 || true
    set +e
    acme.sh --issue --standalone -d "$NEW_DOMAIN" ${ACME_EMAIL:+--accountemail "$ACME_EMAIL"}
    rc=$?
    set -e
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    [[ $rc -ne 0 ]] && err "acme.sh --issue завершился с ошибкой (код $rc)."

    acme.sh --install-cert -d "$NEW_DOMAIN" \
        --key-file "$PROXY_DIR/privkey.key" \
        --fullchain-file "$PROXY_DIR/fullchain.pem" \
        --reloadcmd "docker exec remnawave-nginx nginx -s reload"
}

issue_cert_acmesh_sub() {
    # Bundled-подписка живёт в том же nginx-каталоге, но под своими именами
    # файлов, а challenge идёт по TLS-ALPN на 8443, а не по HTTP на 80.
    local rc
    ufw allow 8443/tcp comment 'TLS-ALPN for acme.sh challenge' >/dev/null 2>&1 || true
    set +e
    acme.sh --issue --standalone -d "$NEW_DOMAIN" \
        --key-file "$SUB_DIR/subdomain_privkey.key" \
        --fullchain-file "$SUB_DIR/subdomain_fullchain.pem" \
        --alpn --tlsport 8443 \
        --reloadcmd "docker exec remnawave-nginx nginx -s reload"
    rc=$?
    set -e
    ufw delete allow 8443/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    [[ $rc -ne 0 ]] && err "acme.sh --issue завершился с ошибкой (код $rc)."
}

docsrw_issue_cert() {
    BASE_DOMAIN="$NEW_DOMAIN"

    if [[ "$ROLE" == "node" ]]; then
        info "Для ноды сертификат этим скриптом не выпускается — в docs.rw у ноды нет штатного TLS-слоя."
        return 0
    fi

    if [[ "$PROXY_KIND" == "caddy" ]]; then
        info "Caddy выпустит сертификат для $NEW_DOMAIN сам после перезапуска с новым Caddyfile — ручной шаг не нужен."
        return 0
    fi

    if $DRY_RUN; then
        if [[ "$ROLE" == "sub" ]]; then
            log "[dry-run] acme.sh --issue --standalone -d $NEW_DOMAIN --alpn --tlsport 8443 --key-file $SUB_DIR/subdomain_privkey.key --fullchain-file $SUB_DIR/subdomain_fullchain.pem"
        else
            log "[dry-run] acme.sh --issue --standalone -d $NEW_DOMAIN"
            log "[dry-run] acme.sh --install-cert -d $NEW_DOMAIN --key-file $PROXY_DIR/privkey.key --fullchain-file $PROXY_DIR/fullchain.pem"
        fi
        return 0
    fi

    command -v acme.sh >/dev/null 2>&1 || \
        err "acme.sh не установлен. Поставь вручную: curl https://get.acme.sh | sh — автоматически ставить не буду."

    if [[ "$ROLE" == "sub" ]]; then
        issue_cert_acmesh_sub
    else
        issue_cert_acmesh_panel
    fi
}

# --- Откат из каталога domain-change-backup-<ts> -----------------------------
do_rollback() {
    banner
    [[ -d "$ROLLBACK_DIR" ]] || err "Каталог бэкапа $ROLLBACK_DIR не найден."
    [[ -n "$TARGET_DIR" ]] || TARGET_DIR="$(dirname "$ROLLBACK_DIR")"
    [[ -d "$TARGET_DIR" ]] || err "Директория установки $TARGET_DIR не найдена."

    if [[ -z "$ROLE" ]]; then
        case "$TARGET_DIR" in
            *remnanode*) ROLE="node" ;;
            *)           ROLE="panel_and_sub" ;;
        esac
        info "Роль не указана, определил по каталогу: $ROLE"
    fi

    # Перезапуск в docsrw идёт по нескольким каталогам — их надо разрешить.
    if [[ "$LAYOUT" == "docsrw" ]]; then
        PANEL_DIR="${PANEL_DIR:-$TARGET_DIR}"
        docsrw_resolve_dirs
    fi

    step "Откат файлов из $ROLLBACK_DIR"
    local bak base dest stored restored=0

    # Манифест хранит точные исходные пути — единственный надёжный способ, когда
    # файлы приходят из разных каталогов (макет docsrw).
    if [[ -f "$ROLLBACK_DIR/manifest" ]]; then
        while IFS=$'\t' read -r stored dest; do
            [[ -n "$stored" && -f "$ROLLBACK_DIR/$stored" ]] || continue
            cp "$ROLLBACK_DIR/$stored" "$dest"
            log "Восстановлен $dest"
            restored=$((restored + 1))
        done < "$ROLLBACK_DIR/manifest"
        [[ $restored -eq 0 ]] && err "Манифест в $ROLLBACK_DIR пуст или битый."

        step "Перезапуск контейнеров"
        if [[ "$LAYOUT" == "docsrw" ]]; then
            docsrw_restart
        else
            restart_stack
        fi
        echo -e "\n${C_BGREEN}${C_BOLD}✔ Откат выполнен.${C_RESET}"
        warn "Откат не трогает панель: если домен уже был изменён в Config Profile / Hosts, верни его там вручную."
        exit 0
    fi

    # Бэкапы, снятые старыми версиями скрипта: только плоский basename.bak.
    # dotglob обязателен: бэкап .env лежит как .env.bak и без него не находится.
    shopt -s nullglob dotglob
    for bak in "$ROLLBACK_DIR"/*.bak; do
        base="$(basename "$bak" .bak)"
        if [[ -f "$TARGET_DIR/$base" ]]; then
            dest="$TARGET_DIR/$base"
        elif [[ -f "$TARGET_DIR/nginx/$base" ]]; then
            dest="$TARGET_DIR/nginx/$base"
        else
            dest="$TARGET_DIR/$base"
        fi
        cp "$bak" "$dest"
        log "Восстановлен $dest"
        restored=$((restored + 1))
    done
    shopt -u nullglob dotglob

    [[ $restored -eq 0 ]] && err "В $ROLLBACK_DIR нет ни одного *.bak."

    step "Перезапуск контейнеров"
    restart_stack

    echo -e "\n${C_BGREEN}${C_BOLD}✔ Откат выполнен.${C_RESET}"
    warn "Откат не трогает панель: если домен уже был изменён в Config Profile / Hosts, верни его там вручную."
    exit 0
}

do_install() {
    [[ $EUID -ne 0 ]] && err "Установка требует root (sudo)."
    banner
    log "Скачиваю актуальную версию скрипта в $INSTALL_PATH..."
    curl -fsSL "$RAW_URL" -o "$INSTALL_PATH" || err "Не удалось скачать скрипт с $RAW_URL"
    chmod +x "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$LEGACY_INSTALL_PATH"
    echo -e "\n${C_BGREEN}${C_BOLD}✔ Установлено!${C_RESET} Теперь можно запускать из любой директории:"
    echo -e "    ${C_CYAN}sudo changedomain${C_RESET}"
    echo -e "    ${C_CYAN}sudo changedomain --role panel --old ... --new ... --dir ... --cert-method cloudflare --cf-zone-new ...${C_RESET}"
    echo -e "${C_DIM}    (старое имя 'changedomen' оставлено симлинком на новое)${C_RESET}"
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
    echo "  Caddy-вариант того же установщика (сертификат Caddy выпускает сам, --cert-method не нужен):"
    echo "    $SCRIPT_NAME --proxy caddy --role panel --old OLD --new NEW --dir /opt/remnawave"
    echo "    $SCRIPT_NAME --proxy caddy --role sub   --old OLD --new NEW --dir /opt/remnawave"
    echo "    $SCRIPT_NAME --proxy caddy --role node  --old OLD --new NEW --dir /opt/remnanode \\"
    echo "       --panel-url https://panel.example.com"
    echo "    (--proxy не обязателен: определяется по наличию Caddyfile / nginx.conf в --dir)"
    echo ""
    echo "  Официальный макет docs.rw (--layout docsrw), панель/подписка/нода в РАЗНЫХ каталогах:"
    echo "    # панель за nginx (сертификат через acme.sh):"
    echo "    $SCRIPT_NAME --layout docsrw --proxy nginx --role panel --old OLD --new NEW \\"
    echo "       [--panel-dir /opt/remnawave] [--proxy-dir /opt/remnawave/nginx] [--acme-email EMAIL]"
    echo "    # панель за caddy (сертификат Caddy выпускает сам):"
    echo "    $SCRIPT_NAME --layout docsrw --proxy caddy --role panel --old OLD --new NEW"
    echo "    # подписка, bundled в тот же nginx-каталог (subdomain_*.pem, TLS-ALPN на 8443):"
    echo "    $SCRIPT_NAME --layout docsrw --proxy nginx --role sub --old OLD --new NEW"
    echo "    # подписка на отдельном сервере:"
    echo "    $SCRIPT_NAME --layout docsrw --proxy nginx --role sub --old OLD --new NEW \\"
    echo "       --sub-dir /opt/remnawave/subscription --proxy-dir /opt/remnawave/nginx"
    echo "    # нода: домен меняется в панели, локальный конфиг маскировки — если найдётся:"
    echo "    $SCRIPT_NAME --layout docsrw --role node --old OLD --new NEW --panel-url https://panel.example.com"
    echo ""
    echo "  --layout       egamesapi (по умолчанию, eGamesAPI/remnawave-reverse-proxy: один --dir + certbot)"
    echo "                 или docsrw (официальный docs.rw: раздельные каталоги, acme.sh или Caddy)."
    echo "  --proxy        nginx|caddy — какой reverse-proxy обслуживает домены. В макете egamesapi"
    echo "                 определяется по Caddyfile/nginx.conf в --dir; в docsrw — по каталогу"
    echo "                 <panel-dir>/nginx vs <panel-dir>/caddy (для --role node там не нужен)."
    echo "  --panel-dir    каталог панели (.env + docker-compose.yml), по умолчанию /opt/remnawave."
    echo "  --proxy-dir    каталог reverse-proxy, по умолчанию <panel-dir>/<proxy>."
    echo "  --sub-dir      каталог subscription-page, по умолчанию совпадает с --proxy-dir"
    echo "                 (задай явно, если подписка стоит на отдельном сервере)."
    echo ""
    echo "  Откат к предыдущему состоянию:"
    echo "    $SCRIPT_NAME --rollback /opt/remnawave/domain-change-backup-20250101-120000 [--role panel]"
    echo ""
    echo "  --cf-zone-new  Имя зоны в Cloudflare для НОВОГО домена (то, что видно в дашборде Cloudflare,"
    echo "                 например example.co.uk — НЕ обязательно последние 2 сегмента домена)."
    echo ""
    echo "  --panel-url    URL панели Remnawave без /api (например https://panel.example.com). Для --role node"
    echo "                 нужен, чтобы поменять домен ещё и в Config Profile / Hosts панели, а не только в файлах."
    echo "  --panel-token  API-ключ панели (Настройки -> API Tokens). Если не передан — скрипт спросит его"
    echo "                 интерактивно, со скрытым вводом. Логин/пароль панели не используются."
    echo "  --panel-cookie Секретная cookie панели в установке eGamesAPI, в виде ИМЯ=ЗНАЧЕНИЕ. Без неё nginx"
    echo "                 отдаёт 444, а Caddy обрывает соединение на любом запросе, включая /api. На сервере"
    echo "                 панели ищется автоматически в nginx.conf/Caddyfile; на ноде — передай флагом или"
    echo "                 вставь в --panel-url ссылку вида https://panel.example.com/auth/login?ИМЯ=ЗНАЧЕНИЕ."
    echo "  --no-panel     Не трогать Panel API вообще (только файлы на диске, как в старом поведении)."
    echo ""
    echo "  --cf-update-dns  Дополнительно обновить A-запись нового домена в Cloudflare тем же токеном,"
    echo "                   что используется для DNS-01 (спросит IP интерактивно)."
    echo ""
    echo "  --install      Установить этот скрипт как глобальную команду 'changedomain' в /usr/local/bin"
    echo "                 (старое имя 'changedomen' остаётся симлинком)."
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
        --panel-url) PANEL_URL="$2"; shift 2 ;;
        --panel-token) PANEL_TOKEN="$2"; shift 2 ;;
        --panel-cookie) PANEL_COOKIE="$2"; shift 2 ;;
        --no-panel) SKIP_PANEL=true; shift ;;
        --cf-update-dns) CF_UPDATE_DNS=true; shift ;;
        --layout) LAYOUT="$2"; shift 2 ;;
        --proxy) PROXY_KIND="$2"; shift 2 ;;
        --panel-dir) PANEL_DIR="$2"; shift 2 ;;
        --proxy-dir) PROXY_DIR="$2"; shift 2 ;;
        --sub-dir) SUB_DIR="$2"; shift 2 ;;
        --rollback) ROLLBACK_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --install) do_install ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo -e "\033[1;31m[x]\033[0m Run as root (sudo)."; exit 1; }

[[ -n "$ROLLBACK_DIR" ]] && do_rollback

[[ -n "$ROLE" ]] && banner

[[ "$LAYOUT" != "egamesapi" && "$LAYOUT" != "docsrw" ]] && err "--layout должен быть egamesapi или docsrw."

# --- Интерактивный опрос, если роль/домены не переданы флагами -----------
# Мастер описывает только макет egamesapi (единый каталог + certbot); для docsrw
# каталогов и подвариантов слишком много, там роль задаётся флагом.
if [[ -z "$ROLE" && "$LAYOUT" == "egamesapi" ]]; then
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

    egamesapi_detect_proxy

    if [[ "$PROXY_KIND" == "caddy" ]]; then
        # У caddy-установки сертификатов на диске нет — спрашивать про certbot нечего.
        info "Caddy получает сертификаты сам, шаг выбора метода сертификата пропущен."
    else

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

    fi  # конец ветки "не caddy" в опросе метода сертификата

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

if [[ "$LAYOUT" == "docsrw" ]]; then
    [[ -z "$ROLE" ]] && err "Для --layout docsrw роль задаётся явно: --role panel|sub|node (см. --help)."
    [[ -z "$OLD_DOMAIN" || -z "$NEW_DOMAIN" ]] && usage
    [[ "$ROLE" != "panel" && "$ROLE" != "sub" && "$ROLE" != "node" ]] && \
        err "Для --layout docsrw поддерживаются роли panel|sub|node. Панель и подписку меняй отдельными запусками."
    [[ -n "$CERT_METHOD" ]] && warn "--cert-method в макете docsrw не используется (там acme.sh или сам Caddy) — игнорирую."
    docsrw_resolve_dirs
else
    [[ -z "$OLD_DOMAIN" || -z "$NEW_DOMAIN" || -z "$TARGET_DIR" ]] && usage
    [[ "$ROLE" != "panel" && "$ROLE" != "sub" && "$ROLE" != "node" && "$ROLE" != "panel_and_sub" ]] && err "role must be panel|sub|node"
    [[ ! -d "$TARGET_DIR" ]] && err "Directory $TARGET_DIR not found."

    egamesapi_detect_proxy

    # Caddy выпускает сертификаты сам, certbot в этом варианте не участвует.
    if [[ "$PROXY_KIND" == "caddy" ]]; then
        [[ -n "$CERT_METHOD" ]] && warn "--cert-method при --proxy caddy не используется (Caddy выпускает сертификат сам) — игнорирую."
    else
        [[ "$CERT_METHOD" != "cloudflare" && "$CERT_METHOD" != "acme" ]] && err "Укажи --cert-method cloudflare или acme."

        if [[ "$CERT_METHOD" == "cloudflare" ]]; then
            [[ -z "$CF_ZONE_NEW" ]] && err "Не указана зона Cloudflare для нового домена (--cf-zone-new)."
            if [[ "$NEW_DOMAIN" != "$CF_ZONE_NEW" && "$NEW_DOMAIN" != *".$CF_ZONE_NEW" ]]; then
                err "$NEW_DOMAIN не является поддоменом зоны $CF_ZONE_NEW."
            fi
        else
            [[ -z "$ACME_EMAIL" ]] && err "Для --cert-method acme нужен --acme-email."
        fi
    fi
fi

# Домен живёт не только в файлах на диске, но и в базе панели, причём где именно —
# зависит от установки, а не от роли. Поэтому спрашиваем всегда, а что реально
# зацепится, решают сами запросы: чего нет — то и не меняется.
# [[ -t 0 ]] обязателен: без терминала read упирается в EOF и под set -e роняет скрипт.
if [[ "$SKIP_PANEL" == false && -z "$PANEL_URL" && -t 0 ]]; then
    step "Смена домена в панели"
    warn "Домен хранится не только в файлах на диске, но и в панели:"
    warn "  Config Profile -> realitySettings.serverNames / dest, xhttpSettings.host"
    warn "  Hosts -> address / sni / host"
    warn "  Nodes -> address"
    read -rp "$(echo -e "${C_CYAN}Поменять домен в панели тоже? (y/N):${C_RESET} ")" c
    if [[ "$c" == "y" || "$c" == "Y" ]]; then
        read -rp "$(echo -e "${C_CYAN}URL панели без /api (например https://panel.example.com):${C_RESET} ")" PANEL_URL
        [[ -z "$PANEL_URL" ]] && SKIP_PANEL=true
    else
        SKIP_PANEL=true
    fi
fi

if [[ "$LAYOUT" == "docsrw" ]]; then
    echo -e "${C_DIM}${OLD_DOMAIN} → ${C_RESET}${C_WHITE}${NEW_DOMAIN}${C_RESET}  ${C_DIM}[docsrw / ${ROLE}${PROXY_KIND:+ / $PROXY_KIND}]${C_RESET}\n"
else
    echo -e "${C_DIM}${OLD_DOMAIN} → ${C_RESET}${C_WHITE}${NEW_DOMAIN}${C_RESET}  ${C_DIM}[${ROLE} / ${CERT_METHOD}]${C_RESET}\n"
fi

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
if [[ "$LAYOUT" == "docsrw" ]]; then

docsrw_issue_cert

elif [[ "$PROXY_KIND" == "caddy" ]]; then

# Caddy-вариант установщика eGamesAPI: сертификатов на диске нет вообще, их
# получает и хранит сам Caddy (встроенный ACME-клиент, том caddy_data).
BASE_DOMAIN="$NEW_DOMAIN"
info "Caddy сам получит новый сертификат для $NEW_DOMAIN после перезапуска контейнера — сертификат не выпускается этим скриптом, никаких доп. действий не требуется."

else

if ! $DRY_RUN && ! command -v certbot >/dev/null 2>&1; then
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

fi  # конец ветки LAYOUT=egamesapi для выпуска сертификата

# --- Опциональное обновление A-записи тем же Cloudflare-токеном ---------
if $CF_UPDATE_DNS; then
    if [[ "$CERT_METHOD" != "cloudflare" ]]; then
        warn "--cf-update-dns требует --cert-method cloudflare (нужен CF-токен) — пропускаю."
    elif $DRY_RUN; then
        log "[dry-run] would PUT https://api.cloudflare.com/client/v4/zones/<$CF_ZONE_NEW>/dns_records — A $NEW_DOMAIN"
    else
        cf_update_dns || warn "DNS в Cloudflare не обновлён — поправь A-запись вручную."
    fi
fi

# --- Бэкап и замена домена в конфигах ---------------------------------
step "Шаг 2/3 — бэкап и подготовка изменений"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${TARGET_DIR}/domain-change-backup-${TS}"
mkdir -p "$BACKUP_DIR"

FILES_TO_PATCH=()
if [[ "$LAYOUT" == "docsrw" ]]; then
    while read -r f; do
        [[ -f "$f" ]] && FILES_TO_PATCH+=("$f")
    done < <(docsrw_candidate_files)
elif [[ "$PROXY_KIND" == "caddy" ]]; then
    # Caddyfile в этой установке домены не содержит: там нативные плейсхолдеры
    # Caddy ({$SELF_STEAL_DOMAIN} и т.п.), а реальные значения лежат в секции
    # environment docker-compose.yml. Поэтому Caddyfile в список не попадает.
    [[ "$ROLE" != "node" && -f "$TARGET_DIR/.env" ]] && FILES_TO_PATCH+=("$TARGET_DIR/.env")
    [[ -f "$TARGET_DIR/docker-compose.yml" ]] && FILES_TO_PATCH+=("$TARGET_DIR/docker-compose.yml")
else
    for f in "$TARGET_DIR/.env" "$TARGET_DIR/docker-compose.yml" "$TARGET_DIR/nginx/nginx.conf" "$TARGET_DIR/nginx.conf"; do
        [[ -f "$f" ]] && FILES_TO_PATCH+=("$f")
    done
fi

# У docsrw+node локальных файлов может не быть вообще — это штатный исход,
# а не ошибка: домен там живёт в панели, а маскировка ставится сторонним скриптом.
DOCSRW_NODE_BEST_EFFORT=false
[[ "$LAYOUT" == "docsrw" && "$ROLE" == "node" ]] && DOCSRW_NODE_BEST_EFFORT=true

if [[ ${#FILES_TO_PATCH[@]} -eq 0 ]] && ! $DOCSRW_NODE_BEST_EFFORT; then
    if [[ "$LAYOUT" == "docsrw" ]]; then
        err "Не нашёл ни одного конфигурационного файла в $PANEL_DIR / $PROXY_DIR — проверь --panel-dir/--proxy-dir."
    fi
    err "Не нашёл ни .env, ни docker-compose.yml, ни nginx.conf в $TARGET_DIR — проверь путь."
fi

log "Файлы, где встречается $OLD_DOMAIN:"
MATCHED_FILES=()
for f in "${FILES_TO_PATCH[@]:-}"; do
    [[ -n "$f" ]] || continue
    if grep -q "$OLD_DOMAIN" "$f"; then
        echo -e "   ${C_CYAN}-${C_RESET} $f"
        MATCHED_FILES+=("$f")
    fi
done

SKIP_LOCAL=false
if [[ ${#MATCHED_FILES[@]} -eq 0 ]]; then
    if $DOCSRW_NODE_BEST_EFFORT; then
        warn "Локальный конфиг маскировки с $OLD_DOMAIN не найден автоматически."
        warn "В docs.rw у ноды нет штатного макета с доменом — обнови его вручную там, где он у тебя настроен."
        SKIP_LOCAL=true
    else
        warn "Строка $OLD_DOMAIN не найдена ни в одном файле. Проверь, что домен указан правильно (без https://, с/без www)."
        exit 1
    fi
elif $DOCSRW_NODE_BEST_EFFORT && [[ ${#MATCHED_FILES[@]} -gt 1 ]]; then
    # Несколько кандидатов — гадать нельзя, какой из них реально обслуживает маскировку.
    warn "Найдено несколько возможных конфигов с $OLD_DOMAIN (см. список выше) — какой из них отвечает за маскировку, определить нельзя."
    warn "Локальные файлы не трогаю, обнови нужный вручную. Домен в панели при этом обновится."
    SKIP_LOCAL=true
fi

if ! $SKIP_LOCAL; then

# Плоские имена basename.bak сталкиваются, когда в docsrw одинаково названные
# файлы приходят из разных каталогов, поэтому пишем манифест с реальными путями.
: > "$BACKUP_DIR/manifest"
for f in "${MATCHED_FILES[@]}"; do
    stored="$(basename "$f").bak"
    if [[ "$LAYOUT" == "docsrw" ]]; then
        stored="$(printf '%s' "$f" | md5sum | cut -c1-8)-$stored"
    fi
    cp "$f" "$BACKUP_DIR/$stored"
    printf '%s\t%s\n' "$stored" "$f" >> "$BACKUP_DIR/manifest"
done
log "Бэкап сохранён в $BACKUP_DIR"

for f in "${MATCHED_FILES[@]}"; do
    echo -e "\n${C_BOLD}${C_WHITE}── diff для $f ──${C_RESET}"
    diff -u "$f" <(sed "s/${OLD_DOMAIN//./\\.}/${NEW_DOMAIN}/g" "$f") \
        | sed -E "s/^(\+.*)/$(printf '%b' "${C_GREEN}")\1$(printf '%b' "${C_RESET}")/; s/^(-.*)/$(printf '%b' "${C_RED}")\1$(printf '%b' "${C_RESET}")/; s/^(@@.*@@)/$(printf '%b' "${C_CYAN}")\1$(printf '%b' "${C_RESET}")/" \
        || true
done

fi  # конец блока подготовки локальных изменений (SKIP_LOCAL)

if $DRY_RUN; then
    if [[ "$LAYOUT" == "docsrw" && "$ROLE" != "node" ]]; then
        while read -r d; do
            log "[dry-run] would restart compose project in $d"
        done < <(docsrw_restart_dirs)
    fi
    if [[ "$SKIP_PANEL" == false && -n "$PANEL_URL" ]]; then
        log "[dry-run] would PATCH ${PANEL_URL%/}/api/config-profiles — serverNames/dest/host: $OLD_DOMAIN -> $NEW_DOMAIN"
        log "[dry-run] would PATCH ${PANEL_URL%/}/api/hosts — address/sni/host: $OLD_DOMAIN -> $NEW_DOMAIN"
        log "[dry-run] would PATCH ${PANEL_URL%/}/api/nodes — address: $OLD_DOMAIN -> $NEW_DOMAIN"
    fi
    log "[dry-run] Изменения не применены."
    exit 0
fi

if ! $SKIP_LOCAL; then

echo ""
read -rp "$(echo -e "${C_BYELLOW}Применить эти изменения? (y/N):${C_RESET} ")" confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; exit 1; }

for f in "${MATCHED_FILES[@]}"; do
    sed -i "s/${OLD_DOMAIN//./\\.}/${NEW_DOMAIN}/g" "$f"
done
log "Домен заменён в: ${MATCHED_FILES[*]}"

fi  # конец блока применения локальных изменений (SKIP_LOCAL)

# --- Если docker-compose.yml монтирует сертификаты по старому домену (base или
#        сам OLD_DOMAIN, в зависимости от того как ставился сертификат) — подставим
#        пути на новый сертификат. Ищем ЛЮБУЮ строку /etc/letsencrypt/live/<что-то>,
#        где <что-то> является префиксом OLD_DOMAIN (т.е. OLD_DOMAIN совпадает с ним
#        или является его поддоменом) — без угадывания по количеству точек.
# Только для egamesapi+nginx: в docs.rw сертификаты кладёт acme.sh по фиксированным
# путям внутри proxy-каталога, а у любого Caddy они вообще внутри named volume,
# так что /etc/letsencrypt/live там не встречается никогда.
COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
if [[ "$LAYOUT" == "egamesapi" && "$PROXY_KIND" != "caddy" && -f "$COMPOSE_FILE" ]]; then
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
if [[ "$LAYOUT" == "docsrw" ]]; then
    docsrw_restart
else
    restart_stack
fi

# --- Panel API ----------------------------------------------------------
# Порядок: сначала локальные файлы + рестарт, только потом панель. Реальный
# Xray-конфиг ноды приезжает ИЗ панели, а сертификат и decoy-сайт живут на самой
# ноде. Если сначала пропатчить панель, нода какое-то время будет отдавать новые
# serverNames старым сертификатом. Поэтому сперва поднимаем ноду на новом домене,
# и только потом панель начинает раздавать этот домен клиентам в подписках.
if [[ "$SKIP_PANEL" == true || -z "$PANEL_URL" ]]; then
    if [[ "$ROLE" == "node" ]]; then
        warn "Не забудь: SELF_STEAL_DOMAIN/serverNames в Config Profile панели меняются ОТДЕЛЬНО, через панель, не этим скриптом."
        warn "Автоматически это делается флагом --panel-url (или ответом 'y' на вопрос про панель)."
    fi
else
    # Если меняли домен самой панели, она уже перезапущена на новом имени, и старый
    # адрес больше не отвечает — в API идём по новому.
    if [[ "$PANEL_URL" == *"$OLD_DOMAIN"* ]]; then
        PANEL_URL="${PANEL_URL//$OLD_DOMAIN/$NEW_DOMAIN}"
        info "URL панели переключён на новый домен: $PANEL_URL"
    fi
    if sync_panel; then
        log "Домен обновлён и в панели."
    else
        warn "Часть про панель НЕ выполнена — см. сообщения выше."
        warn "Локальные изменения файлов и рестарт контейнеров уже применены и НЕ откатывались."
        warn "Поправь вручную: Config Profile -> realitySettings.serverNames/dest, Hosts -> address/sni, Nodes -> address."
        warn "Откатить файлы целиком: $SCRIPT_NAME --rollback $BACKUP_DIR"
    fi
fi

verify_deployment

echo -e "\n${C_BGREEN}${C_BOLD}✔ Готово!${C_RESET} ${C_WHITE}${NEW_DOMAIN}${C_RESET} настроен."
echo -e "${C_DIM}Логи:${C_RESET} ${C_CYAN}docker compose -f $TARGET_DIR/docker-compose.yml logs -f${C_RESET}"
echo -e "${C_DIM}Откат:${C_RESET} ${C_CYAN}$SCRIPT_NAME --rollback $BACKUP_DIR${C_RESET}\n"
