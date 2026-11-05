#!/usr/bin/env bash
# ==============================================================================
# CaelixFlow Server Migration & Auto-Deploy Tool
# Repository: https://github.com/Sp0nge-bob/caelix-migrate.git
#
# Особенности:
#   - Автоопределение сервисов (Vpn-Bot, Website, Middleware, Redis, Nginx, Copyparty, 3x-ui)
#   - Полная совместимость с чистым Debian 13 (Trixie)
#   - Автоматическая установка Docker, Python-venv, Redis, Nginx + stream
#   - Безопасные горячие снимки SQLite (WAL .backup)
#   - Немедленная остановка Nginx для освобождения 80 порта под 3x-ui
#   - Запуск мастера 3x-ui в финале
#   - Ноль приватных данных и секретов в коде скрипта
# ==============================================================================
set -euo pipefail

VERSION="1.0.0"

# ── Цвета и форматирование ────────────────────────────────────────────────────
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m'
    C_BLUE=$'\033[34m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE=""
fi

log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[OK]%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
    printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$C_BLUE" "$C_RESET"
    printf '%s║%s       %sCaelixFlow Migration & Auto-Deploy Tool v%s%s       %s║%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$VERSION" "$C_RESET" "$C_BLUE" "$C_RESET"
    printf '%s║%s   Автоопределение компонентов · Debian 13 · Без даунтайма   %s║%s\n' "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$C_BLUE" "$C_RESET"
}

ensure_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Скрипт должен быть запущен с правами root: sudo bash $0 $*"
    fi
}

