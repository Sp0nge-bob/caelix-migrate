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

VERSION="1.3.1"

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

# ── Парсинг SSH эндпоинта и порта ─────────────────────────────────────────────
parse_ssh_endpoint() {
    local raw_target="$1"
    local raw_port="${2:-}"

    local user_host="$raw_target"
    local port="$raw_port"

    # Поддержка синтаксиса -p PORT
    if [[ "$user_host" =~ -p[[:space:]]*([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
        user_host="$(echo "$user_host" | sed -E 's/-p[[:space:]]*[0-9]+//g')"
    fi

    # Поддержка синтаксиса host:port или user@host:port
    if [[ "$user_host" =~ ^(.*):([0-9]+)$ ]]; then
        user_host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    fi

    user_host="$(echo "$user_host" | tr -d '[:space:]')"
    port="$(echo "$port" | tr -d '[:space:]')"

    # Если пользователь не указан, по умолчанию root
    if [[ "$user_host" != *"@"* && -n "$user_host" ]]; then
        user_host="root@$user_host"
    fi

    echo "$user_host" "${port:-22}"
}

# ── Интерактивный запрос адреса и порта SSH ───────────────────────────────────
ask_ssh_endpoint() {
    local prompt_label="$1"
    local target_input=""
    local port_input=""

    printf '%s? %s (например, root@194.87.1.2 или root@194.87.1.2:2042): %s' \
        "$C_CYAN" "$prompt_label" "$C_RESET" >&2

    if [[ -r /dev/tty ]]; then
        read -r target_input < /dev/tty || true
    else
        read -r target_input || true
    fi
    target_input="$(echo "${target_input:-}" | tr -d '[:space:]')"
    [[ -n "$target_input" ]] || die "SSH-адрес сервера не указан."

    local user_host port
    read -r user_host port <<< "$(parse_ssh_endpoint "$target_input")"

    # Если порт не был указан прямо в строке адреса, уточняем его интерактивно
    if [[ "$target_input" != *":"* && "$target_input" != *"-p"* ]]; then
        printf '%s? SSH порт сервера [%s]: %s' "$C_CYAN" "$port" "$C_RESET" >&2
        if [[ -r /dev/tty ]]; then
            read -r port_input < /dev/tty || true
        else
            read -r port_input || true
        fi
        port_input="$(echo "${port_input:-}" | tr -d '[:space:]')"
        if [[ -n "$port_input" ]]; then
            port="$port_input"
        fi
    fi

    echo "$user_host" "$port"
}

# ── Глобальные переменные SSH Multiplexing ───────────────────────────────────
SSH_MUX_SOCKET=""
SSH_MUX_OPTS=()

# ── Инициализация единой мультиплексированной SSH сессии (ControlMaster) ─────
init_ssh_session() {
    local endpoint="$1"
    local port="$2"

    local hash_id
    hash_id="$(printf '%s_%s' "$endpoint" "$port" | md5sum 2>/dev/null | cut -c1-12 || printf '%s_%s' "$endpoint" "$port" | tr -cd '[:alnum:]' | cut -c1-12)"
    SSH_MUX_SOCKET="/tmp/caelix_mux_${hash_id}.sock"

    # Очистка мертвого сокета, если он остался от прошлых запусков
    if [[ -S "$SSH_MUX_SOCKET" ]]; then
        if ! ssh -O check -o "ControlPath=$SSH_MUX_SOCKET" -p "$port" "$endpoint" >/dev/null 2>&1; then
            rm -f "$SSH_MUX_SOCKET" 2>/dev/null || true
        fi
    fi

    SSH_MUX_OPTS=(
        -p "$port"
        -o "ControlMaster=auto"
        -o "ControlPath=$SSH_MUX_SOCKET"
        -o "ControlPersist=30m"
        -o "StrictHostKeyChecking=accept-new"
        -o "ConnectTimeout=10"
        -o "ServerAliveInterval=15"
        -o "ServerAliveCountMax=3"
    )

    log "Проверка SSH-подключения к $endpoint (порт $port)..."
    printf '%s==>%s %sВведите пароль ОДИН раз — мастер-сессия сохранится на всё время миграции:%s\n' "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET"

    # Первое подключение инициирует master-соединение в фоне (через ControlPersist)
    if ! ssh "${SSH_MUX_OPTS[@]}" "$endpoint" "echo 'CAELIX_SSH_OK'" >/dev/null; then
        rm -f "$SSH_MUX_SOCKET" 2>/dev/null || true
        die "Не удалось подключиться к $endpoint (порт $port). Проверьте адрес, порт и пароль."
    fi

    ok "Мастер-сессия SSH установлена ($endpoint, порт $port). Повторный ввод пароля не потребуется!"
}

# ── Завершение мультиплексированной SSH сессии ────────────────────────────────
close_ssh_session() {
    local endpoint="${1:-}"
    local port="${2:-}"

    if [[ -n "${SSH_MUX_SOCKET:-}" && -S "$SSH_MUX_SOCKET" ]]; then
        if [[ -n "$endpoint" && -n "$port" ]]; then
            ssh -O exit -o "ControlPath=$SSH_MUX_SOCKET" -p "$port" "$endpoint" >/dev/null 2>&1 || true
        fi
        rm -f "$SSH_MUX_SOCKET" 2>/dev/null || true
    fi
}

# ── Получение локального исполняемого файла скрипта (обход /dev/fd/*) ─────────
get_runnable_script() {
    local cached_script="/tmp/caelix-migrate-local-${VERSION}.sh"
    # Если $0 — это реальный файл на диске
    if [[ -f "${BASH_SOURCE[0]:-$0}" && ! "${BASH_SOURCE[0]:-$0}" =~ ^/dev/fd ]]; then
        echo "${BASH_SOURCE[0]:-$0}"
        return 0
    fi

    # Если скрипт запущен через pipe или подстановку процессов <(curl ...)
    if [[ ! -s "$cached_script" ]]; then
        log "Кэширование локальной копии скрипта в $cached_script..." >&2
        if ! curl -fsSL "https://raw.githubusercontent.com/Sp0nge-bob/caelix-migrate/main/migrate.sh" -o "$cached_script"; then
            cat "$0" > "$cached_script" 2>/dev/null || true
        fi
        chmod +x "$cached_script" 2>/dev/null || true
    fi
    echo "$cached_script"
}

# ── Доставка скрипта миграции на удаленный сервер ─────────────────────────────
deploy_remote_script() {
    local endpoint="$1"
    local port="$2"
    local local_script
    local_script="$(get_runnable_script)"

    log "Доставка скрипта миграции на $endpoint..."
    if [[ -s "$local_script" ]]; then
        if scp -o "ControlPath=$SSH_MUX_SOCKET" -P "$port" -o "StrictHostKeyChecking=accept-new" "$local_script" "${endpoint}:/tmp/migrate.sh" >/dev/null 2>&1; then
            ssh "${SSH_MUX_OPTS[@]}" "$endpoint" "chmod +x /tmp/migrate.sh" >/dev/null 2>&1 || true
            ok "Скрипт миграции готов на $endpoint (/tmp/migrate.sh)"
            return 0
        fi
    fi

    local remote_cmd="curl -fsSL https://raw.githubusercontent.com/Sp0nge-bob/caelix-migrate/main/migrate.sh -o /tmp/migrate.sh && chmod +x /tmp/migrate.sh"
    ssh "${SSH_MUX_OPTS[@]}" "$endpoint" "$remote_cmd" >/dev/null 2>&1 || die "Не удалось доставить скрипт миграции на $endpoint."
    ok "Скрипт миграции готов на $endpoint (/tmp/migrate.sh)"
}

# ── Передача файлов между серверами с визуальным прогрессом ───────────────────
transfer_file() {
    local direction="$1" # "pull" или "push"
    local endpoint="$2"
    local port="$3"
    local remote_file="$4"
    local local_file="$5"

    log "Передача архива ($direction) через сеть..."

    local ssh_cmd="ssh -p $port -o ControlPath=$SSH_MUX_SOCKET -o StrictHostKeyChecking=accept-new"
    if [[ "$direction" == "pull" ]]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -avz --progress -e "$ssh_cmd" \
                "${endpoint}:${remote_file}" "$local_file" || \
            scp -o "ControlPath=$SSH_MUX_SOCKET" -P "$port" -o "StrictHostKeyChecking=accept-new" "${endpoint}:${remote_file}" "$local_file"
        else
            scp -o "ControlPath=$SSH_MUX_SOCKET" -P "$port" -o "StrictHostKeyChecking=accept-new" "${endpoint}:${remote_file}" "$local_file"
        fi
    else # push
        if command -v rsync >/dev/null 2>&1; then
            rsync -avz --progress -e "$ssh_cmd" \
                "$local_file" "${endpoint}:${remote_file}" || \
            scp -o "ControlPath=$SSH_MUX_SOCKET" -P "$port" -o "StrictHostKeyChecking=accept-new" "$local_file" "${endpoint}:${remote_file}"
        else
            scp -o "ControlPath=$SSH_MUX_SOCKET" -P "$port" -o "StrictHostKeyChecking=accept-new" "$local_file" "${endpoint}:${remote_file}"
        fi
    fi
    ok "Передача архива завершена успешно."
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

    # Базовые политики
    log "Установка политик по умолчанию (deny incoming, allow outgoing)..."
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

# ── Настройка локального шифрованного DoT DNS-кэша (unbound) ───────────────────
setup_unbound_dot_dns() {
    log "Настройка локального шифрованного DoT DNS-кэша (unbound на 127.0.0.1:53)..."

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v unbound >/dev/null 2>&1 || [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
        log "Установка пакетов unbound, dns-root-data и ca-certificates..."
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends unbound ca-certificates dns-root-data dnsutils || \
            apt-get install -y -qq --no-install-recommends unbound ca-certificates dns-root-data || \
            apt-get install -y -qq --no-install-recommends unbound ca-certificates
    fi

    local cert_bundle="/etc/ssl/certs/ca-certificates.crt"
    if [[ ! -f "$cert_bundle" && -f /etc/ssl/certs/ca-bundle.crt ]]; then
        cert_bundle="/etc/ssl/certs/ca-bundle.crt"
    fi
    if [[ ! -f "$cert_bundle" ]]; then
        err "Не найден системный CA bundle для проверки TLS (DoT)."
        return 1
    fi

    # Инициализация root trust anchor (/var/lib/unbound/root.key), иначе unbound-checkconf на Debian 13 падает
    mkdir -p /var/lib/unbound
    if [[ ! -s /var/lib/unbound/root.key ]]; then
        if command -v unbound-anchor >/dev/null 2>&1; then
            log "Инициализация DNSSEC root trust anchor (/var/lib/unbound/root.key)..."
            unbound-anchor -a /var/lib/unbound/root.key || true
        fi
        if [[ ! -s /var/lib/unbound/root.key && -s /usr/share/dns/root.key ]]; then
            cp -a /usr/share/dns/root.key /var/lib/unbound/root.key
        fi
    fi
    if id -u unbound >/dev/null 2>&1; then
        chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
    fi
    if [[ ! -s /var/lib/unbound/root.key && -f /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf ]]; then
        warn "Не удалось создать /var/lib/unbound/root.key, отключаем auto-trust-anchor-file.conf (DoT работает без него)."
        mv /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf \
           /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf.disabled
    fi

    # Освобождаем порт 53 от stub-listener systemd-resolved, если он активен (например, на Ubuntu)
    if [[ -d /run/systemd/system ]] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log "Отключение DNSStubListener у systemd-resolved для освобождения 53 порта..."
        mkdir -p /etc/systemd/resolved.conf.d
        cat << 'EOF' > /etc/systemd/resolved.conf.d/no-stub.conf
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    # Бэкап /etc/resolv.conf до любых правок
    if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
        local resolv_bak
        resolv_bak="/root/resolv.conf.bak.$(date +%Y%m%d_%H%M%S)"
        cp -aL /etc/resolv.conf "$resolv_bak" 2>/dev/null || cp -a /etc/resolv.conf "$resolv_bak" 2>/dev/null || true
        ok "Сохранён бэкап /etc/resolv.conf -> $resolv_bak"
    fi

    mkdir -p /etc/unbound/unbound.conf.d
    cat << EOF > /etc/unbound/unbound.conf.d/dot-cache.conf
server:
    interface: 127.0.0.1
    port: 53
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    tls-cert-bundle: "${cert_bundle}"
    prefetch: yes
    cache-min-ttl: 60
    cache-max-ttl: 3600
    serve-expired: yes
    serve-expired-ttl: 86400
    msg-cache-size: 16m
    rrset-cache-size: 32m
    num-threads: 1
    hide-identity: yes
    hide-version: yes

forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 9.9.9.9@853#dns.quad9.net
EOF

    if ! unbound-checkconf; then
        err "Ошибка в конфигурации unbound (/etc/unbound/unbound.conf.d/dot-cache.conf)."
        return 1
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl enable unbound >/dev/null 2>&1 || true
        if ! systemctl restart unbound; then
            err "Не удалось запустить службу unbound (проверьте: journalctl -u unbound -n 20 --no-pager)."
            return 1
        fi
    else
        service unbound restart 2>/dev/null || {
            pkill -x unbound 2>/dev/null || true
            unbound -c /etc/unbound/unbound.conf || {
                err "Не удалось запустить unbound."
                return 1
            }
        }
    fi

    # Проверяем резолв через 127.0.0.1 ДО переключения /etc/resolv.conf
    local test_ok="false"
    local attempt
    for attempt in 1 2 3; do
        if command -v nslookup >/dev/null 2>&1; then
            if nslookup -type=A cloudflare.com 127.0.0.1 >/dev/null 2>&1; then
                test_ok="true"
                break
            fi
        elif command -v dig >/dev/null 2>&1; then
            if dig @127.0.0.1 +short A cloudflare.com | grep -qE '^[0-9]+\.'; then
                test_ok="true"
                break
            fi
        elif command -v python3 >/dev/null 2>&1; then
            if python3 -c "import socket,struct; s=socket.socket(2,2); s.settimeout(3); s.sendto(b'\xaa\xbb\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x0acloudflare\x03com\x00\x00\x01\x00\x01',('127.0.0.1',53)); d,_=s.recvfrom(512); assert len(d)>12 and (d[3]&0x0f)==0" 2>/dev/null; then
                test_ok="true"
                break
            fi
        else
            test_ok="true"
            break
        fi
        sleep 1
    done

    if [[ "$test_ok" != "true" ]]; then
        err "unbound запущен, но тестовый DoT-запрос на 127.0.0.1:53 не прошёл. /etc/resolv.conf не изменён."
        return 1
    fi

    # Переключаем системный резолвер на 127.0.0.1 (снимаем symlink, если был)
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
    cat << 'EOF' > /etc/resolv.conf
nameserver 127.0.0.1
options timeout:2 attempts:2
EOF

    ok "Локальный DoT DNS-кэш (unbound 127.0.0.1:53) настроен и активен!"
    log "Апстримы DoT (853): 1.1.1.1 (Cloudflare), 8.8.8.8 (Google), 9.9.9.9 (Quad9)."
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

    # 9. SSL/TLS сертификаты (вне /root/cert)
    DETECTED_LETSENCRYPT="false"
    DETECTED_EXTRA_CERTS=()

    # 9.1 Let's Encrypt (/etc/letsencrypt/live)
    if [[ -d "/etc/letsencrypt/live" ]]; then
        local le_count
        le_count="$(find /etc/letsencrypt/live -type f -o -type l 2>/dev/null | wc -l || echo 0)"
        if [[ "$le_count" -gt 0 ]]; then
            DETECTED_LETSENCRYPT="true"
            if [[ "$silent" != "true" ]]; then
                ok "Обнаружены сертификаты Let's Encrypt: /etc/letsencrypt (будут перенесены)"
            fi
        fi
    fi

    # 9.2 Поиск путей к сертификатам в конфигах Nginx
    local raw_cert_paths=()
    if [[ -d "/etc/nginx" ]]; then
        while IFS= read -r p; do
            [[ -n "$p" ]] && raw_cert_paths+=("$p")
        done < <(grep -h -E '^[[:space:]]*ssl_(certificate|certificate_key|trusted_certificate)[[:space:]]+' \
            /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* 2>/dev/null \
            | awk '{print $2}' | tr -d ';' | tr -d '"' | tr -d "'" | sort -u || true)

        # Также проверяем кастомные каталоги /etc/nginx/ssl и /etc/nginx/certs
        for cdir in "/etc/nginx/ssl" "/etc/nginx/certs"; do
            if [[ -d "$cdir" ]]; then
                while IFS= read -r f; do
                    [[ -n "$f" ]] && raw_cert_paths+=("$f")
                done < <(find "$cdir" -type f \( -name "*.crt" -o -name "*.key" -o -name "*.pem" \) 2>/dev/null || true)
            fi
        done
    fi

    # 9.3 Поиск путей к сертификатам в 3x-ui inbounds (x-ui.db)
    for xdb in "/etc/x-ui/x-ui.db" "/usr/local/x-ui/x-ui.db"; do
        if [[ -f "$xdb" ]] && command -v sqlite3 >/dev/null 2>&1; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && raw_cert_paths+=("$p")
            done < <(sqlite3 "$xdb" "SELECT settings FROM inbounds;" 2>/dev/null \
                | grep -oE '"(certificateFile|keyFile)":[[:space:]]*"[^"]+"' 2>/dev/null \
                | awk -F'"' '{print $4}' | sort -u || true)
        fi
    done

    # 9.4 Фильтрация: исключаем /root/cert*, исключаем /etc/letsencrypt* если уже переносится полностью
    local seen_cert_paths=" "
    for cp in "${raw_cert_paths[@]}"; do
        [[ -z "$cp" ]] && continue
        # Не переносим сертификаты из /root/cert (они создаются мастером 3x-ui на новом сервере)
        if [[ "$cp" == /root/cert* ]]; then
            continue
        fi
        # Если Let's Encrypt уже переносится целиком, не дублируем файлы в extra
        if [[ "$DETECTED_LETSENCRYPT" == "true" && "$cp" == /etc/letsencrypt* ]]; then
            continue
        fi
        # Проверяем существование файла или symlink
        if [[ -e "$cp" || -L "$cp" ]]; then
            if [[ "$seen_cert_paths" != *" $cp "* ]]; then
                seen_cert_paths+="$cp "
                DETECTED_EXTRA_CERTS+=("$cp")
            fi
        fi
    done

    if [[ ${#DETECTED_EXTRA_CERTS[@]} -gt 0 && "$silent" != "true" ]]; then
        ok "Обнаружены внешние SSL сертификаты: ${#DETECTED_EXTRA_CERTS[@]} шт. вне /root/cert (будут перенесены)"
    fi

    populate_scan_summaries
}

# ── Хранилище доступности и выбора компонентов ────────────────────────────────
AVAIL_BOT="false";       INFO_BOT=""
AVAIL_WEB="false";       INFO_WEB=""
AVAIL_MW="false";        INFO_MW=""
AVAIL_REDIS="false";     INFO_REDIS=""
AVAIL_NGINX="false";     INFO_NGINX=""
AVAIL_COPYPARTY="false"; INFO_COPYPARTY=""
AVAIL_CERTS="false";     INFO_CERTS=""
AVAIL_SSH="false";       INFO_SSH=""

SEL_BOT="false"
SEL_WEB="false"
SEL_MW="false"
SEL_REDIS="false"
SEL_NGINX="false"
SEL_COPYPARTY="false"
SEL_CERTS="false"
SEL_SSH="false"

CLI_ONLY_COMPONENTS=""
CLI_EXCLUDE_COMPONENTS=""
CLI_WITH_SSH="false"
CLI_UNPACK_ALL="false"
POSITIONAL_ARGS=()

reset_availability() {
    AVAIL_BOT="false";       INFO_BOT=""
    AVAIL_WEB="false";       INFO_WEB=""
    AVAIL_MW="false";        INFO_MW=""
    AVAIL_REDIS="false";     INFO_REDIS=""
    AVAIL_NGINX="false";     INFO_NGINX=""
    AVAIL_COPYPARTY="false"; INFO_COPYPARTY=""
    AVAIL_CERTS="false";     INFO_CERTS=""
    AVAIL_SSH="false";       INFO_SSH=""
}

reset_component_selection() {
    SEL_BOT="false"
    SEL_WEB="false"
    SEL_MW="false"
    SEL_REDIS="false"
    SEL_NGINX="false"
    SEL_COPYPARTY="false"
    SEL_CERTS="false"
    SEL_SSH="false"
}

get_component_sel() {
    case "$1" in
        bot)       echo "$SEL_BOT" ;;
        web)       echo "$SEL_WEB" ;;
        mw)        echo "$SEL_MW" ;;
        redis)     echo "$SEL_REDIS" ;;
        nginx)     echo "$SEL_NGINX" ;;
        copyparty) echo "$SEL_COPYPARTY" ;;
        certs)     echo "$SEL_CERTS" ;;
        ssh)       echo "$SEL_SSH" ;;
        *)         echo "false" ;;
    esac
}

