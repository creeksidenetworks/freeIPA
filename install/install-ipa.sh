#!/bin/bash

# ==============================================================================
# FreeIPA Server Installation Script for Rocky Linux 8/9
# ==============================================================================
# This script automates the installation of a FreeIPA server on Rocky Linux.
# It can install either a primary FreeIPA server or a replica server.
#
# IMPORTANT: This script MUST be run with root privileges (e.g., `sudo`).
#
# Usage:
#   ./install-ipa.sh -h <fqdn> [-r] [-d <dm_password>] [-p <admin_password>] [-f <forwarder1,forwarder2,...>]
#
# Arguments:
#   -h <fqdn>        : IPA FQDN (e.g., ipa.example.com)
#   -r              : Replica mode (default is standalone)
#   -d <password>   : Directory Manager password (random if not provided)
#   -p <password>   : Admin password (random if not provided)
#   -f <forwarders> : DNS forwarders (comma-separated, e.g., 8.8.8.8,8.8.4.4)
#
# Example:
#   ./install-ipa.sh -h ipa.example.com
#   ./install-ipa.sh -h ipa2.example.com -r -p MyAdminPass123
#   ./install-ipa.sh -h ipa.example.com -f 8.8.8.8,1.1.1.1
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
DNS_FORWARDERS=""

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
Usage: $0 -h <fqdn> [-r] [-d <dm_password>] [-p <admin_password>] [-f <forwarders>]

Arguments:
  -h <fqdn>        IPA FQDN (e.g., ipa.example.com)
  -r              Replica mode (default is standalone)
  -d <password>   Directory Manager password (random if not provided for standalone,
                  optional for replica)
  -p <password>   Admin password (required for replica, random if not provided for standalone)
  -f <forwarders> DNS forwarders (comma-separated, e.g., 8.8.8.8,8.8.4.4)
                  Only applicable for standalone/primary server installation
                  If not specified, --auto-forwarders will be used
                  Replicas will inherit DNS forwarders from the primary server
  -?              Show this help

Examples:
  # Standalone server (first IPA server)
  $0 -h ipa.example.com

  # Standalone server with custom DNS forwarders
  $0 -h ipa.example.com -f 8.8.8.8,1.1.1.1

  # Replica server (requires existing IPA domain)
  $0 -h ipa2.example.com -r -p AdminPassword123

  # Replica with DM password stored for later use
  $0 -h ipa2.example.com -r -p AdminPass123 -d DMPassword123

  # Standalone with custom passwords
  $0 -h ipa.example.com -d MyDMPass123 -p MyAdminPass123

Note for Replica Mode:
  - The server will first join the existing IPA domain as a client
  - Then it will be promoted to a replica server
  - Admin password is required to join the domain
  - Directory Manager password is optional but can be stored for later use
  - The DM password is shared across all servers in the domain
  - DNS forwarders are automatically inherited from the primary server
  - Ensure DNS can resolve the primary IPA server
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

