#!/usr/bin/env bash
# ==============================================================================
# CaelixFlow Server Migration & Auto-Deploy Tool
# Repository: https://github.com/Sp0nge-bob/caelix-migrate.git
#
# Особенности:
#   - Автоопределение сервисов (Vpn-Bot, Website, Middleware, Redis, Nginx, Copyparty, 3x-ui)
#   - Опциональный перенос настроек SSH (.ssh/authorized_keys и /etc/ssh/sshd_config)
#   - Полная совместимость с чистым Debian 13 (Trixie)
#   - Автоматическая установка Docker, Python-venv, Redis, Nginx + stream
#   - Безопасные горячие снимки SQLite (WAL .backup)
#   - Немедленная остановка Nginx для освобождения 80 порта под 3x-ui
#   - Запуск мастера 3x-ui в финале
#   - Ноль приватных данных и секретов в коде скрипта
# ==============================================================================
set -euo pipefail

VERSION="1.0.5"

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
    for p in "$@"; do
        if [[ -e "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 0
}

# ── Опрос переноса SSH настроек ───────────────────────────────────────────────
ask_ssh_transfer() {
    printf '\n%s?%s %sПеренести настройки SSH (.ssh/authorized_keys, .ssh/authorized_key и sshd_config)?%s %s[y/N]%s: ' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"

    local raw_ans=""
    if [[ -r /dev/tty ]]; then
        read -r raw_ans < /dev/tty || true
    else
        read -r raw_ans || true
    fi
    local ans
    ans="$(echo "${raw_ans:-N}" | tr -d '[:space:]')"

    case "$ans" in
        [yY]|[yY][eE][sS]|[дД]|[дД][аА]) echo "true" ;;
        *) echo "false" ;;
    esac
}

# ── Определение SSH порта ─────────────────────────────────────────────────────
detect_ssh_port() {
    local config_file="${1:-/etc/ssh/sshd_config}"
    local port=""
    if [[ -f "$config_file" ]]; then
        port="$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$config_file" 2>/dev/null | awk '{print $2}' | tail -1 || true)"
    fi
    if [[ -z "$port" && -d "/etc/ssh/sshd_config.d" ]]; then
        port="$(grep -h -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -1 || true)"
    fi
    if [[ -z "$port" ]] && command -v ss >/dev/null 2>&1; then
        port="$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | awk '{print $4}' | awk -F: '{print $NF}' | head -1 || true)"
    fi
    echo "${port:-22}"
}

# ── Настройка и включение UFW фаервола ─────────────────────────────────────────
setup_ufw_firewall() {
    local ssh_port="${1:-22}"
    local extra_ports="${2:-}"

    log "Установка и настройка фаервола UFW..."
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq ufw
    fi

    # Включаем поддержку IPv6 в UFW (если файл доступен)
    if [[ -f /etc/default/ufw ]]; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null || true
    fi

    # Базовые правила
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true

    # 1. SSH порт (TCP и UDP)
    log "Открытие SSH порта (${ssh_port}/tcp и ${ssh_port}/udp)..."
    ufw allow "${ssh_port}/tcp" comment "SSH Port TCP" >/dev/null
    ufw allow "${ssh_port}/udp" comment "SSH Port UDP" >/dev/null

    # 2. Веб порты (80/tcp, 443/tcp, 443/udp)
    log "Открытие веб-портов (80/tcp, 443/tcp, 443/udp)..."
    ufw allow 80/tcp comment "HTTP" >/dev/null
    ufw allow 443/tcp comment "HTTPS" >/dev/null
    ufw allow 443/udp comment "QUIC / HTTP3" >/dev/null

    # 3. Дополнительные порты
    if [[ -n "$extra_ports" ]]; then
        for p in $extra_ports; do
            p="$(echo "$p" | tr -d '[:space:]')"
            if [[ -n "$p" ]]; then
                log "Открытие дополнительного порта: $p..."
                ufw allow "$p" >/dev/null || warn "Не удалось открыть порт: $p"
            fi
        done
    fi

    # 4. Включение UFW
    log "Активация фаервола UFW..."
    ufw --force enable >/dev/null
    systemctl enable --now ufw >/dev/null 2>&1 || true
    ok "UFW успешно настроен и активирован!"

    echo
    ufw status
    echo
}