set_component_sel() {
    local id="$1"
    local val="$2"
    case "$id" in
        bot)       SEL_BOT="$val" ;;
        web)       SEL_WEB="$val" ;;
        mw)        SEL_MW="$val" ;;
        redis)     SEL_REDIS="$val" ;;
        nginx)     SEL_NGINX="$val" ;;
        copyparty) SEL_COPYPARTY="$val" ;;
        certs)     SEL_CERTS="$val" ;;
        ssh)       SEL_SSH="$val" ;;
    esac
}

is_component_avail() {
    case "$1" in
        bot)       [[ "$AVAIL_BOT" == "true" ]] ;;
        web)       [[ "$AVAIL_WEB" == "true" ]] ;;
        mw)        [[ "$AVAIL_MW" == "true" ]] ;;
        redis)     [[ "$AVAIL_REDIS" == "true" ]] ;;
        nginx)     [[ "$AVAIL_NGINX" == "true" ]] ;;
        copyparty) [[ "$AVAIL_COPYPARTY" == "true" ]] ;;
        certs)     [[ "$AVAIL_CERTS" == "true" ]] ;;
        ssh)       [[ "$AVAIL_SSH" == "true" ]] ;;
        *)         return 1 ;;
    esac
}

get_component_label() {
    case "$1" in
        bot)       echo "Vpn-Bot" ;;
        web)       echo "Vpn-Website" ;;
        mw)        echo "MiddlewareJSON" ;;
        redis)     echo "Redis" ;;
        nginx)     echo "Nginx" ;;
        copyparty) echo "Copyparty" ;;
        certs)     echo "SSL сертификаты" ;;
        ssh)       echo "SSH настройки" ;;
        *)         echo "$1" ;;
    esac
}

