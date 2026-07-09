#!/bin/bash
# ============================================================
# 3X-UI Installer — Xray Keys + SQLite Inbounds
# Idempotent: upserts inbounds (no duplicates)
# ============================================================

# --------------------------------------------------
# Insert a single inbound (only if not exists — preserves existing clients)
# --------------------------------------------------
_upsert_inbound() {
    local db_path="$1"
    local tag="$2"
    local port="$3"
    local protocol="$4"
    local settings="$5"
    local stream="$6"
    local sniffing="$7"

    local existing
    existing=$(sqlite3 "$db_path" "SELECT id FROM inbounds WHERE tag='${tag}' LIMIT 1;" 2>/dev/null || true)

    if [ -n "$existing" ]; then
        log_info "Inbound ${tag} уже существует, пропускаю (клиенты сохранены)"
        return 0
    fi

    log_info "Создание inbound: ${tag} (порт ${port})"
    sqlite3 "$db_path" "
        INSERT INTO inbounds
            (user_id, up, down, total, remark, enable, expiry_time,
             listen, port, protocol, settings, stream_settings, tag, sniffing)
        VALUES
            (1, 0, 0, 0, '${tag}', 1, 0, '',
             ${port}, '${protocol}', '${settings}', '${stream}', '${tag}', '${sniffing}');
    "
}