check_and_configure_static_ip() {
    local interface=$(get_primary_interface)
    [[ -z "$interface" ]] && error_exit "Could not determine primary network interface"
    
    local current_ip=$(get_primary_ip)
    [[ -z "$current_ip" ]] && error_exit "Could not determine current IP address"
    
    log "Checking network configuration for interface: $interface"
    log "Current IP address: $current_ip"
    
    # Check if using NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        local connection_name=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$interface$" | cut -d: -f1)
        
        if [[ -z "$connection_name" ]]; then
            log "WARNING: No active NetworkManager connection found for $interface"
            return 1
        fi
        
        log "Active connection: $connection_name"
        
        # Check if connection name matches interface name
        if [[ "$connection_name" != "$interface" ]]; then
            log "Connection name '$connection_name' does not match interface name '$interface'"
            log "Renaming connection to match interface..."
            
            # Rename the connection to match the interface
            if nmcli connection modify "$connection_name" connection.id "$interface"; then
                log "✓ Connection renamed from '$connection_name' to '$interface'"
                connection_name="$interface"
            else
                log "WARNING: Failed to rename connection, continuing with current name: $connection_name"
            fi
        fi
        
        # Check if DHCP is enabled (ipv4.method)
        local ipv4_method=$(nmcli -t -f ipv4.method connection show "$connection_name" | cut -d: -f2)
        
        if [[ "$ipv4_method" == "auto" || "$ipv4_method" == "dhcp" ]]; then
            log "WARNING: Interface $interface is configured for DHCP"
            log "FreeIPA requires a static IP address"
            
            # Get current network configuration
            local gateway=$(ip route | grep "^default" | grep "$interface" | awk '{print $3}' | head -1)
            local prefix=$(ip -o -f inet addr show "$interface" | awk '{print $4}' | cut -d/ -f2 | head -1)
            local dns_servers=$(nmcli -t -f IP4.DNS connection show "$connection_name" | cut -d: -f2 | tr '\n' ' ')
            
            # If no DNS servers configured, use common defaults
            if [[ -z "$dns_servers" ]]; then
                dns_servers="8.8.8.8 8.8.4.4"
            fi
            
            # Display current configuration and ask for confirmation
            log ""
            log "=========================================="
            log "Current Network Configuration (DHCP):"
            log "  Interface: $interface"
            log "  Connection: $connection_name"
            log "  IP Address: $current_ip/$prefix"
            log "  Gateway: ${gateway:-<not set>}"
            log "  DNS Servers: $dns_servers"
            log "=========================================="
            log ""
            log "Converting $interface from DHCP to static IP..."
            log ""
            
            log "Converting to static IP configuration..."
            
            # Build the nmcli command arguments
            local modify_args=(
                "connection" "modify" "$connection_name"
                "ipv4.method" "manual"
                "ipv4.addresses" "$current_ip/$prefix"
            )
            
            # Add gateway if available
            if [[ -n "$gateway" ]]; then
                modify_args+=("ipv4.gateway" "$gateway")
            fi
            
            # Add DNS servers
            modify_args+=("ipv4.dns" "$dns_servers")
            
            # Apply configuration
            if nmcli "${modify_args[@]}"; then
                log "✓ Configuration updated successfully"
            else
                error_exit "Failed to configure static IP with nmcli"
            fi
            
            # Bring connection down and up to apply changes
            log "Applying network configuration changes..."
            log "  - Bringing connection down..."
            nmcli connection down "$connection_name" >/dev/null 2>&1 || true
            sleep 2
            
            log "  - Bringing connection up..."
            if nmcli connection up "$connection_name"; then
                log "  ✓ Connection activated successfully"
            else
                error_exit "Failed to bring up connection with static IP"
            fi
            
            # Wait for network to stabilize
            log "Waiting for network to stabilize..."
            sleep 5
            
            # Verify IP didn't change
            local new_ip=$(get_primary_ip)
            if [[ "$new_ip" != "$current_ip" ]]; then
                error_exit "IP address changed after converting to static ($current_ip -> $new_ip). Please check network configuration."
            fi
            
            # Verify the configuration is now static
            local new_ipv4_method=$(nmcli -t -f ipv4.method connection show "$connection_name" | cut -d: -f2)
            if [[ "$new_ipv4_method" == "manual" ]]; then
                log "✓ Successfully converted to static IP: $current_ip/$prefix"
                log "✓ Configuration verified: method=$new_ipv4_method"
            else
                log "WARNING: Configuration method is '$new_ipv4_method' (expected 'manual')"
            fi
        else
            log "✓ Interface $interface is already configured with static IP ($ipv4_method)"
        fi
    else
        log "NetworkManager is not active, checking network-scripts..."
        
        local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-$interface"
        if [[ -f "$ifcfg_file" ]]; then
            if grep -q "BOOTPROTO=dhcp" "$ifcfg_file"; then
                log "WARNING: Interface $interface is configured for DHCP in $ifcfg_file"
                error_exit "Please manually configure $interface with static IP before proceeding. Edit $ifcfg_file and set BOOTPROTO=static with appropriate IP settings."
            else
                log "✓ Interface $interface appears to have static configuration"
            fi
        else
            log "WARNING: Network configuration file not found: $ifcfg_file"
            log "Unable to verify static IP configuration"
        fi
    fi
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
    firewall-cmd --permanent --add-service={ntp,dns,freeipa-ldap,freeipa-ldaps,freeipa-replication,freeipa-trust} >/dev/null
    firewall-cmd --reload >/dev/null
}

