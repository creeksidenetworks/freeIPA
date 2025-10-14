#!/bin/bash
#
# Azure FreeIPA Sync Installation Script for Rocky Linux 9
#
# This script installs and configures the Azure Entra ID to FreeIPA sync tool
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/freeipa-sync"
CONFIG_FILE="/etc/azure_sync.conf"
LOG_DIR="/var/log"
BACKUP_DIR="/var/backups/freeipa-sync"

echo -e "${BLUE}Azure FreeIPA Sync Installation Script${NC}"
echo "========================================"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

# Check if FreeIPA is installed
echo -e "${BLUE}Checking FreeIPA installation...${NC}"
if ! command -v ipa &> /dev/null; then
    echo -e "${RED}Error: FreeIPA not found. Please install FreeIPA first.${NC}"
    exit 1
fi

if ! systemctl is-active --quiet ipa; then
    echo -e "${YELLOW}Warning: FreeIPA service is not running${NC}"
fi

echo -e "${GREEN}✓ FreeIPA found${NC}"

# Install system dependencies
echo -e "${BLUE}Installing system dependencies...${NC}"
dnf update -y
dnf install -y python3 python3-pip python3-devel gcc openssl-devel libffi-devel krb5-devel

# Create installation directory
echo -e "${BLUE}Creating installation directory...${NC}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$BACKUP_DIR"

# Copy files
echo -e "${BLUE}Installing sync script...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cp "$PROJECT_ROOT/src/azure_freeipa_sync.py" "$INSTALL_DIR/"
cp "$PROJECT_ROOT/src/validate_config.py" "$INSTALL_DIR/"
cp "$PROJECT_ROOT/requirements.txt" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/azure_freeipa_sync.py"
chmod +x "$INSTALL_DIR/validate_config.py"

# Install Python dependencies
echo -e "${BLUE}Installing Python dependencies...${NC}"
cd "$INSTALL_DIR"
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

# Copy configuration file if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${BLUE}Installing default configuration...${NC}"
    cp "$PROJECT_ROOT/config/azure_sync.conf.example" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo -e "${YELLOW}Please edit $CONFIG_FILE with your Azure and FreeIPA settings${NC}"
else
    echo -e "${YELLOW}Configuration file already exists: $CONFIG_FILE${NC}"
fi

# Install systemd service files
echo -e "${BLUE}Installing systemd service...${NC}"
cp "$PROJECT_ROOT/config/systemd/azure-freeipa-sync.service" /etc/systemd/system/
cp "$PROJECT_ROOT/config/systemd/azure-freeipa-sync.timer" /etc/systemd/system/

# Reload systemd and enable timer
systemctl daemon-reload
systemctl enable azure-freeipa-sync.timer

# Create log rotation
echo -e "${BLUE}Setting up log rotation...${NC}"
cat > /etc/logrotate.d/azure-freeipa-sync << EOF
/var/log/azure_freeipa_sync.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}

/var/log/freeipa_new_passwords.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 600 root root
}
EOF

# Set up proper SELinux contexts (if SELinux is enabled)
if command -v getenforce &> /dev/null && [[ $(getenforce) != "Disabled" ]]; then
    echo -e "${BLUE}Configuring SELinux contexts...${NC}"
    setsebool -P httpd_can_network_connect 1
    semanage fcontext -a -t bin_t "$INSTALL_DIR/azure_freeipa_sync.py" 2>/dev/null || true
    restorecon -R "$INSTALL_DIR" 2>/dev/null || true
fi

# Create a test script
echo -e "${BLUE}Creating test script...${NC}"
cat > "$INSTALL_DIR/test_sync.sh" << 'EOF'
#!/bin/bash
# Test script for Azure FreeIPA Sync

echo "Testing Azure FreeIPA Sync configuration..."

# Check configuration file
if [ ! -f /etc/azure_sync.conf ]; then
    echo "❌ Configuration file not found: /etc/azure_sync.conf"
    exit 1
fi

echo "✓ Configuration file found"

# Validate configuration and test connectivity
echo "Validating configuration..."
cd /opt/freeipa-sync
python3 validate_config.py -c /etc/azure_sync.conf

if [ $? -eq 0 ]; then
    echo ""
    echo "Running dry-run test..."
    python3 azure_freeipa_sync.py --dry-run
else
    echo "❌ Configuration validation failed. Please fix the issues above."
    exit 1
fi

echo "Test completed. Check the output above for any errors."
EOF

chmod +x "$INSTALL_DIR/test_sync.sh"

# Copy monitor script
echo -e "${BLUE}Installing monitor script...${NC}"
cp "$SCRIPT_DIR/monitor.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/monitor.sh"

# Create symlink for easy access
ln -sf "$INSTALL_DIR/monitor.sh" /usr/local/bin/azure-sync-monitor

echo ""
echo -e "${GREEN}Installation completed successfully!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Edit the configuration file: $CONFIG_FILE"
echo "   - Add your Azure tenant ID, client ID, and client secret"
echo "   - Configure FreeIPA server details"
echo "   - Adjust sync settings as needed"
echo ""
echo "2. Test the configuration:"
echo "   $INSTALL_DIR/test_sync.sh"
echo ""
echo "3. Start the sync timer (for daily automatic sync):"
echo "   systemctl start azure-freeipa-sync.timer"
echo ""
echo "4. Manual sync can be run with:"
echo "   cd $INSTALL_DIR && python3 azure_freeipa_sync.py"
echo ""
echo "5. Monitor sync status:"
echo "   azure-sync-monitor"
echo ""
echo -e "${BLUE}Log files:${NC}"
echo "   - Sync log: /var/log/azure_freeipa_sync.log"
echo "   - New user passwords: /var/log/freeipa_new_passwords.log"
echo "   - Backups: $BACKUP_DIR"
echo ""
echo -e "${YELLOW}Security Note:${NC}"
echo "The configuration file and password log are set with restrictive permissions."
echo "Make sure to secure these files appropriately."