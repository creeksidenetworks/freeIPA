#!/bin/bash

# ==============================================================================
# FreeIPA Server and FreeRADIUS Installation Script for Rocky Linux 8/9
# ==============================================================================
# This script automates the installation of a FreeIPA server on Rocky Linux.
# It can install either a primary FreeIPA server or a replica server.
# It also installs and configures FreeRADIUS to use ipaNTHash for MS-CHAPv2.
#
# IMPORTANT: This script MUST be run with root privileges (e.g., `sudo`).
#
# Usage:
#   ./install-ipa.sh -h <fqdn> [-r] [-d <dm_password>] [-p <admin_password>]
#
# Arguments:
#   -h <fqdn>        : IPA FQDN (e.g., ipa.example.com)
#   -r              : Replica mode (default is standalone)
#   -d <password>   : Directory Manager password (random if not provided)
#   -p <password>   : Admin password (random if not provided)
#
# Example:
#   ./install-ipa.sh -h ipa.example.com
#   ./install-ipa.sh -h ipa2.example.com -r -d MyDMPass123 -p MyAdminPass123
# ==============================================================================

set -e

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/install-ipa-$(date +%Y%m%d-%H%M%S).log"
IPA_FQDN=""
IPA_DOMAIN=""
IPA_REALM=""
DM_PASSWORD=""
ADMIN_PASSWORD=""
REPLICA_MODE=false
RADIUS_SECRET=""

# --- Helper Functions ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

