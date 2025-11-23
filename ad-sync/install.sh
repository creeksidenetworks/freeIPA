#!/bin/bash
#
# AD-FreeIPA Sync Installation Script
# Installs dependencies and sets up the environment
#

set -e
# Parse optional arguments for AD admin username and password
AD_ADMIN_FULL=""
AD_ADMIN_PASS=""
ID_RANGE_BASE=""
DEFAULT_AD_ADMIN=""

# Check if running as root (needed for system packages)
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo to install system dependencies"
    exit 1
fi

# Install system dependencies and Python packages
echo "Checking and installing required system and Python packages..."

PKGS_MISSING=""
for pkg in python3-devel gcc krb5-devel openldap-devel openldap-clients bind-utils; do
    rpm -q $pkg &> /dev/null || PKGS_MISSING+="$pkg "
done

if [ -n "$PKGS_MISSING" ]; then
    echo "Installing missing system packages: $PKGS_MISSING"
    dnf install -y $PKGS_MISSING || { echo "✗ Failed to install system packages: $PKGS_MISSING"; exit 1; }
fi

echo "Upgrading pip and installing Python dependencies..."
pip install --upgrade pip > /dev/null 2>&1 || { echo "✗ Failed to upgrade pip"; exit 1; }
pip install ldap3 python-freeipa pyyaml > /dev/null 2>&1 || { echo "✗ Failed to install Python dependencies"; exit 1; }

echo "============================================="
echo "Active Directory->FreeIPA Sync - Installation"
echo "=========================================="
echo

# If /etc/ipa/secrets exists, use it for FreeIPA credentials
if [ -f "/etc/ipa/secrets" ]; then
  IPA_SERVER=$(hostname -f)
  IPA_USER="admin"
  IPA_PASS=$(awk -F': ' '/^Admin Password:/ {print $2}' /etc/ipa/secrets)
fi

# Prompt for AD admin user and password, verify LDAP connection
while true; do
    # Prompt for username with default value shown
    read -p "Enter AD admin username (e.g. admin@example.lcl) [${AD_ADMIN_FULL}]: " AD_ADMIN_FULL_INPUT
    if [[ -z "$AD_ADMIN_FULL_INPUT" && -n "$AD_ADMIN_FULL" ]]; then
        AD_ADMIN_FULL_INPUT="$AD_ADMIN_FULL"
    fi
    if [[ -z "$AD_ADMIN_FULL_INPUT" ]] || [[ ! "$AD_ADMIN_FULL_INPUT" =~ @ ]]; then
        echo "✗ Please enter a valid AD admin username (e.g. admin@example.lcl)"
        continue
    else
        AD_ADMIN_FULL="$AD_ADMIN_FULL_INPUT"
    fi

    # Prompt for password with default value shown
    read -s -p "Enter AD admin password [${AD_ADMIN_PASS}]: " AD_ADMIN_PASS_INPUT
    echo
    if [[ -z "$AD_ADMIN_PASS_INPUT" && -n "$AD_ADMIN_PASS" ]]; then
        AD_ADMIN_PASS_INPUT="$AD_ADMIN_PASS"
    fi
    if [[ -z "$AD_ADMIN_PASS_INPUT" ]]; then
        echo "✗ Please enter a valid AD admin password."
        continue
    fi
    AD_ADMIN_PASS="$AD_ADMIN_PASS_INPUT"
    AD_DOMAIN=$(echo "$AD_ADMIN_FULL" | awk -F@ '{print $2}')
    AD_SERVER="ldap://$AD_DOMAIN"
    # Try to resolve AD domain to IP address
    if [ -n "$AD_DOMAIN" ]; then
        AD_IP=$(host "$AD_DOMAIN" | awk '/has address/ {print $4; exit}')
        if [ -n "$AD_IP" ]; then
            AD_SERVER="ldap://$AD_IP"
        else
            echo "✗ Could not resolve AD domain '$AD_DOMAIN' to an IP address. Please check the domain and try again."
            exit 1
        fi
    fi

    # Use ldapsearch to auto-detect base DN
    echo "Detecting AD base DN using ldapsearch..."
    BASE_DN=$(ldapsearch -x -H "$AD_SERVER" -D "$AD_ADMIN_FULL" -w "$AD_ADMIN_PASS" -b "" -s base namingContexts 2>/dev/null | awk '/namingContexts:/ {print $2; exit}')
    if [ $? -eq 0 ] && [ -n "$BASE_DN" ]; then
        echo "✓ LDAP connection successful."
    else
        echo "✗ LDAP connection failed. Please re-enter credentials."
        continue
    fi    

    # Prompt for user and group search bases, default to BASE_DN
    read -p "Enter AD user search base [${BASE_DN}]: " USER_BASE_INPUT
    if [[ -z "$USER_BASE_INPUT" ]]; then
        USER_BASE="$BASE_DN"
    else
        USER_BASE="$USER_BASE_INPUT"
    fi

    read -p "Enter AD group search base [${BASE_DN}]: " GROUP_BASE_INPUT
    if [[ -z "$GROUP_BASE_INPUT" ]]; then
        GROUP_BASE="$BASE_DN"
    else
        GROUP_BASE="$GROUP_BASE_INPUT"
    fi

    # Verify user search base
    USER_COUNT=$(ldapsearch -x -H "$AD_SERVER" -D "$AD_ADMIN_FULL" -w "$AD_ADMIN_PASS" -b "$USER_BASE" "(objectClass=user)" dn 2>/dev/null | grep '^dn:' | wc -l)
    echo "✓ Found $USER_COUNT users in '$USER_BASE'"

    # Verify group search base
    GROUP_COUNT=$(ldapsearch -x -H "$AD_SERVER" -D "$AD_ADMIN_FULL" -w "$AD_ADMIN_PASS" -b "$GROUP_BASE" "(objectClass=group)" dn 2>/dev/null | grep '^dn:' | wc -l)
    echo "✓ Found $GROUP_COUNT groups in '$GROUP_BASE'"

    break
