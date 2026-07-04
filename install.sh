#!/bin/bash
# ============================================================
# 3X-UI Installer — Automatic installation & configuration
# For Ubuntu/Debian. Idempotent: safe to re-run.
# ============================================================
# Usage:
#   sudo bash install.sh
#   sudo bash install.sh --non-interactive   (uses saved config or fails)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Self-bootstrap: if lib/ not found (e.g. curl | bash), download repo to temp dir
if [ ! -d "$LIB_DIR" ]; then
    echo "[bootstrap] lib/ not found locally — downloading 3x-ui-installer from GitHub..."
    TMP_DIR=$(mktemp -d)
    curl -sL "https://github.com/svu2009-prog/3x-ui-installer/archive/refs/heads/master.tar.gz" \
        | tar -xz -C "$TMP_DIR"
    SCRIPT_DIR="${TMP_DIR}/3x-ui-installer-master"
    LIB_DIR="${SCRIPT_DIR}/lib"
    cd "$SCRIPT_DIR"
fi

for _lib in common checks firewall nginx panel xray; do
    # shellcheck disable=SC1090
    source "${LIB_DIR}/${_lib}.sh"
done

# ============================================================
# CORE FUNCTIONS
# ============================================================

prompt_for_config() {
    log_section "Ввод данных"

    prompt_with_default "Введите доменное имя (например, example.com)" "" DOMAIN
    prompt_with_default "Введите Email для Let's Encrypt" "" EMAIL
    prompt_with_default "Введите External Proxy Address (IP или домен)" "" EXT_PROXY

    # Generate random values only if not already set from config
    [ -z "${PANEL_PORT:-}" ]        && PANEL_PORT=$(generate_random_port)
    [ -z "${TROJAN_PORT:-}" ]       && TROJAN_PORT=$(generate_random_port)
    [ -z "${TROJAN_TLS_PORT:-}" ]   && TROJAN_TLS_PORT=$(generate_random_port)
    [ -z "${PANEL_PATH:-}" ]        && PANEL_PATH=$(generate_random_string 15)
    [ -z "${PANEL_USER:-}" ]        && PANEL_USER="admin$(generate_random_string 4 0-9)"
    [ -z "${PANEL_PASS:-}" ]        && PANEL_PASS=$(generate_random_string 16)
    [ -z "${SUB_ID_VLESS:-}" ]      && SUB_ID_VLESS=$(generate_random_string 16)
    [ -z "${SUB_ID_TROJAN:-}" ]     && SUB_ID_TROJAN=$(generate_random_string 16)
    [ -z "${SUB_ID_TROJAN_TLS:-}" ] && SUB_ID_TROJAN_TLS=$(generate_random_string 16)
    [ -z "${TIMESTAMP:-}" ]         && TIMESTAMP=$(date +%s%3N)
    [ -z "${CRED_FILE:-}" ]         && CRED_FILE="/root/x-ui-setup-credentials.txt"

    log_success "Конфигурация загружена"
}

install_dependencies() {
    log_section "Зависимости системы"

    local packages=(curl wget socat nginx certbot python3-certbot-nginx sqlite3 jq ufw openssl unzip tar)
    local to_install=()

    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            log_debug "Пакет ${pkg} уже установлен"
        else
            to_install+=("$pkg")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        log_success "Все зависимости уже установлены"
        return
    fi

    log_info "Установка: ${to_install[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || { log_error "apt-get update failed"; exit 1; }
    apt-get install -y "${to_install[@]}" || { log_error "apt-get install failed"; exit 1; }
    log_success "Зависимости установлены"
}

start_services() {
    log_section "Запуск сервисов"

    systemctl start x-ui
    systemctl restart nginx

    sleep 3

    local xray_pid
    xray_pid=$(pgrep -f "xray-linux" || true)
    if [ -n "$xray_pid" ]; then
        log_success "Xray запущен (PID: ${xray_pid})"
    else
        log_warn "Xray не запустился. Логи: journalctl -u x-ui -e"
    fi

    log_info "Финальный перезапуск панели (применение SSL)..."
    x-ui restart >/dev/null 2>&1 || true
    sleep 2

    log_success "Сервисы запущены"
}