# --------------------------------------------------
# Update certificate paths in an existing inbound's stream_settings
# (preserves all clients and other settings)
# --------------------------------------------------
_update_inbound_cert() {
    local db_path="$1"
    local tag="$2"

    local old_stream
    old_stream=$(sqlite3 "$db_path" "SELECT stream_settings FROM inbounds WHERE tag='${tag}' LIMIT 1;" 2>/dev/null || true)

    if [ -z "$old_stream" ]; then
        return 0
    fi

    local new_stream
    new_stream=$(echo "$old_stream" | jq -c \
        '.tlsSettings.certificates[0].certificateFile = "/etc/x-ui/ssl/fullchain.pem" |
         .tlsSettings.certificates[0].keyFile = "/etc/x-ui/ssl/privkey.pem"' 2>/dev/null || echo "$old_stream")

    if [ "$new_stream" != "$old_stream" ]; then
        sqlite3 "$db_path" "UPDATE inbounds SET stream_settings='${new_stream}' WHERE tag='${tag}';"
        log_info "Сертификаты обновлены для inbound ${tag}"
    fi
}

# --------------------------------------------------
# Generate Xray keys (idempotent — skip if already set)
# Генерирует только ключи для выбранных inbound'ов
# --------------------------------------------------
generate_xray_keys() {
    log_section "Ключи Xray"

    local xray_bin="/usr/local/x-ui/bin/xray-linux-$(detect_architecture)"

    if [ ! -f "$xray_bin" ]; then
        log_error "Ядро Xray не найдено: ${xray_bin}"
        log_error "Убедитесь, что 3X-UI установлен корректно"
        exit 1
    fi

    # UUID — нужен для VLESS TCP TLS (inbound 1) и VLESS TCP Reality (inbound 2)
    if is_inbound_selected 1 || is_inbound_selected 2; then
        if [ -z "${UUID:-}" ]; then
            UUID=$("$xray_bin" uuid)
            log_debug "UUID сгенерирован"
        else
            log_debug "UUID уже существует, пропускаю"
        fi
    fi

    # Reality ключи — нужны для VLESS TCP Reality (2) и Trojan gRPC Reality (4)
    if is_inbound_selected 2 || is_inbound_selected 4; then
        if [ -z "${PRIVATE_KEY:-}" ] || [ -z "${PUBLIC_KEY:-}" ]; then
            local reality_keys
            reality_keys=$("$xray_bin" x25519)
            PRIVATE_KEY=$(echo "$reality_keys" | awk -F': ' '/Private/{print $2}')
            PUBLIC_KEY=$(echo "$reality_keys" | awk -F': ' '/Public/{print $2}')
            log_debug "Reality ключи сгенерированы"
        else
            log_debug "Reality ключи уже существуют, пропускаю"
        fi

        if [ -z "${SHORT_ID:-}" ]; then
            SHORT_ID=$(openssl rand -hex 8)
        fi
    fi

    # Trojan пароли — нужны для Trojan TLS (3) и Trojan Reality (4)
    if is_inbound_selected 3; then
        if [ -z "${TROJAN_TLS_PASS:-}" ]; then
            TROJAN_TLS_PASS=$(generate_random_string 16)
        fi
    fi
    if is_inbound_selected 4; then
        if [ -z "${TROJAN_PASS:-}" ]; then
            TROJAN_PASS=$(generate_random_string 16)
        fi
    fi

    # Hysteria — auth и salamander пароль (inbound 5)
    if is_inbound_selected 5; then
        if [ -z "${HYSTERIA_AUTH:-}" ]; then
            HYSTERIA_AUTH=$(generate_random_string 16)
            log_debug "Hysteria auth сгенерирован"
        fi
        if [ -z "${HYSTERIA_PASS:-}" ]; then
            HYSTERIA_PASS=$(generate_random_string 16)
            log_debug "Hysteria salamander пароль сгенерирован"
        fi
    fi

    log_success "Ключи Xray готовы"
}

# --------------------------------------------------
# Configure inbounds in SQLite (idempotent upsert)
# Устанавливает только выбранные входящие
# --------------------------------------------------
configure_inbounds() {
    log_section "Inbounds (SQLite)"

    systemctl stop x-ui >/dev/null 2>&1 || true

    local db_path="/etc/x-ui/x-ui.db"
    local cert="/etc/x-ui/ssl/fullchain.pem"
    local key="/etc/x-ui/ssl/privkey.pem"

    if [ ! -f "$db_path" ]; then
        log_error "База данных не найдена: ${db_path}"
        exit 1
    fi

    # Backup DB
    backup_file "$db_path"

    # ---- Set SSL certs for panel web UI (copied certs, no symlinks) ----
    sqlite3 "$db_path" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '/etc/x-ui/ssl/fullchain.pem');"
    sqlite3 "$db_path" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '/etc/x-ui/ssl/privkey.pem');"
    log_info "SSL сертификаты панели применены"

    # ---- 1. VLESS TCP TLS (443) ----
    if is_inbound_selected 1; then
        log_info "Формирование inbound VLESS TCP TLS..."
        local vless_settings
        vless_settings=$(jq -nc \
            --arg uuid "$UUID" \
            --arg sub "$SUB_ID_VLESS" \
            --argjson ts "$TIMESTAMP" \
            '{clients:[{id:$uuid,flow:"xtls-rprx-vision",email:"vless_tls@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],decryption:"none",encryption:"none",fallbacks:[{alpn:"",dest:"127.0.0.1:8080",name:"",path:"",xver:0}],testseed:[900,500,900,256]}')

        local vless_stream
        vless_stream=$(jq -nc \
            --arg domain "$DOMAIN" \
            '{network:"tcp",tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},security:"tls",tlsSettings:{serverName:$domain,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,certificates:[{certificateFile:"/etc/x-ui/ssl/fullchain.pem",keyFile:"/etc/x-ui/ssl/privkey.pem",ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false,useFile:true}],alpn:["http/1.1"],echServerKeys:"",settings:{fingerprint:"chrome",echConfigList:"",pinnedPeerCertSha256:[],verifyPeerCertByName:""}}}')

        _upsert_inbound "$db_path" "inbound-443" 443 "vless" \
            "$vless_settings" "$vless_stream" \
            '{"enabled":true,"destOverride":["http","tls"]}'

        # Update cert paths if inbound already existed (fix symlink issues)
        _update_inbound_cert "$db_path" "inbound-443"
    fi

    # ---- 2. VLESS TCP Reality ----
    if is_inbound_selected 2; then
        log_info "Формирование inbound VLESS TCP Reality..."
        local vless_reality_settings
        vless_reality_settings=$(jq -nc \
            --arg uuid "$UUID" \
            --arg sub "$SUB_ID_VLESS_REALITY" \
            --argjson ts "$TIMESTAMP" \
            '{clients:[{id:$uuid,flow:"xtls-rprx-vision",email:"vless_reality@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],decryption:"none",encryption:"none",fallbacks:[],testseed:[900,500,900,256]}')

        local vless_reality_stream
        vless_reality_stream=$(jq -nc \
            --arg priv "$PRIVATE_KEY" \
            --arg pub "$PUBLIC_KEY" \
            --arg sid "$SHORT_ID" \
            '{network:"tcp",tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},security:"reality",realitySettings:{show:false,xver:0,target:"www.microsoft.com:443",serverNames:["www.microsoft.com"],privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],mldsa65Seed:"",settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/",mldsa65Verify:""}}}')

        _upsert_inbound "$db_path" "inbound-${VLESS_REALITY_PORT}" "$VLESS_REALITY_PORT" "vless" \
            "$vless_reality_settings" "$vless_reality_stream" \
            '{"enabled":true,"destOverride":["http","tls"]}'
    fi

    # ---- 3. Trojan gRPC TLS ----
    if is_inbound_selected 3; then
        log_info "Формирование inbound Trojan gRPC TLS..."
        local trojan_tls_settings
        trojan_tls_settings=$(jq -nc \
            --arg pass "$TROJAN_TLS_PASS" \
            --arg sub "$SUB_ID_TROJAN_TLS" \
            --argjson ts "$TIMESTAMP" \
            '{clients:[{password:$pass,email:"trojan_tls@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],fallbacks:[]}')

        local trojan_tls_stream
        trojan_tls_stream=$(jq -nc \
            --arg domain "$DOMAIN" \
            '{network:"grpc",grpcSettings:{serviceName:"",authority:"",multiMode:false},security:"tls",tlsSettings:{serverName:$domain,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,certificates:[{certificateFile:"/etc/x-ui/ssl/fullchain.pem",keyFile:"/etc/x-ui/ssl/privkey.pem",ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false,useFile:true}],alpn:["http/1.1"],echServerKeys:"",settings:{fingerprint:"chrome",echConfigList:"",pinnedPeerCertSha256:[],verifyPeerCertByName:""}}}')

        _upsert_inbound "$db_path" "inbound-${TROJAN_TLS_PORT}" "$TROJAN_TLS_PORT" "trojan" \
            "$trojan_tls_settings" "$trojan_tls_stream" \
            '{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}'

        # Update cert paths for existing TLS inbounds
        _update_inbound_cert "$db_path" "inbound-${TROJAN_TLS_PORT}"
    fi

    # ---- 4. Trojan gRPC Reality ----
    if is_inbound_selected 4; then
        log_info "Формирование inbound Trojan gRPC Reality..."
        local trojan_settings
        trojan_settings=$(jq -nc \
            --arg pass "$TROJAN_PASS" \
            --arg sub "$SUB_ID_TROJAN" \
            --argjson ts "$TIMESTAMP" \
            '{clients:[{password:$pass,email:"trojan_reality@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],fallbacks:[]}')

        local trojan_stream
        trojan_stream=$(jq -nc \
            --arg priv "$PRIVATE_KEY" \
            --arg pub "$PUBLIC_KEY" \
            --arg sid "$SHORT_ID" \
            '{network:"grpc",grpcSettings:{serviceName:"",authority:"",multiMode:false},security:"reality",realitySettings:{show:false,xver:0,target:"www.microsoft.com:443",serverNames:["www.microsoft.com"],privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],mldsa65Seed:"",settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/",mldsa65Verify:""}}}')

        _upsert_inbound "$db_path" "inbound-${TROJAN_PORT}" "$TROJAN_PORT" "trojan" \
            "$trojan_settings" "$trojan_stream" \
            '{"enabled":true,"destOverride":["http","tls"]}'
    fi

    # ---- 5. Hysteria UDP ----
    if is_inbound_selected 5; then
        log_info "Формирование inbound Hysteria UDP..."
        local hysteria_settings
        hysteria_settings=$(jq -nc \
            --arg auth "$HYSTERIA_AUTH" \
            --arg sub "$SUB_ID_HYSTERIA" \
            --argjson ts "$TIMESTAMP" \
            '{clients:[{auth:$auth,email:"hysteria@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],version:2}')

        local hysteria_stream
        hysteria_stream=$(jq -nc \
            --arg domain "$DOMAIN" \
            --arg pass "$HYSTERIA_PASS" \
            '{network:"hysteria",hysteriaSettings:{version:2,udpIdleTimeout:60,masquerade:{type:"",dir:"",url:"",rewriteHost:false,insecure:false,content:"",headers:{},statusCode:0}},security:"tls",tlsSettings:{serverName:$domain,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,certificates:[{certificateFile:"/etc/x-ui/ssl/fullchain.pem",keyFile:"/etc/x-ui/ssl/privkey.pem",ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false,useFile:true}],alpn:["h3"],echServerKeys:"",settings:{echConfigList:"",pinnedPeerCertSha256:[],verifyPeerCertByName:""}},finalmask:{udp:[{type:"salamander",settings:{password:$pass}}]}}')

        _upsert_inbound "$db_path" "inbound-${HYSTERIA_PORT}" "$HYSTERIA_PORT" "hysteria" \
            "$hysteria_settings" "$hysteria_stream" \
            '{"enabled":false}'

        # Update cert paths for existing Hysteria inbound
        _update_inbound_cert "$db_path" "inbound-${HYSTERIA_PORT}"
    fi

    log_success "Inbounds настроены"
}