done



echo "✓ Detected AD domain: $AD_DOMAIN"
echo "✓ Detected base DN: $BASE_DN"
echo "✓ Detected user search base: $USER_BASE"
echo "✓ Detected group search base: $GROUP_BASE"


# Prompt for IPA info if not set
while [[ -z "$IPA_SERVER" || -z "$IPA_USER" || -z "$IPA_PASS" ]]; do
    read -p "Enter FreeIPA server hostname (e.g. ipa.example.lcl) [${IPA_SERVER}]: " IPA_SERVER_INPUT
    if [[ -z "$IPA_SERVER_INPUT" && -n "$IPA_SERVER" ]]; then
      IPA_SERVER_INPUT="$IPA_SERVER"
    fi
    if [[ -z "$IPA_SERVER_INPUT" ]]; then
      echo "✗ Please enter a valid FreeIPA server hostname."
      continue
    fi
    IPA_SERVER="$IPA_SERVER_INPUT"

    read -p "Enter FreeIPA username [${IPA_USER}]: " IPA_USER_INPUT
    if [[ -z "$IPA_USER_INPUT" && -n "$IPA_USER" ]]; then
      IPA_USER_INPUT="$IPA_USER"
    fi
    if [[ -z "$IPA_USER_INPUT" ]]; then
      echo "✗ Please enter a valid FreeIPA username."
      continue
    fi
    IPA_USER="$IPA_USER_INPUT"

    read -s -p "Enter FreeIPA password [$IPA_PASS]: " IPA_PASS_INPUT
    echo
    if [[ -z "$IPA_PASS_INPUT" && -n "$IPA_PASS" ]]; then
      IPA_PASS_INPUT="$IPA_PASS"
    fi
    if [[ -z "$IPA_PASS_INPUT" ]]; then
      echo "✗ Please enter a valid FreeIPA password."
      continue
    fi
    IPA_PASS="$IPA_PASS_INPUT"

    # Verify IPA connection via LDAP
    IPA_LDAP_URI="ldap://$IPA_SERVER"
    if command -v ldapsearch &> /dev/null; then
    ldapsearch -x -H "$IPA_LDAP_URI" -D "uid=$IPA_USER,cn=users,cn=accounts,dc=$(echo $IPA_SERVER | awk -F. '{print $1",dc="$2}')" -w "$IPA_PASS" -b "" -s base namingContexts >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✓ FreeIPA LDAP connection successful."
    else
        echo "✗ FreeIPA LDAP connection failed. Please re-enter credentials."
        # Loop will prompt again
        continue
    fi
    else
        echo "ldapsearch not found. Please install openldap-clients first."
        exit 1
    fi
