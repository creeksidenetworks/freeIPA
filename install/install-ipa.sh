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
  -d <password>   Directory Manager password (random if not provided for standalone)
  -p <password>   Admin password (required for replica, random if not provided for standalone)
  -?              Show this help

Examples:
  # Standalone server (first IPA server)
  $0 -h ipa.example.com

  # Replica server (requires existing IPA domain)
  $0 -h ipa2.example.com -r -p AdminPassword123

  # Standalone with custom passwords
  $0 -h ipa.example.com -d MyDMPass123 -p MyAdminPass123

Note for Replica Mode:
  - The server will first join the existing IPA domain as a client
  - Then it will be promoted to a replica server
  - Admin password is required to join the domain
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
        "freeradius" "freeradius-ldap" "freeradius-krb5" "freeradius-utils"
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
    
    # Try to discover the primary server
    local primary_server
    primary_server=$(dig +short _ldap._tcp."$IPA_DOMAIN" SRV | head -1 | awk '{print $4}' | sed 's/\.$//')
    
    if [[ -z "$primary_server" ]]; then
        log "Could not auto-discover primary server, prompting for manual input"
        read -p "Enter the FQDN of the primary FreeIPA server: " primary_server
        [[ -z "$primary_server" ]] && error_exit "Primary server FQDN is required"
    fi
    
    log "Primary FreeIPA server: $primary_server"
    
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
    fi
    
    # Join the domain
    log "Joining domain $IPA_DOMAIN..."
    ipa-client-install \
        --server="$primary_server" \
        --domain="$IPA_DOMAIN" \
        --realm="$IPA_REALM" \
        --hostname="$IPA_FQDN" \
        --principal="$admin_user" \
        --password="$admin_password" \
        --mkhomedir \
        --unattended || error_exit "Failed to join FreeIPA domain"
    
    log "Successfully joined FreeIPA domain"
    
    # Verify we can get Kerberos ticket
    echo "$admin_password" | kinit "$admin_user" || error_exit "Failed to get Kerberos ticket"
    log "Kerberos authentication successful"
    
    # Add host to ipaservers group (REQUIRED for replica promotion)
    log "Adding host to ipaservers group (required for replica)..."
    
    # First check if already member
    if ipa hostgroup-show ipaservers --hosts | grep -q "$IPA_FQDN"; then
        log "Host is already a member of ipaservers group"
    else
        log "Adding $IPA_FQDN to ipaservers hostgroup..."
        if ipa hostgroup-add-member ipaservers --hosts="$IPA_FQDN"; then
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
    if ipa hostgroup-show ipaservers --hosts | grep -q "$IPA_FQDN"; then
        log "✓ Host is confirmed as member of ipaservers group"
    else
        error_exit "Host is not a member of ipaservers group. Cannot proceed with replica installation."
    fi
}

promote_to_replica() {
    log "Promoting client to replica server..."
    
    # Pre-promotion verification: Check ipaservers group membership
    log "Pre-promotion check: Verifying ipaservers group membership..."
    if ! ipa hostgroup-show ipaservers --hosts 2>/dev/null | grep -q "$IPA_FQDN"; then
        error_exit "CRITICAL: Host $IPA_FQDN is not a member of ipaservers group. 
Replica promotion will fail. Please add the host to ipaservers group first:
    ipa hostgroup-add-member ipaservers --hosts=$IPA_FQDN"
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
        echo "$admin_password" | kinit admin || error_exit "Failed to get Kerberos ticket for replica promotion"
    fi
    
    log "Starting replica promotion..."
    ipa-replica-install \
        --setup-adtrust \
        --setup-ca \
        --setup-dns \
        --mkhomedir \
        --allow-zone-overlap \
        --auto-reverse \
        --auto-forwarders \
        --unattended || error_exit "FreeIPA replica promotion failed"
    
    log "Replica promotion completed successfully"
}

# --- FreeRADIUS Configuration ---