validate_fqdn() {
    local fqdn=$1
    if [[ ! $fqdn =~ ^[a-zA-Z0-9][a-zA-Z0-9\.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

show_usage() {
    cat << EOF
Usage: $0 -h <fqdn> [-r] [-d <dm_password>] [-p <admin_password>]

Arguments:
  -h <fqdn>        IPA FQDN (e.g., ipa.example.com)
  -r              Replica mode (default is standalone)
  -d <password>   Directory Manager password (random if not provided)
  -p <password>   Admin password (random if not provided)
  -?              Show this help

Examples:
  $0 -h ipa.example.com
  $0 -h ipa2.example.com -r -d MyDMPass123 -p MyAdminPass123
EOF
}

# --- OS Detection and Repository Setup ---

detect_os() {
    if [[ -f /etc/rocky-release ]]; then
        local version=$(grep -oE '[0-9]+' /etc/rocky-release | head -1)
        if [[ "$version" == "8" || "$version" == "9" ]]; then
            log "Detected Rocky Linux $version"
            return 0
        else
            error_exit "Unsupported Rocky Linux version: $version. This script supports Rocky 8 and 9."
        fi
    elif [[ -f /etc/redhat-release ]]; then
        if grep -q "Red Hat Enterprise Linux" /etc/redhat-release; then
            local version=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
            if [[ "$version" == "8" || "$version" == "9" ]]; then
                log "Detected RHEL $version"
                return 0
            else
                error_exit "Unsupported RHEL version: $version. This script supports RHEL 8 and 9."
            fi
        fi
    fi
    error_exit "This script only supports Rocky Linux 8/9 and RHEL 8/9"
}

setup_repositories() {
    log "Setting up IDM module and repositories..."
    
    # Enable IDM module for Rocky/RHEL 8/9
    if command -v dnf >/dev/null 2>&1; then
        dnf module list idm 2>/dev/null | grep -q "idm" && dnf module enable -y idm:DL1 || true
        dnf install -y epel-release
    else
        yum install -y epel-release
    fi
    
    log "Repositories configured successfully"
}
# --- Package Management ---

install_packages() {
    local packages=("$@")
    log "Installing packages: ${packages[*]}"
    
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "${packages[@]}" || error_exit "Failed to install packages"
    else
        yum install -y "${packages[@]}" || error_exit "Failed to install packages"
    fi
}

# --- Network Configuration ---

get_primary_interface() {
    ip route get 8.8.8.8 | awk '{print $5; exit}'
}

get_primary_ip() {
    local interface=$(get_primary_interface)
    [[ -z "$interface" ]] && error_exit "Could not determine primary network interface"
    
    ip -4 addr show "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}

configure_hostname() {
    local hostname=$1
    local domain=$2
    local ip=$3
    
    log "Configuring hostname: $hostname.$domain"
    hostnamectl set-hostname "$hostname.$domain"
    
    # Update /etc/hosts
    sed -i "/[[:space:]]$hostname\.$domain/d" /etc/hosts
    echo "$ip $hostname.$domain $hostname" >> /etc/hosts
}

configure_firewall() {
    log "Configuring firewall..."
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service={ntp,dns,freeipa-ldap,freeipa-ldaps,freeipa-replication,freeipa-trust,radius} >/dev/null
    firewall-cmd --reload >/dev/null
}

# --- FreeIPA Installation Functions ---

install_standalone_server() {
    local hostname=$(echo "$IPA_FQDN" | cut -d'.' -f1)
    local primary_ip=$(get_primary_ip)
    
    [[ -z "$primary_ip" ]] && error_exit "Could not determine primary IP address"
    
    log "Installing FreeIPA standalone server..."
    log "FQDN: $IPA_FQDN"
    log "Domain: $IPA_DOMAIN" 
    log "Realm: $IPA_REALM"
    log "IP: $primary_ip"
    
    # Install required packages
    local packages=(
        "bind" "bind-dyndb-ldap" "ipa-server" "ipa-server-dns" 
        "freeipa-server-trust-ad" "freeradius" "freeradius-ldap" 
        "freeradius-krb5" "freeradius-utils"
    )
    install_packages "${packages[@]}"
    
    # Configure hostname and firewall
    configure_hostname "$hostname" "$IPA_DOMAIN" "$primary_ip"
    configure_firewall
    
    log "Starting FreeIPA server installation..."
    ipa-server-install \
        --ds-password="$DM_PASSWORD" \
        --admin-password="$ADMIN_PASSWORD" \
        --ip-address="$primary_ip" \
        --domain="$IPA_DOMAIN" \
        --setup-adtrust \
        --realm="$IPA_REALM" \
        --hostname="$IPA_FQDN" \
        --setup-dns \
        --mkhomedir \
        --allow-zone-overlap \
        --auto-reverse \
        --auto-forwarders \
        --unattended || error_exit "FreeIPA installation failed"
    
    log "FreeIPA standalone server installation completed successfully"
}

install_replica_server() {
    local hostname=$(echo "$IPA_FQDN" | cut -d'.' -f1)
    local primary_ip=$(get_primary_ip)
    
    [[ -z "$primary_ip" ]] && error_exit "Could not determine primary IP address"
    
    log "Installing FreeIPA replica server..."
    log "FQDN: $IPA_FQDN"
    log "Domain: $IPA_DOMAIN"
    log "IP: $primary_ip"
    
    # Install required packages
    local packages=(
        "ipa-server" "ipa-server-dns" "freeipa-server-trust-ad" 
        "freeradius" "freeradius-ldap" "freeradius-krb5" "freeradius-utils"
    )
    install_packages "${packages[@]}"
    
    # Configure hostname and firewall
    configure_hostname "$hostname" "$IPA_DOMAIN" "$primary_ip"
    configure_firewall
    
    log "Starting FreeIPA replica installation..."
    ipa-replica-install \
        --setup-adtrust \
        --setup-ca \
        --setup-dns \
        --mkhomedir \
        --allow-zone-overlap \
        --auto-reverse \
        --auto-forwarders \
        --unattended || error_exit "FreeIPA replica installation failed"
    
    log "FreeIPA replica server installation completed successfully"
}

# --- FreeRADIUS Configuration ---

configure_freeradius() {
    log "Configuring FreeRADIUS with LDAP backend..."
    
    # Generate random RADIUS secret if not provided
    [[ -z "$RADIUS_SECRET" ]] && RADIUS_SECRET=$(generate_password)
    
    # Create configuration directories
    mkdir -p /etc/creekside/radius
    
    # Configure LDAP module
    configure_radius_ldap
    
    # Configure EAP module for MS-CHAPv2
    configure_radius_eap
    
    # Configure clients
    configure_radius_clients
    
    # Configure default site
    configure_radius_site
    
    # Generate certificates
    log "Generating RADIUS certificates..."
    bash /etc/raddb/certs/bootstrap >/dev/null 2>&1 || true
    
    # Enable and start FreeRADIUS
    systemctl enable radiusd
    systemctl restart radiusd || error_exit "Failed to start FreeRADIUS"
    
    log "FreeRADIUS configuration completed successfully"
    log "RADIUS client secret: $RADIUS_SECRET"
}

configure_radius_ldap() {
    local ldap_config="/etc/creekside/radius/radius-ldap.cfg"
    local base_dn="cn=accounts,dc=${IPA_DOMAIN//./,dc=}"
    
    log "Configuring FreeRADIUS LDAP module..."
    
    # Copy and modify LDAP configuration
    cp /etc/raddb/mods-available/ldap "$ldap_config"
    
    # Update LDAP configuration
    sed -i "s/server = 'localhost'/server = '127.0.0.1'/" "$ldap_config"
    sed -i "s/identity = 'cn=admin,dc=example,dc=org'/identity = 'cn=Directory Manager'/" "$ldap_config"
    sed -i "s/password = mypass/password = '$DM_PASSWORD'/" "$ldap_config"
    sed -i "s/base_dn = 'dc=example,dc=org'/base_dn = '$base_dn'/" "$ldap_config"
    
    # Configure NT-Password attribute for MS-CHAPv2
    sed -i '/control:NT-Password/c\\t\tcontrol:NT-Password\t\t:= '\''ipaNTHash'\''' "$ldap_config"
    
    # Add memberOf support
    sed -i '/reply:Tunnel-Private-Group-ID/c\\t\treply:memberOf\t\t\t+= '\''memberOf'\''' "$ldap_config"
    
    # Link to FreeRADIUS
    ln -sf "$ldap_config" /etc/raddb/mods-enabled/ldap
}

configure_radius_eap() {
    local eap_config="/etc/creekside/radius/mods-eap.conf"
    
    log "Configuring FreeRADIUS EAP module..."
    
    # Copy and modify EAP configuration
    cp /etc/raddb/mods-available/eap "$eap_config"
    
    # Set default EAP type to MS-CHAPv2
    sed -i 's/default_eap_type = md5/default_eap_type = mschapv2/' "$eap_config"
    
    # Link to FreeRADIUS
    ln -sf "$eap_config" /etc/raddb/mods-enabled/eap
}

configure_radius_clients() {
    local clients_config="/etc/creekside/radius/radius-clients.conf"
    
    log "Configuring FreeRADIUS clients..."
    
    cat > "$clients_config" << EOF
# FreeRADIUS clients configuration
client localnet {
    ipaddr = 0.0.0.0/0
    proto = *
    secret = $RADIUS_SECRET
    nas_type = other
    limit {
        max_connections = 16
        lifetime = 0
        idle_timeout = 30
    }
}

client localhost {
    ipaddr = 127.0.0.1
    proto = *
    secret = $RADIUS_SECRET
    nas_type = other
    limit {
        max_connections = 16
        lifetime = 0
        idle_timeout = 30
    }
}
EOF
    
    # Backup original and link new config
    [[ ! -f /etc/raddb/clients.conf.orig ]] && cp /etc/raddb/clients.conf /etc/raddb/clients.conf.orig
    ln -sf "$clients_config" /etc/raddb/clients.conf
}

configure_radius_site() {
    local site_config="/etc/creekside/radius/radius-default.cfg"
    
    log "Configuring FreeRADIUS default site..."
    
    # Copy and modify default site
    cp /etc/raddb/sites-available/default "$site_config"
    
    # Add group membership to reply
    sed -i 's/post-auth {/post-auth {\n\tforeach \&reply:memberOf {\n\t\tif ("%{Foreach-Variable-0}" =~ \/cn=groups\/i) {\n\t\t\tif ("%{Foreach-Variable-0}" =~ \/cn=([^,=]+)\/i) {\n\t\t\t\tupdate reply {\n\t\t\t\t\tClass += "%{1}"\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}/' "$site_config"
    
    # Link to FreeRADIUS
    ln -sf "$site_config" /etc/raddb/sites-enabled/default
    
    # Add memberOf to dictionary if not present
    if ! grep -q "memberOf" /etc/raddb/dictionary; then
        echo -e "ATTRIBUTE\tmemberOf\t\t3101\tstring" >> /etc/raddb/dictionary
    fi
}

# --- Argument Parsing ---

parse_arguments() {
    while getopts "h:rd:p:?" opt; do
        case $opt in
            h)
                IPA_FQDN="$OPTARG"
                ;;
            r)
                REPLICA_MODE=true
                ;;
            d)
                DM_PASSWORD="$OPTARG"
                ;;
            p)
                ADMIN_PASSWORD="$OPTARG"
                ;;
            ?)
                show_usage
                exit 0
                ;;
            *)
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate required arguments
    if [[ -z "$IPA_FQDN" ]]; then
        echo "ERROR: FQDN is required (-h option)" >&2
        show_usage
        exit 1
    fi
    
    if ! validate_fqdn "$IPA_FQDN"; then
        error_exit "Invalid FQDN format: $IPA_FQDN"
    fi
    
    # Extract domain and realm from FQDN
    IPA_DOMAIN="${IPA_FQDN#*.}"
    IPA_REALM="${IPA_DOMAIN^^}"
    
    # Generate passwords if not provided
    if [[ -z "$DM_PASSWORD" ]]; then
        DM_PASSWORD=$(generate_password)
        log "Generated Directory Manager password: $DM_PASSWORD"
    fi
    
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD=$(generate_password)
        log "Generated Admin password: $ADMIN_PASSWORD"
    fi
    
    # Generate RADIUS secret
    RADIUS_SECRET=$(generate_password)
}

