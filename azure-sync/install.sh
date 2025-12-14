#!/bin/bash
#===============================================================================
# Azure FreeIPA Sync - Installation Script
# Version: 1.0
# Author: Jackson Tong / Creekside Networks LLC
# License: MIT
#
# Description:
#   Interactive installation and configuration utility for Azure to FreeIPA
#   user synchronization. Automatically detects FreeIPA server configuration
#   and guides through Azure AD setup.
#
# Usage:
#   sudo ./install.sh
#
# Requirements:
#   - FreeIPA server installed and configured
#   - Root privileges
#   - Python 3.6+
#   - Network connectivity to Azure AD
#===============================================================================

set -e

# Configuration
INSTALL_DIR="/opt/azure-freeipa-sync"
CONFIG_FILE="$INSTALL_DIR/azure_sync.conf"
LOG_DIR="/var/log"
SERVICE_USER="root"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for terminal output
Red=$(tput setaf 1)
Green=$(tput setaf 2)
Yellow=$(tput setaf 3)
Blue=$(tput setaf 4)
Cyan=$(tput setaf 6)
Bold=$(tput bold)
Reset=$(tput sgr0)
Dim=$(tput dim)

#===============================================================================
# Output Helper Functions
#===============================================================================

# Print a section header with box border
print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))
    echo ""
    printf "${Cyan}%s${Reset}\n" "$(printf '═%.0s' $(seq 1 $width))"
    printf "${Cyan}║${Reset}%*s${Bold}%s${Reset}%*s${Cyan}║${Reset}\n" $padding "" "$title" $((width - padding - ${#title} - 2)) ""
    printf "${Cyan}%s${Reset}\n" "$(printf '═%.0s' $(seq 1 $width))"
}

# Print a step header
print_step() {
    local step_num="$1"
    local title="$2"
    echo ""
    echo -e "${Yellow}[$step_num]${Reset} ${Bold}$title${Reset}"
    echo -e "${Dim}$(printf '─%.0s' $(seq 1 50))${Reset}"
}

# Print success message
print_ok() {
    echo -e "  ${Green}✓${Reset} $1"
}

# Print warning message  
print_warn() {
    echo -e "  ${Yellow}⚠${Reset} $1"
}

# Print error message
print_error() {
    echo -e "  ${Red}✗${Reset} $1"
}

# Print info message
print_info() {
    echo -e "  ${Blue}ℹ${Reset} $1"
}

# Print a summary box
print_summary() {
    local title="$1"
    shift
    local items=("$@")
    echo ""
    echo -e "${Cyan}┌─ $title ────────────────────────${Reset}"
    for item in "${items[@]}"; do
        echo -e "${Cyan}│${Reset}  $item"
    done
    echo -e "${Cyan}└$(printf '─%.0s' $(seq 1 40))${Reset}"
}

#===============================================================================
# Main Functions
#===============================================================================

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Check if running on FreeIPA server
check_ipa_server() {
    print_step "1" "Verifying FreeIPA Server"
    
    if [[ ! -f /etc/ipa/default.conf ]]; then
        print_error "This script must be run on a FreeIPA server"
        print_info "File /etc/ipa/default.conf not found"
        exit 1
    fi
    
    # Try to get IPA admin credentials from /etc/ipa/secrets
    if [[ -f /etc/ipa/secrets ]]; then
        IPA_DM_PASSWORD=$(grep "^Directory Manager Password:" /etc/ipa/secrets | cut -d':' -f2 | tr -d ' ')
        IPA_ADMIN_PASSWORD=$(grep "^Admin Password:" /etc/ipa/secrets | cut -d':' -f2 | tr -d ' ')
        LDAP_AUTH_DN=$(grep "^LDAP Auth Service Account DN:" /etc/ipa/secrets | cut -d':' -f2- | tr -d ' ')
        LDAP_AUTH_PASSWORD=$(grep "^LDAP Auth Service Account Password:" /etc/ipa/secrets | cut -d':' -f2 | tr -d ' ')
        
        if [[ -n "$LDAP_AUTH_DN" && -n "$LDAP_AUTH_PASSWORD" ]]; then
            print_ok "Found LDAP Auth Service Account in /etc/ipa/secrets"
            IPA_BIND_DN="$LDAP_AUTH_DN"
            IPA_BIND_PASSWORD="$LDAP_AUTH_PASSWORD"
        elif [[ -n "$IPA_ADMIN_PASSWORD" ]]; then
            print_ok "Found IPA Admin password in /etc/ipa/secrets"
            IPA_BIND_DN="uid=admin,cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}"
            IPA_BIND_PASSWORD="$IPA_ADMIN_PASSWORD"
        fi
        
        if [[ -n "$IPA_DM_PASSWORD" ]]; then
            print_ok "Found Directory Manager password in /etc/ipa/secrets"
        fi
    fi
    
    # Get IPA server hostname and realm
    # Try 'host' first (default), then 'server' as fallback
    IPA_SERVER=$(grep -E "^host\s*=" /etc/ipa/default.conf | cut -d'=' -f2 | tr -d ' ')
    if [[ -z "$IPA_SERVER" ]]; then
        IPA_SERVER=$(grep -E "^server\s*=" /etc/ipa/default.conf | cut -d'=' -f2 | tr -d ' ')
    fi
    
    IPA_REALM=$(grep -E "^realm\s*=" /etc/ipa/default.conf | cut -d'=' -f2 | tr -d ' ')
    IPA_DOMAIN=$(grep -E "^domain\s*=" /etc/ipa/default.conf | cut -d'=' -f2 | tr -d ' ')
    
    if [[ -z "$IPA_SERVER" || -z "$IPA_REALM" ]]; then
        print_error "Could not detect IPA server configuration"
        print_info "Please check /etc/ipa/default.conf"
        exit 1
    fi
    
    print_ok "FreeIPA Server: $IPA_SERVER"
    print_ok "Realm: $IPA_REALM"
    print_ok "Domain: $IPA_DOMAIN"
}

# Check and install required packages
check_dependencies() {
    print_step "2" "Checking Dependencies"
    
    local missing_packages=()
    
    # Check for Python 3
    if ! command -v python3 &>/dev/null; then
        missing_packages+=("python3")
    else
        local python_version=$(python3 --version | awk '{print $2}')
        print_ok "Python 3 installed (version $python_version)"
    fi
    
    # Check for pip3
    if ! command -v pip3 &>/dev/null; then
        missing_packages+=("python3-pip")
    else
        print_ok "pip3 installed"
    fi
    
    # Install missing packages
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        print_info "Installing missing packages: ${missing_packages[*]}"
        if dnf install -y "${missing_packages[@]}" &>/dev/null; then
            print_ok "Packages installed successfully"
        else
            print_error "Failed to install required packages"
            exit 1
        fi
    fi
    
    # Install Python dependencies
    if [[ -f "$SCRIPT_DIR/requirements.txt" ]]; then
        print_info "Installing Python dependencies..."
        if pip3 install -q -r "$SCRIPT_DIR/requirements.txt"; then
            print_ok "Python dependencies installed"
        else
            print_error "Failed to install Python dependencies"
            exit 1
        fi
    else
        print_warn "requirements.txt not found, skipping Python dependencies"
    fi
}

# Get Azure AD configuration from user
get_azure_config() {
    print_step "3" "Azure AD Configuration"
    
    echo ""
    echo -e "${Bold}Enter your Azure AD application details:${Reset}"
    echo -e "${Dim}(You can get these from Azure Portal > App registrations)${Reset}"
    echo ""
    
    # Client ID
    while true; do
        echo -n "  Azure Client ID (Application ID): "
        read AZURE_CLIENT_ID
        if [[ -n "$AZURE_CLIENT_ID" && "$AZURE_CLIENT_ID" =~ ^[a-f0-9-]{36}$ ]]; then
            break
        else
            print_warn "Please enter a valid Client ID (GUID format)"
        fi
    done
    
    # Client Secret
    while true; do
        echo -n "  Azure Client Secret: "
        read AZURE_CLIENT_SECRET
        if [[ -n "$AZURE_CLIENT_SECRET" ]]; then
            break
        else
            print_warn "Client Secret cannot be empty"
        fi
    done
    
    # Tenant ID
    while true; do
        echo -n "  Azure Tenant ID (Directory ID): "
        read AZURE_TENANT_ID
        if [[ -n "$AZURE_TENANT_ID" && "$AZURE_TENANT_ID" =~ ^[a-f0-9-]{36}$ ]]; then
            break
        else
            print_warn "Please enter a valid Tenant ID (GUID format)"
        fi
    done
    
    print_ok "Azure AD configuration collected"
}

# Get IPA credentials
# Note: For user/group management, admin account is required.
get_ipa_credentials() {
    print_step "4" "FreeIPA Credentials"
    
    # Check if admin password is available from secrets file
    if [[ -n "$IPA_ADMIN_PASSWORD" ]]; then
        IPA_BIND_DN="uid=admin,cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}"
        IPA_BIND_PASSWORD="$IPA_ADMIN_PASSWORD"
        print_ok "Using admin credentials from /etc/ipa/secrets"
    elif [[ -n "$LDAP_AUTH_PASSWORD" ]]; then
        # Found ldapauth but it can't manage users - use admin instead
        print_warn "System account 'ldapauth' found but cannot manage users/groups"
        print_info "Switching to admin account for Azure sync operations"
        
        IPA_BIND_DN="uid=admin,cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}"
        
        echo ""
        while true; do
            echo -n "  Admin Password: "
            read -s IPA_BIND_PASSWORD
            echo
            if [[ -n "$IPA_BIND_PASSWORD" ]]; then
                break
            else
                print_warn "Password cannot be empty"
            fi
        done
        print_ok "Configured to use admin account"
    else
        # No credentials found, prompt for admin
        echo ""
        echo -e "${Bold}Enter FreeIPA admin credentials:${Reset}"
        echo -e "${Dim}(Required for user/group management)${Reset}"
        echo ""
        
        echo -n "  IPA Bind DN [uid=admin,cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}]: "
        read input_bind_dn
        IPA_BIND_DN=${input_bind_dn:-"uid=admin,cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}"}
        
        while true; do
            echo -n "  IPA Bind Password: "
            read -s IPA_BIND_PASSWORD
            echo
            if [[ -n "$IPA_BIND_PASSWORD" ]]; then
                break
            else
                print_warn "Password cannot be empty"
            fi
        done
        print_ok "Admin credentials configured"
    fi
}

# Create configuration file
create_config_file() {
    print_step "5" "Creating Configuration File"
    
    # Create install directory
    mkdir -p "$INSTALL_DIR"
    
    # Generate configuration file
    cat > "$CONFIG_FILE" <<EOF
# Azure FreeIPA Sync Configuration
# Generated on $(date)

[azure]
client_id = $AZURE_CLIENT_ID
client_secret = $AZURE_CLIENT_SECRET
tenant_id = $AZURE_TENANT_ID

[freeipa]
server = $IPA_SERVER
realm = $IPA_REALM
domain = $IPA_DOMAIN
bind_dn = $IPA_BIND_DN
bind_password = $IPA_BIND_PASSWORD

[sync]
# Default shell for new users
default_shell = /bin/bash

# Default home directory base
home_directory = /home

# Log file location
log_file = $LOG_DIR/azure-freeipa-sync.log

# Dry run mode (set to false for actual sync)
dry_run = false
EOF

    chmod 600 "$CONFIG_FILE"
    print_ok "Configuration saved to: $CONFIG_FILE"
}

# Install script files
install_files() {
    print_step "6" "Installing Application Files"
    
    # Copy Python script
    if [[ -f "$SCRIPT_DIR/azure_freeipa_sync.py" ]]; then
        cp "$SCRIPT_DIR/azure_freeipa_sync.py" "$INSTALL_DIR/"
        chmod 755 "$INSTALL_DIR/azure_freeipa_sync.py"
        print_ok "Script installed: $INSTALL_DIR/azure_freeipa_sync.py"
    else
        print_error "Source file not found: azure_freeipa_sync.py"
        exit 1
    fi
    
    # Create symlink
    ln -sf "$INSTALL_DIR/azure_freeipa_sync.py" /usr/local/bin/azure-freeipa-sync
    print_ok "Symlink created: /usr/local/bin/azure-freeipa-sync"
}

# Create systemd timer for scheduled sync
create_systemd_timer() {
    print_step "7" "Configuring Automated Sync"
    
    echo ""
    echo -e "${Bold}How often should the sync run?${Reset}"
    echo -e "  ${Cyan}1)${Reset} Every hour"
    echo -e "  ${Cyan}2)${Reset} Every 4 hours"
    echo -e "  ${Cyan}3)${Reset} Every 12 hours"
    echo -e "  ${Cyan}4)${Reset} Daily (at midnight)"
    echo -e "  ${Cyan}5)${Reset} Weekly (Sunday at midnight)"
    echo -e "  ${Cyan}6)${Reset} Manual only (no automatic sync)"
    echo ""
    echo -n "  Select [1-6]: "
    read sync_frequency
    
    case $sync_frequency in
        1) TIMER_SCHEDULE="*-*-* *:00:00"; TIMER_DESC="hourly" ;;
        2) TIMER_SCHEDULE="*-*-* 00/4:00:00"; TIMER_DESC="every 4 hours" ;;
        3) TIMER_SCHEDULE="*-*-* 00/12:00:00"; TIMER_DESC="every 12 hours" ;;
        4) TIMER_SCHEDULE="*-*-* 00:00:00"; TIMER_DESC="daily" ;;
        5) TIMER_SCHEDULE="Sun *-*-* 00:00:00"; TIMER_DESC="weekly" ;;
        6) 
            print_info "Skipping systemd timer creation"
            return
            ;;
        *) TIMER_SCHEDULE="*-*-* 00:00:00"; TIMER_DESC="daily" ;;
    esac
    
    # Create systemd service
    cat > /etc/systemd/system/azure-freeipa-sync.service <<EOF
