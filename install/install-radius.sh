#!/bin/bash

# ==============================================================================
# FreeRADIUS Installation Script for FreeIPA on Rocky Linux 8/9
# ==============================================================================
# This script installs and configures FreeRADIUS to use FreeIPA LDAP backend
# with ipaNTHash for MS-CHAPv2 authentication.
#
# IMPORTANT: This script MUST be run with root privileges (e.g., `sudo`).
#
# Prerequisites:
#   - FreeIPA server must be installed and running
#   - /etc/ipa/secrets file should exist (created by install-ipa.sh)
#
# Usage:
#   ./install-radius.sh [-d <dm_password>] [-s <radius_secret>]
#
# Arguments:
#   -d <password>   : Directory Manager password (reads from /etc/ipa/secrets if not provided)
#   -s <secret>     : RADIUS client secret (random if not provided)
#   -?              : Show this help
#
# Example:
#   ./install-radius.sh
#   ./install-radius.sh -d MyDMPass123 -s MyRadiusSecret123
# ==============================================================================

set -e

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/install-radius-$(date +%Y%m%d-%H%M%S).log"
IPA_FQDN=""
IPA_DOMAIN=""
IPA_REALM=""
DM_PASSWORD=""
RADIUS_SECRET=""
SECRETS_FILE="/etc/ipa/secrets"

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

show_usage() {
    cat << EOF
Usage: $0 [-d <dm_password>] [-s <radius_secret>]

Arguments:
  -d <password>   Directory Manager password (reads from /etc/ipa/secrets if not provided)
  -s <secret>     RADIUS client secret (random if not provided)
  -?              Show this help

Examples:
  # Use passwords from /etc/ipa/secrets
  $0

  # Specify Directory Manager password
  $0 -d MyDMPass123

  # Specify both passwords
  $0 -d MyDMPass123 -s MyRadiusSecret123

Prerequisites:
  - FreeIPA server must be installed and running
  - /etc/ipa/secrets file should exist (created by install-ipa.sh)
  - If /etc/ipa/secrets doesn't exist, you must provide -d option
EOF
}

# --- OS Detection ---

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

# --- FreeIPA Information Retrieval ---

get_ipa_info() {
    log "Retrieving FreeIPA configuration..."
    
    # Check if FreeIPA is installed
    if [[ ! -f /etc/ipa/default.conf ]]; then
        error_exit "FreeIPA is not installed. Please run install-ipa.sh first."
    fi
    
    # Read FreeIPA configuration
    IPA_DOMAIN=$(grep '^domain' /etc/ipa/default.conf | cut -d'=' -f2 | tr -d ' ')
    IPA_REALM=$(grep '^realm' /etc/ipa/default.conf | cut -d'=' -f2 | tr -d ' ')
    IPA_FQDN=$(hostname -f)
    
    if [[ -z "$IPA_DOMAIN" || -z "$IPA_REALM" ]]; then
        error_exit "Could not read FreeIPA configuration from /etc/ipa/default.conf"
    fi
    
    log "FreeIPA Domain: $IPA_DOMAIN"
    log "FreeIPA Realm: $IPA_REALM"
    log "FreeIPA FQDN: $IPA_FQDN"
}

# --- Read Secrets ---

read_secrets_file() {
    log "Reading secrets from $SECRETS_FILE..."
    
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log "WARNING: $SECRETS_FILE not found"
        return 1
    fi
    
    # Try to read Directory Manager password from secrets file
    if [[ -z "$DM_PASSWORD" ]]; then
        DM_PASSWORD=$(grep "^Directory Manager Password:" "$SECRETS_FILE" | cut -d':' -f2- | sed 's/^[[:space:]]*//')
        if [[ -n "$DM_PASSWORD" ]]; then
            log "Read Directory Manager password from $SECRETS_FILE"
        fi
    fi
    
    return 0
}

prompt_for_passwords() {
    if [[ -z "$DM_PASSWORD" ]]; then
        log "Directory Manager password not found in $SECRETS_FILE"
        read -s -p "Enter Directory Manager password: " DM_PASSWORD
        echo
        [[ -z "$DM_PASSWORD" ]] && error_exit "Directory Manager password is required"
    fi
    
    if [[ -z "$RADIUS_SECRET" ]]; then
        RADIUS_SECRET=$(generate_password)
        log "Generated RADIUS client secret: $RADIUS_SECRET"
    fi
}

# --- Firewall Configuration ---

configure_firewall() {
    log "Configuring firewall for RADIUS..."
    
    if systemctl is-active --quiet firewalld; then
        if ! firewall-cmd --list-services | grep -q radius; then
            firewall-cmd --permanent --add-service=radius >/dev/null
            firewall-cmd --reload >/dev/null
            log "Added RADIUS service to firewall"
        else
            log "RADIUS service already enabled in firewall"
        fi
    else
        log "Firewalld is not active, skipping firewall configuration"
    fi
}

# --- FreeRADIUS Configuration ---