get_component_info() {
    case "$1" in
        bot)       echo "$INFO_BOT" ;;
        web)       echo "$INFO_WEB" ;;
        mw)        echo "$INFO_MW" ;;
        redis)     echo "$INFO_REDIS" ;;
        nginx)     echo "$INFO_NGINX" ;;
        copyparty) echo "$INFO_COPYPARTY" ;;
        certs)     echo "$INFO_CERTS" ;;
        ssh)       echo "$INFO_SSH" ;;
    esac
}

normalize_component_id() {
    local raw
    raw="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$raw" in
        bot|vpnbot|vpn-bot)                       echo "bot" ;;
        web|site|website|vpnwebsite|vpn-website)  echo "web" ;;
        mw|middleware|middlewarejson)             echo "mw" ;;
        redis|redis-server)                       echo "redis" ;;
        nginx)                                    echo "nginx" ;;
        copyparty|cp)                             echo "copyparty" ;;
        certs|cert|ssl|tls|letsencrypt)           echo "certs" ;;
        ssh|sshd)                                 echo "ssh" ;;
        *)                                        return 1 ;;
    esac
}

populate_scan_summaries() {
    reset_availability

    if [[ -n "$DETECTED_BOT" ]]; then
        AVAIL_BOT="true"
        local db_info="нет bot.db"
        if [[ -f "$DETECTED_BOT/data/bot.db" ]]; then
            db_info="bot.db: $(du -h "$DETECTED_BOT/data/bot.db" 2>/dev/null | cut -f1 || echo "есть")"
        fi
        local env_info="нет"
        [[ -f "$DETECTED_BOT/.env" ]] && env_info="OK"
        INFO_BOT="$DETECTED_BOT ($db_info, .env: $env_info)"
    fi

    if [[ -n "$DETECTED_WEB" ]]; then
        AVAIL_WEB="true"
        local env_info="нет"
        [[ -f "$DETECTED_WEB/.env" ]] && env_info="OK"
        INFO_WEB="$DETECTED_WEB (.env: $env_info)"
    fi

    if [[ -n "$DETECTED_MW" ]]; then
        AVAIL_MW="true"
        local env_info="нет"
        [[ -f "$DETECTED_MW/.env" ]] && env_info="OK"
        INFO_MW="$DETECTED_MW (.env: $env_info)"
    fi

    if [[ "$DETECTED_REDIS" == "true" ]]; then
        AVAIL_REDIS="true"
        INFO_REDIS="redis-server"
    fi

    if [[ "$DETECTED_NGINX" == "true" ]]; then
        AVAIL_NGINX="true"
        local conf_count=0
        if [[ -d "/etc/nginx/conf.d" ]]; then
            conf_count="$(find /etc/nginx/conf.d -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)"
        fi
        INFO_NGINX="nginx.conf + ${conf_count} файл(ов) в conf.d/"
    fi

    if [[ -n "$DETECTED_COPYPARTY" ]]; then
        AVAIL_COPYPARTY="true"
        local cp_dc="нет"
        [[ -f "$DETECTED_COPYPARTY/docker-compose.yml" ]] && cp_dc="OK"
        INFO_COPYPARTY="$DETECTED_COPYPARTY (docker-compose: $cp_dc)"
    fi

    local certs_parts=()
    if [[ "$DETECTED_LETSENCRYPT" == "true" ]]; then
        local le_domains
        le_domains="$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null | awk -F/ '{print $NF}' | paste -sd, - 2>/dev/null || true)"
        [[ -z "$le_domains" ]] && le_domains="активен"
        certs_parts+=("Let's Encrypt: $le_domains")
    fi
    if [[ ${#DETECTED_EXTRA_CERTS[@]} -gt 0 ]]; then
        certs_parts+=("${#DETECTED_EXTRA_CERTS[@]} внешних файлов")
    fi
    if [[ ${#certs_parts[@]} -gt 0 ]]; then
        AVAIL_CERTS="true"
        INFO_CERTS="$(IFS=", "; echo "${certs_parts[*]}")"
    fi

    local ssh_parts=()
    if [[ -n "$DETECTED_SSH_AUTHORIZED_KEYS" ]]; then
        local count_keys
        count_keys="$(grep -c -E "^(ssh-|ecdsa-|sk-)" "$DETECTED_SSH_AUTHORIZED_KEYS" 2>/dev/null || echo "1+")"
        ssh_parts+=("authorized_keys ($count_keys)")
    fi
    if [[ -n "$DETECTED_SSH_AUTHORIZED_KEY" ]]; then
        local count_key
        count_key="$(grep -c -E "^(ssh-|ecdsa-|sk-)" "$DETECTED_SSH_AUTHORIZED_KEY" 2>/dev/null || echo "1+")"
        ssh_parts+=("authorized_key ($count_key)")
    fi
    if [[ "$DETECTED_SSHD_CONF" == "true" ]]; then
        ssh_parts+=("sshd_config")
    fi
    if [[ ${#ssh_parts[@]} -gt 0 ]]; then
        AVAIL_SSH="true"
        INFO_SSH="$(IFS=", "; echo "${ssh_parts[*]}")"
    fi
}

print_scan_env() {
    scan_components "true"
    echo "___CAELIX_SCAN_BEGIN___"
    printf 'AVAIL_BOT=%s\n' "$AVAIL_BOT"
    printf 'INFO_BOT=%s\n' "${INFO_BOT//$'\n'/ }"
    printf 'AVAIL_WEB=%s\n' "$AVAIL_WEB"
    printf 'INFO_WEB=%s\n' "${INFO_WEB//$'\n'/ }"
    printf 'AVAIL_MW=%s\n' "$AVAIL_MW"
    printf 'INFO_MW=%s\n' "${INFO_MW//$'\n'/ }"
    printf 'AVAIL_REDIS=%s\n' "$AVAIL_REDIS"
    printf 'INFO_REDIS=%s\n' "${INFO_REDIS//$'\n'/ }"
    printf 'AVAIL_NGINX=%s\n' "$AVAIL_NGINX"
    printf 'INFO_NGINX=%s\n' "${INFO_NGINX//$'\n'/ }"
    printf 'AVAIL_COPYPARTY=%s\n' "$AVAIL_COPYPARTY"
    printf 'INFO_COPYPARTY=%s\n' "${INFO_COPYPARTY//$'\n'/ }"
    printf 'AVAIL_CERTS=%s\n' "$AVAIL_CERTS"
    printf 'INFO_CERTS=%s\n' "${INFO_CERTS//$'\n'/ }"
    printf 'AVAIL_SSH=%s\n' "$AVAIL_SSH"
    printf 'INFO_SSH=%s\n' "${INFO_SSH//$'\n'/ }"
    printf 'DETECTED_XUI=%s\n' "$DETECTED_XUI"
    echo "___CAELIX_SCAN_END___"
}

scan_remote_components() {
    local endpoint="$1"
    log "Сканирование доступных компонентов на сервере $endpoint..."
    local raw_out
    raw_out="$(ssh "${SSH_MUX_OPTS[@]}" "$endpoint" \
        'if [ "$(id -u)" -eq 0 ]; then bash /tmp/migrate.sh scan --env; else sudo bash /tmp/migrate.sh scan --env; fi' \
        2>/dev/null | tr -d '\r')" || true

    reset_availability
    DETECTED_XUI="false"

    local in_block="false"
    local parsed_any="false"
    while IFS= read -r line; do
        if [[ "$line" == "___CAELIX_SCAN_BEGIN___" ]]; then
            in_block="true"
            continue
        elif [[ "$line" == "___CAELIX_SCAN_END___" ]]; then
            in_block="false"
            break
        fi
        [[ "$in_block" != "true" ]] && continue
        parsed_any="true"
        local key="${line%%=*}"
        local val="${line#*=}"
        case "$key" in
            AVAIL_BOT)       AVAIL_BOT="$val" ;;
            INFO_BOT)        INFO_BOT="$val" ;;
            AVAIL_WEB)       AVAIL_WEB="$val" ;;
            INFO_WEB)        INFO_WEB="$val" ;;
            AVAIL_MW)        AVAIL_MW="$val" ;;
            INFO_MW)         INFO_MW="$val" ;;
            AVAIL_REDIS)     AVAIL_REDIS="$val" ;;
            INFO_REDIS)      INFO_REDIS="$val" ;;
            AVAIL_NGINX)     AVAIL_NGINX="$val" ;;
            INFO_NGINX)      INFO_NGINX="$val" ;;
            AVAIL_COPYPARTY) AVAIL_COPYPARTY="$val" ;;
            INFO_COPYPARTY)  INFO_COPYPARTY="$val" ;;
            AVAIL_CERTS)     AVAIL_CERTS="$val" ;;
            INFO_CERTS)      INFO_CERTS="$val" ;;
            AVAIL_SSH)       AVAIL_SSH="$val" ;;
            INFO_SSH)        INFO_SSH="$val" ;;
            DETECTED_XUI)    DETECTED_XUI="$val" ;;
        esac
    done <<< "$raw_out"

    [[ "$parsed_any" == "true" ]] || die "Не удалось получить список компонентов с сервера $endpoint."
}

parse_component_args() {
    CLI_ONLY_COMPONENTS=""
    CLI_EXCLUDE_COMPONENTS=""
    CLI_WITH_SSH="false"
    CLI_UNPACK_ALL="false"
    POSITIONAL_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                shift
                [[ $# -gt 0 ]] || die "Флаг --only требует список компонентов (например: --only bot,web)"
                CLI_ONLY_COMPONENTS="$1"
                ;;
            --only=*)
                CLI_ONLY_COMPONENTS="${1#--only=}"
                ;;
            --exclude)
                shift
                [[ $# -gt 0 ]] || die "Флаг --exclude требует список компонентов (например: --exclude bot,web)"
                CLI_EXCLUDE_COMPONENTS="$1"
                ;;
            --exclude=*)
                CLI_EXCLUDE_COMPONENTS="${1#--exclude=}"
                ;;
            --with-ssh)
                CLI_WITH_SSH="true"
                ;;
            --all|--yes|-y)
                CLI_UNPACK_ALL="true"
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                ;;
        esac
        shift || true
    done
}

apply_cli_component_filters() {
    local mode="${1:-pack}"
    reset_component_selection

    # Базовые значения: для pack/push/pull всё найденное кроме ssh; для unpack — всё из архива
    local cid
    for cid in bot web mw redis nginx copyparty certs; do
        if is_component_avail "$cid"; then
            set_component_sel "$cid" "true"
        fi
    done
    if is_component_avail "ssh"; then
        if [[ "$mode" == "unpack" || "$CLI_WITH_SSH" == "true" ]]; then
            set_component_sel "ssh" "true"
        fi
    fi

    # --only переопределяет набор полностью
    if [[ -n "$CLI_ONLY_COMPONENTS" ]]; then
        reset_component_selection
        local tokens
        tokens="$(echo "$CLI_ONLY_COMPONENTS" | tr ',' ' ')"
        local tok norm
        for tok in $tokens; do
            [[ -z "$tok" ]] && continue
            if norm="$(normalize_component_id "$tok")"; then
                if is_component_avail "$norm"; then
                    set_component_sel "$norm" "true"
                else
                    warn "Компонент '$norm' не обнаружен и будет пропущен."
                fi
            else
                die "Неизвестный компонент в --only: '$tok' (допустимы: bot, web, mw, redis, nginx, copyparty, certs, ssh)"
            fi
        done
    fi

    # --exclude снимает указанные компоненты
    if [[ -n "$CLI_EXCLUDE_COMPONENTS" ]]; then
        local tokens
        tokens="$(echo "$CLI_EXCLUDE_COMPONENTS" | tr ',' ' ')"
        local tok norm
        for tok in $tokens; do
            [[ -z "$tok" ]] && continue
            if norm="$(normalize_component_id "$tok")"; then
                set_component_sel "$norm" "false"
            else
                die "Неизвестный компонент в --exclude: '$tok' (допустимы: bot, web, mw, redis, nginx, copyparty, certs, ssh)"
            fi
        done
    fi
}

