#!/bin/bash
# Проверка чистых функций change-domain.sh на временных фикстурах.
# Ничего не устанавливает, не требует root, docker и сети: функции вынимаются
# из скрипта и вызываются на файлах во временном каталоге.
#
#   bash test_change_domain.sh
#
set -euo pipefail

SCRIPT="${1:-$(dirname "$0")/change-domain.sh}"
[[ -f "$SCRIPT" ]] || { echo "не найден $SCRIPT"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Вытаскиваем проверяемые функции, чтобы тест шёл по реальному коду, а не по копии.
sed -n '/^build_patch_expr()/,/^}/p;/^file_will_change()/,/^}/p;/^panel_cookie_files()/,/^}/p;/^resolve_panel_cookie()/,/^}$/p;/^cf_key_kind()/,/^}/p;/^nodes_to_restart()/,/^}/p' \
    "$SCRIPT" > "$TMP/functions.sh"

log() { :; }
PATCH_EXPR=(); CERT_DIRS_FOUND=(); FILES_TO_PATCH=(); PANEL_COOKIE=""; PROXY_DIR=""
# shellcheck disable=SC1090
source "$TMP/functions.sh"

FAILED=0
ok()   { echo "  OK   $*"; }
fail() { echo "  FAIL $*"; FAILED=1; }
check() { [[ "$2" == "$3" ]] && ok "$1" || { fail "$1"; echo "       ждали: $3"; echo "       вышло: $2"; }; }

# --- 1. Домен и пути к сертификату чинятся во ВСЕХ файлах -------------------
# Прод-случай из ISSUES.md #1: сертификат wildcard на зону, поэтому каталог
# сертификата — родительский домен, а не сам домен ноды. Раньше путь чинился
# только в docker-compose.yml, а в nginx.conf оставался старым, и nginx уходил
# в restart-loop с "cannot load certificate".
echo "[1] замена домена и путей к сертификату"
D="$TMP/egames"; mkdir -p "$D"
cat > "$D/.env" <<'EOF'
SELF_STEAL_DOMAIN=yt.sim.h2so4nlkanoda.ru
SELF_STEAL_PORT=9443
EOF
cat > "$D/docker-compose.yml" <<'EOF'
services:
  remnawave-nginx:
    image: nginx:1.28
    volumes:
      - /etc/letsencrypt/live/h2so4nlkanoda.ru/fullchain.pem:/etc/nginx/ssl/h2so4nlkanoda.ru/fullchain.pem:ro
      - /etc/letsencrypt/live/h2so4nlkanoda.ru/privkey.pem:/etc/nginx/ssl/h2so4nlkanoda.ru/privkey.pem:ro
EOF
cat > "$D/nginx.conf" <<'EOF'
server {
    server_name yt.sim.h2so4nlkanoda.ru;
    listen 8443 ssl;
    ssl_certificate "/etc/nginx/ssl/h2so4nlkanoda.ru/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/h2so4nlkanoda.ru/privkey.pem";
}
EOF
cat > "$D/unrelated.conf" <<'EOF'
ssl_certificate "/etc/nginx/ssl/someone-else.example/fullchain.pem";
EOF

OLD_DOMAIN="yt.sim.h2so4nlkanoda.ru"
NEW_DOMAIN="ytsim.vltx.eu.cc"
BASE_DOMAIN="vltx.eu.cc"   # wildcard-сертификат выпущен на зону
FILES_TO_PATCH=("$D/.env" "$D/docker-compose.yml" "$D/nginx.conf" "$D/unrelated.conf")
build_patch_expr

check "каталог старого сертификата найден" "${CERT_DIRS_FOUND[*]}" "h2so4nlkanoda.ru"

for f in "$D/.env" "$D/docker-compose.yml" "$D/nginx.conf"; do
    if file_will_change "$f"; then ok "изменится $(basename "$f")"; else fail "не изменится $(basename "$f")"; fi
done
if file_will_change "$D/unrelated.conf"; then
    fail "чужой сертификат не должен трогаться"
else
    ok "чужой сертификат не тронут"
fi

for f in "${FILES_TO_PATCH[@]}"; do sed -i "${PATCH_EXPR[@]}" "$f"; done

check "nginx.conf: путь к сертификату" \
    "$(grep -c '/etc/nginx/ssl/vltx.eu.cc/' "$D/nginx.conf")" "2"
check "nginx.conf: старого пути не осталось" \
    "$(grep -c 'h2so4nlkanoda' "$D/nginx.conf" || true)" "0"
check "docker-compose.yml: старого пути не осталось" \
    "$(grep -c 'h2so4nlkanoda' "$D/docker-compose.yml" || true)" "0"
check "docker-compose.yml: letsencrypt переехал на зону нового домена" \
    "$(grep -c '/etc/letsencrypt/live/vltx.eu.cc/' "$D/docker-compose.yml")" "2"
check ".env: домен заменён" \
    "$(grep -c 'SELF_STEAL_DOMAIN=ytsim.vltx.eu.cc' "$D/.env")" "1"
check "чужой сертификат остался как был" \
    "$(grep -c 'someone-else.example' "$D/unrelated.conf")" "1"

# --- 2. Сертификат без wildcard: каталог равен самому домену ----------------
echo "[2] сертификат на конкретный домен, без зоны"
D2="$TMP/plain"; mkdir -p "$D2"
cat > "$D2/docker-compose.yml" <<'EOF'
      - /etc/letsencrypt/live/node.example.com/fullchain.pem:/etc/nginx/ssl/node.example.com/fullchain.pem:ro
EOF
OLD_DOMAIN="node.example.com"; NEW_DOMAIN="node.example.org"; BASE_DOMAIN="node.example.org"
FILES_TO_PATCH=("$D2/docker-compose.yml")
build_patch_expr
sed -i "${PATCH_EXPR[@]}" "$D2/docker-compose.yml"
check "путь переехал целиком" \
    "$(grep -c '/etc/letsencrypt/live/node.example.org/fullchain.pem:/etc/nginx/ssl/node.example.org/fullchain.pem' "$D2/docker-compose.yml")" "1"

# --- 3. Секретная cookie панели (установка eGamesAPI) ----------------------
echo "[3] поиск секретной cookie панели"
DN="$TMP/cookie-nginx"; DC="$TMP/cookie-caddy"; mkdir -p "$DN" "$DC"
cat > "$DN/nginx.conf" <<'EOF'
map $http_cookie $auth_cookie {
    default 0;
    "~*QwErTyUi=aSdFgHjK" 1;
}
EOF
cat > "$DC/Caddyfile" <<'EOF'
    handle @has_token_param {
        header +Set-Cookie "abcdEFGH=ijklMNOP; Path=/; HttpOnly; Secure; SameSite=Strict"
    }
EOF

TARGET_DIR="$DN"; PANEL_URL="https://panel.example.com"; PANEL_COOKIE=""
resolve_panel_cookie || true
check "cookie из nginx.conf" "$PANEL_COOKIE" "QwErTyUi=aSdFgHjK"

TARGET_DIR="$DC"; PANEL_COOKIE=""
resolve_panel_cookie || true
check "cookie из Caddyfile" "$PANEL_COOKIE" "abcdEFGH=ijklMNOP"

TARGET_DIR="$TMP/нет-такого"; PANEL_COOKIE=""
PANEL_URL="https://panel.example.com/auth/login?zxcvBNM=poiuYTR"
resolve_panel_cookie || true
check "cookie из ссылки в --panel-url" "$PANEL_COOKIE" "zxcvBNM=poiuYTR"
check "URL панели очищен от query и /auth/login" "$PANEL_URL" "https://panel.example.com"

TARGET_DIR="$TMP/нет-такого"; PANEL_COOKIE=""; PANEL_URL="https://panel.example.com"
if resolve_panel_cookie; then fail "cookie не должна была найтись"; else ok "нет cookie — нет ложной находки"; fi

# --- 4. Тип ключа Cloudflare ----------------------------------------------
echo "[4] распознавание ключа Cloudflare"
check "Global API Key (37 hex)" "$(cf_key_kind 0123456789abcdef0123456789abcdef01234)" "global"
check "API Token (40 символов)" "$(cf_key_kind Xy_9-AbCdEfGhIjKlMnOpQrStUvWxYz012345678)" "token"
check "токен из одних строчных и цифр (40)" "$(cf_key_kind 0123456789abcdef0123456789abcdef01234567)" "token"
check "мусор — не угадываем" "$(cf_key_kind короткий)" "unknown"

# --- 5. Какие ноды перезапускать после правки Config Profile ---------------
# Перезапускать надо только ноды на изменённых профилях и те, которым поменяли
# адрес: чужие ноды панели трогать незачем.
if command -v jq >/dev/null 2>&1; then
    echo "[5] выбор нод для перезапуска"
    cat > "$TMP/nodes.json" <<'EOF'
{"response":[
  {"uuid":"n1","name":"Steal","address":"node.example.com","configProfile":{"activeConfigProfileUuid":"p1"}},
  {"uuid":"n2","name":"Другая","address":"1.2.3.4","configProfile":{"activeConfigProfileUuid":"p2"}},
  {"uuid":"n3","name":"БезПрофиля","address":"old.example.com","configProfile":{"activeConfigProfileUuid":null}}
]}
EOF
    GOT=$(nodes_to_restart '["p1"]' '["n3"]' < "$TMP/nodes.json" | tr -d '\r' | tr '\t' '=' | tr '\n' ' ')
    check "нода на изменённом профиле + нода со смененным адресом" "$GOT" "n1=Steal n3=БезПрофиля "

    GOT=$(nodes_to_restart '[]' '[]' < "$TMP/nodes.json" | tr -d '\r' | tr '\n' ' ')
    check "ничего не меняли — никого не перезапускаем" "$GOT" ""
else
    echo "[5] выбор нод для перезапуска — пропущено, нет jq"
fi

echo
if [[ $FAILED -eq 0 ]]; then
    echo "Все проверки прошли."
else
    echo "Есть падения."
    exit 1
fi
