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
    # pipefail ловит сбой curl (без него tar "успешно" распакует пустоту)
    set -o pipefail
    if ! curl -sL "https://github.com/svu2009-prog/3x-ui-installer/archive/refs/heads/master.tar.gz" \
            | tar -xz -C "$TMP_DIR"; then
        echo "[bootstrap] Ошибка загрузки репозитория"
        exit 1
    fi
    set +o pipefail
    SCRIPT_DIR="${TMP_DIR}/3x-ui-installer-master"
    LIB_DIR="${SCRIPT_DIR}/lib"
    if [ ! -d "$LIB_DIR" ]; then
        echo "[bootstrap] Архив распакован, но lib/ не найден"
        exit 1
    fi
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

    prompt_with_default "Введите доменное имя (например, example.com)" "" DOMAIN is_valid_domain
    prompt_with_default "Введите Email для Let's Encrypt" "" EMAIL is_valid_email

    # Generate random values only if not already set from config
    [ -z "${PANEL_PORT:-}" ]             && PANEL_PORT=$(generate_random_port)
    [ -z "${TROJAN_PORT:-}" ]            && TROJAN_PORT=$(generate_random_port "$PANEL_PORT")
    [ -z "${TROJAN_TLS_PORT:-}" ]        && TROJAN_TLS_PORT=$(generate_random_port "$PANEL_PORT" "$TROJAN_PORT")
    [ -z "${VLESS_REALITY_PORT:-}" ]     && VLESS_REALITY_PORT=$(generate_random_port "$PANEL_PORT" "$TROJAN_PORT" "$TROJAN_TLS_PORT")
    [ -z "${HYSTERIA_PORT:-}" ]          && HYSTERIA_PORT=$(generate_random_port "$PANEL_PORT" "$TROJAN_PORT" "$TROJAN_TLS_PORT" "$VLESS_REALITY_PORT")
    [ -z "${PANEL_PATH:-}" ]             && PANEL_PATH=$(generate_random_string 15)
    [ -z "${PANEL_USER:-}" ]             && PANEL_USER="admin$(generate_random_string 4 0-9)"
    [ -z "${PANEL_PASS:-}" ]             && PANEL_PASS=$(generate_random_string 16)
    [ -z "${SUB_ID_VLESS:-}" ]           && SUB_ID_VLESS=$(generate_random_string 16)
    [ -z "${SUB_ID_VLESS_REALITY:-}" ]   && SUB_ID_VLESS_REALITY=$(generate_random_string 16)
    [ -z "${SUB_ID_TROJAN:-}" ]          && SUB_ID_TROJAN=$(generate_random_string 16)
    [ -z "${SUB_ID_TROJAN_TLS:-}" ]      && SUB_ID_TROJAN_TLS=$(generate_random_string 16)
    [ -z "${SUB_ID_HYSTERIA:-}" ]        && SUB_ID_HYSTERIA=$(generate_random_string 16)
    [ -z "${TIMESTAMP:-}" ]              && TIMESTAMP=$(date +%s%3N)
    [ -z "${CRED_FILE:-}" ]              && CRED_FILE="/root/x-ui-setup-credentials.txt"

    log_success "Конфигурация загружена"
}

install_dependencies() {
    log_section "Зависимости системы"

    # dnsutils — для dig (DNS-проверка в verify_setup)
    # iproute2 — для ss (проверка слушающих портов)
    local packages=(curl wget socat nginx certbot python3-certbot-nginx sqlite3 jq ufw openssl unzip tar dnsutils iproute2)
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

    systemctl stop nginx 2>/dev/null || true
    systemctl start x-ui

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

    _remove_nginx_443
    systemctl restart nginx || log_warn "Nginx не удалось перезапустить, проверьте: systemctl status nginx"

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

    # 3. Check xray port 443 via localhost (TLS) with correct SNI
    local xray_443
    xray_443=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}:443" 2>/dev/null || true)
    if [ "$xray_443" = "200" ]; then
        log_success "Xray fallback (443 → nginx:8080): работает (HTTP ${xray_443})"
    else
        log_warn "Xray fallback (443 → nginx:8080): не отвечает (HTTP ${xray_443:-нет ответа})"
        log_warn "Возможно: сертификаты Let's Encrypt недоступны для xray"
        log_warn "Проверьте: ls -la /etc/letsencrypt/live/${DOMAIN}/"
        ((errors++)) || true
    fi

    # 4. Check port 443 from inside
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        log_success "Порт 443: слушается xray"
    else
        log_warn "Порт 443: никто не слушает"
        ((errors++)) || true
    fi

    # 5. DNS check for the domain
    local dns_ip
    dns_ip=$(dig +short "$DOMAIN" 2>/dev/null || host "$DOMAIN" 2>/dev/null | awk '{print $NF}' || true)
    local server_ip
    server_ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || true)
    if [ -n "$dns_ip" ] && [ -n "$server_ip" ]; then
        if [ "$dns_ip" = "$server_ip" ]; then
            log_success "DNS: ${DOMAIN} → ${dns_ip} (совпадает с IP сервера)"
        else
            log_warn "DNS: ${DOMAIN} → ${dns_ip}, но IP сервера = ${server_ip}"
            log_warn "Создайте A-запись: ${DOMAIN} → ${server_ip}"
            ((errors++)) || true
        fi
    else
        log_info "DNS: не удалось проверить (пропускаю)"
    fi

    if [ "$errors" -gt 0 ]; then
        log_warn "Обнаружено ${errors} проблем. Проверьте журналы: journalctl -u x-ui -e --no-pager"
    else
        log_success "Все проверки пройдены"
    fi
}