# --- LDAP Service Account Creation ---

create_ldapauth_service_account() {
    log "Creating ldapauth service account for LDAP authentication..."
    
    local service_dn="uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}"
    local ldapauth_password=$(generate_password)
    
    # Get Kerberos ticket as admin
    echo "$ADMIN_PASSWORD" | kinit admin@"$IPA_REALM" || error_exit "Failed to get Kerberos ticket"
    
    # Create LDIF for service account
    cat > /tmp/ldapauth.ldif << EOF
dn: $service_dn
objectClass: account
objectClass: simplesecurityobject
uid: ldapauth
userPassword: $ldapauth_password
description: LDAP authentication service account for applications requiring LDAP access
EOF
    
    # Add service account (use FQDN instead of localhost)
    if ldapadd -Y GSSAPI -H ldap://"$IPA_FQDN" -f /tmp/ldapauth.ldif; then
        rm -f /tmp/ldapauth.ldif
        log "✓ Service account 'ldapauth' created successfully"
        log "Password: $ldapauth_password"
        
        # Add ACI to allow ldapauth to read ipaNTHash attribute for MS-CHAP authentication
        log "Adding permission for ldapauth to read ipaNTHash attribute..."
        local users_dn="cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}"
        local aci_name="LDAP Service Account ipaNTHash Access"
        local aci_value="(targetattr=\"ipaNTHash\")(version 3.0; acl \"$aci_name\"; allow (read,search,compare) userdn=\"ldap:///$service_dn\";)"
        
        # Create LDIF to add ACI
        cat > /tmp/ldapauth_aci.ldif << EOF
dn: $users_dn
changetype: modify
add: aci
aci: $aci_value
EOF
        
        if ldapmodify -Y GSSAPI -H ldap://"$IPA_FQDN" -f /tmp/ldapauth_aci.ldif 2>/dev/null; then
            log "✓ Permission granted for ldapauth to read ipaNTHash"
        else
            log "WARNING: Could not add ACI for ipaNTHash access (may already exist)"
        fi
        rm -f /tmp/ldapauth_aci.ldif
        
        # Verify service account can bind (use 127.0.0.1 for simple bind)
        if ldapsearch -x -D "$service_dn" -w "$ldapauth_password" -H ldap://127.0.0.1 -b "cn=accounts,dc=${IPA_DOMAIN//./,dc=}" -s base dn >/dev/null 2>&1; then
            log "✓ Service account authentication verified"
        else
            log "WARNING: Could not verify service account authentication"
        fi
        
        # Save password to temporary location for later inclusion in secrets file
        mkdir -p /tmp/ipa-install-secrets
        echo "LDAP Auth Service Account Password: $ldapauth_password" > /tmp/ipa-install-secrets/ldapauth_password
        log "✓ Password will be saved to /etc/ipa/secrets"
    else
        rm -f /tmp/ldapauth.ldif
        error_exit "Failed to create ldapauth service account"
    fi
    
    # Destroy kerberos ticket
    kdestroy 2>/dev/null || true
}

# --- FreeIPA Installation Functions ---

