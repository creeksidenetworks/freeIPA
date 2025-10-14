#!/bin/bash

# ==============================================================================
# FreeIPA and FreeRADIUS Uninstall Script
# ==============================================================================
# This script removes FreeIPA and FreeRADIUS installations and configurations
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

error() {
    echo -e "${RED}ERROR: $1${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

This script uninstalls FreeIPA and FreeRADIUS from the system.

Options:
  --force-yes    Skip confirmation prompts (use with caution)
  --keep-data    Keep user data and certificates (safer option)
  --help         Show this help message

WARNING: This will remove all FreeIPA data including users, groups, 
and certificates unless --keep-data is specified.
EOF
}

confirm_uninstall() {
    if [[ "$FORCE_YES" == "true" ]]; then
        return 0
    fi
    
    echo
    warn "This will completely remove FreeIPA and FreeRADIUS from this system!"
    warn "All users, groups, certificates, and configuration will be lost!"
    echo
    read -p "Are you absolutely sure you want to continue? (type 'yes' to confirm): " response
    
    if [[ "$response" != "yes" ]]; then
        log "Uninstall cancelled by user"
        exit 0
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

stop_services() {
    log "Stopping FreeIPA and FreeRADIUS services..."
    
    # Stop FreeRADIUS
    if systemctl is-active radiusd >/dev/null 2>&1; then
        systemctl stop radiusd || true
        systemctl disable radiusd || true
        success "FreeRADIUS service stopped"
    fi
    
    # Stop FreeIPA services
    if command -v ipactl >/dev/null 2>&1; then
        ipactl stop || true
        success "FreeIPA services stopped"
    fi
}

uninstall_freeipa() {
    log "Uninstalling FreeIPA..."
    
    if command -v ipa-server-install >/dev/null 2>&1; then
        if [[ "$KEEP_DATA" == "true" ]]; then
            warn "Keeping FreeIPA data as requested"
        else
            log "Running FreeIPA uninstaller..."
            ipa-server-install --uninstall --unattended || true
        fi
    fi
    
    # Remove FreeIPA packages
    local ipa_packages=(
        "ipa-server" "ipa-server-dns" "freeipa-server-trust-ad"
        "bind-dyndb-ldap" "bind"
    )
    
    if command -v dnf >/dev/null 2>&1; then
        dnf remove -y "${ipa_packages[@]}" || true
    else
        yum remove -y "${ipa_packages[@]}" || true
    fi
    
    success "FreeIPA uninstalled"
}

uninstall_freeradius() {
    log "Uninstalling FreeRADIUS..."
    
    # Remove FreeRADIUS packages
    local radius_packages=(
        "freeradius" "freeradius-ldap" "freeradius-krb5" "freeradius-utils"
    )
    
    if command -v dnf >/dev/null 2>&1; then
        dnf remove -y "${radius_packages[@]}" || true
    else
        yum remove -y "${radius_packages[@]}" || true
    fi
    
    success "FreeRADIUS uninstalled"
}

cleanup_configurations() {
    log "Cleaning up configuration files..."
    
    # Remove custom configuration directories
    if [[ -d "/etc/creekside" ]]; then
        rm -rf /etc/creekside
        success "Removed /etc/creekside configuration directory"
    fi
    
    # Clean up FreeRADIUS configurations (if keeping data, backup first)
    if [[ -d "/etc/raddb" ]]; then
        if [[ "$KEEP_DATA" == "true" ]]; then
            mv /etc/raddb /etc/raddb.backup.$(date +%Y%m%d-%H%M%S) || true
            log "FreeRADIUS config backed up to /etc/raddb.backup.*"
        else
            rm -rf /etc/raddb || true
            success "Removed FreeRADIUS configurations"
        fi
    fi
    
    # Clean up FreeIPA configurations
    if [[ "$KEEP_DATA" != "true" ]]; then
        rm -rf /etc/ipa || true
        rm -rf /var/lib/ipa || true
        rm -rf /var/log/ipa* || true
        rm -rf /etc/dirsrv || true
        rm -rf /etc/pki/CA || true
        rm -rf /etc/pki/nssdb || true
        success "Removed FreeIPA configurations and data"
    else
        log "Keeping FreeIPA data as requested"
    fi
}

cleanup_firewall() {
    log "Cleaning up firewall rules..."
    
    if systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-service=freeipa-ldap || true
        firewall-cmd --permanent --remove-service=freeipa-ldaps || true
        firewall-cmd --permanent --remove-service=freeipa-replication || true
        firewall-cmd --permanent --remove-service=freeipa-trust || true
        firewall-cmd --permanent --remove-service=dns || true
        firewall-cmd --permanent --remove-service=radius || true
        firewall-cmd --reload || true
        success "Firewall rules cleaned up"
    fi
}

reset_hostname() {
    log "Resetting hostname configuration..."
    
    # Reset to simple hostname
    local simple_hostname=$(hostname | cut -d'.' -f1)
    hostnamectl set-hostname "$simple_hostname" || true
    
    # Clean up /etc/hosts entries (be careful here)
    warn "Please manually review /etc/hosts for FreeIPA entries to remove"
}

# Parse arguments
FORCE_YES=false
KEEP_DATA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force-yes)
            FORCE_YES=true
            shift
            ;;
        --keep-data)
            KEEP_DATA=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
log "Starting FreeIPA/FreeRADIUS uninstall process"

check_root
confirm_uninstall
stop_services
uninstall_freeipa
uninstall_freeradius
cleanup_configurations
cleanup_firewall
reset_hostname

echo
success "Uninstall process completed!"
echo
log "System cleanup summary:"
log "- FreeIPA services stopped and uninstalled"
log "- FreeRADIUS services stopped and uninstalled"
log "- Configuration files $([ "$KEEP_DATA" == "true" ] && echo "backed up" || echo "removed")"
log "- Firewall rules cleaned up"
echo
warn "Please reboot the system to ensure all changes take effect"

if [[ "$KEEP_DATA" == "true" ]]; then
    echo
    warn "Data preservation mode was used. Some manual cleanup may be required."
    warn "Review backup directories and /etc/hosts for remaining entries."
fi