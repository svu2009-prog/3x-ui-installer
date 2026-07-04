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
                    ((restored++))
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
    echo $((RANDOM % 50000 + 10000))
}

# ============================================================
# CONFIG FILE MANAGEMENT
# ============================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Загрузка конфигурации: ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        return 0
    fi
    log_info "Файл конфигурации не найден, будет создан при сохранении"
    return 1
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# 3X-UI Installer Configuration
# Auto-generated: $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file and re-run install.sh to apply changes

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
EXT_PROXY="${EXT_PROXY:-}"

# Generated settings (do NOT manually edit unless you know what you're doing)
PANEL_PORT="${PANEL_PORT:-}"
TROJAN_PORT="${TROJAN_PORT:-}"
TROJAN_TLS_PORT="${TROJAN_TLS_PORT:-}"
PANEL_PATH="${PANEL_PATH:-}"
PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"
SUB_ID_VLESS="${SUB_ID_VLESS:-}"
SUB_ID_TROJAN="${SUB_ID_TROJAN:-}"
SUB_ID_TROJAN_TLS="${SUB_ID_TROJAN_TLS:-}"
UUID="${UUID:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
SHORT_ID="${SHORT_ID:-}"
TROJAN_PASS="${TROJAN_PASS:-}"
TROJAN_TLS_PASS="${TROJAN_TLS_PASS:-}"
TIMESTAMP="${TIMESTAMP:-}"
CRED_FILE="${CRED_FILE:-/root/x-ui-setup-credentials.txt}"
EOF
    log_success "Конфигурация сохранена: ${CONFIG_FILE}"
}

# ============================================================
# INTERACTIVE PROMPT (with saved default)
# ============================================================
prompt_with_default() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"

    if [ -n "${!var_name:-}" ]; then
        log_info "${prompt}: используем сохранённое значение"
        return
    fi

    local value
    if [ -n "$default" ]; then
        read -p "$(echo -e "${CYAN}${prompt}${NC} [${GREEN}${default}${NC}]: ")" value
        value="${value:-$default}"
    else
        read -p "$(echo -e "${CYAN}${prompt}${NC}: ")" value
    fi

    printf -v "$var_name" '%s' "$value"
}
