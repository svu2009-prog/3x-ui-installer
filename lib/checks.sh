#!/bin/bash
# ============================================================
# 3X-UI Installer — Idempotency Checks
# ============================================================

# --- Package ---
is_package_installed() {
    local pkg="$1"
    dpkg -s "$pkg" >/dev/null 2>&1
}

# --- Systemd Service ---
is_service_active() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

is_service_enabled() {
    local service="$1"
    systemctl is-enabled --quiet "$service" 2>/dev/null
}

# --- 3X-UI Panel ---
is_3xui_installed() {
    [ -f "/usr/local/x-ui/x-ui" ] && [ -f "/etc/systemd/system/x-ui.service" ]
}

is_3xui_running() {
    is_service_active "x-ui"
}

get_latest_github_version() {
    curl -sL "https://api.github.com/repos/mhsanaei/3x-ui/releases/latest" 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null || echo ""
}

version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# --- SSL Certificate ---
is_certificate_issued() {
    local domain="$1"
    certbot certificates 2>/dev/null | grep -q "Domains:.*${domain}"
}

get_certificate_expiry() {
    local domain="$1"
    local cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
    if [ -f "$cert_file" ]; then
        openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2
    fi
}

# --- UFW ---
is_ufw_rule_exists() {
    local port="$1"
    ufw status numbered 2>/dev/null | grep -qP "${port}/tcp"
}

is_ufw_active() {
    ufw status 2>/dev/null | grep -q "Status: active"
}

# --- Inbounds (SQLite) ---
inbound_exists_by_tag() {
    local db_path="$1"
    local tag="$2"
    [ -f "$db_path" ] || return 1
    local result
    result=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM inbounds WHERE tag='${tag}';" 2>/dev/null)
    [ "$result" -gt 0 ] 2>/dev/null
}