show_summary() {
    log_section "Итог установки"

    # Генерируем URL только для выбранных inbound'ов
    local vless_url=""
    local vless_reality_url=""
    local trojan_url=""
    local trojan_tls_url=""
    local hysteria_url=""

    if is_inbound_selected 1; then
        vless_url="vless://${UUID}@${DOMAIN}:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=${DOMAIN}&fp=chrome#VLESS-TLS-Fallback"
    fi
    if is_inbound_selected 2; then
        vless_reality_url="vless://${UUID}@${DOMAIN}:${VLESS_REALITY_PORT}?security=reality&encryption=none&type=tcp&flow=xtls-rprx-vision&pbk=${PUBLIC_KEY}&sni=www.microsoft.com&sid=${SHORT_ID}&fp=chrome#VLESS-Reality"
    fi
    if is_inbound_selected 3; then
        trojan_tls_url="trojan://${TROJAN_TLS_PASS}@${DOMAIN}:${TROJAN_TLS_PORT}?security=tls&type=grpc&sni=${DOMAIN}&fp=chrome#Trojan-gRPC-TLS"
    fi
    if is_inbound_selected 4; then
        trojan_url="trojan://${TROJAN_PASS}@${DOMAIN}:${TROJAN_PORT}?security=reality&type=grpc&pbk=${PUBLIC_KEY}&sni=www.microsoft.com&sid=${SHORT_ID}&fp=chrome#Trojan-Reality"
    fi
    if is_inbound_selected 5; then
        hysteria_url="hysteria2://${HYSTERIA_AUTH}@${DOMAIN}:${HYSTERIA_PORT}?security=tls&sni=${DOMAIN}&insecure=0&obfs=salamander&obfs-password=${HYSTERIA_PASS}&alpn=h3#Hysteria-UDP"
    fi

    # Save credentials file
    {
        echo "=== Данные 3X-UI ==="
        echo "Домен: ${DOMAIN}"
        echo "Порт панели: ${PANEL_PORT}"
        echo "Путь панели: /${PANEL_PATH}"
        echo "Логин панели: ${PANEL_USER}"
        echo "Пароль панели: ${PANEL_PASS}"
        echo ""
        echo "=== Выбранные входящие ==="
        for s in "${SELECTED_INBOUNDS[@]}"; do
            echo "  ${INBOUND_NAMES[$((s-1))]}"
        done
        echo ""
        echo "=== Ключи подключений ==="
        [ -n "$vless_url" ]         && echo "VLESS UUID: ${UUID}"
        [ -n "$vless_reality_url" ] && echo "VLESS UUID: ${UUID}"
        [ -n "$trojan_url" ]        && echo "Trojan Pass (Reality): ${TROJAN_PASS}"
        [ -n "$trojan_tls_url" ]    && echo "Trojan Pass (TLS): ${TROJAN_TLS_PASS}"
        [ -n "$hysteria_url" ]      && echo "Hysteria Auth: ${HYSTERIA_AUTH}"
        [ -n "$hysteria_url" ]      && echo "Hysteria Salamander Pass: ${HYSTERIA_PASS}"
        if is_inbound_selected 2 || is_inbound_selected 4; then
            echo "Reality Private Key: ${PRIVATE_KEY}"
            echo "Reality Public Key: ${PUBLIC_KEY}"
            echo "Reality ShortID: ${SHORT_ID}"
        fi
        echo ""
        echo "=== Ссылки для импорта ==="
        [ -n "$vless_url" ]         && echo "VLESS TLS: ${vless_url}"
        [ -n "$vless_reality_url" ] && echo "VLESS Reality: ${vless_reality_url}"
        [ -n "$trojan_url" ]        && echo "Trojan Reality: ${trojan_url}"
        [ -n "$trojan_tls_url" ]    && echo "Trojan TLS: ${trojan_tls_url}"
        [ -n "$hysteria_url" ]      && echo "Hysteria: ${hysteria_url}"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE" 2>/dev/null || true

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

    if [ -n "$vless_url" ]; then
        echo -e "${YELLOW}VLESS (TLS + Nginx Fallback) [443]:${NC}"
        echo -e "  ${GREEN}${vless_url}${NC}"
        echo ""
    fi
    if [ -n "$vless_reality_url" ]; then
        echo -e "${YELLOW}VLESS (TCP + Reality) [${VLESS_REALITY_PORT}]:${NC}"
        echo -e "  ${GREEN}${vless_reality_url}${NC}"
        echo ""
    fi
    if [ -n "$trojan_url" ]; then
        echo -e "${YELLOW}Trojan (gRPC + Reality) [${TROJAN_PORT}]:${NC}"
        echo -e "  ${GREEN}${trojan_url}${NC}"
        echo ""
    fi
    if [ -n "$trojan_tls_url" ]; then
        echo -e "${YELLOW}Trojan (gRPC + TLS) [${TROJAN_TLS_PORT}]:${NC}"
        echo -e "  ${GREEN}${trojan_tls_url}${NC}"
        echo ""
    fi
    if [ -n "$hysteria_url" ]; then
        echo -e "${YELLOW}Hysteria (UDP + TLS) [${HYSTERIA_PORT}]:${NC}"
        echo -e "  ${GREEN}${hysteria_url}${NC}"
        echo ""
    fi

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
    select_inbounds

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
