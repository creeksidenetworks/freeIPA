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
    print_step "6" "Creating Configuration File"
    
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
default_shell = /bin/bash
home_directory = /home
log_file = $LOG_DIR/azure-freeipa-sync.log
dry_run = false

[smtp]
enabled = $SMTP_ENABLED
server = $SMTP_SERVER
port = $SMTP_PORT
use_tls = $SMTP_USE_TLS
username = $SMTP_USERNAME
password = $SMTP_PASSWORD
from_address = $SMTP_FROM
to_addresses = $SMTP_TO
notify_on_success = $SMTP_NOTIFY_SUCCESS
EOF

    chmod 600 "$CONFIG_FILE"
    print_ok "Configuration saved to: $CONFIG_FILE"
}

# Install script files
install_files() {
    print_step "7" "Installing Application Files"
    
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
    print_step "8" "Configuring Automated Sync"
    
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

# Collect optional SMTP notification settings
configure_smtp() {
    print_step "9" "Email Notifications (SMTP)"

    echo ""
    echo -n "  Enable email notifications on errors? [y/N]: "
    read -r enable_smtp
    if [[ "${enable_smtp,,}" != "y" ]]; then
        SMTP_ENABLED=false
        SMTP_SERVER=""
        SMTP_PORT=587
        SMTP_USE_TLS=true
        SMTP_USERNAME=""
        SMTP_PASSWORD=""
        SMTP_FROM=""
        SMTP_TO=""
        SMTP_NOTIFY_SUCCESS=false
        print_info "Notifications disabled — you can enable them later in $CONFIG_FILE"
        return
    fi

    SMTP_ENABLED=true

    echo -n "  SMTP server: "
    read -r SMTP_SERVER
    echo -n "  SMTP port [587]: "
    read -r SMTP_PORT
    SMTP_PORT=${SMTP_PORT:-587}
    echo -n "  Use STARTTLS? [Y/n]: "
    read -r tls_choice
    [[ "${tls_choice,,}" == "n" ]] && SMTP_USE_TLS=false || SMTP_USE_TLS=true
    echo -n "  SMTP username (leave blank if none): "
    read -r SMTP_USERNAME
    if [[ -n "$SMTP_USERNAME" ]]; then
        echo -n "  SMTP password: "
        read -rs SMTP_PASSWORD
        echo
    else
        SMTP_PASSWORD=""
    fi
    echo -n "  From address: "
    read -r SMTP_FROM
    echo -n "  To address(es) (comma-separated): "
    read -r SMTP_TO
    echo -n "  Also notify on successful (error-free) runs? [y/N]: "
    read -r notify_ok
    [[ "${notify_ok,,}" == "y" ]] && SMTP_NOTIFY_SUCCESS=true || SMTP_NOTIFY_SUCCESS=false

    print_ok "SMTP notifications configured"
}

# Install logrotate config and tiered cleanup cron jobs
setup_log_rotation() {
    print_step "10" "Configuring Log Rotation"

    # logrotate config: rotate hourly, dateext stamps for cleanup script
    cp "$SCRIPT_DIR/logrotate.conf" /etc/logrotate.d/azure-freeipa-sync
    chmod 644 /etc/logrotate.d/azure-freeipa-sync
    print_ok "logrotate config installed: /etc/logrotate.d/azure-freeipa-sync"

    # Hourly cron: trigger logrotate for this config every hour
    cat > /etc/cron.hourly/azure-freeipa-sync-rotate <<'EOF'
#!/bin/bash
/usr/sbin/logrotate /etc/logrotate.d/azure-freeipa-sync
EOF
    chmod 755 /etc/cron.hourly/azure-freeipa-sync-rotate
    print_ok "Hourly log rotation cron installed"

    # Cleanup script: tiered retention (hourly/daily/weekly)
    cp "$SCRIPT_DIR/cleanup_logs.py" "$INSTALL_DIR/cleanup_logs.py"
    chmod 755 "$INSTALL_DIR/cleanup_logs.py"
    print_ok "Log cleanup script installed: $INSTALL_DIR/cleanup_logs.py"

    # Daily cron: run tiered retention cleanup once a day
    cat > /etc/cron.daily/azure-freeipa-sync-cleanup <<EOF
#!/bin/bash
/usr/bin/python3 $INSTALL_DIR/cleanup_logs.py
EOF
    chmod 755 /etc/cron.daily/azure-freeipa-sync-cleanup
    print_ok "Daily log cleanup cron installed"

    print_info "Retention policy: hourly (24 h) -> daily (7 days) -> weekly (3 months)"
}

# Create dedicated azuresync service account with least-privilege role
create_sync_user() {
    print_step "5" "Creating Azure Sync Service Account"

    echo ""
    echo -n "  Create dedicated 'azuresync' service account? (Recommended) [Y/n]: "
    read -r create_svc
    if [[ "${create_svc,,}" == "n" ]]; then
        print_info "Skipping — current admin credentials will be used"
        return
    fi

    local ipa_domain_dc="dc=${IPA_DOMAIN//./,dc=}"
    local azuresync_dn="uid=azuresync,cn=users,cn=accounts,${ipa_domain_dc}"

    # Generate a secure random password
    local azuresync_password
    azuresync_password=$(python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%&*-+=_'
print(''.join(secrets.choice(chars) for _ in range(24)))
")

    # Kinit as admin to use IPA CLI
    if echo "$IPA_BIND_PASSWORD" | kinit admin &>/dev/null; then
        print_ok "Authenticated as admin (Kerberos)"
    else
        print_warn "Could not obtain Kerberos ticket as admin — skipping service account creation"
        return
    fi

    # Create or update azuresync user
    if ipa user-show azuresync &>/dev/null 2>&1; then
        print_warn "User 'azuresync' already exists"
        echo -n "  Reset password? [y/N]: "
        read -r reset_pw
        if [[ "${reset_pw,,}" != "y" ]]; then
            echo -n "  Enter existing azuresync password: "
            read -rs azuresync_password
            echo
            IPA_BIND_DN="$azuresync_dn"
            IPA_BIND_PASSWORD="$azuresync_password"
            kdestroy &>/dev/null || true
            return
        fi
    else
        if ipa user-add azuresync \
                --first=Azure --last=Sync \
                --shell=/sbin/nologin \
                &>/dev/null 2>&1; then
            print_ok "Created IPA user 'azuresync'"
        else
            print_error "Failed to create 'azuresync' — check IPA admin credentials"
            kdestroy &>/dev/null || true
            return
        fi
    fi

    # Set password and disable expiration via FreeIPA JSON API.
    # Using user_mod (same as the sync script) properly updates the Kerberos
    # principal key and krbLastPwdChange, then the second call clears the
    # admin-reset "must change on first login" flag by pushing expiration to 2099.
    # Credentials are passed via environment to avoid shell-quoting issues.
    if AZURESYNC_PW="$azuresync_password" \
       IPA_HOST="$IPA_SERVER" \
       IPA_ADMIN_PW="$IPA_BIND_PASSWORD" \
       python3 <<'PYEOF'
import os, sys
sys.path.insert(0, '/usr/lib64/python3.9/site-packages')
sys.path.insert(0, '/usr/lib/python3.9/site-packages')
from python_freeipa import ClientMeta
try:
    client = ClientMeta(os.environ['IPA_HOST'], verify_ssl=False)
    client.login('admin', os.environ['IPA_ADMIN_PW'])
    client.user_mod('azuresync', o_userpassword=os.environ['AZURESYNC_PW'])
    client.user_mod('azuresync', o_krbpasswordexpiration='20991231235959Z')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
    then
        print_ok "Password set (Kerberos keys updated)"
        print_ok "Password expiration disabled (set to 2099-12-31)"
    else
        print_warn "Could not set password via FreeIPA API — set it manually after install"
    fi

    # Create the sync role (idempotent)
    if ! ipa role-show "Azure Sync Role" &>/dev/null 2>&1; then
        ipa role-add "Azure Sync Role" \
            --desc="Least-privilege role for Azure Entra ID to FreeIPA sync" \
            &>/dev/null
        print_ok "Created 'Azure Sync Role'"
    else
        print_info "Role 'Azure Sync Role' already exists"
    fi

    # Assign required privileges (errors ignored if already assigned)
    ipa role-add-privilege "Azure Sync Role" \
        --privileges="User Administrators" &>/dev/null || true
    ipa role-add-privilege "Azure Sync Role" \
        --privileges="Group Administrators" &>/dev/null || true
    print_ok "Privileges: User Administrators, Group Administrators"

    # Assign azuresync to the role
    ipa role-add-member "Azure Sync Role" --users=azuresync &>/dev/null || true
    print_ok "Assigned azuresync to 'Azure Sync Role'"

    kdestroy &>/dev/null || true

    # Update bind credentials so create_config_file() writes azuresync details
    IPA_BIND_DN="$azuresync_dn"
    IPA_BIND_PASSWORD="$azuresync_password"

    # Log generated credentials securely for admin reference
    local pw_log="/var/log/azuresync_setup.log"
    printf '%s | azuresync | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$azuresync_password" \
        >> "$pw_log"
    chmod 600 "$pw_log"
    print_ok "Credentials logged to $pw_log (root read-only)"
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
    create_sync_user
    configure_smtp
    create_config_file
    install_files
    create_systemd_timer
    setup_log_rotation
    show_usage_instructions
    
    echo -e "${Green}${Bold}✓ Installation completed successfully${Reset}"
    echo ""
}

main "$@"