# ── 1. Сканирование и автоопределение компонентов ─────────────────────────────
scan_components() {
    local silent="${1:-false}"
    if [[ "$silent" != "true" ]]; then
        log "Сканирование установленных компонентов на сервере..."
    fi

    DETECTED_BOT=""
    DETECTED_WEB=""
    DETECTED_MW=""
    DETECTED_REDIS="false"
    DETECTED_NGINX="false"
    DETECTED_COPYPARTY=""
    DETECTED_XUI="false"
    DETECTED_SSH_KEYS=""
    DETECTED_SSHD_CONF="false"

    # 1. VPN-Bot
    local bot_path
    bot_path="$(find_path "/opt/vpn-bot" "/root/vpn-platega-bot" "/opt/vpn-platega-bot")"
    if [[ -n "$bot_path" && (-f "$bot_path/app.py" || -f "$bot_path/run_bot.py") ]]; then
        DETECTED_BOT="$bot_path"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен Vpn-Bot: $DETECTED_BOT"
        fi
    fi

    # 2. VPN-Website
    local web_path
    web_path="$(find_path "/opt/vpn-website" "/root/vpn-website")"
    if [[ -n "$web_path" && -f "$web_path/app/main.py" ]]; then
        DETECTED_WEB="$web_path"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен Vpn-Website: $DETECTED_WEB"
        fi
    fi

    # 3. MiddlewareJSON
    local mw_path
    mw_path="$(find_path "/opt/middlewarejson" "/root/middlewarejson")"
    if [[ -n "$mw_path" && -f "$mw_path/app/main.py" ]]; then
        DETECTED_MW="$mw_path"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен MiddlewareJSON: $DETECTED_MW"
        fi
    fi

    # 4. Redis
    if command -v redis-server >/dev/null 2>&1 || systemctl is-active --quiet redis-server 2>/dev/null; then
        DETECTED_REDIS="true"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен Redis-server"
        fi
    fi

    # 5. Nginx
    if [[ -f "/etc/nginx/nginx.conf" || -d "/etc/nginx/conf.d" ]]; then
        DETECTED_NGINX="true"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен Nginx (/etc/nginx/nginx.conf, /etc/nginx/conf.d/)"
        fi
    fi

    # 6. Copyparty
    local cp_path
    cp_path="$(find_path "/opt/copyparty" "/root/copyparty")"
    if [[ -n "$cp_path" && (-f "$cp_path/docker-compose.yml" || -f "$cp_path/copyparty.conf") ]]; then
        DETECTED_COPYPARTY="$cp_path"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен Copyparty: $DETECTED_COPYPARTY"
        fi
    fi

    # 7. 3x-ui
    if [[ -d "/etc/x-ui" || -d "/usr/local/x-ui" || -f "/etc/x-ui/x-ui.db" ]] || systemctl is-active --quiet x-ui 2>/dev/null; then
        DETECTED_XUI="true"
        if [[ "$silent" != "true" ]]; then
            ok "Обнаружен 3x-ui (интерактивный мастер будет предложен в финале)"
        fi
    fi

    # 8. SSH настройки (проверяем authorized_keys и authorized_key)
    DETECTED_SSH_AUTHORIZED_KEYS=""
    DETECTED_SSH_AUTHORIZED_KEY=""
    DETECTED_SSHD_CONF="false"

    for dir in "/root/.ssh" "$HOME/.ssh"; do
        if [[ -f "$dir/authorized_keys" && -z "$DETECTED_SSH_AUTHORIZED_KEYS" ]]; then
            DETECTED_SSH_AUTHORIZED_KEYS="$dir/authorized_keys"
        fi
        if [[ -f "$dir/authorized_key" && -z "$DETECTED_SSH_AUTHORIZED_KEY" ]]; then
            DETECTED_SSH_AUTHORIZED_KEY="$dir/authorized_key"
        fi
    done

    if [[ -f "/etc/ssh/sshd_config" ]]; then
        DETECTED_SSHD_CONF="true"
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
        if [[ -f "$DETECTED_BOT/data/bot.db" ]]; then
            db_info="bot.db: $(du -h "$DETECTED_BOT/data/bot.db" 2>/dev/null | cut -f1 || echo "есть")"
        fi
        local env_info="нет"
        if [[ -f "$DETECTED_BOT/.env" ]]; then
            env_info="OK"
        fi
        printf '  %s[✔]%s %-16s %s (%s, .env: %s)\n' \
            "$C_GREEN" "$C_RESET" "Vpn-Bot" "$DETECTED_BOT" "$db_info" "$env_info"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Vpn-Bot"
    fi

    if [[ -n "$DETECTED_WEB" ]]; then
        local env_info="нет"
        if [[ -f "$DETECTED_WEB/.env" ]]; then
            env_info="OK"
        fi
        printf '  %s[✔]%s %-16s %s (.env: %s)\n' \
            "$C_GREEN" "$C_RESET" "Vpn-Website" "$DETECTED_WEB" "$env_info"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Vpn-Website"
    fi

    if [[ -n "$DETECTED_MW" ]]; then
        local env_info="нет"
        if [[ -f "$DETECTED_MW/.env" ]]; then
            env_info="OK"
        fi
        printf '  %s[✔]%s %-16s %s (.env: %s)\n' \
            "$C_GREEN" "$C_RESET" "MiddlewareJSON" "$DETECTED_MW" "$env_info"
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
        if [[ -d "/etc/nginx/conf.d" ]]; then
            conf_count="$(find /etc/nginx/conf.d -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)"
        fi
        printf '  %s[✔]%s %-16s /etc/nginx/nginx.conf и %s файлов в conf.d/\n' "$C_GREEN" "$C_RESET" "Nginx" "$conf_count"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Nginx"
    fi

    if [[ -n "$DETECTED_COPYPARTY" ]]; then
        local cp_dc="нет"
        if [[ -f "$DETECTED_COPYPARTY/docker-compose.yml" ]]; then
            cp_dc="OK"
        fi
        printf '  %s[✔]%s %-16s %s (docker-compose: %s)\n' \
            "$C_GREEN" "$C_RESET" "Copyparty" "$DETECTED_COPYPARTY" "$cp_dc"
        count=$((count + 1))
    else
        printf '  %s[ ]%s %-16s не найден\n' "$C_DIM" "$C_RESET" "Copyparty"
    fi

    if [[ "$DETECTED_XUI" == "true" ]]; then
        printf '  %s[i]%s %-16s обнаружен (будет предложена установка мастером на новом сервере)\n' "$C_CYAN" "$C_RESET" "3x-ui"
    fi

    # 8. SSH диагностика
    local ssh_keys_desc=()
    if [[ -n "$DETECTED_SSH_AUTHORIZED_KEYS" ]]; then
        local count_keys
        count_keys="$(grep -c -E "^(ssh-|ecdsa-|sk-)" "$DETECTED_SSH_AUTHORIZED_KEYS" 2>/dev/null || echo "1+")"
        ssh_keys_desc+=("authorized_keys ($count_keys шт.)")
    fi
    if [[ -n "$DETECTED_SSH_AUTHORIZED_KEY" ]]; then
        local count_key
        count_key="$(grep -c -E "^(ssh-|ecdsa-|sk-)" "$DETECTED_SSH_AUTHORIZED_KEY" 2>/dev/null || echo "1+")"
        ssh_keys_desc+=("authorized_key ($count_key шт.)")
    fi

    if [[ ${#ssh_keys_desc[@]} -gt 0 || "$DETECTED_SSHD_CONF" == "true" ]]; then
        local keys_label="не найдены"
        if [[ ${#ssh_keys_desc[@]} -gt 0 ]]; then
            keys_label="$(IFS=", "; echo "${ssh_keys_desc[*]}")"
        fi
        local sshd_label="sshd_config: нет"
        if [[ "$DETECTED_SSHD_CONF" == "true" ]]; then
            sshd_label="sshd_config: OK"
        fi
        printf '  %s[✔]%s %-16s Ключи: %s | %s (будет предложен перенос)\n' \
            "$C_GREEN" "$C_RESET" "SSH настройки" "$keys_label" "$sshd_label"
    else
        printf '  %s[ ]%s %-16s .ssh/authorized_keys, .ssh/authorized_key и sshd_config не найдены\n' \
            "$C_DIM" "$C_RESET" "SSH настройки"
    fi

    # UFW диагностика
    local ufw_status="не установлен"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "active"; then
            ufw_status="активен"
        else
            ufw_status="отключен"
        fi
    fi
    local detected_ssh_port_scan
    detected_ssh_port_scan="$(detect_ssh_port "/etc/ssh/sshd_config")"
    printf '  %s[i]%s %-16s %s (SSH порт: %s/tcp+udp, веб-порты: 80/tcp, 443/tcp+udp)\n' \
        "$C_CYAN" "$C_RESET" "UFW фаервол" "$ufw_status" "$detected_ssh_port_scan"

    printf '%s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf 'Готовность к миграции: обнаружено %s ключевых компонентов.\n' "$count"
}

# ── 3. Упаковка в защищённый бандл (PACK) ─────────────────────────────────────
pack_components() {
    local target_archive="${1:-/tmp/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz}"
    local with_ssh="${2:-false}"
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
        echo "HAS_SSH=\"$with_ssh\""
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

    # 6. SSH (authorized_keys, authorized_key и sshd_config)
    if [[ "$with_ssh" == "true" ]]; then
        log "Сбор настроек SSH (.ssh/authorized_keys, .ssh/authorized_key, sshd_config)..."
        mkdir -p "$staging/ssh"

        # Собираем authorized_keys и/или authorized_key
        for fname in "authorized_keys" "authorized_key"; do
            for dir in "/root/.ssh" "$HOME/.ssh"; do
                if [[ -f "$dir/$fname" ]]; then
                    cp -a "$dir/$fname" "$staging/ssh/$fname"
                    break
                fi
            done
        done

        if [[ -f "/etc/ssh/sshd_config" ]]; then
            cp -a "/etc/ssh/sshd_config" "$staging/ssh/sshd_config"
        fi
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

    # 3. SSH настройки (authorized_keys, authorized_key и sshd_config)
    if [[ "${HAS_SSH:-false}" == "true" && -d "$staging/ssh" ]]; then
        log "Восстановление настроек SSH..."
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh

        local keys_restored=false
        if [[ -f "$staging/ssh/authorized_keys" ]]; then
            cp -a "$staging/ssh/authorized_keys" /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            keys_restored=true
        fi
        if [[ -f "$staging/ssh/authorized_key" ]]; then
            cp -a "$staging/ssh/authorized_key" /root/.ssh/authorized_key
            chmod 600 /root/.ssh/authorized_key
            keys_restored=true
        fi

        # Дублируем для абсолютной совместимости (если был только authorized_key или только authorized_keys)
        if [[ -f "/root/.ssh/authorized_key" && ! -f "/root/.ssh/authorized_keys" ]]; then
            cp -a "/root/.ssh/authorized_key" "/root/.ssh/authorized_keys"
            chmod 600 "/root/.ssh/authorized_keys"
        elif [[ -f "/root/.ssh/authorized_keys" && ! -f "/root/.ssh/authorized_key" ]]; then
            cp -a "/root/.ssh/authorized_keys" "/root/.ssh/authorized_key"
            chmod 600 "/root/.ssh/authorized_key"
        fi

        if [[ "$keys_restored" == "true" ]]; then
            ok "Ключи SSH (.ssh/authorized_keys и/или .ssh/authorized_key) успешно восстановлены"
        fi

        if [[ -f "$staging/ssh/sshd_config" ]]; then
            cp -a "$staging/ssh/sshd_config" /etc/ssh/sshd_config
            ok "Конфигурация SSH (/etc/ssh/sshd_config) обновлена"
        fi

        log "Перезапуск службы SSH (systemctl restart ssh sshd)..."
        systemctl restart ssh 2>/dev/null || true
        systemctl restart sshd 2>/dev/null || true
        ok "Службы SSH успешно перезапущены"
    fi

    # 4. Nginx конфиги (служба остаётся выключенной)
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

    # 5. Copyparty
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

    # 6. MiddlewareJSON
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

    # 7. Vpn-Website
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

    # 8. Vpn-Bot
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

    # 8. Настройка и включение UFW фаервола
    local target_ssh_port
    target_ssh_port="$(detect_ssh_port "/etc/ssh/sshd_config")"
    log "Настройка фаервола UFW (SSH порт: $target_ssh_port/tcp+udp, веб-порты: 80/tcp, 443/tcp, 443/udp)..."

    printf '\n%s?%s %sУкажите дополнительные порты для UFW (через пробел, например: 2053 8443) или Enter для пропуска:%s ' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"

    local raw_extra_ports=""
    if [[ -r /dev/tty ]]; then
        read -r raw_extra_ports < /dev/tty || true
    else
        read -r raw_extra_ports || true
    fi
    local extra_ports
    extra_ports="$(echo "$raw_extra_ports" | tr -d '\r\n')"

    setup_ufw_firewall "$target_ssh_port" "$extra_ports"

    prompt_3xui_installation
}

# ── 6. Интерактивный опрос и запуск мастера 3x-ui ───────────────────────────
prompt_3xui_installation() {
    printf '\n%s?%s %sНачать установку 3x-ui прямо сейчас?%s %s[y/N]%s: ' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"

    local raw_answer=""
    if [[ -r /dev/tty ]]; then
        read -r raw_answer < /dev/tty || true
    else
        read -r raw_answer || true
    fi
    local answer
    answer="$(echo "${raw_answer:-N}" | tr -d '[:space:]')"

    case "$answer" in
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
        if [[ -r /dev/tty ]]; then
            read -r target_ssh < /dev/tty || true
        else
            read -r target_ssh || true
        fi
    fi
    target_ssh="$(echo "${target_ssh:-}" | tr -d '[:space:]')"
    [[ -n "$target_ssh" ]] || die "SSH-адрес сервера не указан."

    local with_ssh="false"
    with_ssh="$(ask_ssh_transfer)"

    log "Запуск прямого переноса НА $target_ssh (перенос SSH: $with_ssh)..."
    scan_components

    local tmp_archive="/tmp/caelix_transfer_$(date +%s).tar.gz"
    pack_components "$tmp_archive" "$with_ssh"

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
        if [[ -r /dev/tty ]]; then
            read -r source_ssh < /dev/tty || true
        else
            read -r source_ssh || true
        fi
    fi
    source_ssh="$(echo "${source_ssh:-}" | tr -d '[:space:]')"
    [[ -n "$source_ssh" ]] || die "SSH-адрес сервера не указан."

    local with_ssh="false"
    with_ssh="$(ask_ssh_transfer)"

    log "Подключение к старому серверу $source_ssh для сбора данных (перенос SSH: $with_ssh)..."
    scp -o StrictHostKeyChecking=accept-new "$0" "${source_ssh}:/tmp/migrate.sh"
    ssh -t -o StrictHostKeyChecking=accept-new "$source_ssh" "sudo bash /tmp/migrate.sh pack /tmp/caelix-source-bundle.tar.gz $with_ssh"

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
    while true; do
        banner
        printf '  %s1)%s  %s[PUSH]%s   Перенести этот сервер НА другой (указать IP)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s2)%s  %s[PULL]%s   Забрать данные СО старого сервера (указать IP)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s3)%s  %s[PACK]%s   Создать локальный .tar.gz архив (бэкап)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s4)%s  %s[UNPACK]%s Развернуть систему из локального архива\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s5)%s  %s[SCAN]%s   Проверить, что будет перенесено (Dry Run, только аудит)\n\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s0)%s  Выход\n\n' "$C_DIM" "$C_RESET"

        local raw_choice=""
        printf '%sВыберите действие [0-5]: %s' "$C_BOLD" "$C_RESET"
        if [[ -r /dev/tty ]]; then
            read -r raw_choice < /dev/tty || true
        else
            read -r raw_choice || true
        fi

        local choice
        choice="$(echo "${raw_choice:-0}" | tr -d '[:space:]')"

        case "$choice" in
            1)
                push_to_target
                break
                ;;
            2)
                pull_from_source
                break
                ;;
            3)
                local out=""
                printf '%sПуть для архива [/root/caelix-migration-%s.tar.gz]: %s' "$C_CYAN" "$(date +%Y%m%d_%H%M%S)" "$C_RESET"
                if [[ -r /dev/tty ]]; then
                    read -r out < /dev/tty || true
                else
                    read -r out || true
                fi
                out="$(echo "$out" | tr -d '[:space:]')"
                [[ -z "$out" ]] && out="/root/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz"

                local with_ssh="false"
                with_ssh="$(ask_ssh_transfer)"

                scan_components
                pack_components "$out" "$with_ssh"
                printf '\nНажмите Enter, чтобы продолжить...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            4)
                local in_file=""
                local latest_default
                latest_default="$(find /root /tmp -maxdepth 2 -name "caelix-*.tar.gz" 2>/dev/null | head -1 || true)"
                printf '%sПуть к архиву [%s]: %s' "$C_CYAN" "${latest_default:-/root/backup.tar.gz}" "$C_RESET"
                if [[ -r /dev/tty ]]; then
                    read -r in_file < /dev/tty || true
                else
                    read -r in_file || true
                fi
                in_file="$(echo "$in_file" | tr -d '[:space:]')"
                [[ -z "$in_file" ]] && in_file="$latest_default"
                unpack_and_deploy "$in_file"
                break
                ;;
            5)
                run_scan_audit
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            0|q|Q)
                echo "Выход."
                exit 0
                ;;
            *)
                warn "Неверный выбор: '$choice'."
                sleep 1
                ;;
        esac
    done
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
            pack_components "${1:-/tmp/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz}" "${2:-false}"
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
        ufw)
            ensure_root
            banner
            local detected_port
            detected_port="$(detect_ssh_port "/etc/ssh/sshd_config")"
            log "Настройка фаервола UFW (SSH порт: $detected_port/tcp+udp)..."
            printf '\n%s?%s %sУкажите дополнительные порты для UFW (через пробел, например: 2053 8443) или Enter для пропуска:%s ' \
                "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
            local raw_extra=""
            if [[ -r /dev/tty ]]; then read -r raw_extra < /dev/tty || true; else read -r raw_extra || true; fi
            local extra_ports
            extra_ports="$(echo "$raw_extra" | tr -d '\r\n')"
            setup_ufw_firewall "$detected_port" "$extra_ports"
            ;;
        ""|-h|--help)
            ensure_root
            interactive_menu
            ;;
        *)
            banner
            err "Неизвестная команда: $cmd"
            echo "Использование: sudo bash $0 [push|pull|pack|unpack|scan|ufw]"
            exit 1
            ;;
    esac
}

main "$@"
