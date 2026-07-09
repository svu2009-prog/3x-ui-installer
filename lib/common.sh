#!/bin/bash
# ============================================================
# 3X-UI Installer — Common Library
# Bash strict mode, colors, logging, traps, backup, helpers
# ============================================================

set -Eeuo pipefail

# --- Colors ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export BLUE='\033[0;34m'
export MAGENTA='\033[0;35m'
export GRAY='\033[0;90m'
export BOLD='\033[1m'
export NC='\033[0m'

# --- Paths ---
LOG_DIR="/var/log/3x-ui-installer"
LOG_FILE="${LOG_DIR}/install.log"
CONFIG_DIR="/etc/3x-ui-installer"
CONFIG_FILE="${CONFIG_DIR}/config.conf"
TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# --- Backup tracking ---
declare -a BACKUP_FILES=()

# ============================================================
# LOGGING
# ============================================================
log_init() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log_info "=== 3X-UI Installer запущен $(date '+%Y-%m-%d %H:%M:%S') ==="
}

_log() {
    local level="$1"
    local color="$2"
    local msg="$3"
    local timestamp
    timestamp=$(date +"$TIMESTAMP_FORMAT")
    echo -e "${color}[${timestamp}] [${level}] ${msg}${NC}"
    echo "[${timestamp}] [${level}] ${msg}" >> "$LOG_FILE"
}

log_info()    { _log "INFO"    "$GRAY"    "$1"; }
log_success() { _log "OK"     "$GREEN"   "$1"; }
log_warn()    { _log "WARN"   "$YELLOW"  "$1"; }
log_error()   { _log "ERROR"  "$RED"     "$1"; }
log_debug()   { _log "DEBUG"  "$MAGENTA" "$1"; }

log_section() {
    local msg="$1"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ${msg}${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo "[$(date +"$TIMESTAMP_FORMAT")] [===] ${msg}" >> "$LOG_FILE"
}

# ============================================================
# TRAP HANDLERS
# ============================================================
_cleanup_on_error() {
    local exit_code=$?
    log_error "Скрипт прерван с ошибкой (код: ${exit_code}) на строке ${BASH_LINENO[0]}"
    log_error "Команда: ${BASH_COMMAND}"

    if [ ${#BACKUP_FILES[@]} -gt 0 ]; then
        log_warn "Восстановление резервных копий..."
        local restored=0
        for backup in "${BACKUP_FILES[@]}"; do
            if [ -f "$backup" ]; then
                local original="${backup%.bak.*}"
                if [ -n "$original" ] && [ -f "$backup" ]; then
                    cp -f "$backup" "$original" 2>/dev/null || true
                    restored=$((restored + 1))
                fi
            fi
        done
        log_info "Восстановлено файлов: ${restored}"
    fi

    exit "$exit_code"
}

_cleanup_on_exit() {
    local exit_code=$?
    # Clean up temporary bootstrap directory if it exists
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ "$exit_code" -eq 0 ]; then
        log_info "=== 3X-UI Installer завершён успешно $(date '+%Y-%m-%d %H:%M:%S') ==="
    fi
}

_interrupt_handler() {
    echo ""
    log_warn "Получен сигнал прерывания. Выполнение остановлено."
    exit 1
}

setup_traps() {
    trap '_cleanup_on_error' ERR
    trap '_cleanup_on_exit' EXIT
    trap '_interrupt_handler' INT TERM
}

# ============================================================
# BACKUP
# ============================================================
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%s)"
        cp -f "$file" "$backup"
        BACKUP_FILES+=("$backup")
        log_debug "Резервная копия: ${backup}"
        echo "$backup"
    fi
}

# ============================================================
# SYSTEM CHECKS
# ============================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен запускаться от имени root (sudo)!"
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)
                log_info "ОС: ${NAME} ${VERSION_ID}"
                ;;
            *)
                log_warn "ОС: ${ID:-unknown} — возможны несовместимости. Рекомендуется Ubuntu/Debian."
                ;;
        esac
    fi
}

detect_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|x64|amd64)  echo "amd64" ;;
        aarch64|arm64)      echo "arm64" ;;
        *)
            log_error "Неподдерживаемая архитектура: ${arch}. Нужны amd64 или arm64."
            exit 1
            ;;
    esac
}