find_path() {
    local candidates=("$@")
    for p in "${candidates[@]}"; do
        if [[ -e "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# ── 1. Сканирование и автоопределение компонентов ─────────────────────────────
scan_components() {
    local silent="${1:-false}"
    [[ "$silent" != "true" ]] && log "Сканирование установленных компонентов на сервере..."

    DETECTED_BOT=""
    DETECTED_WEB=""
    DETECTED_MW=""
    DETECTED_REDIS="false"
    DETECTED_NGINX="false"
    DETECTED_COPYPARTY=""
    DETECTED_XUI="false"

    # 1. VPN-Bot
    local bot_path
    bot_path="$(find_path "/opt/vpn-bot" "/root/vpn-platega-bot" "/opt/vpn-platega-bot" || true)"
    if [[ -n "$bot_path" && (-f "$bot_path/app.py" || -f "$bot_path/run_bot.py") ]]; then
        DETECTED_BOT="$bot_path"
        [[ "$silent" != "true" ]] && ok "Обнаружен Vpn-Bot: $DETECTED_BOT"
    fi

    # 2. VPN-Website
    local web_path
    web_path="$(find_path "/opt/vpn-website" "/root/vpn-website" || true)"
    if [[ -n "$web_path" && -f "$web_path/app/main.py" ]]; then
        DETECTED_WEB="$web_path"
        [[ "$silent" != "true" ]] && ok "Обнаружен Vpn-Website: $DETECTED_WEB"
    fi

    # 3. MiddlewareJSON
    local mw_path
    mw_path="$(find_path "/opt/middlewarejson" "/root/middlewarejson" || true)"
    if [[ -n "$mw_path" && -f "$mw_path/app/main.py" ]]; then
        DETECTED_MW="$mw_path"
        [[ "$silent" != "true" ]] && ok "Обнаружен MiddlewareJSON: $DETECTED_MW"
    fi

    # 4. Redis
    if command -v redis-server >/dev/null 2>&1 || systemctl is-active --quiet redis-server 2>/dev/null; then
        DETECTED_REDIS="true"
        [[ "$silent" != "true" ]] && ok "Обнаружен Redis-server"
    fi

    # 5. Nginx
    if [[ -f "/etc/nginx/nginx.conf" || -d "/etc/nginx/conf.d" ]]; then
        DETECTED_NGINX="true"
        [[ "$silent" != "true" ]] && ok "Обнаружен Nginx (/etc/nginx/nginx.conf, /etc/nginx/conf.d/)"
    fi

    # 6. Copyparty
    local cp_path
    cp_path="$(find_path "/opt/copyparty" "/root/copyparty" || true)"
    if [[ -n "$cp_path" && (-f "$cp_path/docker-compose.yml" || -f "$cp_path/copyparty.conf") ]]; then
        DETECTED_COPYPARTY="$cp_path"
        [[ "$silent" != "true" ]] && ok "Обнаружен Copyparty: $DETECTED_COPYPARTY"
    fi

    # 7. 3x-ui
    if [[ -d "/etc/x-ui" || -d "/usr/local/x-ui" || -f "/etc/x-ui/x-ui.db" ]] || systemctl is-active --quiet x-ui 2>/dev/null; then
        DETECTED_XUI="true"
        [[ "$silent" != "true" ]] && ok "Обнаружен 3x-ui (интерактивный мастер будет предложен в финале)"
    fi
}

# ── 2. Режим только аудит (SCAN / DRY RUN) ────────────────────────────────────
run_scan_audit() {
    scan_components "true"
    echo
    printf '%sРезультаты проверки сервера для миграции:%s\n' "$C_BOLD" "$C_RESET"
    printf '%s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"

    local count=0

    if [[ -n "$DETECTED_BOT" ]]; then
        local db_info="нет bot.db"
        [[ -f "$DETECTED_BOT/data/bot.db" ]] && db_info="bot.db: $(du -h "$DETECTED_BOT/data/bot.db" | cut -f1)"
        printf '  %s[✔]%s %-16s %s (%s, .env: %s)\n' \
            "$C_GREEN" "$C_RESET" "Vpn-Bot" "$DETECTED_BOT" "$db_info" "$([ -f "$DETECTED_BOT/.env" ] && echo "OK" || echo "нет")"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Vpn-Bot"
    fi

    if [[ -n "$DETECTED_WEB" ]]; then
        printf '  %s[✔]%s %-16s %s (.env: %s)\n' \
            "$C_GREEN" "$C_RESET" "Vpn-Website" "$DETECTED_WEB" "$([ -f "$DETECTED_WEB/.env" ] && echo "OK" || echo "нет")"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Vpn-Website"
    fi

    if [[ -n "$DETECTED_MW" ]]; then
        printf '  %s[✔]%s %-16s %s (.env: %s)\n' \
            "$C_GREEN" "$C_RESET" "MiddlewareJSON" "$DETECTED_MW" "$([ -f "$DETECTED_MW/.env" ] && echo "OK" || echo "нет")"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "MiddlewareJSON"
    fi

    if [[ "$DETECTED_REDIS" == "true" ]]; then
        printf '  %s[✔]%s %-16s redis-server установлен / активен\n' "$C_GREEN" "$C_RESET" "Redis"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не установлен\n' "$C_DIM" "$C_RESET" "Redis"
    fi

    if [[ "$DETECTED_NGINX" == "true" ]]; then
        local conf_count=0
        [[ -d "/etc/nginx/conf.d" ]] && conf_count="$(find /etc/nginx/conf.d -maxdepth 1 -type f | wc -l || true)"
        printf '  %s[✔]%s %-16s /etc/nginx/nginx.conf и %s файлов в conf.d/\n' "$C_GREEN" "$C_RESET" "Nginx" "$conf_count"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Nginx"
    fi

    if [[ -n "$DETECTED_COPYPARTY" ]]; then
        printf '  %s[✔]%s %-16s %s (docker-compose: %s)\n' \
            "$C_GREEN" "$C_RESET" "Copyparty" "$DETECTED_COPYPARTY" "$([ -f "$DETECTED_COPYPARTY/docker-compose.yml" ] && echo "OK" || echo "нет")"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Copyparty"
    fi

    if [[ "$DETECTED_XUI" == "true" ]]; then
        printf '  %s[i]%s %-16s обнаружен (будет предложена установка мастером на новом сервере)\n' "$C_CYAN" "$C_RESET" "3x-ui"
    fi

    printf '%s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf 'Готовность к миграции: обнаружено %s компонентов.\n\n' "$count"
}

# ── 3. Упаковка в защищённый бандл (PACK) ─────────────────────────────────────
pack_components() {
    local target_archive="${1:-/tmp/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz}"
    local staging
    staging="$(mktemp -d /tmp/caelix_pack_XXXXXX)"
    chmod 700 "$staging"

    log "Подготовка данных для миграции в $staging..."

    mkdir -p "$staging/meta"
    local manifest="$staging/meta/manifest.env"

    {
        echo "# CaelixFlow Migration Manifest"
        echo "PACKED_AT=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo "HAS_BOT=\"$([ -n "$DETECTED_BOT" ] && echo true || echo false)\""
        echo "HAS_WEB=\"$([ -n "$DETECTED_WEB" ] && echo true || echo false)\""
        echo "HAS_MW=\"$([ -n "$DETECTED_MW" ] && echo true || echo false)\""
        echo "HAS_REDIS=\"$DETECTED_REDIS\""
        echo "HAS_NGINX=\"$DETECTED_NGINX\""
        echo "HAS_COPYPARTY=\"$([ -n "$DETECTED_COPYPARTY" ] && echo true || echo false)\""
        echo "HAS_XUI=\"$DETECTED_XUI\""
    } > "$manifest"

    # 1. VPN-Bot
    if [[ -n "$DETECTED_BOT" ]]; then
        log "Сбор Vpn-Bot..."
        mkdir -p "$staging/bot"
        if [[ -f "$DETECTED_BOT/.env" ]]; then
            cp -a "$DETECTED_BOT/.env" "$staging/bot/.env"
        fi
        if [[ -f "$DETECTED_BOT/data/bot.db" ]]; then
            mkdir -p "$staging/bot/data"
            log "Создание целостного горячего снимка bot.db (sqlite3 backup)..."
            if command -v sqlite3 >/dev/null 2>&1; then
                sqlite3 "$DETECTED_BOT/data/bot.db" ".backup '$staging/bot/data/bot.db'"
                sqlite3 "$staging/bot/data/bot.db" "PRAGMA integrity_check;" >/dev/null
            else
                cp -a "$DETECTED_BOT/data/bot.db"* "$staging/bot/data/" 2>/dev/null || true
            fi
        fi
        if [[ -d "$DETECTED_BOT/data" ]]; then
            mkdir -p "$staging/bot/data"
            rsync -a --exclude="*.lock" --exclude="*.sock" "$DETECTED_BOT/data/" "$staging/bot/data/" 2>/dev/null || true
        fi
        rsync -a --exclude=".venv" --exclude="__pycache__" --exclude=".git" --exclude="data" --exclude=".pytest_cache" \
            "$DETECTED_BOT/" "$staging/bot/app/" 2>/dev/null || true
    fi

    # 2. VPN-Website
    if [[ -n "$DETECTED_WEB" ]]; then
        log "Сбор Vpn-Website..."
        mkdir -p "$staging/web"
        if [[ -f "$DETECTED_WEB/.env" ]]; then
            cp -a "$DETECTED_WEB/.env" "$staging/web/.env"
        fi
        rsync -a --exclude=".venv" --exclude="__pycache__" --exclude=".git" --exclude=".pytest_cache" \
            "$DETECTED_WEB/" "$staging/web/app/" 2>/dev/null || true
    fi

    # 3. MiddlewareJSON
    if [[ -n "$DETECTED_MW" ]]; then
        log "Сбор MiddlewareJSON..."
        mkdir -p "$staging/mw"
        if [[ -f "$DETECTED_MW/.env" ]]; then
            cp -a "$DETECTED_MW/.env" "$staging/mw/.env"
        fi
        if [[ -f "$DETECTED_MW/data/middleware.db" ]]; then
            mkdir -p "$staging/mw/data"
            if command -v sqlite3 >/dev/null 2>&1; then
                sqlite3 "$DETECTED_MW/data/middleware.db" ".backup '$staging/mw/data/middleware.db'"
            else
                cp -a "$DETECTED_MW/data/middleware.db"* "$staging/mw/data/" 2>/dev/null || true
            fi
        fi
        rsync -a --exclude=".venv" --exclude="__pycache__" --exclude=".git" --exclude="data" \
            "$DETECTED_MW/" "$staging/mw/app/" 2>/dev/null || true
    fi

    # 4. Nginx (строго конфиги)
    if [[ "$DETECTED_NGINX" == "true" ]]; then
        log "Сбор конфигурации Nginx (только nginx.conf и conf.d/*)..."
        mkdir -p "$staging/nginx/conf.d"
        [[ -f "/etc/nginx/nginx.conf" ]] && cp -a "/etc/nginx/nginx.conf" "$staging/nginx/"
        [[ -d "/etc/nginx/conf.d" ]] && cp -a /etc/nginx/conf.d/* "$staging/nginx/conf.d/" 2>/dev/null || true
    fi

    # 5. Copyparty
    if [[ -n "$DETECTED_COPYPARTY" ]]; then
        log "Сбор Copyparty ($DETECTED_COPYPARTY)..."
        mkdir -p "$staging/copyparty"
        rsync -a "$DETECTED_COPYPARTY/" "$staging/copyparty/" 2>/dev/null || true
    fi

    log "Упаковка архива $target_archive..."
    mkdir -p "$(dirname "$target_archive")"
    tar -czf "$target_archive" -C "$staging" .
    rm -rf "$staging"

    ok "Архив успешно создан: $target_archive ($(du -h "$target_archive" | cut -f1))"
}

# ── 4. Установка всех зависимостей на чистом Debian 13 (Trixie) ───────────────
install_system_dependencies() {
    log "Установка системных зависимостей (Debian 13 Trixie)..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # 1. Системные утилиты и библиотеки Python
    log "1/5. Системные пакеты (curl, git, rsync, sqlite3, python3-venv)..."
    apt-get install -y -qq \
        curl wget git rsync tar gzip bzip2 xz-utils sudo \
        ca-certificates gnupg lsb-release procps net-tools ufw \
        sqlite3 jq \
        python3 python3-venv python3-pip python3-dev \
        build-essential libffi-dev libssl-dev

    # 2. Redis
    log "2/5. Redis-server..."
    apt-get install -y -qq redis-server
    systemctl enable --now redis-server || true

    # 3. Nginx и stream модуль (Служба СРАЗУ останавливается!)
    log "3/5. Nginx + libnginx-mod-stream (с немедленной остановкой для 80 порта)..."
    apt-get install -y -qq nginx libnginx-mod-stream certbot python3-certbot-nginx
    systemctl stop nginx 2>/dev/null || true

    # 4. Docker и Docker Compose через get.docker.com
    log "4/5. Docker & Docker Compose..."
    if ! command -v docker >/dev/null 2>&1; then
        local docker_sh
        docker_sh="$(mktemp /tmp/get-docker-XXXXXX.sh)"
        if curl -fsSL https://get.docker.com -o "$docker_sh"; then
            sh "$docker_sh" >/dev/null 2>&1 || true
            rm -f "$docker_sh"
        else
            warn "get.docker.com недоступен, пробуем установку из apt..."
            apt-get install -y -qq docker.io docker-compose-v2 || true
        fi
    fi
    systemctl enable --now docker || true

    # 5. Оптимизация сети (BBR)
    log "5/5. Проверка сетевого тюнинга BBR..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        {
            echo "net.core.default_qdisc=fq"
            echo "net.ipv4.tcp_congestion_control=bbr"
        } >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
    fi

    ok "Все системные зависимости установлены."
}

# ── 5. Развёртывание из архива (UNPACK) ────────────────────────────────────────
unpack_and_deploy() {
    local source_archive="$1"
    [[ -f "$source_archive" ]] || die "Архив не найден: $source_archive"

    local staging
    staging="$(mktemp -d /tmp/caelix_unpack_XXXXXX)"
    chmod 700 "$staging"

    log "Распаковка бандла $source_archive..."
    tar -xzf "$source_archive" -C "$staging"

    local manifest="$staging/meta/manifest.env"
    [[ -f "$manifest" ]] || die "В архиве отсутствует манифест meta/manifest.env!"

    # shellcheck source=/dev/null
    source "$manifest"
    ok "Манифест прочитан (создан $PACKED_AT)"

    # 1. Зависимости
    install_system_dependencies

    # 2. Пользователь vpnbot
    if [[ "${HAS_BOT:-false}" == "true" ]]; then
        if ! id -u vpnbot >/dev/null 2>&1; then
            log "Создание системного пользователя vpnbot..."
            useradd -r -m -d /opt/vpn-bot -s /bin/bash vpnbot || true
        fi
        cat << 'EOF' > /etc/sudoers.d/vpn-bot-restart
vpnbot ALL=(ALL) NOPASSWD: /bin/systemctl restart vpn-bot-web vpn-bot-telegram, /bin/systemctl restart vpn-bot-web, /bin/systemctl restart vpn-bot-telegram
EOF
        chmod 440 /etc/sudoers.d/vpn-bot-restart
    fi

    # 3. Nginx конфиги (служба остаётся выключенной)
    if [[ "${HAS_NGINX:-false}" == "true" && -d "$staging/nginx" ]]; then
        log "Раскладка конфигурации Nginx..."
        mkdir -p /etc/nginx/conf.d
        [[ -f "$staging/nginx/nginx.conf" ]] && cp -a "$staging/nginx/nginx.conf" /etc/nginx/
        [[ -d "$staging/nginx/conf.d" ]] && cp -a "$staging/nginx/conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true

        log "Проверка синтаксиса Nginx (nginx -t)..."
        nginx -t 2>/dev/null || warn "nginx -t сообщил о замечаниях (сертификаты /root/cert будут созданы после мастера 3x-ui)."
        systemctl stop nginx 2>/dev/null || true
        ok "Конфиги Nginx разложены. Служба Nginx выключена для освобождения 80 порта."
    fi

    # 4. Copyparty
    if [[ "${HAS_COPYPARTY:-false}" == "true" && -d "$staging/copyparty" ]]; then
        log "Восстановление Copyparty в /opt/copyparty..."
        mkdir -p /opt/copyparty
        rsync -a "$staging/copyparty/" /opt/copyparty/

        if [[ -f "/opt/copyparty/docker-compose.yml" ]]; then
            log "Запуск Copyparty через Docker Compose..."
            (
                cd /opt/copyparty
                if docker compose version >/dev/null 2>&1; then
                    docker compose up -d
                elif command -v docker-compose >/dev/null 2>&1; then
                    docker-compose up -d
                fi
            )
            ok "Copyparty успешно запущен в Docker"
        fi
    fi

    # 5. MiddlewareJSON
    if [[ "${HAS_MW:-false}" == "true" && -d "$staging/mw" ]]; then
        log "Восстановление MiddlewareJSON в /opt/middlewarejson..."
        mkdir -p /opt/middlewarejson
        [[ -d "$staging/mw/app" ]] && rsync -a "$staging/mw/app/" /opt/middlewarejson/
        [[ -f "$staging/mw/.env" ]] && cp -a "$staging/mw/.env" /opt/middlewarejson/.env
        if [[ -d "$staging/mw/data" ]]; then
            mkdir -p /opt/middlewarejson/data
            rsync -a "$staging/mw/data/" /opt/middlewarejson/data/
        fi

        log "Настройка Python .venv для MiddlewareJSON..."
        [[ ! -d "/opt/middlewarejson/.venv" ]] && python3 -m venv /opt/middlewarejson/.venv
        if [[ -f "/opt/middlewarejson/requirements.txt" ]]; then
            /opt/middlewarejson/.venv/bin/pip install --upgrade pip -q 2>/dev/null || true
            /opt/middlewarejson/.venv/bin/pip install -r /opt/middlewarejson/requirements.txt -q
        fi

        cat << 'EOF' > /etc/systemd/system/middlewarejson.service
[Unit]
Description=CaelixFlow MiddlewareJSON Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/middlewarejson
ExecStart=/opt/middlewarejson/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8080
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now middlewarejson || true
        ok "MiddlewareJSON запущен"
    fi

    # 6. Vpn-Website
    if [[ "${HAS_WEB:-false}" == "true" && -d "$staging/web" ]]; then
        log "Восстановление Vpn-Website в /opt/vpn-website..."
        mkdir -p /opt/vpn-website
        [[ -d "$staging/web/app" ]] && rsync -a "$staging/web/app/" /opt/vpn-website/
        [[ -f "$staging/web/.env" ]] && cp -a "$staging/web/.env" /opt/vpn-website/.env

        log "Настройка Python .venv для Vpn-Website..."
        [[ ! -d "/opt/vpn-website/.venv" ]] && python3 -m venv /opt/vpn-website/.venv
        if [[ -f "/opt/vpn-website/requirements.txt" ]]; then
            /opt/vpn-website/.venv/bin/pip install --upgrade pip -q 2>/dev/null || true
            /opt/vpn-website/.venv/bin/pip install -r /opt/vpn-website/requirements.txt -q
        fi

        cat << 'EOF' > /etc/systemd/system/vpn-website.service
[Unit]
Description=CaelixFlow VPN Website & User Cabinet
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vpn-website
ExecStart=/opt/vpn-website/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8090
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now vpn-website || true
        ok "Vpn-Website запущен"
    fi

    # 7. Vpn-Bot
    if [[ "${HAS_BOT:-false}" == "true" && -d "$staging/bot" ]]; then
        log "Восстановление Vpn-Bot в /opt/vpn-bot..."
        mkdir -p /opt/vpn-bot
        [[ -d "$staging/bot/app" ]] && rsync -a "$staging/bot/app/" /opt/vpn-bot/
        [[ -f "$staging/bot/.env" ]] && cp -a "$staging/bot/.env" /opt/vpn-bot/.env
        if [[ -d "$staging/bot/data" ]]; then
            mkdir -p /opt/vpn-bot/data
            rsync -a "$staging/bot/data/" /opt/vpn-bot/data/
        fi

        log "Настройка Python .venv для Vpn-Bot..."
        [[ ! -d "/opt/vpn-bot/.venv" ]] && python3 -m venv /opt/vpn-bot/.venv
        if [[ -f "/opt/vpn-bot/requirements.txt" ]]; then
            /opt/vpn-bot/.venv/bin/pip install --upgrade pip -q 2>/dev/null || true
            /opt/vpn-bot/.venv/bin/pip install -r /opt/vpn-bot/requirements.txt -q
        fi

        chown -R vpnbot:vpnbot /opt/vpn-bot
        chmod 600 /opt/vpn-bot/.env 2>/dev/null || true

        cat << 'EOF' > /etc/systemd/system/vpn-bot-telegram.service
[Unit]
Description=VPN Bot Telegram Polling & Scheduler
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User=vpnbot
WorkingDirectory=/opt/vpn-bot
ExecStart=/opt/vpn-bot/.venv/bin/python run_bot.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

        cat << 'EOF' > /etc/systemd/system/vpn-bot-web.service
[Unit]
Description=VPN Bot Webhook & Fulfillment Server
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User=vpnbot
WorkingDirectory=/opt/vpn-bot
ExecStart=/opt/vpn-bot/.venv/bin/python app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now vpn-bot-web vpn-bot-telegram || true
        ok "Vpn-Bot запущен"
    fi

    rm -rf "$staging"
    echo
    ok "=========================================================="
    ok "  Все перенесённые службы успешно развёрнуты и запущены!  "
    ok "=========================================================="

    prompt_3xui_installation
}

# ── 6. Интерактивный опрос и запуск мастера 3x-ui ───────────────────────────
prompt_3xui_installation() {
    printf '\n%s?%s %sНачать установку 3x-ui прямо сейчас?%s %s[y/N]%s: ' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"

    local answer=""
    if [[ -r /dev/tty ]]; then
        read -r answer < /dev/tty || true
    else
        read -r answer || true
    fi

    case "${answer:-N}" in
        [yY]|[yY][eE][sS]|[дД]|[дД][аА])
            log "Запуск официального мастера 3x-ui (порт 80 свободен)..."
            echo
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
            ;;
        *)
            log "Пропуск установки 3x-ui. Вы можете запустить её позже командой:"
            printf '  %sbash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)%s\n\n' "$C_GREEN" "$C_RESET"
            ;;
    esac
}

# ── 7. Перенос Server-to-Server по SSH (PUSH) ────────────────────────────────
push_to_target() {
    local target_ssh="${1:-}"
    if [[ -z "$target_ssh" ]]; then
        printf '%s? Введите SSH адрес целевого сервера (например, root@194.87.1.2): %s' "$C_CYAN" "$C_RESET"
        read -r target_ssh || true
    fi
    [[ -n "$target_ssh" ]] || die "SSH-адрес сервера не указан."

    log "Запуск прямого переноса НА $target_ssh..."
    scan_components

    local tmp_archive="/tmp/caelix_transfer_$(date +%s).tar.gz"
    pack_components "$tmp_archive"

    log "Копирование скрипта и архива на $target_ssh..."
    scp -o StrictHostKeyChecking=accept-new "$0" "${target_ssh}:/tmp/migrate.sh"
    scp -o StrictHostKeyChecking=accept-new "$tmp_archive" "${target_ssh}:/tmp/caelix-bundle.tar.gz"
    rm -f "$tmp_archive"

    log "Запуск развёртывания на $target_ssh..."
    ssh -t -o StrictHostKeyChecking=accept-new "$target_ssh" "sudo bash /tmp/migrate.sh unpack /tmp/caelix-bundle.tar.gz"

    ok "Миграция на $target_ssh успешно завершена!"
}

# ── 8. Забор данных со старого сервера по SSH (PULL) ─────────────────────────
pull_from_source() {
    local source_ssh="${1:-}"
    if [[ -z "$source_ssh" ]]; then
        printf '%s? Введите SSH адрес старого сервера (например, root@194.87.1.2): %s' "$C_CYAN" "$C_RESET"
        read -r source_ssh || true
    fi
    [[ -n "$source_ssh" ]] || die "SSH-адрес сервера не указан."

    log "Подключение к старому серверу $source_ssh для сбора данных..."
    scp -o StrictHostKeyChecking=accept-new "$0" "${source_ssh}:/tmp/migrate.sh"
    ssh -t -o StrictHostKeyChecking=accept-new "$source_ssh" "sudo bash /tmp/migrate.sh pack /tmp/caelix-source-bundle.tar.gz"

    local local_archive="/tmp/caelix-bundle.tar.gz"
    log "Загрузка архива со старого сервера..."
    scp -o StrictHostKeyChecking=accept-new "${source_ssh}:/tmp/caelix-source-bundle.tar.gz" "$local_archive"
    ssh -o StrictHostKeyChecking=accept-new "$source_ssh" "rm -f /tmp/migrate.sh /tmp/caelix-source-bundle.tar.gz" 2>/dev/null || true

    log "Начало развёртывания на текущем сервере..."
    unpack_and_deploy "$local_archive"
    rm -f "$local_archive"
}

# ── 9. Интерактивное главное меню ─────────────────────────────────────────────
interactive_menu() {
    banner
    printf '  %s1)%s  %s[PUSH]%s   Перенести этот сервер НА другой (указать IP)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s2)%s  %s[PULL]%s   Забрать данные СО старого сервера (указать IP)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s3)%s  %s[PACK]%s   Создать локальный .tar.gz архив (бэкап)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s4)%s  %s[UNPACK]%s Развернуть систему из локального архива\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s5)%s  %s[SCAN]%s   Проверить, что будет перенесено (Dry Run, только аудит)\n\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s0)%s  Выход\n\n' "$C_DIM" "$C_RESET"

    local choice=""
    printf '%sВыберите действие [0-5]: %s' "$C_BOLD" "$C_RESET"
    if [[ -r /dev/tty ]]; then
        read -r choice < /dev/tty || true
    else
        read -r choice || true
    fi

    case "${choice:-0}" in
        1) push_to_target ;;
        2) pull_from_source ;;
        3)
            local out=""
            printf '%sПуть для архива [/root/caelix-migration-%s.tar.gz]: %s' "$C_CYAN" "$(date +%Y%m%d_%H%M%S)" "$C_RESET"
            read -r out || true
            [[ -z "$out" ]] && out="/root/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz"
            scan_components
            pack_components "$out"
            ;;
        4)
            local in_file=""
            local latest_default
            latest_default="$(find /root /tmp -maxdepth 2 -name "caelix-*.tar.gz" 2>/dev/null | head -1 || true)"
            printf '%sПуть к архиву [%s]: %s' "$C_CYAN" "${latest_default:-/root/backup.tar.gz}" "$C_RESET"
            read -r in_file || true
            [[ -z "$in_file" ]] && in_file="$latest_default"
            unpack_and_deploy "$in_file"
            ;;
        5) run_scan_audit ;;
        0) echo "Выход."; exit 0 ;;
        *) warn "Неверный выбор."; exit 1 ;;
    esac
}

# ── 10. Точка входа ───────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        push)
            ensure_root
            banner
            push_to_target "${1:-}"
            ;;
        pull)
            ensure_root
            banner
            pull_from_source "${1:-}"
            ;;
        pack)
            ensure_root
            banner
            scan_components
            pack_components "${1:-/tmp/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz}"
            ;;
        unpack)
            ensure_root
            banner
            unpack_and_deploy "${1:-}"
            ;;
        scan)
            banner
            if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                warn "Скрипт запущен без прав root. Некоторые пути могут быть недоступны для проверки."
            fi
            run_scan_audit
            ;;
        ""|-h|--help)
            ensure_root
            interactive_menu
            ;;
        *)
            banner
            err "Неизвестная команда: $cmd"
            echo "Использование: sudo bash $0 [push|pull|pack|unpack|scan]"
            exit 1
            ;;
    esac
}

main "$@"
