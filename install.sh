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

    # Persist config for future runs
    save_config
    show_summary
}

main "$@"