done

# Auto-detect id_range_base using AD admin user or FreeIPA
# If not provided via -s, try to retrieve from FreeIPA if configured
if [ -z "$ID_RANGE_BASE" ] && [ -n "$IPA_PASS" ]; then
      # Try using ipa command with Kerberos auth
      printf "$IPA_PASS\n" | kinit "$IPA_USER" 2>/dev/null
      if [ $? -eq 0 ]; then
        ID_RANGE_BASE=$(ipa idrange-find 2>/dev/null | awk '/First Posix ID of the range:/ {print $7; exit}')
        kdestroy 2>/dev/null
        if [ -n "$ID_RANGE_BASE" ]; then
          echo "✓ Retrieved ID range base from FreeIPA: $ID_RANGE_BASE"
        fi
      fi
fi

# If still not set, prompt user
if [ -z "$ID_RANGE_BASE" ]; then
      read -p "Enter ID range base [default: 200000]: " input
      if [ -z "$input" ]; then
        ID_RANGE_BASE=200000
      else
        ID_RANGE_BASE=$input
      fi
      echo "✓ Using ID range base: $ID_RANGE_BASE"
fi

# Always include full FreeIPA section in config.yaml
cat > config.yaml << EOF
# Active Directory Configuration
active_directory:
    server: "$AD_SERVER"
    port: 389
    use_ssl: false
    bind_dn: "$AD_ADMIN_FULL"
    bind_password: "$AD_ADMIN_PASS"
    base_dn: "$BASE_DN"
    user_search_base: "$USER_BASE"
    group_search_base: "$GROUP_BASE"
    user_filter: "(objectClass=user)"
    group_filter: "(objectClass=group)"
    id_range_base: $ID_RANGE_BASE

# FreeIPA Configuration
freeipa:
    server: "$IPA_SERVER"
    username: "$IPA_USER"
    password: "$IPA_PASS"
    verify_ssl: false

# Sync Configuration
sync:
    sync_users: true
    sync_groups: true
    sync_group_memberships: true
  
  # User attribute mapping (AD -> FreeIPA)
  user_attribute_mapping:
    sAMAccountName: uid
    givenName: givenname
    sn: sn
    mail: mail
    displayName: cn
    telephoneNumber: telephonenumber
    title: title
    department: ou
    uidNumber: uidnumber              # Unix UID (requires AD IdM for Unix)
    gidNumber: gidnumber              # Unix GID (requires AD IdM for Unix)
    loginShell: loginshell            # Unix shell
    unixHomeDirectory: homedirectory  # Unix home directory
  
  # Group attribute mapping
  group_attribute_mapping:
      sAMAccountName: cn
      description: description
      gidNumber: gidnumber              # Unix GID for groups
  
  # Filters (empty = sync all)
  user_include_filter: []
  user_exclude_filter: []
  group_include_filter: []
  group_exclude_filter: []
EOF

echo "✓ Created config.yaml from /etc/ipa/secrets and AD admin info."

echo
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo
echo "Next steps:"
echo "1. Edit config.yaml with your settings"
echo "2. Test connections: ./ad_sync.py test"
echo "3. Run dry-run: ./ad_sync.py sync --dry-run"
echo "4. Run live sync: ./ad_sync.py sync"
echo
