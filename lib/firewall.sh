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

    local ports=(22 80 443 "$PANEL_PORT" "$TROJAN_PORT" "$TROJAN_TLS_PORT")
    local added=0
    local skipped=0

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

    log_success "Firewall: добавлено правил — ${added}, пропущено — ${skipped}"
}
