#!/bin/bash
# ============================================================
# 3X-UI Installer — Uninstall script
# Safely removes all components with confirmation prompts
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck disable=SC1090
source "${LIB_DIR}/common.sh"

main() {
    log_init
    setup_traps
    check_root

    echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║          3X-UI Installer — UNINSTALL            ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}ВНИМАНИЕ: Это удалит 3X-UI и все связанные компоненты.${NC}"
    echo ""

    read -p "$(echo -e "${RED}Продолжить удаление? [y/N]: ${NC}")" confirm
    [[ "$confirm" =~ ^[yY] ]] || { log_info "Отменено"; exit 0; }

    # ---- Stop & disable services ----
    log_section "Остановка сервисов"
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true

    # ---- Remove binaries ----
    log_section "Удаление файлов"
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
    rm -f /etc/systemd/system/x-ui.service
    rm -f /usr/bin/x-ui
    systemctl daemon-reload
    log_info "Файлы 3X-UI удалены"

    # ---- Config ----
    if [ -f /etc/3x-ui-installer/config.conf ]; then
        read -p "Удалить конфигурацию (/etc/3x-ui-installer)? [y/N]: " answer
        if [[ "$answer" =~ ^[yY] ]]; then
            rm -rf /etc/3x-ui-installer
            log_info "Конфигурация удалена"
        fi
    fi

    # ---- Credentials ----
    if [ -f /root/x-ui-setup-credentials.txt ]; then
        read -p "Удалить файл с учётными данными (/root/x-ui-setup-credentials.txt)? [y/N]: " answer
        if [[ "$answer" =~ ^[yY] ]]; then
            rm -f /root/x-ui-setup-credentials.txt
            log_info "Учётные данные удалены"
        fi
    fi

    # ---- SSL certificates ----
    read -p "Удалить SSL сертификаты Let's Encrypt? [y/N]: " answer
    if [[ "$answer" =~ ^[yY] ]]; then
        if [ -f /etc/3x-ui-installer/config.conf ]; then
            # shellcheck disable=SC1091
            source /etc/3x-ui-installer/config.conf
            if [ -n "${DOMAIN:-}" ]; then
                certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
                log_info "Сертификат для ${DOMAIN} удалён"
            fi
        else
            log_warn "Конфиг не найден, пропускаю удаление сертификатов (сделайте вручную: certbot delete)"
        fi
    fi

    # ---- UFW rules ----
    read -p "Сбросить правила UFW до заводских? [y/N]: " answer
    if [[ "$answer" =~ ^[yY] ]]; then
        ufw --force reset >/dev/null 2>&1 || true
        log_info "Правила UFW сброшены"
    fi

    # ---- Log ----
    read -p "Удалить лог установки (/var/log/3x-ui-installer)? [y/N]: " answer
    if [[ "$answer" =~ ^[yY] ]]; then
        rm -rf /var/log/3x-ui-installer
        log_info "Лог удалён"
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  3X-UI полностью удалён                         ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
}

main "$@"