configure_radius_ldap() {
    local ldap_config="/etc/raddb/mods-available/ipa-ldap"
    local base_dn="cn=accounts,dc=${IPA_DOMAIN//./,dc=}"

    log "Configuring FreeRADIUS IPA LDAP module..."

    # Generate complete IPA LDAP configuration file
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

    # Enable IPA LDAP module with symlink
    ln -sf /etc/raddb/mods-available/ipa-ldap /etc/raddb/mods-enabled/ipa-ldap
    
    log "IPA LDAP module configured successfully"
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
    local site_config="/etc/raddb/sites-available/ipa"
    
    log "Configuring FreeRADIUS IPA site..."
    
    # Generate complete IPA site configuration
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
	if (&control:LDAP-Group) {
		foreach &control:LDAP-Group {
			if ("%{Foreach-Variable-0}" =~ /cn=([^,=]+),cn=groups/i) {
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

    # Disable default site and enable IPA site
    rm -f /etc/raddb/sites-enabled/default
    ln -sf /etc/raddb/sites-available/ipa /etc/raddb/sites-enabled/ipa
    
    log "IPA site configured successfully with group membership support"
}

configure_freeradius() {
    log "Configuring FreeRADIUS with LDAP backend..."
    
    # Configure LDAP module
    configure_radius_ldap
    
    # Configure clients
    configure_radius_clients
    
    # Configure site with group support
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
}

# --- Save Secrets ---

save_radius_secrets() {
    local secrets_file="$SECRETS_FILE"
    
    # Update or append RADIUS secret to /etc/ipa/secrets
    if [[ -f "$secrets_file" ]]; then
        # Check if RADIUS secret already exists
        if grep -q "^RADIUS Client Secret:" "$secrets_file"; then
            # Update existing entry
            sed -i "s/^RADIUS Client Secret:.*/RADIUS Client Secret: $RADIUS_SECRET/" "$secrets_file"
            log "Updated RADIUS secret in $secrets_file"
        else
            # Append new entry
            echo "" >> "$secrets_file"
            echo "RADIUS Client Secret: $RADIUS_SECRET" >> "$secrets_file"
            log "Added RADIUS secret to $secrets_file"
        fi
    else
        # Create new secrets file
        cat > "$secrets_file" << EOF
# FreeRADIUS Installation Secrets
# Generated on: $(date)

RADIUS Client Secret: $RADIUS_SECRET
EOF
        chmod 600 "$secrets_file"
        log "Created $secrets_file with RADIUS secret"
    fi
    
    # Also save to log file location
    cat > "$LOG_FILE.passwords" << EOF
FreeRADIUS Installation Secrets
Generated on: $(date)
FQDN: $IPA_FQDN
Domain: $IPA_DOMAIN
Realm: $IPA_REALM

RADIUS Client Secret: $RADIUS_SECRET

Log file: $LOG_FILE
EOF
    chmod 600 "$LOG_FILE.passwords"
    log "Secrets also saved to: $LOG_FILE.passwords"
}

# --- Argument Parsing ---

parse_arguments() {
    while getopts "d:s:?" opt; do
        case $opt in
            d)
                DM_PASSWORD="$OPTARG"
                ;;
            s)
                RADIUS_SECRET="$OPTARG"
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
}

# --- Configuration Summary ---

show_configuration_summary() {
    log "=== FreeRADIUS Installation Configuration ==="
    log "FQDN: $IPA_FQDN"
    log "Domain: $IPA_DOMAIN"
    log "Realm: $IPA_REALM"
    log "Directory Manager Password: $DM_PASSWORD"
    log "RADIUS Client Secret: $RADIUS_SECRET"
    log "Log File: $LOG_FILE"
    log "=============================================="
}

# --- Main Function ---

main() {
    log "Starting FreeRADIUS installation script"
    log "Script version: 1.0 for Rocky Linux 8/9"
    
    # Root check
    [[ $EUID -ne 0 ]] && error_exit "This script must be run as root"
    
    # Parse arguments
    parse_arguments "$@"
    
    # OS detection
    detect_os
    
    # Get FreeIPA configuration
    get_ipa_info
    
    # Read secrets from file or prompt
    read_secrets_file || true
    prompt_for_passwords
    
    # Show configuration
    show_configuration_summary
    
    # Install FreeRADIUS packages
    local packages=("freeradius" "freeradius-ldap" "freeradius-krb5" "freeradius-utils")
    install_packages "${packages[@]}"
    
    # Configure firewall
    configure_firewall
    
    # Configure FreeRADIUS
    configure_freeradius
    
    # Save secrets
    save_radius_secrets
    
    log "=== Installation Complete ==="
    log "FreeRADIUS is now running and configured for FreeIPA"
    log "RADIUS client secret: $RADIUS_SECRET"
    log "All secrets saved to: $SECRETS_FILE"
    log "Installation log: $LOG_FILE"
    log ""
    log "Test RADIUS authentication with:"
    log "  radtest <username> <password> 127.0.0.1 0 $RADIUS_SECRET"
}

# Execute main function with all arguments
main "$@"
