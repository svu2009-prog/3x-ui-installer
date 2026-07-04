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
<title>Server is running</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
         display: flex; justify-content: center; align-items: center; height: 100vh;
         margin: 0; background: #0f0f1a; color: #e0e0e0; }
  .card { text-align: center; padding: 2rem; max-width: 480px; }
  h1 { font-size: 2rem; margin-bottom: 0.5rem; color: #4ade80; }
  p { color: #94a3b8; line-height: 1.6; }
  .badge { display: inline-block; padding: 0.25rem 0.75rem; border-radius: 999px;
           background: #1e293b; color: #4ade80; font-size: 0.8rem; margin-top: 1rem; }
</style>
</head>
<body>
<div class="card">
  <h1>✓ Server Active</h1>
  <p>This server is running and ready for secure proxy connections.</p>
  <div class="badge">3X-UI Panel</div>
</div>
</body>
</html>
STUBEOF

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