install_standalone_server() {
    local hostname=$(echo "$IPA_FQDN" | cut -d'.' -f1)
    
    # Check and configure static IP before proceeding
    check_and_configure_static_ip
    
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
        "freeipa-server-trust-ad"
    )
    install_packages "${packages[@]}"
    
    # Configure hostname and firewall
    configure_hostname "$hostname" "$IPA_DOMAIN" "$primary_ip"
    configure_firewall
    
    log "Starting FreeIPA server installation..."
    
    # Build installation command
    local install_cmd=(
        "ipa-server-install"
        "--ds-password=$DM_PASSWORD"
        "--admin-password=$ADMIN_PASSWORD"
        "--ip-address=$primary_ip"
        "--domain=$IPA_DOMAIN"
        "--setup-adtrust"
        "--realm=$IPA_REALM"
        "--hostname=$IPA_FQDN"
        "--setup-dns"
        "--mkhomedir"
        "--allow-zone-overlap"
        "--auto-reverse"
        "--unattended"
        "--idstart=1668600000" 
        "--idmax=1668800000"
    )
    
    # Add DNS forwarders handling
    if [[ -n "$DNS_FORWARDERS" ]]; then
        log "Custom DNS forwarders will be configured post-installation: $DNS_FORWARDERS"
        # Do not pass --forwarder to installer, will configure after installation
        install_cmd+=("--no-forwarders")
    else
        log "Using auto-detected DNS forwarders"
        install_cmd+=("--auto-forwarders")
    fi
    
    # Always disable DNSSEC validation to allow DNS forwarding
    install_cmd+=("--no-dnssec-validation")
    log "DNSSEC validation will be disabled"
    
    # Execute installation
    "${install_cmd[@]}" || error_exit "FreeIPA installation failed"
    
    log "FreeIPA standalone server installation completed successfully"
    
    # Configure DNS forwarders post-installation
    if [[ -n "$DNS_FORWARDERS" ]]; then
        log "Configuring DNS forwarders post-installation..."
        sleep 3  # Wait for services to stabilize
        
        # Get Kerberos ticket for admin
        echo "$ADMIN_PASSWORD" | kinit admin@"$IPA_REALM" >/dev/null 2>&1 || {
            log "WARNING: Could not get Kerberos ticket to configure forwarders"
            log "         You can manually set them with: ipa dnsconfig-mod --forwarder=<ip> --forward-policy=only"
            return
        }
        
        # Build ipa dnsconfig-mod command
        local dnsconfig_cmd=("ipa" "dnsconfig-mod")
        IFS=',' read -ra FORWARDERS <<< "$DNS_FORWARDERS"
        for forwarder in "${FORWARDERS[@]}"; do
            forwarder=$(echo "$forwarder" | xargs)  # Trim whitespace
            [[ -n "$forwarder" ]] && dnsconfig_cmd+=("--forwarder=$forwarder")
        done
        
        # Add forward policy
        dnsconfig_cmd+=("--forward-policy=only")
        
        # Apply forwarders
        if "${dnsconfig_cmd[@]}" >/dev/null 2>&1; then
            log "✓ DNS forwarders configured: $DNS_FORWARDERS"
            log "✓ Forward policy set to: only"
            
            # Verify they were set
            local verified_forwarders=$(ipa dnsconfig-show 2>/dev/null | grep "Global forwarders:" | cut -d: -f2)
            if [[ -n "$verified_forwarders" ]]; then
                log "✓ Verified: Global forwarders:$verified_forwarders"
            fi
        else
            log "WARNING: Failed to configure DNS forwarders post-installation"
            log "         You can manually set them with: ipa dnsconfig-mod --forwarder=<ip> --forward-policy=only"
        fi
        
        # Destroy kerberos ticket
        kdestroy 2>/dev/null || true
    fi
    
    # Create ldapauth service account for LDAP authentication
    create_ldapauth_service_account
}