[Unit]
Description=Azure FreeIPA User Synchronization
After=network.target ipa.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/azure-freeipa-sync -c $CONFIG_FILE
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer
    cat > /etc/systemd/system/azure-freeipa-sync.timer <<EOF
[Unit]
Description=Azure FreeIPA Sync Timer ($TIMER_DESC)
Requires=azure-freeipa-sync.service

[Timer]
OnCalendar=$TIMER_SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable azure-freeipa-sync.timer
    systemctl start azure-freeipa-sync.timer
    
    print_ok "Systemd service created: azure-freeipa-sync.service"
    print_ok "Systemd timer created: azure-freeipa-sync.timer"
    print_ok "Sync schedule: $TIMER_DESC"
}

# Show usage instructions
show_usage_instructions() {
    print_header "Installation Complete"
    
    echo ""
    print_summary "Configuration Summary" \
        "Install Directory: $INSTALL_DIR" \
        "Config File: $CONFIG_FILE" \
        "Log File: $LOG_DIR/azure-freeipa-sync.log" \
        "FreeIPA Server: $IPA_SERVER" \
        "Azure Tenant: $AZURE_TENANT_ID"
    
    echo ""
    echo -e "${Green}${Bold}Next Steps:${Reset}"
    echo ""
    echo -e "  ${Bold}1. Test the configuration (dry-run):${Reset}"
    echo -e "     ${Cyan}azure-freeipa-sync --dry-run${Reset}"
    echo ""
    echo -e "  ${Bold}2. Run manual sync:${Reset}"
    echo -e "     ${Cyan}azure-freeipa-sync${Reset}"
    echo ""
    echo -e "  ${Bold}3. View sync logs:${Reset}"
    echo -e "     ${Cyan}tail -f $LOG_DIR/azure-freeipa-sync.log${Reset}"
    echo ""
    echo -e "  ${Bold}4. Check timer status:${Reset}"
    echo -e "     ${Cyan}systemctl status azure-freeipa-sync.timer${Reset}"
    echo ""
    echo -e "  ${Bold}5. View timer schedule:${Reset}"
    echo -e "     ${Cyan}systemctl list-timers azure-freeipa-sync.timer${Reset}"
    echo ""
    echo -e "  ${Bold}6. Manually trigger sync:${Reset}"
    echo -e "     ${Cyan}systemctl start azure-freeipa-sync.service${Reset}"
    echo ""
    echo -e "${Dim}For more information, see README.md${Reset}"
    echo ""
}

#===============================================================================
# Main Installation Flow
#===============================================================================

main() {
    print_header "Azure FreeIPA Sync - Installation"
    
    check_ipa_server
    check_dependencies
    get_azure_config
    get_ipa_credentials
    create_config_file
    install_files
    create_systemd_timer
    show_usage_instructions
    
    echo -e "${Green}${Bold}✓ Installation completed successfully${Reset}"
    echo ""
}

main "$@"