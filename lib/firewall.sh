#!/bin/bash
# ============================================================
# 3X-UI Installer — Firewall (UFW) Setup
# Idempotent: only adds missing rules, never duplicates
# ============================================================

configure_firewall() {
    log_section "Firewall (UFW)"

    # Enable UFW if not active
    if ! is_ufw_active; then
        log_info "Включение UFW..."
        ufw --force enable >/dev/null
        log_info "UFW включён"
    else
        log_info "UFW уже активен"
    fi

    # Базовые порты (всегда)
    local ports=(22 80 443 "$PANEL_PORT")

    # Добавляем порты только для выбранных inbound'ов
    if is_inbound_selected 1; then
        # VLESS TCP TLS — порт 443 уже в базовых
        :
    fi
    if is_inbound_selected 2; then
        ports+=("$VLESS_REALITY_PORT")
    fi
    if is_inbound_selected 3; then
        ports+=("$TROJAN_TLS_PORT")
    fi
    if is_inbound_selected 4; then
        ports+=("$TROJAN_PORT")
    fi

    local added=0
    local skipped=0

    # TCP правила
    for port in "${ports[@]}"; do
        if [ -z "$port" ]; then
            continue
        fi
        if is_ufw_rule_exists "$port"; then
            log_debug "Порт ${port}/tcp уже разрешён"
            skipped=$((skipped + 1))
        else
            log_info "Разрешаю порт ${port}/tcp"
            ufw allow "${port}/tcp" >/dev/null
            added=$((added + 1))
        fi
    done

    # UDP правило для Hysteria (inbound 5)
    if is_inbound_selected 5; then
        if ufw status 2>/dev/null | grep -q "${HYSTERIA_PORT}/udp"; then
            log_debug "Порт ${HYSTERIA_PORT}/udp уже разрешён"
            skipped=$((skipped + 1))
        else
            log_info "Разрешаю порт ${HYSTERIA_PORT}/udp (Hysteria)"
            ufw allow "${HYSTERIA_PORT}/udp" >/dev/null
            added=$((added + 1))
        fi
    fi

    log_success "Firewall: добавлено правил — ${added}, пропущено — ${skipped}"
}
