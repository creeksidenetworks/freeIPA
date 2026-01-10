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
#   ./install-radius.sh [-p <admin_password>] [-s <radius_secret>]
#
# Arguments:
#   -p <password>   : Admin password (reads from /etc/ipa/secrets if not provided)
#   -s <secret>     : RADIUS client secret (random if not provided)
#   -?              : Show this help
#
# Example:
#   ./install-radius.sh
#   ./install-radius.sh -p MyAdminPass123 -s MyRadiusSecret123
# ==============================================================================

set -e

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/install-radius-$(date +%Y%m%d-%H%M%S).log"
IPA_FQDN=""
IPA_DOMAIN=""
IPA_REALM=""
ADMIN_PASSWORD=""
RADIUS_SERVICE_PASSWORD=""
LDAP_SERVICE_DN=""
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
Usage: $0 [-p <admin_password>] [-s <radius_secret>]

Arguments:
  -p <password>   Admin password (reads from /etc/ipa/secrets if not provided)
  -s <secret>     RADIUS client secret (random if not provided)
  -?              Show this help

Examples:
  # Use passwords from /etc/ipa/secrets
  $0

  # Specify Admin password
  $0 -p MyAdminPass123

  # Specify both passwords
  $0 -p MyAdminPass123 -s MyRadiusSecret123

Prerequisites:
  - FreeIPA server must be installed and running
  - /etc/ipa/secrets file should exist (created by install-ipa.sh)
  - If /etc/ipa/secrets doesn't exist, you must provide -p option

Note:
  - This script will verify or create 'ldapauth' service account in FreeIPA
  - The service account is used for LDAP authentication (FreeRADIUS and other services)
  - Password is automatically saved to /etc/ipa/secrets
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
    
    # Try to read Admin password from secrets file
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD=$(grep "^Admin Password:" "$SECRETS_FILE" | cut -d':' -f2- | sed 's/^[[:space:]]*//')
        if [[ -n "$ADMIN_PASSWORD" ]]; then
            log "Read Admin password from $SECRETS_FILE"
        fi
    fi
    
    # Try to read LDAP Auth service account password if it exists
    if [[ -z "$RADIUS_SERVICE_PASSWORD" ]]; then
        RADIUS_SERVICE_PASSWORD=$(grep "^LDAP Auth Service Account Password:" "$SECRETS_FILE" | cut -d':' -f2- | sed 's/^[[:space:]]*//')
        if [[ -n "$RADIUS_SERVICE_PASSWORD" ]]; then
            log "Read LDAP Auth service account password from $SECRETS_FILE"
        fi
    fi
    
    return 0
}

prompt_for_passwords() {
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        log "Admin password not found in $SECRETS_FILE"
        read -s -p "Enter Admin password: " ADMIN_PASSWORD
        echo
        [[ -z "$ADMIN_PASSWORD" ]] && error_exit "Admin password is required"
    fi
    
    # Note: LDAP Auth service account password is handled in verify_or_create_ldapauth_account()
    # which checks if the account exists and prompts the user accordingly
    
    if [[ -z "$RADIUS_SECRET" ]]; then
        RADIUS_SECRET=$(generate_password)
        log "Generated RADIUS client secret: $RADIUS_SECRET"
    fi
}

# --- Service Account Verification ---

prompt_service_account_choice() {
    echo ""
    log "ldapauth service account not found in FreeIPA"
    log "You have two options:"
    echo ""
    echo "1. Create a new 'ldapauth' service account (recommended)"
    echo "2. Use Directory Manager (cn=Directory Manager) for LDAP authentication"
    echo ""
    read -p "Please choose an option (1 or 2): " choice
    
    case "$choice" in
        1)
            return 1  # Signal to create account
            ;;
        2)
            return 0  # Signal to use directory manager
            ;;
        *)
            log "ERROR: Invalid choice. Please enter 1 or 2."
            prompt_service_account_choice
            ;;
    esac
}