# ============================================================
# RANDOM GENERATORS
# ============================================================
generate_random_string() {
    local length="$1"
    local chars="${2:-A-Za-z0-9}"
    LC_ALL=C tr -dc "$chars" < /dev/urandom 2>/dev/null | head -c "$length" || true
}

generate_random_port() {
    # Генерирует свободный TCP-порт в диапазоне 10000–59999.
    # Принимает необязательный список уже занятых портов (для уникальности внутри вызова),
    # например: generate_random_port "$PANEL_PORT" "$TROJAN_PORT"
    local used=("$@")
    local port
    local attempts=0
    while [ $attempts -lt 50 ]; do
        port=$((RANDOM % 50000 + 10000))
        local conflict=0
        # не совпадает ли с уже сгенерированными в этом вызове
        for u in "${used[@]}"; do
            if [ "$u" = "$port" ]; then
                conflict=1
                break
            fi
        done
        # не из служебных (22, 80, 443, 8080 и т.п.)
        case "$port" in
            22|80|443|8080) conflict=1 ;;
        esac
        if [ $conflict -eq 0 ] && ! command -v ss >/dev/null 2>&1; then
            echo "$port"; return 0
        fi
        if [ $conflict -eq 0 ] && ! ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            echo "$port"; return 0
        fi
        attempts=$((attempts + 1))
    done
    # fallback — вернуть хоть что-то валидное, проверка в verify_setup покажет конфликт
    echo "$((RANDOM % 50000 + 10000))"
}

# ============================================================
# INPUT VALIDATION
# ============================================================
# Валидация доменного имени: метки из букв/цифр/дефисов, разделённые точками.
is_valid_domain() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    # 1-253 символа, только a-zA-Z0-9.-, минимум одна точка, метки 1-63 символа
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    [ "${#domain}" -le 253 ] || return 1
    # Запрет пробелов и пустых меток (двойные точки)
    [[ "$domain" != *" "* ]] || return 1
    [[ "$domain" != *".."* ]] || return 1
    return 0
}

# Валидация email: локальная часть@домен (упрощённая проверка).
is_valid_email() {
    local email="$1"
    [ -n "$email" ] || return 1
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || return 1
    return 0
}

# ============================================================
# INBOUND SELECTION MENU
# ============================================================
# Массив названий входящих (индекс 1..5)
declare -a INBOUND_NAMES=(
    "VLESS TCP TLS"
    "VLESS TCP Reality"
    "Trojan gRPC TLS"
    "Trojan gRPC Reality"
    "Hysteria UDP"
)

# Массив выбранных inbound IDs (1..5)
declare -a SELECTED_INBOUNDS=()

is_inbound_selected() {
    local idx="$1"
    local s
    for s in "${SELECTED_INBOUNDS[@]}"; do
        [ "$s" = "$idx" ] && return 0
    done
    return 1
}