verify_setup() {
    log_section "Проверка установки"

    local errors=0

    # 1. Service status
    if is_service_active "x-ui"; then
        log_success "x-ui: active"
    else
        log_error "x-ui: не запущен (journalctl -u x-ui -e)"
        ((errors++)) || true
    fi

    if is_service_active "nginx"; then
        log_success "nginx: active"
    else
        log_error "nginx: не запущен"
        ((errors++)) || true
    fi

    sleep 2

    # 2. Check nginx stub page on 8080
    local stub
    stub=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080 2>/dev/null || true)
    if [ "$stub" = "200" ]; then
        log_success "Страница-заглушка nginx (8080): доступна (HTTP ${stub})"
    else
        log_warn "Страница-заглушка nginx (8080): недоступна (HTTP ${stub:-нет ответа})"
        ((errors++)) || true
    fi

    # 3. Check xray port 443 via localhost (TLS)
    local xray_443
    xray_443=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 https://127.0.0.1:443 2>/dev/null || true)
    if [ "$xray_443" = "200" ]; then
        log_success "Xray fallback (443 → 8080): работает (HTTP ${xray_443})"
    else
        log_warn "Xray fallback (443 → 8080): не отвечает (HTTP ${xray_443:-нет ответа})"
        log_warn "Возможно: сертификаты недоступны или inbound не настроен"
        ((errors++)) || true
    fi

    # 4. Check port 443 from inside
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        log_success "Порт 443: слушается"
    else
        log_warn "Порт 443: никто не слушает"
        ((errors++)) || true
    fi

    if [ "$errors" -gt 0 ]; then
        log_warn "Обнаружено ${errors} проблем. Проверьте журналы: journalctl -u x-ui -e --no-pager"
    else
        log_success "Все проверки пройдены"
    fi
}

show_summary() {
    log_section "Итог установки"

    local vless_url="vless://${UUID}@${DOMAIN}:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=${DOMAIN}&fp=chrome#VLESS-TLS-Fallback"
    local trojan_url="trojan://${TROJAN_PASS}@${EXT_PROXY}:${TROJAN_PORT}?security=reality&serviceName=grpc&type=grpc&pbk=${PUBLIC_KEY}&sni=www.microsoft.com&sid=${SHORT_ID}&fp=chrome#Trojan-Reality"
    local trojan_tls_url="trojan://${TROJAN_TLS_PASS}@${DOMAIN}:${TROJAN_TLS_PORT}?security=tls&type=grpc&sni=${DOMAIN}&fp=chrome#Trojan-gRPC-TLS"

    # Save credentials file
    {
        echo "=== Данные 3X-UI ==="
        echo "Домен: ${DOMAIN}"
        echo "External Proxy: ${EXT_PROXY}"
        echo "Порт панели: ${PANEL_PORT}"
        echo "Путь панели: /${PANEL_PATH}"
        echo "Логин панели: ${PANEL_USER}"
        echo "Пароль панели: ${PANEL_PASS}"
        echo "Порт Trojan (Reality): ${TROJAN_PORT}"
        echo "Порт Trojan (TLS): ${TROJAN_TLS_PORT}"
        echo ""
        echo "=== Ключи подключений ==="
        echo "VLESS UUID: ${UUID}"
        echo "Trojan Pass (Reality): ${TROJAN_PASS}"
        echo "Trojan Pass (TLS): ${TROJAN_TLS_PASS}"
        echo "Reality Private Key: ${PRIVATE_KEY}"
        echo "Reality Public Key: ${PUBLIC_KEY}"
        echo "Reality ShortID: ${SHORT_ID}"
        echo ""
        echo "=== Ссылки для импорта ==="
        echo "VLESS: ${vless_url}"
        echo "Trojan Reality: ${trojan_url}"
        echo "Trojan TLS: ${trojan_tls_url}"
    } > "$CRED_FILE"

    # Console output
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}               УСТАНОВКА ЗАВЕРШЕНА!                          ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}--- Панель управления 3X-UI (HTTPS) ---${NC}"
    echo -e "  URL:      ${GREEN}https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}${NC}"
    echo -e "  Логин:    ${GREEN}${PANEL_USER}${NC}"
    echo -e "  Пароль:   ${GREEN}${PANEL_PASS}${NC}"
    echo ""
    echo -e "${CYAN}--- Ссылки для клиентов ---${NC}"
    echo -e "${YELLOW}VLESS (TLS + Nginx Fallback) [443]:${NC}"
    echo -e "  ${GREEN}${vless_url}${NC}"
    echo ""
    echo -e "${YELLOW}Trojan (gRPC + Reality) [${TROJAN_PORT}]:${NC}"
    echo -e "  ${GREEN}${trojan_url}${NC}"
    echo ""
    echo -e "${YELLOW}Trojan (gRPC + TLS) [${TROJAN_TLS_PORT}]:${NC}"
    echo -e "  ${GREEN}${trojan_tls_url}${NC}"
    echo ""
    echo -e "${GRAY}Лог установки: ${LOG_FILE}${NC}"
    echo -e "${GRAY}Учётные данные: ${CRED_FILE}${NC}"
    echo -e "${GRAY}Конфигурация: ${CONFIG_FILE}${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
}

# ============================================================
# MAIN
# ============================================================
main() {
    # Bootstrap logging and traps (before sourcing libs)
    log_init
    setup_traps
    check_root
    check_os

    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      3X-UI Installer  —  idempotent setup      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

    # Load saved config (if exists), then prompt for missing fields
    load_config || true
    prompt_for_config

    # Execute steps
    install_dependencies
    install_panel
    configure_firewall
    setup_nginx_ssl
    generate_xray_keys
    configure_inbounds
    start_services

    # Verify all components
    verify_setup

    # Persist config for future runs
    save_config
    show_summary
}

main "$@"