install_replica_server() {
    local hostname=$(echo "$IPA_FQDN" | cut -d'.' -f1)
    
    # Check and configure static IP before proceeding
    check_and_configure_static_ip
    
    local primary_ip=$(get_primary_ip)
    
    [[ -z "$primary_ip" ]] && error_exit "Could not determine primary IP address"
    
    log "Installing FreeIPA replica server..."
    log "FQDN: $IPA_FQDN"
    log "Domain: $IPA_DOMAIN"
    log "IP: $primary_ip"
    
    # Check if already enrolled as client
    local already_client=false
    if [[ -f "/etc/ipa/default.conf" ]]; then
        log "Existing FreeIPA client configuration detected"
        already_client=true
    fi
    
    # Install required packages
    local packages=()
    if [[ "$already_client" == false ]]; then
        packages+=("ipa-client")
    fi
    packages+=(
        "ipa-server" "ipa-server-dns" "freeipa-server-trust-ad"
    )
    install_packages "${packages[@]}"
    
    # Configure hostname and firewall
    configure_hostname "$hostname" "$IPA_DOMAIN" "$primary_ip"
    configure_firewall
    
    # Step 1: Join as client if not already joined
    if [[ "$already_client" == false ]]; then
        join_ipa_domain
    fi
    
    # Step 2: Promote to replica server
    promote_to_replica
    
    log "FreeIPA replica server installation completed successfully"
}

join_ipa_domain() {
    log "Joining FreeIPA domain as client..."
    
    # Try to discover the primary server (exclude ourselves)
    local primary_server
    local current_fqdn="$IPA_FQDN"
    
    # Get all LDAP servers from SRV records
    local srv_results=$(dig +short _ldap._tcp."$IPA_DOMAIN" SRV 2>/dev/null | awk '{print $4}' | sed 's/\.$//')
    
    if [[ -n "$srv_results" ]]; then
        # Filter out the current server
        while IFS= read -r server; do
            if [[ "$server" != "$current_fqdn" ]] && [[ -n "$server" ]]; then
                primary_server="$server"
                log "Discovered FreeIPA server: $primary_server"
                break
            fi
        done <<< "$srv_results"
    fi
    
    # If still no server found, prompt for manual input
    if [[ -z "$primary_server" ]]; then
        log "Could not auto-discover primary server (or no other servers found)"
        read -p "Enter the FQDN of the primary FreeIPA server: " primary_server
        [[ -z "$primary_server" ]] && error_exit "Primary server FQDN is required"
    fi
    
    # Ensure we're not using ourselves as the enrollment server
    if [[ "$primary_server" == "$current_fqdn" ]]; then
        log "ERROR: Cannot use replica server ($current_fqdn) as enrollment server"
        read -p "Enter the FQDN of an existing FreeIPA server: " primary_server
        [[ -z "$primary_server" ]] && error_exit "Primary server FQDN is required"
        
        if [[ "$primary_server" == "$current_fqdn" ]]; then
            error_exit "Cannot use the replica server itself as enrollment server. Please provide a different server."
        fi
    fi
    
    log "Primary FreeIPA server: $primary_server"
    
    # Verify the server is reachable
    log "Verifying primary server is reachable..."
    if ! ping -c 1 -W 2 "$primary_server" >/dev/null 2>&1; then
        log "WARNING: Cannot ping $primary_server"
        read -p "Server is not responding to ping. Continue anyway? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && error_exit "Cannot reach primary server"
    fi
    
    # Get admin credentials for joining
    local admin_user="admin"
    local admin_password
    
    if [[ -n "$ADMIN_PASSWORD" ]]; then
        admin_password="$ADMIN_PASSWORD"
        log "Using provided admin password for domain join"
    else
        read -s -p "Enter the admin password for domain join: " admin_password
        echo
        [[ -z "$admin_password" ]] && error_exit "Admin password is required"
        # Update global variable so it can be saved to secrets file
        ADMIN_PASSWORD="$admin_password"
    fi
    
    # Join the domain
    log "Joining domain $IPA_DOMAIN..."
    
    # Check if client is already installed but just needs re-enrollment
        
    ipa-client-install \
        --server="$primary_server" \
        --domain="$IPA_DOMAIN" \
        --realm="$IPA_REALM" \
        --hostname="$IPA_FQDN" \
        --principal="$admin_user" \
        --password="$admin_password" \
        --mkhomedir \
        --force-join \
        --unattended 2>&1 | tee -a "$LOG_FILE" || {
            log "ERROR: Client installation failed. Last 30 lines of /var/log/ipaclient-install.log:"
            tail -30 /var/log/ipaclient-install.log 2>/dev/null | tee -a "$LOG_FILE" || true
            error_exit "Failed to join FreeIPA domain with --force-join. Check logs above."
        }
    
    log "Successfully joined FreeIPA domain"
    
        # Verify we can get Kerberos ticket (use full principal with realm)
    echo "$admin_password" | kinit "${admin_user}@${IPA_REALM}" || error_exit "Failed to get Kerberos ticket"
    log "Kerberos authentication successful"
    
    # Verify ipa command is working
    if ! ipa env realm >/dev/null 2>&1; then
        error_exit "IPA command not working properly after client installation. Try re-running the script."
    fi
    
    # Add host to ipaservers group (REQUIRED for replica promotion)
    log "Adding host to ipaservers group (required for replica)..."
    
    # First check if already member
    if ipa hostgroup-show ipaservers 2>/dev/null | grep -E "Member hosts:.*\b$IPA_FQDN\b"; then
        log "Host is already a member of ipaservers group"
    else
        log "Adding $IPA_FQDN to ipaservers hostgroup..."
        if ipa hostgroup-add-member ipaservers --hosts="$IPA_FQDN" 2>&1 | tee -a "$LOG_FILE"; then
            log "Successfully added host to ipaservers group"
        else
            error_exit "CRITICAL: Failed to add host to ipaservers group. This is required for replica installation.
    
Manual fix: Run the following command on the primary server:
    ipa hostgroup-add-member ipaservers --hosts=$IPA_FQDN
    
Then re-run this script."
        fi
    fi
    
    # Verify membership
    log "Verifying ipaservers group membership..."
    if ipa hostgroup-show ipaservers 2>/dev/null | grep -E "Member hosts:.*\b$IPA_FQDN\b"; then
        log "✓ Host is confirmed as member of ipaservers group"
    else
        error_exit "Host is not a member of ipaservers group. Cannot proceed with replica installation."
    fi
}

