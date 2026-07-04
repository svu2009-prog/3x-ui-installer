#!/bin/bash
# ============================================================
# 3X-UI Installer — Nginx + SSL (Certbot)
# Idempotent: checks existing cert, creates backups
# ============================================================

setup_nginx_ssl() {
    log_section "Nginx и SSL"

    local nginx_config="/etc/nginx/sites-available/default"

    # Ensure web root exists
    mkdir -p /var/www/html
    if [ ! -f /var/www/html/index.html ]; then
        echo "<!DOCTYPE html><html><head><title>Welcome!</title></head><body><h1>OK</h1></body></html>" > /var/www/html/index.html
    fi

    # ---- Step 1: temporary config for certbot (port 80 only) ----
    log_info "Временная конфигурация Nginx для получения сертификата..."
    backup_file "$nginx_config"

    cat > "$nginx_config" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

    nginx -t >/dev/null || { log_error "Конфигурация Nginx невалидна"; exit 1; }
    systemctl restart nginx

    # ---- Step 2: obtain / renew SSL certificate ----
    if is_certificate_issued "$DOMAIN"; then
        log_info "SSL сертификат для ${DOMAIN} уже существует"
        local expiry
        expiry=$(get_certificate_expiry "$DOMAIN")
        log_info "Срок действия: ${expiry:-неизвестно}"
        certbot renew --nginx --non-interactive --quiet || true
        log_success "Сертификат проверен"
    else
        log_info "Выпуск SSL сертификата для ${DOMAIN}..."
        certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect || {
            log_error "Ошибка выпуска SSL сертификата для ${DOMAIN}"
            exit 1
        }
        log_success "SSL сертификат получен"
    fi

    # ---- Step 3: final Nginx config (redirect 80→443, panel on 8080) ----
    log_info "Финальная конфигурация Nginx..."
    backup_file "$nginx_config"

    cat > "$nginx_config" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 8080;
    server_name ${DOMAIN};
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

    nginx -t || { log_error "Конфигурация Nginx невалидна"; exit 1; }
    systemctl restart nginx
    log_success "Nginx и SSL настроены"
}