selected_components_to_csv() {
    local out=()
    local cid
    for cid in bot web mw redis nginx copyparty certs ssh; do
        if [[ "$(get_component_sel "$cid")" == "true" ]]; then
            out+=("$cid")
        fi
    done
    IFS=","
    echo "${out[*]}"
}

selected_components_summary() {
    local out=()
    local cid
    for cid in bot web mw redis nginx copyparty certs ssh; do
        if [[ "$(get_component_sel "$cid")" == "true" ]]; then
            out+=("$(get_component_label "$cid")")
        fi
    done
    IFS=", "
    echo "${out[*]}"
}

count_selected_components() {
    local cnt=0
    local cid
    for cid in bot web mw redis nginx copyparty certs ssh; do
        if [[ "$(get_component_sel "$cid")" == "true" ]]; then
            cnt=$((cnt + 1))
        fi
    done
    echo "$cnt"
}

select_components_interactive() {
    local mode="${1:-pack}"
    local title="Выбор компонентов для миграции"
    if [[ "$mode" == "unpack" ]]; then
        title="Выбор компонентов из архива для развёртывания"
    fi

    local item_ids=()
    local cid
    for cid in bot web mw redis nginx copyparty certs ssh; do
        if is_component_avail "$cid"; then
            item_ids+=("$cid")
        fi
    done

    if [[ ${#item_ids[@]} -eq 0 ]]; then
        err "Не найдено ни одного компонента CaelixFlow для выбора."
        return 1
    fi

    while true; do
        echo >&2
        printf '%s%s%s\n' "$C_BOLD" "$title" "$C_RESET" >&2
        printf '%s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2

        local i=0
        local selected_count=0
        for cid in "${item_ids[@]}"; do
            i=$((i + 1))
            local label info mark
            label="$(get_component_label "$cid")"
            info="$(get_component_info "$cid")"
            if [[ "$(get_component_sel "$cid")" == "true" ]]; then
                mark="${C_GREEN}[✔]${C_RESET}"
                selected_count=$((selected_count + 1))
            else
                mark="${C_DIM}[ ]${C_RESET}"
            fi
            local extra_tag=""
            if [[ "$cid" == "ssh" && "$mode" != "unpack" ]]; then
                extra_tag=" ${C_DIM}[по умолч. выкл]${C_RESET}"
            fi
            printf '  %s%2d)%s %s %-16s %s%s%s%s\n' \
                "$C_CYAN" "$i" "$C_RESET" "$mark" "$label" "$C_DIM" "$info" "$C_RESET" "$extra_tag" >&2
        done

        printf '%s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2
        printf 'Выбрано: %s%d%s из %d\n' "$C_BOLD" "$selected_count" "$C_RESET" "${#item_ids[@]}" >&2

        # Мягкие подсказки о связях между компонентами
        if [[ "$SEL_WEB" == "true" && "$SEL_BOT" != "true" ]]; then
            warn "Подсказка: Vpn-Website использует общую БД из Vpn-Bot (data/bot.db). Если на целевом сервере её нет, отметьте Vpn-Bot."
        fi
        if [[ "$SEL_BOT" == "true" && "$AVAIL_REDIS" == "true" && "$SEL_REDIS" != "true" ]]; then
            warn "Подсказка: Vpn-Bot использует Redis (отметьте Redis, если он ещё не установлен на новом сервере)."
        fi
        if [[ "$SEL_NGINX" == "true" && "$AVAIL_CERTS" == "true" && "$SEL_CERTS" != "true" ]]; then
            warn "Подсказка: конфиги Nginx могут ссылаться на SSL-сертификаты (пункт SSL сертификаты)."
        fi

        echo >&2
        printf '%sУправление:%s\n' "$C_BOLD" "$C_RESET" >&2
        printf '  %s•%s Номера (напр. %s1 2%s)        — переключить [✔]/[ ]\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
        printf '  %s•%s %sonly 1 2%s (или %s=1 2%s)    — выбрать ТОЛЬКО указанные пункты\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
        printf '  %s•%s %sbw%s                      — только Vpn-Bot + Vpn-Website\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
        printf '  %s•%s %sapp%s                     — Бот + Сайт + Middleware + Redis\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
        printf '  %s•%s %sinfra%s                   — всё, КРОМЕ Бота и Сайта\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
        printf '  %s•%s %sall%s / %snone%s              — всё (без SSH) / снять все галочки\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
        printf '  %s•%s %sEnter%s                   — подтвердить и продолжить (%s0%s — отмена)\n\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_DIM" "$C_RESET" >&2

        printf '%sВыбор [Enter = продолжить]: %s' "$C_BOLD" "$C_RESET" >&2
        local raw_input=""
        local read_rc=0
        if [[ -r /dev/tty ]]; then
            read -r raw_input < /dev/tty || read_rc=$?
        else
            read -r raw_input || read_rc=$?
        fi
        if [[ "$read_rc" -ne 0 && -z "${raw_input:-}" ]]; then
            warn "Ввод прерван (EOF). Операция отменена."
            return 1
        fi
        raw_input="$(echo "${raw_input:-}" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

        # Enter — подтверждение
        if [[ -z "$raw_input" ]]; then
            if [[ "$selected_count" -eq 0 ]]; then
                warn "Не выбран ни один компонент. Отметьте хотя бы один пункт или введите 0 для отмены."
                continue
            fi
            return 0
        fi

        local lower_input
        lower_input="$(echo "$raw_input" | tr '[:upper:]' '[:lower:]')"

        case "$lower_input" in
            0|q|quit|exit|cancel)
                warn "Операция отменена пользователем."
                return 1
                ;;
            all)
                for cid in "${item_ids[@]}"; do
                    if [[ "$cid" == "ssh" && "$mode" != "unpack" ]]; then
                        set_component_sel "$cid" "false"
                    else
                        set_component_sel "$cid" "true"
                    fi
                done
                continue
                ;;
            all+ssh|allssh)
                for cid in "${item_ids[@]}"; do
                    set_component_sel "$cid" "true"
                done
                continue
                ;;
            none|clear|c)
                reset_component_selection
                continue
                ;;
            bw|botweb|bot+web)
                reset_component_selection
                is_component_avail "bot" && SEL_BOT="true"
                is_component_avail "web" && SEL_WEB="true"
                if [[ "$SEL_BOT" != "true" && "$SEL_WEB" != "true" ]]; then
                    warn "Vpn-Bot и Vpn-Website не обнаружены."
                fi
                continue
                ;;
            app|apps)
                reset_component_selection
                for cid in bot web mw redis; do
                    is_component_avail "$cid" && set_component_sel "$cid" "true"
                done
                continue
                ;;
            infra|nobot|no-bot)
                reset_component_selection
                for cid in "${item_ids[@]}"; do
                    if [[ "$cid" != "bot" && "$cid" != "web" && "$cid" != "ssh" ]]; then
                        set_component_sel "$cid" "true"
                    fi
                done
                continue
                ;;
        esac

        # Режим: only ..., =..., +..., -... или обычное переключение
        local op="toggle"
        local body="$raw_input"
        if [[ "$lower_input" == only\ * ]]; then
            op="only"
            body="${raw_input#*[Oo][Nn][Ll][Yy]}"
        elif [[ "$raw_input" == =* ]]; then
            op="only"
            body="${raw_input#=}"
        elif [[ "$raw_input" == +* ]]; then
            op="on"
            body="${raw_input#+}"
        elif [[ "$lower_input" == add\ * ]]; then
            op="on"
            body="${raw_input#*[Aa][Dd][Dd]}"
        elif [[ "$raw_input" == -* ]]; then
            op="off"
            body="${raw_input#-}"
        elif [[ "$lower_input" == del\ * ]]; then
            op="off"
            body="${raw_input#*[Dd][Ee][Ll]}"
        fi

        local tokens
        tokens="$(echo "$body" | tr ',' ' ')"
        local resolved_ids=()
        local valid_all="true"
        local tok norm idx
        for tok in $tokens; do
            [[ -z "$tok" ]] && continue
            if [[ "$op" == "on" && "$tok" == +* ]]; then
                tok="${tok#+}"
            elif [[ "$op" == "off" && "$tok" == -* ]]; then
                tok="${tok#-}"
            fi
            if [[ "$tok" =~ ^[0-9]+$ ]]; then
                idx=$((tok - 1))
                if [[ "$idx" -ge 0 && "$idx" -lt ${#item_ids[@]} ]]; then
                    resolved_ids+=("${item_ids[$idx]}")
                else
                    warn "Неверный номер пункта: $tok (доступно 1..${#item_ids[@]})."
                    valid_all="false"
                fi
            elif norm="$(normalize_component_id "$tok")"; then
                if is_component_avail "$norm"; then
                    resolved_ids+=("$norm")
                else
                    warn "Компонент '$norm' недоступен в текущем списке."
                    valid_all="false"
                fi
            else
                warn "Неизвестная команда или пункт: '$tok'."
                valid_all="false"
            fi
        done

        [[ "$valid_all" == "false" || ${#resolved_ids[@]} -eq 0 ]] && continue

        if [[ "$op" == "only" ]]; then
            reset_component_selection
            for cid in "${resolved_ids[@]}"; do
                set_component_sel "$cid" "true"
            done
        elif [[ "$op" == "on" ]]; then
            for cid in "${resolved_ids[@]}"; do
                set_component_sel "$cid" "true"
            done
        elif [[ "$op" == "off" ]]; then
            for cid in "${resolved_ids[@]}"; do
                set_component_sel "$cid" "false"
            done
        else
            for cid in "${resolved_ids[@]}"; do
                if [[ "$(get_component_sel "$cid")" == "true" ]]; then
                    set_component_sel "$cid" "false"
                else
                    set_component_sel "$cid" "true"
                fi
            done
        fi
    done
}

resolve_component_selection() {
    local mode="${1:-pack}"
    apply_cli_component_filters "$mode"

    if [[ "$CLI_UNPACK_ALL" == "true" || -n "$CLI_ONLY_COMPONENTS" || -n "$CLI_EXCLUDE_COMPONENTS" ]]; then
        local cnt
        cnt="$(count_selected_components)"
        [[ "$cnt" -gt 0 ]] || die "После применения фильтра не осталось ни одного компонента."
        ok "Выбранные компоненты: $(selected_components_summary)"
        return 0
    fi

    if [[ -t 0 || -r /dev/tty ]]; then
        select_components_interactive "$mode" || return 1
        ok "Выбранные компоненты: $(selected_components_summary)"
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

    # 9. SSL/TLS сертификаты (вне /root/cert)
    local certs_summary=()
    if [[ "$DETECTED_LETSENCRYPT" == "true" ]]; then
        local le_domains
        le_domains="$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null | awk -F/ '{print $NF}' | paste -sd, - 2>/dev/null || true)"
        [[ -z "$le_domains" ]] && le_domains="активен"
        certs_summary+=("Let's Encrypt: $le_domains")
    fi
    if [[ ${#DETECTED_EXTRA_CERTS[@]} -gt 0 ]]; then
        certs_summary+=("${#DETECTED_EXTRA_CERTS[@]} внешних файлов")
    fi

    if [[ ${#certs_summary[@]} -gt 0 ]]; then
        local cert_desc
        cert_desc="$(IFS=", "; echo "${certs_summary[*]}")"
        printf '  %s[✔]%s %-16s %s (будут перенесены)\n' \
            "$C_GREEN" "$C_RESET" "SSL сертификаты" "$cert_desc"
        count=$((count + 1))
    else
        printf '  %s[i]%s %-16s в /root/cert или отсутствуют (выпуск через 3x-ui)\n' \
            "$C_CYAN" "$C_RESET" "SSL сертификаты"
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

    # DoT DNS-кэш диагностика
    local dot_status="не настроен"
    if [[ -f /etc/unbound/unbound.conf.d/dot-cache.conf ]] && (systemctl is-active --quiet unbound 2>/dev/null || pgrep -x unbound >/dev/null 2>&1); then
        dot_status="активен (unbound DoT 127.0.0.1:53)"
    elif command -v unbound >/dev/null 2>&1; then
        dot_status="unbound установлен, dot-cache.conf не настроен"
    fi
    printf '  %s[i]%s %-16s %s\n' "$C_CYAN" "$C_RESET" "DoT DNS-кэш" "$dot_status"

    printf '%s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf 'Готовность к миграции: обнаружено %s ключевых компонентов.\n' "$count"
}

# ── 3. Упаковка в защищённый бандл (PACK) ─────────────────────────────────────
pack_components() {
    local target_archive="${1:-/tmp/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz}"
    local legacy_with_ssh="${2:-}"
    if [[ "$legacy_with_ssh" == "true" ]]; then
        SEL_SSH="true"
    elif [[ "$legacy_with_ssh" == "false" ]]; then
        SEL_SSH="false"
    fi

    local pack_bot="false"
    local pack_web="false"
    local pack_mw="false"
    local pack_redis="false"
    local pack_nginx="false"
    local pack_copyparty="false"
    local pack_ssh="false"
    local pack_le="false"
    local pack_extra_certs="false"

    [[ -n "$DETECTED_BOT" && "$SEL_BOT" == "true" ]] && pack_bot="true"
    [[ -n "$DETECTED_WEB" && "$SEL_WEB" == "true" ]] && pack_web="true"
    [[ -n "$DETECTED_MW" && "$SEL_MW" == "true" ]] && pack_mw="true"
    [[ "$DETECTED_REDIS" == "true" && "$SEL_REDIS" == "true" ]] && pack_redis="true"
    [[ "$DETECTED_NGINX" == "true" && "$SEL_NGINX" == "true" ]] && pack_nginx="true"
    [[ -n "$DETECTED_COPYPARTY" && "$SEL_COPYPARTY" == "true" ]] && pack_copyparty="true"
    [[ "$AVAIL_SSH" == "true" && "$SEL_SSH" == "true" ]] && pack_ssh="true"
    if [[ "$SEL_CERTS" == "true" ]]; then
        [[ "$DETECTED_LETSENCRYPT" == "true" ]] && pack_le="true"
        [[ ${#DETECTED_EXTRA_CERTS[@]} -gt 0 ]] && pack_extra_certs="true"
    fi

    local staging
    staging="$(mktemp -d /tmp/caelix_pack_XXXXXX)"
    chmod 700 "$staging"

    log "Подготовка данных для миграции в $staging..."

    mkdir -p "$staging/meta"
    local manifest="$staging/meta/manifest.env"

    {
        echo "# CaelixFlow Migration Manifest"
        echo "PACKED_AT=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo "HAS_BOT=\"$pack_bot\""
        echo "HAS_WEB=\"$pack_web\""
        echo "HAS_MW=\"$pack_mw\""
        echo "HAS_REDIS=\"$pack_redis\""
        echo "HAS_NGINX=\"$pack_nginx\""
        echo "HAS_COPYPARTY=\"$pack_copyparty\""
        echo "HAS_XUI=\"$DETECTED_XUI\""
        echo "HAS_SSH=\"$pack_ssh\""
        echo "HAS_LETSENCRYPT=\"$pack_le\""
        echo "HAS_EXTRA_CERTS=\"$pack_extra_certs\""
    } > "$manifest"

    # 1. VPN-Bot
    if [[ "$pack_bot" == "true" ]]; then
        log "Сбор Vpn-Bot..."
        mkdir -p "$staging/bot"
        if [[ -f "$DETECTED_BOT/.env" ]]; then
            cp -a "$DETECTED_BOT/.env" "$staging/bot/.env"
        fi
        local bot_db_snapshotted="false"
        if [[ -f "$DETECTED_BOT/data/bot.db" ]]; then
            mkdir -p "$staging/bot/data"
            log "Создание целостного горячего снимка bot.db (sqlite3 backup)..."
            if command -v sqlite3 >/dev/null 2>&1; then
                sqlite3 "$DETECTED_BOT/data/bot.db" ".backup '$staging/bot/data/bot.db'"
                sqlite3 "$staging/bot/data/bot.db" "PRAGMA integrity_check;" >/dev/null
                bot_db_snapshotted="true"
            else
                cp -a "$DETECTED_BOT/data/bot.db"* "$staging/bot/data/" 2>/dev/null || true
            fi
        fi
        if [[ -d "$DETECTED_BOT/data" ]]; then
            mkdir -p "$staging/bot/data"
            if [[ "$bot_db_snapshotted" == "true" ]]; then
                rsync -a --exclude="*.lock" --exclude="*.sock" --exclude="bot.db*" \
                    "$DETECTED_BOT/data/" "$staging/bot/data/" 2>/dev/null || true
            else
                rsync -a --exclude="*.lock" --exclude="*.sock" \
                    "$DETECTED_BOT/data/" "$staging/bot/data/" 2>/dev/null || true
            fi
        fi
        rsync -a --exclude=".venv" --exclude="__pycache__" --exclude=".git" --exclude="data" --exclude=".pytest_cache" \
            "$DETECTED_BOT/" "$staging/bot/app/" 2>/dev/null || true
    fi

    # 2. VPN-Website
    if [[ "$pack_web" == "true" ]]; then
        log "Сбор Vpn-Website..."
        mkdir -p "$staging/web"
        if [[ -f "$DETECTED_WEB/.env" ]]; then
            cp -a "$DETECTED_WEB/.env" "$staging/web/.env"
        fi
        rsync -a --exclude=".venv" --exclude="__pycache__" --exclude=".git" --exclude=".pytest_cache" \
            "$DETECTED_WEB/" "$staging/web/app/" 2>/dev/null || true
    fi

    # 3. MiddlewareJSON
    if [[ "$pack_mw" == "true" ]]; then
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
    if [[ "$pack_nginx" == "true" ]]; then
        log "Сбор конфигурации Nginx (nginx.conf, conf.d/*, snippets/streams при наличии)..."
        mkdir -p "$staging/nginx/conf.d"
        [[ -f "/etc/nginx/nginx.conf" ]] && cp -a "/etc/nginx/nginx.conf" "$staging/nginx/"
        [[ -d "/etc/nginx/conf.d" ]] && cp -a /etc/nginx/conf.d/* "$staging/nginx/conf.d/" 2>/dev/null || true
        for extra_ng_dir in "snippets" "streams"; do
            if [[ -d "/etc/nginx/$extra_ng_dir" ]]; then
                mkdir -p "$staging/nginx/$extra_ng_dir"
                rsync -a "/etc/nginx/$extra_ng_dir/" "$staging/nginx/$extra_ng_dir/" 2>/dev/null || true
            fi
        done
    fi

    # 5. Copyparty
    if [[ "$pack_copyparty" == "true" ]]; then
        log "Сбор Copyparty ($DETECTED_COPYPARTY)..."
        mkdir -p "$staging/copyparty"
        rsync -a "$DETECTED_COPYPARTY/" "$staging/copyparty/" 2>/dev/null || true
    fi

    # 6. SSH (authorized_keys, authorized_key и sshd_config)
    if [[ "$pack_ssh" == "true" ]]; then
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

    # 7. SSL/TLS сертификаты (вне /root/cert)
    if [[ "$pack_le" == "true" ]]; then
        log "Сбор сертификатов Let's Encrypt (/etc/letsencrypt)..."
        mkdir -p "$staging/certs/letsencrypt"
        rsync -a /etc/letsencrypt/ "$staging/certs/letsencrypt/" 2>/dev/null || true
    fi

    if [[ "$pack_extra_certs" == "true" ]]; then
        log "Сбор внешних SSL сертификатов (${#DETECTED_EXTRA_CERTS[@]} файлов)..."
        mkdir -p "$staging/certs/extra"
        for cfile in "${DETECTED_EXTRA_CERTS[@]}"; do
            if [[ -e "$cfile" || -L "$cfile" ]]; then
                local rel_dir
                rel_dir="$(dirname "$cfile" | sed 's|^/||')"
                mkdir -p "$staging/certs/extra/$rel_dir"
                cp -aL "$cfile" "$staging/certs/extra/$rel_dir/" 2>/dev/null || true
            fi
        done
    fi

    log "Упаковка архива $target_archive..."
    mkdir -p "$(dirname "$target_archive")"
    if command -v pigz >/dev/null 2>&1; then
        tar -I pigz -cf "$target_archive" -C "$staging" .
    else
        tar -czf "$target_archive" -C "$staging" .
    fi
    rm -rf "$staging"

    ok "Архив успешно создан: $target_archive ($(du -h "$target_archive" | cut -f1))"
}

# ── 4. Установка всех зависимостей на чистом Debian 13 (Trixie) ───────────────
install_system_dependencies() {
    local has_copyparty="${1:-false}"
    local need_python="${2:-true}"
    local need_redis="${3:-true}"
    local need_nginx="${4:-true}"
    log "Установка системных зависимостей (Debian 13 Trixie)..."

    export DEBIAN_FRONTEND=noninteractive
    log "Обновление списка пакетов (apt-get update)..."
    apt-get update

    # 1. Базовые системные утилиты и Python (при необходимости)
    log "1/5. Системные пакеты (curl, git, rsync, sqlite3, pigz)..."
    apt-get install -y --no-install-recommends \
        curl wget git rsync tar gzip bzip2 xz-utils sudo \
        ca-certificates gnupg lsb-release procps net-tools ufw \
        sqlite3 jq pigz

    if [[ "$need_python" == "true" ]]; then
        log "1.1/5. Python окружение и сборочные зависимости..."
        apt-get install -y --no-install-recommends \
            python3 python3-venv python3-pip python3-dev \
            build-essential libffi-dev libssl-dev
    fi

    # 2. Redis (только если выбран Redis)
    if [[ "$need_redis" == "true" ]]; then
        log "2/5. Redis-server..."
        apt-get install -y --no-install-recommends redis-server
        systemctl enable --now redis-server || true
    else
        log "2/5. Пропуск установки Redis (не выбран)..."
    fi

    # 3. Nginx и stream модуль (только если выбран Nginx; служба СРАЗУ останавливается!)
    if [[ "$need_nginx" == "true" ]]; then
        log "3/5. Nginx + libnginx-mod-stream (с немедленной остановкой для 80 порта)..."
        apt-get install -y --no-install-recommends nginx libnginx-mod-stream certbot python3-certbot-nginx
        systemctl stop nginx 2>/dev/null || true
    elif [[ "${HAS_LETSENCRYPT:-false}" == "true" ]]; then
        log "3/5. Установка certbot для сертификатов Let's Encrypt (Nginx не выбран)..."
        apt-get install -y --no-install-recommends certbot || true
    else
        log "3/5. Пропуск установки Nginx (не выбран)..."
    fi

    # 4. Docker и Docker Compose (только если на сервере обнаружен и выбран Copyparty)
    if [[ "$has_copyparty" == "true" ]]; then
        log "4/5. Docker & Docker Compose для Copyparty..."
        if ! command -v docker >/dev/null 2>&1; then
            local docker_sh
            docker_sh="$(mktemp /tmp/get-docker-XXXXXX.sh)"
            if curl -fsSL https://get.docker.com -o "$docker_sh"; then
                sh "$docker_sh" || true
                rm -f "$docker_sh"
            else
                warn "get.docker.com недоступен, пробуем установку из apt..."
                apt-get install -y --no-install-recommends docker.io docker-compose-v2 || true
            fi
        fi
        systemctl enable --now docker || true
    else
        log "4/5. Пропуск установки Docker (Copyparty не выбран)..."
    fi

    # 5. Оптимизация сети (BBR)
    log "5/5. Проверка сетевого тюнинга BBR..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        {
            echo "net.core.default_qdisc=fq"
            echo "net.ipv4.tcp_congestion_control=bbr"
        } >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
    fi

    ok "Системные зависимости готовы."
}

# ── Установка системных команд и алиасов консоли ──────────────────────────────
install_system_aliases_and_commands() {
    log "Настройка системных команд и алиасов (vpnplategabot, vpnwebsite, bot, web)..."

    # 1. VPN-Bot command
    if [[ -d "/opt/vpn-bot/deploy" ]]; then
        chmod +x /opt/vpn-bot/deploy/*.sh /opt/vpn-bot/deploy/lib/*.sh 2>/dev/null || true
        cat << 'EOF' > /usr/local/bin/vpnplategabot
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="/opt/vpn-bot"
CTL="$APP_DIR/deploy/vpn-bot-ctl.sh"
if [[ ! -f "$CTL" ]]; then
    echo "ERR: не найден $CTL" >&2
    exit 1
fi
exec bash "$CTL" "$@"
EOF
        chmod 755 /usr/local/bin/vpnplategabot
        ln -sf /usr/local/bin/vpnplategabot /usr/local/bin/bot
        ok "Установлена команда vpnplategabot (ярлык: bot)"
    fi

    # 2. VPN-Website command
    if [[ -d "/opt/vpn-website/deploy" ]]; then
        chmod +x /opt/vpn-website/deploy/*.sh /opt/vpn-website/deploy/lib/*.sh 2>/dev/null || true
        cat << 'EOF' > /usr/local/bin/vpnwebsite
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="/opt/vpn-website"
CTL="$APP_DIR/deploy/vpn-website-ctl.sh"
if [[ ! -f "$CTL" ]]; then
    echo "ERR: не найден $CTL" >&2
    exit 1
fi
exec bash "$CTL" "$@"
EOF
        chmod 755 /usr/local/bin/vpnwebsite
        ln -sf /usr/local/bin/vpnwebsite /usr/local/bin/web
        ok "Установлена команда vpnwebsite (ярлык: web)"
    fi

    # 3. Global shell profile aliases (/etc/profile.d/caelixflow.sh)
    mkdir -p /etc/profile.d
    cat << 'EOF' > /etc/profile.d/caelixflow.sh
# ==============================================================================
# CaelixFlow CLI Shortcuts & Management Aliases
# ==============================================================================
alias bot='vpnplategabot'
alias web='vpnwebsite'

alias bot-status='systemctl status vpn-bot-web vpn-bot-telegram'
alias bot-restart='systemctl restart vpn-bot-web vpn-bot-telegram'
alias bot-stop='systemctl stop vpn-bot-web vpn-bot-telegram'
alias bot-start='systemctl start vpn-bot-web vpn-bot-telegram'
alias bot-log='journalctl -u vpn-bot-web -u vpn-bot-telegram -f'
alias bot-logs='journalctl -u vpn-bot-web -u vpn-bot-telegram -f'

alias web-status='systemctl status vpn-website'
alias web-restart='systemctl restart vpn-website'
alias web-stop='systemctl stop vpn-website'
alias web-start='systemctl start vpn-website'
alias web-log='journalctl -u vpn-website -f'
alias web-logs='journalctl -u vpn-website -f'

alias caelix-status='systemctl status vpn-bot-web vpn-bot-telegram vpn-website nginx redis-server'
alias caelix-restart='systemctl restart vpn-bot-web vpn-bot-telegram vpn-website'
EOF
    chmod 644 /etc/profile.d/caelixflow.sh

    # Подключение в .bashrc для root и пользователей
    for rc in /root/.bashrc /home/*/.bashrc; do
        if [[ -f "$rc" ]] && ! grep -q "caelixflow.sh" "$rc" 2>/dev/null; then
            printf '\n# CaelixFlow Aliases\n[ -f /etc/profile.d/caelixflow.sh ] && . /etc/profile.d/caelixflow.sh\n' >> "$rc"
        fi
    done
    ok "Алиасы консоли прописаны в /etc/profile.d/caelixflow.sh и ~/.bashrc"
}

# ── 5. Развёртывание из архива (UNPACK) ────────────────────────────────────────
unpack_and_deploy() {
    local source_archive="$1"
    local skip_select="${2:-false}"
    [[ -f "$source_archive" ]] || die "Архив не найден: $source_archive"

    local staging
    staging="$(mktemp -d /tmp/caelix_unpack_XXXXXX)"
    chmod 700 "$staging"

    log "Распаковка бандла $source_archive..."
    tar -xf "$source_archive" -C "$staging"

    local manifest="$staging/meta/manifest.env"
    [[ -f "$manifest" ]] || die "В архиве отсутствует манифест meta/manifest.env!"

    # shellcheck source=/dev/null
    source "$manifest"
    ok "Манифест прочитан (создан $PACKED_AT)"

    # Заполняем доступность компонентов из архива для возможного выборочного развёртывания
    reset_availability
    [[ "${HAS_BOT:-false}" == "true" ]] && { AVAIL_BOT="true"; INFO_BOT="из архива"; }
    [[ "${HAS_WEB:-false}" == "true" ]] && { AVAIL_WEB="true"; INFO_WEB="из архива"; }
    [[ "${HAS_MW:-false}" == "true" ]] && { AVAIL_MW="true"; INFO_MW="из архива"; }
    [[ "${HAS_REDIS:-false}" == "true" ]] && { AVAIL_REDIS="true"; INFO_REDIS="из архива"; }
    [[ "${HAS_NGINX:-false}" == "true" ]] && { AVAIL_NGINX="true"; INFO_NGINX="из архива"; }
    [[ "${HAS_COPYPARTY:-false}" == "true" ]] && { AVAIL_COPYPARTY="true"; INFO_COPYPARTY="из архива"; }
    if [[ "${HAS_LETSENCRYPT:-false}" == "true" || "${HAS_EXTRA_CERTS:-false}" == "true" ]]; then
        AVAIL_CERTS="true"
        INFO_CERTS="из архива"
    fi
    [[ "${HAS_SSH:-false}" == "true" ]] && { AVAIL_SSH="true"; INFO_SSH="из архива"; }

    if [[ "$skip_select" == "true" ]]; then
        CLI_UNPACK_ALL="true"
    fi

    if ! resolve_component_selection "unpack"; then
        rm -rf "$staging"
        return 1
    fi

    [[ "$SEL_BOT" != "true" ]] && HAS_BOT="false"
    [[ "$SEL_WEB" != "true" ]] && HAS_WEB="false"
    [[ "$SEL_MW" != "true" ]] && HAS_MW="false"
    [[ "$SEL_REDIS" != "true" ]] && HAS_REDIS="false"
    [[ "$SEL_NGINX" != "true" ]] && HAS_NGINX="false"
    [[ "$SEL_COPYPARTY" != "true" ]] && HAS_COPYPARTY="false"
    [[ "$SEL_SSH" != "true" ]] && HAS_SSH="false"
    if [[ "$SEL_CERTS" != "true" ]]; then
        HAS_LETSENCRYPT="false"
        HAS_EXTRA_CERTS="false"
    fi

    local need_python="false"
    if [[ "${HAS_BOT:-false}" == "true" || "${HAS_WEB:-false}" == "true" || "${HAS_MW:-false}" == "true" ]]; then
        need_python="true"
    fi

    # 1. Зависимости (ставятся только нужные для выбранных компонентов)
    install_system_dependencies "${HAS_COPYPARTY:-false}" "$need_python" "${HAS_REDIS:-false}" "${HAS_NGINX:-false}"

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
            [[ -f /etc/ssh/sshd_config ]] && cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.caelix.bak
            cp -a "$staging/ssh/sshd_config" /etc/ssh/sshd_config
            if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
                warn "Новый /etc/ssh/sshd_config не прошёл проверку sshd -t! Восстанавливаем предыдущий конфиг..."
                if [[ -f /etc/ssh/sshd_config.caelix.bak ]]; then
                    cp -a /etc/ssh/sshd_config.caelix.bak /etc/ssh/sshd_config
                fi
            else
                ok "Конфигурация SSH (/etc/ssh/sshd_config) проверена и обновлена"
                if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
                    local new_ssh_port
                    new_ssh_port="$(detect_ssh_port "/etc/ssh/sshd_config")"
                    ufw allow "${new_ssh_port}/tcp" comment "SSH Port TCP" >/dev/null 2>&1 || true
                    ufw allow "${new_ssh_port}/udp" comment "SSH Port UDP" >/dev/null 2>&1 || true
                fi
            fi
        fi

        log "Перезапуск службы SSH (systemctl restart ssh sshd)..."
        systemctl restart ssh 2>/dev/null || true
        systemctl restart sshd 2>/dev/null || true
        ok "Службы SSH успешно перезапущены"
    fi

    # 3.5. Восстановление SSL/TLS сертификатов (вне /root/cert)
    if [[ "${HAS_LETSENCRYPT:-false}" == "true" && -d "$staging/certs/letsencrypt" ]]; then
        log "Восстановление сертификатов Let's Encrypt в /etc/letsencrypt..."
        mkdir -p /etc/letsencrypt
        rsync -a "$staging/certs/letsencrypt/" /etc/letsencrypt/
        chmod -R 755 /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
        ok "Сертификаты Let's Encrypt успешно восстановлены"
    fi

    if [[ "${HAS_EXTRA_CERTS:-false}" == "true" && -d "$staging/certs/extra" ]]; then
        log "Восстановление внешних SSL сертификатов..."
        (
            cd "$staging/certs/extra"
            find . -type f | while IFS= read -r rel_file; do
                local target_path="/${rel_file#./}"
                mkdir -p "$(dirname "$target_path")"
                cp -a "$rel_file" "$target_path"
                if [[ "$target_path" == *key* || "$target_path" == *.key ]]; then
                    chmod 600 "$target_path" 2>/dev/null || true
                else
                    chmod 644 "$target_path" 2>/dev/null || true
                fi
                log "Восстановлен SSL сертификат: $target_path"
            done
        )
        ok "Внешние SSL сертификаты успешно восстановлены"
    fi

    # 4. Nginx конфиги (служба остаётся выключенной)
    if [[ "${HAS_NGINX:-false}" == "true" && -d "$staging/nginx" ]]; then
        log "Раскладка конфигурации Nginx..."
        mkdir -p /etc/nginx/conf.d
        [[ -f "$staging/nginx/nginx.conf" ]] && cp -a "$staging/nginx/nginx.conf" /etc/nginx/
        [[ -d "$staging/nginx/conf.d" ]] && cp -a "$staging/nginx/conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
        for extra_ng_dir in "snippets" "streams"; do
            if [[ -d "$staging/nginx/$extra_ng_dir" ]]; then
                mkdir -p "/etc/nginx/$extra_ng_dir"
                rsync -a "$staging/nginx/$extra_ng_dir/" "/etc/nginx/$extra_ng_dir/" 2>/dev/null || true
            fi
        done

        log "Проверка синтаксиса Nginx (nginx -t)..."
        if nginx -t 2>/dev/null; then
            ok "Синтаксис Nginx корректен."
        else
            warn "nginx -t сообщил о замечаниях (сертификаты /root/cert будут созданы после мастера 3x-ui)."
        fi
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
        systemctl stop middlewarejson 2>/dev/null || true
        mkdir -p /opt/middlewarejson
        [[ -d "$staging/mw/app" ]] && rsync -a "$staging/mw/app/" /opt/middlewarejson/
        if [[ -f "$staging/mw/.env" ]]; then
            cp -a "$staging/mw/.env" /opt/middlewarejson/.env
            chmod 600 /opt/middlewarejson/.env 2>/dev/null || true
        fi
        if [[ -d "$staging/mw/data" ]]; then
            mkdir -p /opt/middlewarejson/data
            if [[ -f "$staging/mw/data/middleware.db" && ! -f "$staging/mw/data/middleware.db-wal" ]]; then
                rm -f /opt/middlewarejson/data/middleware.db-wal /opt/middlewarejson/data/middleware.db-shm /opt/middlewarejson/data/middleware.db-journal 2>/dev/null || true
            fi
            rsync -a "$staging/mw/data/" /opt/middlewarejson/data/
        fi

        log "Настройка Python .venv для MiddlewareJSON..."
        [[ ! -d "/opt/middlewarejson/.venv" ]] && python3 -m venv /opt/middlewarejson/.venv
        if [[ -f "/opt/middlewarejson/requirements.txt" ]]; then
            log "Установка зависимостей MiddlewareJSON (pip)..."
            /opt/middlewarejson/.venv/bin/pip install --upgrade pip 2>/dev/null || true
            /opt/middlewarejson/.venv/bin/pip install --no-cache-dir -r /opt/middlewarejson/requirements.txt
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
TimeoutStopSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable middlewarejson >/dev/null 2>&1 || true
        systemctl restart middlewarejson || true
        ok "MiddlewareJSON настроен и перезапущен"
    fi

    # 7. Vpn-Bot (выполняется до Vpn-Website, чтобы общая data/bot.db уже была на месте)
    if [[ "${HAS_BOT:-false}" == "true" && -d "$staging/bot" ]]; then
        log "Восстановление Vpn-Bot в /opt/vpn-bot..."
        local web_was_active="false"
        if systemctl is-active --quiet vpn-website 2>/dev/null; then
            web_was_active="true"
            systemctl stop vpn-website 2>/dev/null || true
        fi
        systemctl stop vpn-bot-web vpn-bot-telegram 2>/dev/null || true

        mkdir -p /opt/vpn-bot
        [[ -d "$staging/bot/app" ]] && rsync -a "$staging/bot/app/" /opt/vpn-bot/
        if [[ -f "$staging/bot/.env" ]]; then
            cp -a "$staging/bot/.env" /opt/vpn-bot/.env
        fi
        if [[ -d "$staging/bot/data" ]]; then
            mkdir -p /opt/vpn-bot/data
            if [[ -f "$staging/bot/data/bot.db" && ! -f "$staging/bot/data/bot.db-wal" ]]; then
                rm -f /opt/vpn-bot/data/bot.db-wal /opt/vpn-bot/data/bot.db-shm /opt/vpn-bot/data/bot.db-journal 2>/dev/null || true
            fi
            rsync -a "$staging/bot/data/" /opt/vpn-bot/data/
        fi

        log "Настройка Python .venv для Vpn-Bot..."
        [[ ! -d "/opt/vpn-bot/.venv" ]] && python3 -m venv /opt/vpn-bot/.venv
        if [[ -f "/opt/vpn-bot/requirements.txt" ]]; then
            sed -i 's|^incy-link-encoder.*|incy-link-encoder @ git+https://github.com/INCY-DEV/incy-link-encoder.git#subdirectory=python|' /opt/vpn-bot/requirements.txt
            log "Установка зависимостей Vpn-Bot (pip)..."
            /opt/vpn-bot/.venv/bin/pip install --upgrade pip 2>/dev/null || true
            /opt/vpn-bot/.venv/bin/pip install --no-cache-dir -r /opt/vpn-bot/requirements.txt
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
TimeoutStopSec=5
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
TimeoutStopSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable vpn-bot-web vpn-bot-telegram >/dev/null 2>&1 || true
        systemctl restart vpn-bot-web vpn-bot-telegram || true
        if [[ "$web_was_active" == "true" && "${HAS_WEB:-false}" != "true" ]]; then
            systemctl start vpn-website 2>/dev/null || true
        fi
        ok "Vpn-Bot настроен и перезапущен"
    fi

    # 8. Vpn-Website
    if [[ "${HAS_WEB:-false}" == "true" && -d "$staging/web" ]]; then
        log "Восстановление Vpn-Website в /opt/vpn-website..."
        systemctl stop vpn-website 2>/dev/null || true
        mkdir -p /opt/vpn-website
        [[ -d "$staging/web/app" ]] && rsync -a "$staging/web/app/" /opt/vpn-website/
        if [[ -f "$staging/web/.env" ]]; then
            cp -a "$staging/web/.env" /opt/vpn-website/.env
            chmod 600 /opt/vpn-website/.env 2>/dev/null || true
        fi

        log "Настройка Python .venv для Vpn-Website..."
        [[ ! -d "/opt/vpn-website/.venv" ]] && python3 -m venv /opt/vpn-website/.venv
        if [[ -f "/opt/vpn-website/requirements.txt" ]]; then
            sed -i 's|^incy-link-encoder.*|incy-link-encoder @ git+https://github.com/INCY-DEV/incy-link-encoder.git#subdirectory=python|' /opt/vpn-website/requirements.txt
            log "Установка зависимостей Vpn-Website (pip)..."
            /opt/vpn-website/.venv/bin/pip install --upgrade pip 2>/dev/null || true
            /opt/vpn-website/.venv/bin/pip install --no-cache-dir -r /opt/vpn-website/requirements.txt
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
TimeoutStopSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable vpn-website >/dev/null 2>&1 || true
        systemctl restart vpn-website || true
        ok "Vpn-Website настроен и перезапущен"
    fi

    # 9. Системные команды и алиасы консоли
    install_system_aliases_and_commands

    rm -rf "$staging"

    # Проверка статуса развёрнутых служб
    local check_services=()
    [[ "${HAS_REDIS:-false}" == "true" ]] && check_services+=("redis-server")
    [[ "${HAS_MW:-false}" == "true" ]] && check_services+=("middlewarejson")
    [[ "${HAS_WEB:-false}" == "true" ]] && check_services+=("vpn-website")
    [[ "${HAS_BOT:-false}" == "true" ]] && check_services+=("vpn-bot-web" "vpn-bot-telegram")

    local all_healthy="true"
    if [[ ${#check_services[@]} -gt 0 ]]; then
        sleep 2
        echo
        printf '%sПроверка состояния развёрнутых служб:%s\n' "$C_BOLD" "$C_RESET"
        local svc
        for svc in "${check_services[@]}"; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf '  %s[✔]%s %-20s активна\n' "$C_GREEN" "$C_RESET" "$svc"
            else
                printf '  %s[ERR]%s %-18s не запустилась (лог: journalctl -u %s -n 20 --no-pager)\n' \
                    "$C_RED" "$C_RESET" "$svc" "$svc"
                all_healthy="false"
            fi
        done
    fi

    echo
    if [[ "$all_healthy" == "true" ]]; then
        ok "=========================================================="
        ok "  Все выбранные службы успешно развёрнуты и запущены!    "
        ok "=========================================================="
    else
        warn "=========================================================="
        warn "  Развёртывание завершено, но есть службы с ошибкой старта "
        warn "=========================================================="
    fi
    if [[ "${HAS_BOT:-false}" == "true" || "${HAS_WEB:-false}" == "true" ]]; then
        printf '\n%sКоманды управления службами в консоли:%s\n' "$C_BOLD" "$C_RESET"
        if [[ "${HAS_BOT:-false}" == "true" ]]; then
            printf '  • Бот:    %svpnplategabot%s  (или %sbot%s, %sbot-status%s, %sbot-restart%s, %sbot-logs%s)\n' \
                "$C_GREEN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
        fi
        if [[ "${HAS_WEB:-false}" == "true" ]]; then
            printf '  • Сайт:   %svpnwebsite%s     (или %sweb%s, %sweb-status%s, %sweb-restart%s, %sweb-logs%s)\n' \
                "$C_GREEN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
        fi
        printf '  • Общее:  %scaelix-status%s, %scaelix-restart%s\n\n' \
            "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    fi

    # 8. Настройка и включение UFW фаервола
    local configure_ufw="true"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
        printf '\n%s?%s %sUFW фаервол уже активен на этом сервере. Обновить/добавить базовые правила (SSH, 80, 443)?%s %s[y/N]%s: ' \
            "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
        local raw_ufw_ans=""
        if [[ -r /dev/tty ]]; then read -r raw_ufw_ans < /dev/tty || true; else read -r raw_ufw_ans || true; fi
        local ufw_ans
        ufw_ans="$(echo "${raw_ufw_ans:-N}" | tr -d '[:space:]')"
        case "$ufw_ans" in
            [yY]|[yY][eE][sS]|[дД]|[дД][аА]) configure_ufw="true" ;;
            *) configure_ufw="false"; log "Пропуск изменения правил UFW (текущие правила сохранены)." ;;
        esac
    fi

    if [[ "$configure_ufw" == "true" ]]; then
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
    fi

    prompt_unbound_dot_installation

    if ! systemctl is-active --quiet x-ui 2>/dev/null && [[ ! -f /etc/x-ui/x-ui.db ]]; then
        prompt_3xui_installation
    fi
}

# ── Интерактивное предложение настройки DoT DNS-кэша (unbound) ────────────────
prompt_unbound_dot_installation() {
    if [[ -f /etc/unbound/unbound.conf.d/dot-cache.conf ]] && (systemctl is-active --quiet unbound 2>/dev/null || pgrep -x unbound >/dev/null 2>&1); then
        ok "Локальный DoT DNS-кэш (unbound 127.0.0.1:53) уже активен."
        return 0
    fi

    printf '\n%s?%s %sНастроить локальный шифрованный DoT DNS-кэш (unbound на 127.0.0.1:53)?%s %s[Y/n]%s: ' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"

    local raw_answer=""
    if [[ -r /dev/tty ]]; then
        read -r raw_answer < /dev/tty || true
    else
        read -r raw_answer || true
    fi
    local answer
    answer="$(echo "${raw_answer:-Y}" | tr -d '[:space:]')"

    case "$answer" in
        [nN]|[nN][oO]|[нН]|[нН][еЕ][тТ])
            log "Пропуск настройки DoT DNS-кэша. Вы можете настроить его позже командой: sudo bash $0 dns"
            ;;
        *)
            setup_unbound_dot_dns || warn "Не удалось настроить unbound DoT DNS-кэш (продолжаем)."
            ;;
    esac
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
    local target_endpoint target_port
    if [[ -n "${1:-}" ]]; then
        read -r target_endpoint target_port <<< "$(parse_ssh_endpoint "$1" "${2:-}")"
    else
        read -r target_endpoint target_port <<< "$(ask_ssh_endpoint "Введите SSH адрес целевого сервера")"
    fi

    scan_components "true"
    resolve_component_selection "pack" || return 1

    log "Запуск переноса НА $target_endpoint (порт $target_port): $(selected_components_summary)..."
    init_ssh_session "$target_endpoint" "$target_port"
    trap 'close_ssh_session "$target_endpoint" "$target_port"' EXIT INT TERM

    local tmp_archive="/tmp/caelix_transfer_$(date +%s).tar.gz"
    pack_components "$tmp_archive"

    deploy_remote_script "$target_endpoint" "$target_port"
    transfer_file "push" "$target_endpoint" "$target_port" "/tmp/caelix-bundle.tar.gz" "$tmp_archive"
    rm -f "$tmp_archive"

    log "Запуск развёртывания на $target_endpoint..."
    ssh -t "${SSH_MUX_OPTS[@]}" "$target_endpoint" \
        'if [ "$(id -u)" -eq 0 ]; then bash /tmp/migrate.sh unpack /tmp/caelix-bundle.tar.gz --all; else sudo bash /tmp/migrate.sh unpack /tmp/caelix-bundle.tar.gz --all; fi'
    ssh "${SSH_MUX_OPTS[@]}" "$target_endpoint" "rm -f /tmp/migrate.sh /tmp/caelix-bundle.tar.gz" 2>/dev/null || true

    close_ssh_session "$target_endpoint" "$target_port"
    trap - EXIT INT TERM

    ok "Миграция на $target_endpoint успешно завершена!"
}

# ── 8. Забор данных со старого сервера по SSH (PULL) ─────────────────────────
pull_from_source() {
    local source_endpoint source_port
    if [[ -n "${1:-}" ]]; then
        read -r source_endpoint source_port <<< "$(parse_ssh_endpoint "$1" "${2:-}")"
    else
        read -r source_endpoint source_port <<< "$(ask_ssh_endpoint "Введите SSH адрес старого сервера")"
    fi

    log "Подключение к старому серверу $source_endpoint (порт $source_port)..."
    init_ssh_session "$source_endpoint" "$source_port"
    trap 'close_ssh_session "$source_endpoint" "$source_port"' EXIT INT TERM

    deploy_remote_script "$source_endpoint" "$source_port"
    scan_remote_components "$source_endpoint"

    if ! resolve_component_selection "pack"; then
        ssh "${SSH_MUX_OPTS[@]}" "$source_endpoint" "rm -f /tmp/migrate.sh" 2>/dev/null || true
        close_ssh_session "$source_endpoint" "$source_port"
        trap - EXIT INT TERM
        return 1
    fi

    local selected_csv
    selected_csv="$(selected_components_to_csv)"

    log "Сборка архива на удаленном сервере ($source_endpoint): $(selected_components_summary)..."
    ssh -t "${SSH_MUX_OPTS[@]}" "$source_endpoint" \
        "if [ \"\$(id -u)\" -eq 0 ]; then bash /tmp/migrate.sh pack /tmp/caelix-source-bundle.tar.gz --only '$selected_csv'; else sudo bash /tmp/migrate.sh pack /tmp/caelix-source-bundle.tar.gz --only '$selected_csv'; fi"

    local local_archive="/tmp/caelix-bundle.tar.gz"
    transfer_file "pull" "$source_endpoint" "$source_port" "/tmp/caelix-source-bundle.tar.gz" "$local_archive"
    ssh "${SSH_MUX_OPTS[@]}" "$source_endpoint" "rm -f /tmp/migrate.sh /tmp/caelix-source-bundle.tar.gz" 2>/dev/null || true

    close_ssh_session "$source_endpoint" "$source_port"
    trap - EXIT INT TERM

    log "Начало развёртывания на текущем сервере..."
    unpack_and_deploy "$local_archive" "true"
    rm -f "$local_archive"
}

# ── 8.5. Проверка IP через iplense.cc ──────────────────────────────────────────
check_ip_iplense() {
    log "Запуск проверки IP и чистоты сети через iplense.cc..."
    if ! command -v curl >/dev/null 2>&1; then
        warn "Утилита curl не найдена. Попытка установки..."
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq curl || true
        fi
    fi

    if ! command -v curl >/dev/null 2>&1; then
        err "Для проверки IP требуется curl. Установите его вручную: apt install -y curl"
        return 1
    fi

    echo
    bash <(curl -sL https://iplense.cc/cli) -l en || {
        warn "Прямой запуск через подстановку процессов не удался, пробуем пайп..."
        curl -sL https://iplense.cc/cli | bash -s -- -l en || true
    }
}

# ── 8.6. Измерение скорости интернета (speedtest-cli) ─────────────────────────
run_speedtest() {
    log "Запуск измерения скорости интернета (speedtest-cli)..."

    # 1. Если speedtest-cli уже установлен
    if command -v speedtest-cli >/dev/null 2>&1; then
        echo
        speedtest-cli "$@" || true
        return 0
    fi

    # 2. Если установлен официальный Ookla speedtest
    if command -v speedtest >/dev/null 2>&1; then
        echo
        speedtest "$@" || true
        return 0
    fi

    # 3. Попытка быстрой установки через apt, если есть root
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        log "Установка пакета speedtest-cli через apt..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq speedtest-cli || true
    fi

    if command -v speedtest-cli >/dev/null 2>&1; then
        echo
        speedtest-cli "$@" || true
        return 0
    fi

    # 4. Автономный запуск скрипта через python3 без необходимости установки пакетов
    if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        log "Запуск автономного speedtest-cli через Python 3..."
        echo
        python3 <(curl -sL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py) "$@" || {
            curl -sL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 - "$@" || true
        }
        return 0
    fi

    err "Не удалось запустить speedtest-cli. Установите его командой: apt install -y speedtest-cli"
    return 1
}

# ── 9. Интерактивное главное меню ─────────────────────────────────────────────
interactive_menu() {
    while true; do
        banner
        if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
            warn "Скрипт запущен без прав root. Пункты [1-4] потребуют прав root (sudo)."
            echo
        fi

        printf '  %s1)%s  %s[PUSH]%s      Перенести этот сервер НА другой (с выбором компонентов)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s2)%s  %s[PULL]%s      Забрать данные СО старого сервера (с выбором компонентов)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s3)%s  %s[PACK]%s      Создать локальный .tar.gz архив (с выбором компонентов)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s4)%s  %s[UNPACK]%s    Развернуть систему из локального архива\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s5)%s  %s[SCAN]%s      Проверить, что будет перенесено (Dry Run, только аудит)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s6)%s  %s[IPLENSE]%s   Проверить IP адрес и чистоту сети (iplense.cc)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s7)%s  %s[SPEEDTEST]%s Измерение скорости интернета (speedtest-cli)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s8)%s  %s[DNS-DOT]%s   Настроить локальный DoT DNS-кэш (unbound 127.0.0.1:53)\n\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '  %s0)%s  Выход\n\n' "$C_DIM" "$C_RESET"

        local raw_choice=""
        printf '%sВыберите действие [0-8]: %s' "$C_BOLD" "$C_RESET"
        if [[ -r /dev/tty ]]; then
            read -r raw_choice < /dev/tty || true
        else
            read -r raw_choice || true
        fi

        local choice
        choice="$(echo "${raw_choice:-0}" | tr -d '[:space:]')"

        case "$choice" in
            1)
                ensure_root
                CLI_ONLY_COMPONENTS=""
                CLI_EXCLUDE_COMPONENTS=""
                CLI_WITH_SSH="false"
                CLI_UNPACK_ALL="false"
                if push_to_target; then
                    break
                fi
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            2)
                ensure_root
                CLI_ONLY_COMPONENTS=""
                CLI_EXCLUDE_COMPONENTS=""
                CLI_WITH_SSH="false"
                CLI_UNPACK_ALL="false"
                if pull_from_source; then
                    break
                fi
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            3)
                ensure_root
                CLI_ONLY_COMPONENTS=""
                CLI_EXCLUDE_COMPONENTS=""
                CLI_WITH_SSH="false"
                CLI_UNPACK_ALL="false"
                local out=""
                printf '%sПуть для архива [/root/caelix-migration-%s.tar.gz]: %s' "$C_CYAN" "$(date +%Y%m%d_%H%M%S)" "$C_RESET"
                if [[ -r /dev/tty ]]; then
                    read -r out < /dev/tty || true
                else
                    read -r out || true
                fi
                out="$(echo "$out" | tr -d '[:space:]')"
                [[ -z "$out" ]] && out="/root/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz"

                scan_components "true"
                if resolve_component_selection "pack"; then
                    pack_components "$out"
                fi
                printf '\nНажмите Enter, чтобы продолжить...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            4)
                ensure_root
                CLI_ONLY_COMPONENTS=""
                CLI_EXCLUDE_COMPONENTS=""
                CLI_WITH_SSH="false"
                CLI_UNPACK_ALL="false"
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
                if unpack_and_deploy "$in_file"; then
                    break
                fi
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            5)
                run_scan_audit
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            6)
                check_ip_iplense
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            7)
                run_speedtest
                printf '\nНажмите Enter, чтобы вернуться в меню...'
                if [[ -r /dev/tty ]]; then read -r _ < /dev/tty || true; else read -r _ || true; fi
                ;;
            8)
                ensure_root
                setup_unbound_dot_dns
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
            parse_component_args "$@"
            push_to_target "${POSITIONAL_ARGS[0]:-}" "${POSITIONAL_ARGS[1]:-}"
            ;;
        pull)
            ensure_root
            banner
            parse_component_args "$@"
            pull_from_source "${POSITIONAL_ARGS[0]:-}" "${POSITIONAL_ARGS[1]:-}"
            ;;
        pack)
            ensure_root
            banner
            parse_component_args "$@"
            local pack_out="${POSITIONAL_ARGS[0]:-/tmp/caelix-migration-$(date +%Y%m%d_%H%M%S).tar.gz}"
            local legacy_ssh="${POSITIONAL_ARGS[1]:-}"
            if [[ "$legacy_ssh" == "true" || "$legacy_ssh" == "false" ]]; then
                CLI_WITH_SSH="$legacy_ssh"
                CLI_UNPACK_ALL="true"
            fi
            scan_components "true"
            resolve_component_selection "pack" || exit 1
            pack_components "$pack_out"
            ;;
        unpack)
            ensure_root
            banner
            parse_component_args "$@"
            unpack_and_deploy "${POSITIONAL_ARGS[0]:-}"
            ;;
        scan)
            if [[ "${1:-}" == "--env" ]]; then
                print_scan_env
                return 0
            fi
            banner
            if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                warn "Скрипт запущен без прав root. Некоторые пути могут быть недоступны для проверки."
            fi
            run_scan_audit
            ;;
        ip|iplense|check-ip|checkip)
            banner
            check_ip_iplense
            ;;
        speed|speedtest|speedtest-cli)
            banner
            run_speedtest "$@"
            ;;
        dns|dot|dns-dot)
            ensure_root
            banner
            setup_unbound_dot_dns
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
            interactive_menu
            ;;
        *)
            banner
            err "Неизвестная команда: $cmd"
            echo "Использование: sudo bash $0 [push|pull|pack|unpack|scan|ufw|dns|ip|speed] [--only bot,web] [--exclude bot,web]"
            exit 1
            ;;
    esac
}

main "$@"