add_ipa_servers_to_hosts() {
    log "Adding IPA servers to /etc/hosts for reverse DNS resolution..."
    
    # Get list of all IPA servers
    local ipa_servers=$(ipa server-find --raw 2>/dev/null | grep "cn:" | awk '{print $2}')
    
    if [[ -z "$ipa_servers" ]]; then
        log "WARNING: Could not get list of IPA servers from ipa server-find"
        return
    fi
    
    # For each server, resolve IP and add to /etc/hosts if not already present
    while IFS= read -r server; do
        [[ -z "$server" ]] && continue
        
        # Skip if server already in /etc/hosts
        if grep -q "$server" /etc/hosts; then
            log "  ✓ $server already in /etc/hosts"
            continue
        fi
        
        # Resolve the server's IP
        local server_ip=$(dig +short "$server" A | head -1)
        
        if [[ -z "$server_ip" ]] || [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "  WARNING: Could not resolve IP for $server, skipping"
            continue
        fi
        
        # Add to /etc/hosts
        local hostname=$(echo "$server" | cut -d'.' -f1)
        echo "$server_ip $server $hostname" >> /etc/hosts
        log "  ✓ Added $server ($server_ip) to /etc/hosts"
        
    done <<< "$ipa_servers"
    
    log "Completed updating /etc/hosts with IPA servers"
}

promote_to_replica() {
    log "Promoting client to replica server..."
    
    # Pre-promotion verification: Ensure host exists in IPA
    log "Pre-promotion check: Verifying host exists in IPA..."
    if ! ipa host-show "$IPA_FQDN" >/dev/null 2>&1; then
        log "WARNING: Host $IPA_FQDN does not exist in IPA database"
        log "This usually means the client enrollment didn't complete properly"
        error_exit "Host not found in IPA. Please verify client installation completed successfully and re-run the script."
    fi
    log "✓ Host exists in IPA"
    
    # Pre-promotion verification: Check ipaservers group membership
    log "Pre-promotion check: Verifying ipaservers group membership..."
    if ! ipa hostgroup-show ipaservers 2>/dev/null | grep -E "Member hosts:.*\b$IPA_FQDN\b"; then
        log "Host is not a member of ipaservers group. Adding it now..."
        
        if ipa hostgroup-add-member ipaservers --hosts="$IPA_FQDN" 2>&1 | tee -a "$LOG_FILE" | grep -q "Number of members added 1"; then
            log "✓ Successfully added host to ipaservers group"
        else
            log "Failed to add host to ipaservers group. Checking for error details..."
            if tail -5 "$LOG_FILE" | grep -q "no such entry"; then
                error_exit "CRITICAL: Host $IPA_FQDN does not exist in IPA database. Cannot add to hostgroup.
                
This indicates the client enrollment was incomplete. Please verify:
1. Client installation completed successfully
2. Host exists: ipa host-show $IPA_FQDN
3. If host doesn't exist, re-run client installation"
            else
                error_exit "CRITICAL: Failed to add host to ipaservers group. Check the log above for details.
    
Manual fix: Run the following command:
    ipa hostgroup-add-member ipaservers --hosts=$IPA_FQDN"
            fi
        fi
        
        # Verify it was added
        if ! ipa hostgroup-show ipaservers 2>/dev/null | grep -E "Member hosts:.*\b$IPA_FQDN\b"; then
            error_exit "CRITICAL: Failed to verify host membership in ipaservers group after adding it."
        fi
    fi
    log "✓ Pre-promotion check passed: Host is member of ipaservers group"
    
    # Ensure we have valid Kerberos ticket
    if ! klist -s 2>/dev/null; then
        log "No valid Kerberos ticket found, attempting to get one"
        local admin_password
        if [[ -n "$ADMIN_PASSWORD" ]]; then
            admin_password="$ADMIN_PASSWORD"
        else
            read -s -p "Enter the admin password: " admin_password
            echo
        fi
        echo "$admin_password" | kinit "admin@${IPA_REALM}" || error_exit "Failed to get Kerberos ticket for replica promotion"
    fi
    
    # Add all IPA servers to /etc/hosts to ensure reverse DNS works
    log "Ensuring all IPA servers are in /etc/hosts for reverse DNS resolution..."
    add_ipa_servers_to_hosts
    
    log "Starting replica promotion..."
    
    # Build replica installation command
    local install_cmd=(
        "ipa-replica-install"
        "--setup-adtrust"
        "--setup-ca"
        "--setup-dns"
        "--mkhomedir"
        "--allow-zone-overlap"
        "--auto-reverse"
        "--unattended"
    )
    
    # Note: DNS forwarders are inherited from primary server via LDAP replication
    # We intentionally do NOT set forwarders here to maintain consistency
    log "DNS forwarders will be inherited from the primary server"
    install_cmd+=("--auto-forwarders")
    
    # Execute replica installation
    "${install_cmd[@]}" || error_exit "FreeIPA replica promotion failed"
    
    log "Replica promotion completed successfully"
}

# --- Argument Parsing ---

parse_arguments() {
    while getopts "h:rd:p:f:?" opt; do
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
            f)
                DNS_FORWARDERS="$OPTARG"
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
    
    # Warn if DNS forwarders specified for replica mode
    if [[ "$REPLICA_MODE" = true ]] && [[ -n "$DNS_FORWARDERS" ]]; then
        log "WARNING: DNS forwarders (-f) specified for replica mode"
        log "         Replicas inherit DNS forwarders from the primary server via LDAP"
        log "         The -f option will be ignored for replica installation"
        DNS_FORWARDERS=""
    fi
    
    # Extract domain and realm from FQDN
    IPA_DOMAIN="${IPA_FQDN#*.}"
    IPA_REALM="${IPA_DOMAIN^^}"
    
    # Generate passwords if not provided
    if [[ -z "$DM_PASSWORD" ]]; then
        if [[ "$REPLICA_MODE" = true ]]; then
            log "Replica mode: Directory Manager password not provided"
            log "  Will not be saved to /etc/ipa/secrets"
        else
            DM_PASSWORD=$(generate_password)
            log "Generated Directory Manager password: $DM_PASSWORD"
        fi
    else
        if [[ "$REPLICA_MODE" = true ]]; then
            log "Directory Manager password provided and will be saved to /etc/ipa/secrets"
        fi
    fi
    
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        if [[ "$REPLICA_MODE" = true ]]; then
            log "WARNING: Replica mode requires admin password to join domain"
            log "You will be prompted for the admin password during installation"
        else
            ADMIN_PASSWORD=$(generate_password)
            log "Generated Admin password: $ADMIN_PASSWORD"
        fi
    fi
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
    log "Log File: $LOG_FILE"
    log "================================="
}