select_inbounds() {
    log_section "Выбор входящих (Inbounds)"

    echo -e "${CYAN}Доступные входящие:${NC}"
    local i
    for ((i=0; i<${#INBOUND_NAMES[@]}; i++)); do
        echo -e "  ${GREEN}$((i+1))${NC}. ${INBOUND_NAMES[$i]}"
    done
    echo ""
    echo -e "${YELLOW}Введите номера через пробел (например: 1 3 5) или 'all' для выбора всех:${NC}"
    echo -e "${GRAY}Минимум 1 входящее.${NC}"
    echo ""

    while true; do
        read -rp "$(echo -e "${CYAN}Ваш выбор:${NC} ")" input
        input=$(echo "$input" | tr ',' ' ' | xargs)

        SELECTED_INBOUNDS=()

        if [ "$input" = "all" ] || [ "$input" = "все" ]; then
            SELECTED_INBOUNDS=(1 2 3 4 5)
        else
            local valid=true
            local num s duplicate
            for num in $input; do
                if [[ "$num" =~ ^[1-5]$ ]]; then
                    duplicate=false
                    for s in "${SELECTED_INBOUNDS[@]}"; do
                        [ "$s" = "$num" ] && duplicate=true && break
                    done
                    if [ "$duplicate" = false ]; then
                        SELECTED_INBOUNDS+=("$num")
                    fi
                else
                    log_error "Неверный номер: '${num}'. Допустимы: 1-5"
                    valid=false
                    break
                fi
            done

            [ "$valid" = false ] && continue

            if [ ${#SELECTED_INBOUNDS[@]} -eq 0 ]; then
                log_error "Не выбрано ни одного входящего"
                continue
            fi
        fi

        echo ""
        log_info "Выбранные входящие:"
        for s in "${SELECTED_INBOUNDS[@]}"; do
            echo -e "  ${GREEN}✓ ${INBOUND_NAMES[$((s-1))]}${NC}"
        done
        echo ""
        break
    done
}

# ============================================================
# CONFIG FILE MANAGEMENT
# ============================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Загрузка конфигурации: ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        # Восстанавливаем массив SELECTED_INBOUNDS из строки
        if [ -n "${SELECTED_INBOUNDS:-}" ]; then
            local saved_inbounds="${SELECTED_INBOUNDS}"
            SELECTED_INBOUNDS=()
            for num in $saved_inbounds; do
                SELECTED_INBOUNDS+=("$num")
            done
        fi
        return 0
    fi
    log_info "Файл конфигурации не найден, будет создан при сохранении"
    return 1
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
# 3X-UI Installer Configuration
# Auto-generated: $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file and re-run install.sh to apply changes

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"

# Selected inbounds (space-separated IDs: 1=VLESS TLS, 2=VLESS Reality, 3=Trojan TLS, 4=Trojan Reality, 5=Hysteria)
SELECTED_INBOUNDS="${SELECTED_INBOUNDS[*]:-}"

# Generated settings (do NOT manually edit unless you know what you're doing)
PANEL_PORT="${PANEL_PORT:-}"
TROJAN_PORT="${TROJAN_PORT:-}"
TROJAN_TLS_PORT="${TROJAN_TLS_PORT:-}"
VLESS_REALITY_PORT="${VLESS_REALITY_PORT:-}"
HYSTERIA_PORT="${HYSTERIA_PORT:-}"
PANEL_PATH="${PANEL_PATH:-}"
PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"
SUB_ID_VLESS="${SUB_ID_VLESS:-}"
SUB_ID_VLESS_REALITY="${SUB_ID_VLESS_REALITY:-}"
SUB_ID_TROJAN="${SUB_ID_TROJAN:-}"
SUB_ID_TROJAN_TLS="${SUB_ID_TROJAN_TLS:-}"
SUB_ID_HYSTERIA="${SUB_ID_HYSTERIA:-}"
UUID="${UUID:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
SHORT_ID="${SHORT_ID:-}"
TROJAN_PASS="${TROJAN_PASS:-}"
TROJAN_TLS_PASS="${TROJAN_TLS_PASS:-}"
HYSTERIA_AUTH="${HYSTERIA_AUTH:-}"
HYSTERIA_PASS="${HYSTERIA_PASS:-}"
TIMESTAMP="${TIMESTAMP:-}"
INSTALLED_VERSION="${INSTALLED_VERSION:-}"
CRED_FILE="${CRED_FILE:-/root/x-ui-setup-credentials.txt}"
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    log_success "Конфигурация сохранена: ${CONFIG_FILE}"
}

# ============================================================
# INTERACTIVE PROMPT (with saved default)
# ============================================================
# prompt_with_default <prompt_text> <default> <var_name> [validator_fn]
# Если значение уже задано (из сохранённого конфига) — перезапрашивать не будем,
# но при наличии validator_fn проверим и сохранённое значение.
prompt_with_default() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"
    local validator="${4:-}"

    # Если уже задано из конфига — опционально валидируем, но не переспрашиваем
    if [ -n "${!var_name:-}" ]; then
        if [ -n "$validator" ] && ! "$validator" "${!var_name}"; then
            log_warn "Сохранённое значение '${!var_name}' невалидно, перезапрашиваю"
        else
            log_info "${prompt}: используем сохранённое значение"
            return
        fi
        # обнуляем невалидное значение, чтобы войти в цикл ввода
        printf -v "$var_name" '%s' ""
    fi

    local value
    while true; do
        if [ -n "$default" ]; then
            read -p "$(echo -e "${CYAN}${prompt}${NC} [${GREEN}${default}${NC}]: ")" value
            value="${value:-$default}"
        else
            read -p "$(echo -e "${CYAN}${prompt}${NC}: ")" value
        fi

        if [ -z "$value" ]; then
            log_error "Значение не может быть пустым"
            continue
        fi
        if [ -n "$validator" ] && ! "$validator" "$value"; then
            log_error "Невалидное значение. Попробуйте снова."
            continue
        fi
        break
    done

    printf -v "$var_name" '%s' "$value"
}
