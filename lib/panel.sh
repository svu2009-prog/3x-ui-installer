#!/bin/bash
# ============================================================
# 3X-UI Installer — Panel Installation / Update
# Idempotent: skips if already installed and running
# ============================================================

install_panel() {
    log_section "Установка 3X-UI панели"

    if is_3xui_installed && is_3xui_running; then
        local version
        version=$(get_3xui_version)
        log_info "3X-UI уже установлен (версия: ${version}). Пропускаю установку."
        log_info "Если нужно переустановить, выполните: rm -rf /usr/local/x-ui && re-run install.sh"
        return 0
    fi

    log_info "Остановка предыдущей версии (если есть)..."
    systemctl stop x-ui >/dev/null 2>&1 || true

    log_info "Удаление старых файлов..."
    rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service /usr/bin/x-ui
    mkdir -p /etc/x-ui

    # ---- Download ----
    local arch
    arch=$(detect_architecture)
    local url="https://github.com/mhsanaei/3x-ui/releases/latest/download/x-ui-linux-${arch}.tar.gz"

    log_info "Скачивание: ${url}"
    curl -L -s -f -o /tmp/x-ui.tar.gz "$url" || {
        log_error "Не удалось скачать 3X-UI (${url})"
        exit 1
    }

    log_info "Распаковка..."
    tar -xzf /tmp/x-ui.tar.gz -C /usr/local/
    chmod +x /usr/local/x-ui/x-ui
    rm -f /tmp/x-ui.tar.gz

    # ---- Download CLI helper ----
    log_info "Скачивание x-ui.sh..."
    curl -L -s -f -o /usr/bin/x-ui "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/x-ui.sh" || {
        log_error "Не удалось скачать x-ui.sh"
        exit 1
    }
    chmod +x /usr/bin/x-ui

    # ---- Systemd unit ----
    cat > /etc/systemd/system/x-ui.service << 'SERVICEEOF'
[Unit]
Description=x-ui Service
Documentation=https://github.com/mhsanaei/3x-ui
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable x-ui >/dev/null 2>&1

    # ---- Configure credentials ----
    log_info "Настройка учётных данных панели..."
    cd /usr/local/x-ui/
    ./x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "/$PANEL_PATH" || true

    if [ -f "x-ui.db" ] && [ ! -f "/etc/x-ui/x-ui.db" ]; then
        mv x-ui.db /etc/x-ui/x-ui.db
    fi

    if [ ! -f "/etc/x-ui/x-ui.db" ]; then
        log_error "База данных /etc/x-ui/x-ui.db не создана!"
        exit 1
    fi

    log_success "3X-UI панель установлена (порт: ${PANEL_PORT}, путь: /${PANEL_PATH})"
}
