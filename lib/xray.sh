#!/bin/bash
# ============================================================
# 3X-UI Installer — Xray Keys + SQLite Inbounds
# Idempotent: upserts inbounds (no duplicates)
# ============================================================

# --------------------------------------------------
# Upsert a single inbound (INSERT if not exists, UPDATE if exists)
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
        log_info "Обновление inbound: ${tag} (порт ${port})"
        sqlite3 "$db_path" "
            UPDATE inbounds
            SET port=${port},
                protocol='${protocol}',
                settings='${settings}',
                stream_settings='${stream}',
                sniffing='${sniffing}',
                enable=1,
                updated_at=$(date +%s%3N)
            WHERE tag='${tag}';
        "
    else
        log_info "Создание inbound: ${tag} (порт ${port})"
        sqlite3 "$db_path" "
            INSERT INTO inbounds
                (user_id, up, down, total, remark, enable, expiry_time,
                 listen, port, protocol, settings, stream_settings, tag, sniffing)
            VALUES
                (1, 0, 0, 0, '${tag}', 1, 0, '',
                 ${port}, '${protocol}', '${settings}', '${stream}', '${tag}', '${sniffing}');
        "
    fi
}

# --------------------------------------------------
# Generate Xray keys (idempotent — skip if already set)
# --------------------------------------------------
generate_xray_keys() {
    log_section "Ключи Xray"

    local xray_bin="/usr/local/x-ui/bin/xray-linux-$(detect_architecture)"

    if [ ! -f "$xray_bin" ]; then
        log_error "Ядро Xray не найдено: ${xray_bin}"
        log_error "Убедитесь, что 3X-UI установлен корректно"
        exit 1
    fi

    if [ -z "${UUID:-}" ]; then
        UUID=$("$xray_bin" uuid)
        log_debug "UUID сгенерирован"
    else
        log_debug "UUID уже существует, пропускаю"
    fi

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
    if [ -z "${TROJAN_PASS:-}" ]; then
        TROJAN_PASS=$(generate_random_string 16)
    fi
    if [ -z "${TROJAN_TLS_PASS:-}" ]; then
        TROJAN_TLS_PASS=$(generate_random_string 16)
    fi

    log_success "Ключи Xray готовы"
}

# --------------------------------------------------
# Configure inbounds in SQLite (idempotent upsert)
# --------------------------------------------------
configure_inbounds() {
    log_section "Inbounds (SQLite)"

    systemctl stop x-ui >/dev/null 2>&1 || true

    local db_path="/etc/x-ui/x-ui.db"
    local cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

    if [ ! -f "$db_path" ]; then
        log_error "База данных не найдена: ${db_path}"
        exit 1
    fi

    # Backup DB
    backup_file "$db_path"

    # ---- Set SSL certs for panel web UI ----
    sqlite3 "$db_path" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '${cert}');"
    sqlite3 "$db_path" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '${key}');"
    log_info "SSL сертификаты панели применены"

    # ---- 1. VLESS TCP TLS (443) ----
    log_info "Формирование inbound VLESS..."
    local vless_settings
    vless_settings=$(jq -nc \
        --arg uuid "$UUID" \
        --arg sub "$SUB_ID_VLESS" \
        --argjson ts "$TIMESTAMP" \
        '{clients:[{id:$uuid,flow:"xtls-rprx-vision",email:"vless_tls@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],decryption:"none",fallbacks:[{dest:"127.0.0.1:8080",xver:0}]}')

    local vless_stream
    vless_stream=$(jq -nc \
        --arg domain "$DOMAIN" \
        '{network:"tcp",security:"tls",tcpSettings:{header:{type:"none"}},tlsSettings:{serverName:$domain,certificates:[{certificateFile:("/etc/letsencrypt/live/"+$domain+"/fullchain.pem"),keyFile:("/etc/letsencrypt/live/"+$domain+"/privkey.pem")}],alpn:["h2","http/1.1"]}}')

    _upsert_inbound "$db_path" "inbound-443" 443 "vless" \
        "$vless_settings" "$vless_stream" \
        '{"enabled":true,"destOverride":["http","tls"]}'

    # ---- 2. Trojan gRPC Reality ----
    log_info "Формирование inbound Trojan Reality..."
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
        --arg ext "$EXT_PROXY" \
        --argjson port "$TROJAN_PORT" \
        '{network:"grpc",grpcSettings:{serviceName:"",authority:"",multiMode:false},security:"reality",realitySettings:{show:false,xver:0,target:"www.microsoft.com:443",serverNames:["www.microsoft.com"],privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],mldsa65Seed:"",settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/",mldsa65Verify:""}},externalProxy:[{forceTls:"same",dest:$ext,port:$port,remark:""}]}')

    _upsert_inbound "$db_path" "inbound-${TROJAN_PORT}" "$TROJAN_PORT" "trojan" \
        "$trojan_settings" "$trojan_stream" \
        '{"enabled":true,"destOverride":["http","tls"]}'

    # ---- 3. Trojan gRPC TLS ----
    log_info "Формирование inbound Trojan TLS..."
    local trojan_tls_settings
    trojan_tls_settings=$(jq -nc \
        --arg pass "$TROJAN_TLS_PASS" \
        --arg sub "$SUB_ID_TROJAN_TLS" \
        --argjson ts "$TIMESTAMP" \
        '{clients:[{password:$pass,email:"trojan_tls@3x-ui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,created_at:$ts,updated_at:$ts}],fallbacks:[]}')

    local trojan_tls_stream
    trojan_tls_stream=$(jq -nc \
        --arg domain "$DOMAIN" \
        '{network:"grpc",grpcSettings:{serviceName:"",authority:"",multiMode:false},security:"tls",tlsSettings:{serverName:$domain,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,certificates:[{certificateFile:("/etc/letsencrypt/live/"+$domain+"/fullchain.pem"),keyFile:("/etc/letsencrypt/live/"+$domain+"/privkey.pem"),ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false,useFile:true}],alpn:["http/1.1"],echServerKeys:"",settings:{fingerprint:"chrome",echConfigList:"",pinnedPeerCertSha256:[],verifyPeerCertByName:""}}}')

    _upsert_inbound "$db_path" "inbound-${TROJAN_TLS_PORT}" "$TROJAN_TLS_PORT" "trojan" \
        "$trojan_tls_settings" "$trojan_tls_stream" \
        '{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}'

    log_success "Inbounds настроены (VLESS:443, Trojan-reality:${TROJAN_PORT}, Trojan-tls:${TROJAN_TLS_PORT})"
}