configure_freeradius() {
    log "Configuring FreeRADIUS with LDAP backend..."
    
    # Generate random RADIUS secret if not provided
    [[ -z "$RADIUS_SECRET" ]] && RADIUS_SECRET=$(generate_password)
    
    # Configure LDAP module
    configure_radius_ldap
    
    # Configure clients
    configure_radius_clients
    
    # Configure default site with group support
    configure_radius_site
    
    # Add memberOf to dictionary if not present
    if ! grep -q "memberOf" /etc/raddb/dictionary; then
        echo -e "ATTRIBUTE\tmemberOf\t\t3101\tstring" >> /etc/raddb/dictionary
    fi
    
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
    local ldap_config="/etc/raddb/mods-available/ldap"
    local base_dn="cn=accounts,dc=${IPA_DOMAIN//./,dc=}"

    log "Configuring FreeRADIUS LDAP module..."

    # Backup original LDAP config
    [[ ! -f "${ldap_config}.orig" ]] && cp "$ldap_config" "${ldap_config}.orig"

    # Generate complete LDAP configuration file
    cat > "$ldap_config" << 'LDAPEOF'
# -*- text -*-
#
#  FreeRADIUS LDAP module configuration for FreeIPA
#

ldap {
    server = '127.0.0.1'
    port = 389
    
    identity = 'cn=Directory Manager'
LDAPEOF

    # Add password (with variable expansion)
    echo "    password = '$DM_PASSWORD'" >> "$ldap_config"
    
    # Continue with rest of config
    cat >> "$ldap_config" << LDAPEOF2
    
    base_dn = '$base_dn'
    
    sasl {
    }
    
    update {
        control:Password-With-Header    += 'userPassword'
        control:NT-Password             := 'ipaNTHash'
        control:LDAP-Group              += 'memberOf'
        
        control:                        += 'radiusControlAttribute'
        request:                        += 'radiusRequestAttribute'
        reply:                          += 'radiusReplyAttribute'
		reply:memberOf                  += 'memberOf'
    }
    
    user_dn = "LDAP-UserDn"
    
    user {
        base_dn = "\${..base_dn}"
        filter = "(uid=%{%{Stripped-User-Name}:-%{User-Name}})"
        
        sasl {
        }
        
        scope = 'sub'
    }
    
    group {
        base_dn = "\${..base_dn}"
        filter = '(objectClass=posixGroup)'
        scope = 'sub'
        name_attribute = cn
        membership_attribute = 'memberOf'
        cacheable_name = 'no'
        cacheable_dn = 'no'
    }
    
    profile {
    }
    
    client {
        base_dn = "\${..base_dn}"
        filter = '(objectClass=radiusClient)'
        
        template {
        }
        
        attribute {
            ipaddr              = 'radiusClientIdentifier'
            secret              = 'radiusClientSecret'
        }
    }
    
    accounting {
        reference = "%{tolower:type.%{Acct-Status-Type}}"
        
        type {
            start {
                update {
                    description := "Online at %S"
                }
            }
            
            interim-update {
                update {
                    description := "Last seen at %S"
                }
            }
            
            stop {
                update {
                    description := "Offline at %S"
                }
            }
        }
    }
    
    post-auth {
        update {
            description := "Authenticated at %S"
        }
    }
    
    options {
        chase_referrals = yes
        rebind = yes
        res_timeout = 10
        srv_timelimit = 3
        net_timeout = 1
        idle = 60
        probes = 3
        interval = 3
        ldap_debug = 0x0028
    }
    
    tls {
    }
    
    pool {
        start = \${thread[pool].start_servers}
        min = \${thread[pool].min_spare_servers}
        max = \${thread[pool].max_servers}
        spare = \${thread[pool].max_spare_servers}
        uses = 0
        retry_delay = 30
        lifetime = 0
        idle_timeout = 60
    }
}
LDAPEOF2

    # Enable LDAP module
    ln -sf /etc/raddb/mods-available/ldap /etc/raddb/mods-enabled/ldap
    
    log "LDAP module configured successfully"
}