use_directory_manager_auth() {
    log "Using Directory Manager for LDAP authentication"
    
    # Set service DN to Directory Manager
    LDAP_SERVICE_DN="cn=Directory Manager"
    RADIUS_SERVICE_PASSWORD="$ADMIN_PASSWORD"
    
    log "✓ Directory Manager will be used for LDAP authentication"
    log "Note: Directory Manager is a privileged account. Consider creating a dedicated ldapauth account in the future."
}

verify_or_create_ldapauth_account() {
    log "Checking for ldapauth service account..."
    
    local service_dn="uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}"
    LDAP_SERVICE_DN="$service_dn"  # Set global variable for later use
    
    # Get Kerberos ticket as admin
    echo "$ADMIN_PASSWORD" | kinit admin@"$IPA_REALM" || error_exit "Failed to get Kerberos ticket"
    
    # Check if service account exists
    if ldapsearch -Y GSSAPI -H ldap://"$IPA_FQDN" -b "$service_dn" "(objectclass=*)" dn 2>/dev/null | grep -q "^dn: "; then
        log "✓ ldapauth service account exists"
        
        # Check if password is in secrets file
        if [[ -n "$RADIUS_SERVICE_PASSWORD" ]]; then
            log "Found password in $SECRETS_FILE, verifying..."
            
            # Verify password works
            if ldapsearch -x -D "$service_dn" -w "$RADIUS_SERVICE_PASSWORD" -H ldap://127.0.0.1 -b "cn=accounts,dc=${IPA_DOMAIN//./,dc=}" -s base dn >/dev/null 2>&1; then
                log "✓ Password from $SECRETS_FILE is valid"
            else
                log "ERROR: Password from $SECRETS_FILE does not work"
                read -s -p "Enter the ldapauth service account password: " RADIUS_SERVICE_PASSWORD
                echo
                
                # Verify the provided password
                if ldapsearch -x -D "$service_dn" -w "$RADIUS_SERVICE_PASSWORD" -H ldap://127.0.0.1 -b "cn=accounts,dc=${IPA_DOMAIN//./,dc=}" -s base dn >/dev/null 2>&1; then
                    log "✓ Provided password is valid"
                    
                    # Update secrets file with correct password
                    if grep -q "^LDAP Auth Service Account Password:" "$SECRETS_FILE" 2>/dev/null; then
                        sed -i "s/^LDAP Auth Service Account Password:.*/LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD/" "$SECRETS_FILE"
                    else
                        echo "LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD" >> "$SECRETS_FILE"
                    fi
                    log "✓ Updated password in $SECRETS_FILE"
                else
                    kdestroy 2>/dev/null || true
                    error_exit "Invalid password. Cannot proceed."
                fi
            fi
        else
            # Password not in secrets file, prompt user
            log "Password not found in $SECRETS_FILE"
            read -s -p "Enter the ldapauth service account password: " RADIUS_SERVICE_PASSWORD
            echo
            
            # Verify the provided password
            if ldapsearch -x -D "$service_dn" -w "$RADIUS_SERVICE_PASSWORD" -H ldap://127.0.0.1 -b "cn=accounts,dc=${IPA_DOMAIN//./,dc=}" -s base dn >/dev/null 2>&1; then
                log "✓ Password verified successfully"
                
                # Save to secrets file
                if [[ -f "$SECRETS_FILE" ]]; then
                    echo "" >> "$SECRETS_FILE"
                    echo "LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD" >> "$SECRETS_FILE"
                    log "✓ Saved password to $SECRETS_FILE"
                fi
            else
                kdestroy 2>/dev/null || true
                error_exit "Invalid password. Cannot proceed."
            fi
        fi
    else
        # Account doesn't exist, ask user
        kdestroy 2>/dev/null || true
        
        if prompt_service_account_choice; then
            # User chose to use Directory Manager
            use_directory_manager_auth
            return
        fi
        
        # User chose to create the account
        log "ldapauth service account not found, creating it..."
        
        # Get Kerberos ticket again for creating account
        echo "$ADMIN_PASSWORD" | kinit admin@"$IPA_REALM" || error_exit "Failed to get Kerberos ticket"
        
        RADIUS_SERVICE_PASSWORD=$(generate_password)
        
        # Create LDIF for service account
        cat > /tmp/ldapauth.ldif << EOF
dn: $service_dn
objectClass: account
objectClass: simplesecurityobject
uid: ldapauth
userPassword: $RADIUS_SERVICE_PASSWORD
description: LDAP authentication service account for FreeRADIUS and other services
EOF
        
        # Add service account
        if ldapadd -Y GSSAPI -H ldap://"$IPA_FQDN" -f /tmp/ldapauth.ldif; then
            rm -f /tmp/ldapauth.ldif
            log "✓ Service account 'ldapauth' created successfully"
            log "Password: $RADIUS_SERVICE_PASSWORD"
            
            # Add ACI to allow ldapauth to read ipaNTHash attribute for RADIUS authentication
            log "Adding permission for ldapauth to read ipaNTHash attribute..."
            local users_dn="cn=users,cn=accounts,dc=${IPA_DOMAIN//./,dc=}"
            local aci_name="RADIUS Service Account ipaNTHash Access"
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
            
            # Verify service account can bind
            if ldapsearch -x -D "$service_dn" -w "$RADIUS_SERVICE_PASSWORD" -H ldap://127.0.0.1 -b "cn=accounts,dc=${IPA_DOMAIN//./,dc=}" -s base dn >/dev/null 2>&1; then
                log "✓ Service account authentication verified"
            else
                log "WARNING: Could not verify service account authentication"
            fi
            
            # Save password to secrets file
            if [[ -f "$SECRETS_FILE" ]]; then
                if grep -q "^LDAP Auth Service Account Password:" "$SECRETS_FILE" 2>/dev/null; then
                    sed -i "s/^LDAP Auth Service Account Password:.*/LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD/" "$SECRETS_FILE"
                else
                    echo "" >> "$SECRETS_FILE"
                    echo "LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD" >> "$SECRETS_FILE"
                fi
                log "✓ Password saved to $SECRETS_FILE"
            else
                log "WARNING: $SECRETS_FILE not found, password not saved"
            fi
        else
            rm -f /tmp/ldapauth.ldif
            kdestroy 2>/dev/null || true
            error_exit "Failed to create ldapauth service account"
        fi
    fi
    
    # Destroy kerberos ticket
    kdestroy 2>/dev/null || true
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
    
    # Determine service description based on whether using ldapauth or Directory Manager
    local service_description
    if [[ "$LDAP_SERVICE_DN" == "cn=Directory Manager" ]]; then
        service_description="Directory Manager"
    else
        service_description="ldapauth"
    fi

    # Generate complete IPA LDAP configuration file
    cat > "$ldap_config" << LDAPEOF
# -*- text -*-
#
#  FreeRADIUS LDAP module configuration for FreeIPA
#  Using service account: $service_description
#

ldap {
    server = '127.0.0.1'
    port = 389
    
    identity = '$LDAP_SERVICE_DN'
    password = '$RADIUS_SERVICE_PASSWORD'
    
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
LDAPEOF

    # Enable IPA LDAP module with symlink
    ln -sf /etc/raddb/mods-available/ipa-ldap /etc/raddb/mods-enabled/ldap
    
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
    
    # Update or append RADIUS secrets to /etc/ipa/secrets
    if [[ -f "$secrets_file" ]]; then
        # Update Admin Password if provided/entered
        if [[ -n "$ADMIN_PASSWORD" ]]; then
            if grep -q "^Admin Password:" "$secrets_file"; then
                sed -i "s/^Admin Password:.*/Admin Password: $ADMIN_PASSWORD/" "$secrets_file"
            else
                # Add after Directory Manager Password or at the end
                if grep -q "^Directory Manager Password:" "$secrets_file"; then
                    sed -i "/^Directory Manager Password:/a Admin Password: $ADMIN_PASSWORD" "$secrets_file"
                else
                    echo "Admin Password: $ADMIN_PASSWORD" >> "$secrets_file"
                fi
            fi
            log "Updated Admin password in $secrets_file"
        fi
        
        # Update LDAP Auth Service Account Password if provided/entered
        if [[ -n "$RADIUS_SERVICE_PASSWORD" ]]; then
            if grep -q "^LDAP Auth Service Account Password:" "$secrets_file"; then
                sed -i "s/^LDAP Auth Service Account Password:.*/LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD/" "$secrets_file"
            else
                echo "" >> "$secrets_file"
                echo "LDAP Auth Service Account DN: uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}" >> "$secrets_file"
                echo "LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD" >> "$secrets_file"
            fi
            log "Updated LDAP Auth password in $secrets_file"
        fi
        
        # Update RADIUS client secret
        if grep -q "^RADIUS Client Secret:" "$secrets_file"; then
            sed -i "s/^RADIUS Client Secret:.*/RADIUS Client Secret: $RADIUS_SECRET/" "$secrets_file"
        else
            echo "" >> "$secrets_file"
            echo "RADIUS Client Secret: $RADIUS_SECRET" >> "$secrets_file"
        fi
        log "Updated RADIUS client secret in $secrets_file"
    else
        # Create new secrets file (shouldn't happen, but handle it)
        cat > "$secrets_file" << EOF
# FreeRADIUS Installation Secrets
# Generated on: $(date)

Admin Password: $ADMIN_PASSWORD
LDAP Auth Service Account DN: uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}
LDAP Auth Service Account Password: $RADIUS_SERVICE_PASSWORD
RADIUS Client Secret: $RADIUS_SECRET
EOF
        chmod 600 "$secrets_file"
        log "Created $secrets_file with RADIUS secrets"
    fi
    
    # Also save to log file location
    cat > "$LOG_FILE.passwords" << EOF
FreeRADIUS Installation Secrets
Generated on: $(date)
FQDN: $IPA_FQDN
Domain: $IPA_DOMAIN
Realm: $IPA_REALM

Service Account: uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}
Service Account Password: $RADIUS_SERVICE_PASSWORD
RADIUS Client Secret: $RADIUS_SECRET

