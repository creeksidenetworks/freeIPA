#!/bin/bash
#
# Azure FreeIPA Sync Uninstall Script
#
# This script removes the Azure FreeIPA Sync installation
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/freeipa-sync"
CONFIG_FILE="/etc/azure_sync.conf"
SERVICE_NAME="azure-freeipa-sync"

echo -e "${BLUE}Azure FreeIPA Sync Uninstall Script${NC}"
echo "===================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

# Confirm uninstallation
echo -e "${YELLOW}This will remove the Azure FreeIPA Sync tool and all associated files.${NC}"
echo -e "${YELLOW}Configuration and log files will be preserved unless you choose to remove them.${NC}"
echo ""
read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo -e "${BLUE}Stopping and disabling services...${NC}"
# Stop and disable timer
systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true

# Stop service if running
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true

echo -e "${BLUE}Removing systemd service files...${NC}"
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"

# Reload systemd
systemctl daemon-reload

echo -e "${BLUE}Removing installation directory...${NC}"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "✓ Removed $INSTALL_DIR"
else
    echo "Installation directory not found: $INSTALL_DIR"
fi

echo -e "${BLUE}Removing symlinks...${NC}"
rm -f /usr/local/bin/azure-sync-monitor

echo -e "${BLUE}Removing log rotation config...${NC}"
rm -f /etc/logrotate.d/azure-freeipa-sync

# Ask about configuration and log files
echo ""
echo -e "${YELLOW}Optional cleanup:${NC}"

if [ -f "$CONFIG_FILE" ]; then
    read -p "Remove configuration file $CONFIG_FILE? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE"
        echo "✓ Removed configuration file"
    else
        echo "Configuration file preserved"
    fi
fi

if [ -f "/var/log/azure_freeipa_sync.log" ]; then
    read -p "Remove log files? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f /var/log/azure_freeipa_sync.log*
        rm -f /var/log/freeipa_new_passwords.log*
        echo "✓ Removed log files"
    else
        echo "Log files preserved"
    fi
fi

if [ -d "/var/backups/freeipa-sync" ]; then
    read -p "Remove backup directory /var/backups/freeipa-sync? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /var/backups/freeipa-sync
        echo "✓ Removed backup directory"
    else
        echo "Backup directory preserved"
    fi
fi

# Ask about Python packages
echo ""
read -p "Remove Python packages installed for this tool? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Removing Python packages...${NC}"
    pip3 uninstall -y msal requests python-freeipa 2>/dev/null || true
    echo "✓ Python packages removed"
fi

echo ""
echo -e "${GREEN}Uninstall completed successfully!${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo "✓ Service and timer removed"
echo "✓ Installation directory removed"
echo "✓ Systemd files removed"
echo "✓ Symlinks removed"

if [ -f "$CONFIG_FILE" ]; then
    echo "- Configuration file preserved: $CONFIG_FILE"
fi

if [ -f "/var/log/azure_freeipa_sync.log" ]; then
    echo "- Log files preserved in /var/log/"
fi

if [ -d "/var/backups/freeipa-sync" ]; then
    echo "- Backup directory preserved: /var/backups/freeipa-sync"
fi

echo ""
echo "The Azure FreeIPA Sync tool has been removed from this system."