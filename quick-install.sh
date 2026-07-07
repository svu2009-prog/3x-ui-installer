#!/bin/bash
# ============================================================
# 3X-UI Quick Installer — zero dependencies, works with curl|bash
# Downloads the full repo and runs the modular install.sh
# ============================================================
# Usage: sudo bash <(curl -sL https://raw.githubusercontent.com/...)
#        (install.sh требует root для systemd/apt/sqlite в /etc)
# ============================================================

set -eo pipefail

REPO="svu2009-prog/3x-ui-installer"
BRANCH="master"
TAR_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

echo "╔══════════════════════════════════════════════════╗"
echo "║       3X-UI Quick Installer (bootstrap)         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Требуем root — install.sh всё равно упадёт на check_root, лучше сообщить явно здесь
if [[ $EUID -ne 0 ]]; then
    echo "[!] Требуется root. Перезапустите с sudo:"
    echo "    sudo bash <(curl -sL https://raw.githubusercontent.com/${REPO}/${BRANCH}/quick-install.sh)"
    exit 1
fi

# Create temp directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[1/2] Downloading 3x-ui-installer from GitHub..."
# pipefail ловит сбой curl (404/нет сети) — иначе tar "успешно" распаковал бы пустоту
if ! curl -sL "$TAR_URL" | tar -xz -C "$TMP_DIR"; then
    echo "[!] Ошибка загрузки репозитория (${TAR_URL})"
    echo "    Проверьте подключение к интернет и доступность GitHub."
    exit 1
fi

INSTALL_DIR="${TMP_DIR}/3x-ui-installer-${BRANCH}"
if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
    echo "[!] Архив распакован, но install.sh не найден в ${INSTALL_DIR}"
    exit 1
fi
cd "$INSTALL_DIR"

echo "[2/2] Running install.sh..."
echo ""

# Execute the main installer
bash "${INSTALL_DIR}/install.sh"
