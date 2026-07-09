#!/bin/bash
# ============================================================
# 3X-UI Installer — Nginx + SSL (Certbot)
# Idempotent: checks existing cert, creates backups
# ============================================================

setup_nginx_ssl() {
    log_section "Nginx и SSL"

    local nginx_config="/etc/nginx/sites-available/default"

    # Ensure web root and stub page
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'STUBEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Сайт в разработке</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
         display: flex; justify-content: center; align-items: center; min-height: 100vh;
         background: linear-gradient(135deg, #0f0f1a 0%, #1a1a2e 100%); color: #e0e0e0; }
  .card { text-align: center; padding: 3rem 2rem; max-width: 520px; width: 90%; }
  .icon { font-size: 4rem; margin-bottom: 1rem; }
  h1 { font-size: 1.8rem; font-weight: 600; margin-bottom: 1rem; color: #f0f0f0; }
  p { color: #94a3b8; line-height: 1.7; font-size: 1.05rem; margin-bottom: 0.5rem; }
  .loader { display: inline-block; width: 40px; height: 40px; border: 3px solid #1e293b;
            border-top-color: #4ade80; border-radius: 50%; animation: spin .8s linear infinite;
            margin-top: 1.5rem; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
<div class="card">
  <div class="icon">🚧</div>
  <h1>Сайт находится в разработке</h1>
  <p>Ведутся технические работы.</p>
  <p>Сайт будет запущен в ближайшее время.</p>
  <div class="loader"></div>
</div>
</body>
</html>
STUBEOF

    # ---- Step 1: temporary config for certbot (port 80 only) ----
    log_info "Временная конфигурация Nginx для получения сертификата..."

    # Local backup (NOT added to global BACKUP_FILES — avoids restore on unrelated errors)
    local nginx_bak="${nginx_config}.bak.$$"
    [ -f "$nginx_config" ] && cp -f "$nginx_config" "$nginx_bak"

    _write_nginx "certbot" "$nginx_config"

    nginx -t >/dev/null 2>&1 || {
        [ -f "$nginx_bak" ] && cp -f "$nginx_bak" "$nginx_config" && rm -f "$nginx_bak"
        log_error "Временная конфигурация Nginx невалидна"
        exit 1
    }
    systemctl restart nginx

    # ---- Step 2: obtain / renew SSL certificate ----
    if is_certificate_issued "$DOMAIN"; then
        log_info "SSL сертификат для ${DOMAIN} уже существует"
        local expiry
        expiry=$(get_certificate_expiry "$DOMAIN")
        log_info "Срок действия: ${expiry:-неизвестно}"
        certbot renew --webroot -w /var/www/html --non-interactive --quiet || true
        log_success "Сертификат проверен"
    else
        log_info "Выпуск SSL сертификата для ${DOMAIN}..."
        certbot certonly --webroot -w /var/www/html -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive || {
            log_error "Ошибка выпуска SSL сертификата для ${DOMAIN}"
            exit 1
        }
        log_success "SSL сертификат получен"
    fi

    # ---- Step 3: copy certs to stable path for xray (no symlinks) ----
    log_info "Копирование сертификатов в /etc/x-ui/ssl/ (для xray)..."
    mkdir -p /etc/x-ui/ssl
    cp -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/x-ui/ssl/fullchain.pem
    cp -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   /etc/x-ui/ssl/privkey.pem

    # ---- Step 4: restore backup (certbot did NOT touch nginx config) ----
    if [ -f "$nginx_bak" ]; then
        cp -f "$nginx_bak" "$nginx_config"
        rm -f "$nginx_bak"
    fi

    # ---- Step 5: final Nginx config (redirect 80→443, panel on 8080) ----
    log_info "Финальная конфигурация Nginx..."

    _write_nginx "final" "$nginx_config"

    nginx -t || {
        log_error "Финальная конфигурация Nginx невалидна"
        exit 1
    }
    systemctl restart nginx
    log_success "Nginx и SSL настроены"
}

# Helper: write nginx config based on mode
_write_nginx() {
    local mode="$1"
    local target="$2"

    if [ "$mode" = "certbot" ]; then
        cat > "$target" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    else
        cat > "$target" <<EOF
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
    fi
}