# --- Summary and Confirmation ---

show_configuration_summary() {
    log "=== Installation Configuration ==="
    log "FQDN: $IPA_FQDN"
    log "Domain: $IPA_DOMAIN" 
    log "Realm: $IPA_REALM"
    log "Mode: $([ "$REPLICA_MODE" = true ] && echo "Replica" || echo "Standalone")"
    log "Directory Manager Password: $DM_PASSWORD"
    log "Admin Password: $ADMIN_PASSWORD"
    log "RADIUS Secret: $RADIUS_SECRET"
    log "Log File: $LOG_FILE"
    log "================================="
}

save_passwords() {
    cat > "$LOG_FILE.passwords" << EOF
FreeIPA Installation Passwords
Generated on: $(date)
FQDN: $IPA_FQDN
Domain: $IPA_DOMAIN
Realm: $IPA_REALM

Directory Manager Password: $DM_PASSWORD
Admin Password: $ADMIN_PASSWORD
RADIUS Client Secret: $RADIUS_SECRET

Log file: $LOG_FILE
EOF
    chmod 600 "$LOG_FILE.passwords"
    log "Passwords saved to: $LOG_FILE.passwords"
}

# --- Main Function ---

main() {
    log "Starting FreeIPA installation script"
    log "Script version: 2.0 for Rocky Linux 8/9"
    
    # Root check
    [[ $EUID -ne 0 ]] && error_exit "This script must be run as root"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Show configuration
    show_configuration_summary
    
    # OS detection and setup
    detect_os
    setup_repositories
    
    # Install based on mode
    if [[ "$REPLICA_MODE" = true ]]; then
        install_replica_server
    else
        install_standalone_server
    fi
    
    # Configure FreeRADIUS (only for standalone mode)
    if [[ "$REPLICA_MODE" != true ]]; then
        configure_freeradius
    fi
    
    # Save passwords
    save_passwords
    
    log "=== Installation Complete ==="
    log "FreeIPA server is now running"
    log "You can access the web interface at: https://$IPA_FQDN"
    log "Admin username: admin"
    log "Admin password: $ADMIN_PASSWORD"
    if [[ "$REPLICA_MODE" != true ]]; then
        log "FreeRADIUS is configured and running"
        log "RADIUS client secret: $RADIUS_SECRET"
    fi
    log "All passwords saved to: $LOG_FILE.passwords"
}

# Execute main function with all arguments
main "$@"