configure_radius_clients() {
    local clients_config="/etc/raddb/clients.conf"
    
    log "Configuring FreeRADIUS clients..."
    
    # Backup original clients config
    [[ ! -f "${clients_config}.orig" ]] && cp "$clients_config" "${clients_config}.orig"
    
    # Generate complete clients configuration file
    cat > "$clients_config" << EOF
# -*- text -*-
#
# FreeRADIUS clients configuration for FreeIPA
#

client localhost {
    ipaddr = 127.0.0.1
    proto = *
    secret = $RADIUS_SECRET
    require_message_authenticator = no
    nas_type = other
    limit {
        max_connections = 16
        lifetime = 0
        idle_timeout = 30
    }
}

client localhost_ipv6 {
    ipv6addr = ::1
    secret = $RADIUS_SECRET
}

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
EOF
    
    log "Clients configuration generated successfully"
}

configure_radius_site() {
    local site_config="/etc/raddb/sites-available/default"
    
    log "Configuring FreeRADIUS default site..."
    
    # Backup original site config
    [[ ! -f "${site_config}.orig" ]] && cp "$site_config" "${site_config}.orig"
    
    # Generate complete default site configuration
    cat > "$site_config" << 'SITEEOF'
# -*- text -*-
#
# FreeRADIUS default virtual server for FreeIPA
#

server default {

listen {
	type = auth
	ipaddr = *
	port = 0
	limit {
		max_connections = 16
		lifetime = 0
		idle_timeout = 30
	}
}

listen {
	ipaddr = *
	port = 0
	type = acct
	limit {
	}
}

listen {
	type = auth
	ipv6addr = ::
	port = 0
	limit {
		max_connections = 16
		lifetime = 0
		idle_timeout = 30
	}
}

listen {
	ipv6addr = ::
	port = 0
	type = acct
	limit {
	}
}

authorize {
	filter_username
	preprocess
	chap
	mschap
	digest
	suffix
	eap {
		ok = return
	}
	files
	-sql
	-ldap
	ldap
	expiration
	logintime
	pap
}

authenticate {
	Auth-Type PAP {
		pap
	}
	Auth-Type CHAP {
		chap
	}
	Auth-Type MS-CHAP {
		mschap
	}
	mschap
	digest
	eap
}

preacct {
	preprocess
	acct_unique
	suffix
	files
}

accounting {
	detail
	unix
	-sql
	exec
	attr_filter.accounting_response
}

session {
}

post-auth {
	update {
		&reply: += &session-state:
	}
	
	# Process group membership from LDAP memberOf attribute
	# Extract group names and add to reply
	foreach &reply:memberOf {
		if ("%{Foreach-Variable-0}" =~ /cn=groups/i) {
			if ("%{Foreach-Variable-0}" =~ /cn=([^,=]+)/i) {
				update reply {
					Class += "%{1}"
				}
			}
		}
	}
	
	-sql
	exec
	remove_reply_message_if_eap
	
	Post-Auth-Type REJECT {
		-sql
		attr_filter.access_reject
		eap
		remove_reply_message_if_eap
	}
	
	Post-Auth-Type Challenge {
	}
}

pre-proxy {
}

post-proxy {
	eap
}

}
SITEEOF

    # Enable the default site
    ln -sf /etc/raddb/sites-available/default /etc/raddb/sites-enabled/default
    
    log "Default site configured successfully with group membership support"
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
        if [[ "$REPLICA_MODE" = true ]]; then
            log "Replica mode: Directory Manager password not required for replica installation"
        else
            DM_PASSWORD=$(generate_password)
            log "Generated Directory Manager password: $DM_PASSWORD"
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
    local secrets_file="/etc/ipa/secrets"
    
    # Create /etc/ipa directory if it doesn't exist
    mkdir -p /etc/ipa
    
    # Save secrets to /etc/ipa/secrets
    cat > "$secrets_file" << EOF
# FreeIPA Installation Secrets
# Generated on: $(date)
# FQDN: $IPA_FQDN
# Domain: $IPA_DOMAIN
# Realm: $IPA_REALM

Directory Manager Password: $DM_PASSWORD
Admin Password: $ADMIN_PASSWORD
RADIUS Client Secret: $RADIUS_SECRET

Log file: $LOG_FILE
EOF
    chmod 600 "$secrets_file"
    log "Secrets saved to: $secrets_file"
    
    # Also save to log file location for backwards compatibility
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
    log "All secrets saved to: /etc/ipa/secrets"
    log "Installation log: $LOG_FILE"
}

# Execute main function with all arguments
main "$@"