Log file: $LOG_FILE
EOF
    chmod 600 "$LOG_FILE.passwords"
    log "Secrets also saved to: $LOG_FILE.passwords"
}

# --- Argument Parsing ---

parse_arguments() {
    while getopts "p:s:?" opt; do
        case $opt in
            p)
                ADMIN_PASSWORD="$OPTARG"
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
    local service_account_desc
    if [[ "$LDAP_SERVICE_DN" == "cn=Directory Manager" ]]; then
        service_account_desc="Directory Manager (cn=Directory Manager)"
    else
        service_account_desc="ldapauth (uid=ldapauth,cn=sysaccounts,cn=etc)"
    fi
    
    log "=== FreeRADIUS Installation Configuration ==="
    log "FQDN: $IPA_FQDN"
    log "Domain: $IPA_DOMAIN"
    log "Realm: $IPA_REALM"
    log "LDAP Service Account: $service_account_desc"
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
    
    # Verify or create ldapauth service account in FreeIPA
    verify_or_create_ldapauth_account
    
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
    log ""
    
    # Display service account information
    if [[ "$LDAP_SERVICE_DN" == "cn=Directory Manager" ]]; then
        log "LDAP Service Account: Directory Manager (cn=Directory Manager)"
    else
        log "LDAP Service Account: ldapauth"
        log "Service Account DN: uid=ldapauth,cn=sysaccounts,cn=etc,dc=${IPA_DOMAIN//./,dc=}"
    fi
    
    log "RADIUS Client Secret: $RADIUS_SECRET"
    log "All secrets saved to: $SECRETS_FILE"
    log "Installation log: $LOG_FILE"
    log ""
    log "Test RADIUS authentication with:"
    log "  radtest <username> <password> 127.0.0.1 0 $RADIUS_SECRET"
}

# Execute main function with all arguments
main "$@"