save_passwords() {
    local secrets_file="/etc/ipa/secrets"
    
    # Create /etc/ipa directory if it doesn't exist
    mkdir -p /etc/ipa
    
    # For replicas, DM password might not be set, so we need to prompt or note it
    local dm_pass_note=""
    if [[ -z "$DM_PASSWORD" ]]; then
        dm_pass_note="<Use Directory Manager password from primary server>"
    else
        dm_pass_note="$DM_PASSWORD"
    fi
    
    # Build ldapauth DN
    local ldapauth_dn="uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}"
    
    # Save secrets to /etc/ipa/secrets
    cat > "$secrets_file" << EOF
# FreeIPA Installation Secrets
# Generated on: $(date)

Directory Manager Password: $dm_pass_note
Admin Password: $ADMIN_PASSWORD
EOF

    # Append ldapauth information if it was created
    if [[ -f /tmp/ipa-install-secrets/ldapauth_password ]]; then
        echo "" >> "$secrets_file"
        echo "LDAP Auth Service Account DN: $ldapauth_dn" >> "$secrets_file"
        cat /tmp/ipa-install-secrets/ldapauth_password >> "$secrets_file"
        rm -rf /tmp/ipa-install-secrets
        log "Added ldapauth service account information to secrets file"
    fi
    
    chmod 600 "$secrets_file"
    log "Secrets saved to: $secrets_file"
    
    if [[ -z "$DM_PASSWORD" ]]; then
        log "NOTE: Directory Manager password not set."
        log "      Update $secrets_file with the correct password or provide with -d option if needed."
    fi
    
    # Also save to log file location for backwards compatibility
    cat > "$LOG_FILE.passwords" << EOF
FreeIPA Installation Passwords
Generated on: $(date)
FQDN: $IPA_FQDN
Domain: $IPA_DOMAIN
Realm: $IPA_REALM

Directory Manager Password: $dm_pass_note
Admin Password: $ADMIN_PASSWORD

Log file: $LOG_FILE
EOF
    chmod 600 "$LOG_FILE.passwords"
    log "Passwords also saved to: $LOG_FILE.passwords"
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
    
    # Save passwords
    save_passwords
    
    log "=== Installation Complete ==="
    log "FreeIPA server is now running"
    log "You can access the web interface at: https://$IPA_FQDN"
    log "Admin username: admin"
    log "Admin password: $ADMIN_PASSWORD"
    log "All secrets saved to: /etc/ipa/secrets"
    log "Installation log: $LOG_FILE"
    log ""
    log "Next steps:"
    log "  - To install FreeRADIUS: ./install-radius.sh"
    log "  - To add users: ipa user-add <username>"
    log "  - To configure replication: Run this script on another server with -r option"
}

# Execute main function with all arguments
main "$@"
