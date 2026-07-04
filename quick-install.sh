#!/bin/bash
# ============================================================
# 3X-UI Quick Installer — zero dependencies, works with curl|bash
# Downloads the full repo and runs the modular install.sh
# ============================================================
# Usage: bash <(curl -sL https://raw.githubusercontent.com/...)
# ============================================================

set -e

REPO="svu2009-prog/3x-ui-installer"
BRANCH="master"
TAR_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

echo "╔══════════════════════════════════════════════════╗"
echo "║       3X-UI Quick Installer (bootstrap)         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Create temp directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[1/2] Downloading 3x-ui-installer from GitHub..."
curl -sL "$TAR_URL" | tar -xz -C "$TMP_DIR"

INSTALL_DIR="${TMP_DIR}/3x-ui-installer-${BRANCH}"
cd "$INSTALL_DIR"

echo "[2/2] Running install.sh..."
echo ""

# Execute the main installer
bash "${INSTALL_DIR}/install.sh"
