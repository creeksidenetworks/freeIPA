#!/bin/bash

# Azure FreeIPA Sync - Installation Script
# This script installs and configures the Azure to FreeIPA sync tool

set -e

# Configuration
INSTALL_DIR="/opt/azure-freeipa-sync"
CONFIG_DIR="/etc/azure-freeipa-sync"
LOG_DIR="/var/log"
SERVICE_USER="root"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_status "Starting Azure FreeIPA Sync installation..."

# Install Python dependencies
print_status "Installing Python dependencies..."
pip3 install -r requirements.txt

# Create directories
print_status "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

# Copy files
print_status "Installing files..."
cp azure_freeipa_sync.py "$INSTALL_DIR/"
cp azure_sync.conf.example "$CONFIG_DIR/"

# Set permissions
print_status "Setting permissions..."
chmod 755 "$INSTALL_DIR/azure_freeipa_sync.py"
chmod 600 "$CONFIG_DIR/azure_sync.conf.example"

# Create symlink for easy access
ln -sf "$INSTALL_DIR/azure_freeipa_sync.py" /usr/local/bin/azure-freeipa-sync

print_status "Installation completed successfully!"
echo
print_warning "Next steps:"
echo "1. Copy the example configuration:"
echo "   cp $CONFIG_DIR/azure_sync.conf.example $CONFIG_DIR/azure_sync.conf"
echo
echo "2. Edit the configuration file:"
echo "   nano $CONFIG_DIR/azure_sync.conf"
echo
echo "3. Test the configuration:"
echo "   azure-freeipa-sync --dry-run -c $CONFIG_DIR/azure_sync.conf"
echo
echo "4. Run the sync:"
echo "   azure-freeipa-sync -c $CONFIG_DIR/azure_sync.conf"
echo
print_status "Installation guide: https://github.com/your-repo/azure-sync/README.md"