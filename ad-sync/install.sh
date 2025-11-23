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
DEFAULT_AD_ADMIN="jtong@innosilicon.corp"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u)
      AD_ADMIN_FULL="$2"
      shift 2
      ;;
    -w)
      AD_ADMIN_PASS="$2"
      shift 2
      ;;
    -s)
      ID_RANGE_BASE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
echo "=========================================="
echo "AD-FreeIPA Sync - Installation"
echo "=========================================="
echo

# Prompt for AD admin user and password, verify LDAP connection
while true; do
  # Prompt for username if not provided or invalid
  while [[ -z "$AD_ADMIN_FULL" || ! "$AD_ADMIN_FULL" =~ @ ]]; do
    read -p "Enter AD admin username (e.g. admin@example.lcl): " AD_ADMIN_FULL_INPUT
    if [[ -z "$AD_ADMIN_FULL_INPUT" ]] || [[ ! "$AD_ADMIN_FULL_INPUT" =~ @ ]]; then
      echo "✗ Please enter a valid AD admin username (e.g. admin@example.lcl)"
      continue
    else
      AD_ADMIN_FULL="$AD_ADMIN_FULL_INPUT"
    fi
  done
  # Prompt for password if not provided
  if [[ -z "$AD_ADMIN_PASS" ]]; then
    read -s -p "Enter AD admin password: " AD_ADMIN_PASS
    echo
  fi
  AD_DOMAIN=$(echo "$AD_ADMIN_FULL" | awk -F@ '{print $2}')
  AD_SERVER="ldap://$AD_DOMAIN"
  # Try to resolve AD domain to IP address
  if command -v host &> /dev/null && [ -n "$AD_DOMAIN" ]; then
    AD_IP=$(host "$AD_DOMAIN" | awk '/has address/ {print $4; exit}')
    if [ -n "$AD_IP" ]; then
      AD_SERVER="ldap://$AD_IP"
    fi
  fi
  # Test LDAP connection
  if command -v ldapsearch &> /dev/null; then
    ldapsearch -x -H "$AD_SERVER" -D "$AD_ADMIN_FULL" -w "$AD_ADMIN_PASS" -b "" -s base namingContexts >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "✓ LDAP connection successful."
      break
    else
      echo "✗ LDAP connection failed. Please re-enter credentials."
      AD_ADMIN_PASS=""
    fi
  else
    echo "ldapsearch not found. Please install openldap-clients first."
    exit 1
  fi
done

# Check if running as root (needed for system packages)
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo to install system dependencies"
    exit 1
fi

# Check Python version
echo "Checking Python version..."
python3 --version || { echo "Error: Python 3 not found"; exit 1; }

# Install system dependencies
echo "Installing system dependencies..."
# Quietly check/install system dependencies
PKGS_MISSING=""
if command -v dnf &> /dev/null; then
  for pkg in python3-devel gcc krb5-devel openldap-devel; do
    dnf list installed $pkg &> /dev/null || PKGS_MISSING+="$pkg "
  done
  if [ -n "$PKGS_MISSING" ]; then
    dnf install -y $PKGS_MISSING
  fi
elif command -v yum &> /dev/null; then
  for pkg in python3-devel gcc krb5-devel openldap-devel; do
    yum list installed $pkg &> /dev/null || PKGS_MISSING+="$pkg "
  done
  if [ -n "$PKGS_MISSING" ]; then
    yum install -y $PKGS_MISSING
  fi
elif command -v apt-get &> /dev/null; then
  for pkg in python3-dev gcc libkrb5-dev libldap2-dev libsasl2-dev; do
    dpkg -s $pkg &> /dev/null || PKGS_MISSING+="$pkg "
  done
  if [ -n "$PKGS_MISSING" ]; then
    apt-get update
    apt-get install -y $PKGS_MISSING
  fi
else
  echo "Warning: Could not detect package manager. Please install manually:"
  echo "  - python3-devel/python3-dev"
  echo "  - gcc"
  echo "  - krb5-devel/libkrb5-dev"
  echo "  - openldap-devel/libldap2-dev"
fi

# Create virtual environment
#if [ ! -d "venv" ]; then
#    echo "Creating virtual environment..."
#    python3 -m venv venv
#else
#    echo "Virtual environment already exists"
#fi

# Activate virtual environment
#echo "Activating virtual environment..."
#source venv/bin/activate

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip > /dev/null 2>&1

# Install dependencies
echo "Installing dependencies..."
pip install ldap3 python-freeipa pyyaml > /dev/null 2>&1

echo "Now generating config.yaml from /etc/ipa/secrets and AD admin info..."

# Create config file if it doesn't exist
if [ -f "config.yaml" ]; then
  echo "Save config.yaml to config.yaml.bak"
  mv config.yaml config.yaml.bak
fi

# If /etc/ipa/secrets exists, use it for FreeIPA credentials
if [ -f "/etc/ipa/secrets" ]; then
    IPA_SERVER=$(hostname -f)
    IPA_USER="admin"
    IPA_PASS=$(awk -F': ' '/^Admin Password:/ {print $2}' /etc/ipa/secrets)
    if [ -z "$IPA_PASS" ]; then
        IPA_PASS="your_ipa_password"
    fi
else
    IPA_SERVER="ipa.example.com"
    IPA_USER="admin"
    IPA_PASS="your_ipa_password"
fi

echo "✓ Detected FreeIPA server: $IPA_SERVER"
echo "✓ Detected FreeIPA user: $IPA_USER"

# Use ldapsearch to auto-detect base DN, user_search_base, and group_search_base
if command -v ldapsearch &> /dev/null; then
    echo "Detecting AD base DN and search bases using ldapsearch..."
    BASE_DN=$(ldapsearch -x -H "$AD_SERVER" -D "$AD_ADMIN_FULL" -w "$AD_ADMIN_PASS" -b "" -s base namingContexts 2>/dev/null | awk '/namingContexts:/ {print $2; exit}')
    USER_BASE="$BASE_DN"
    GROUP_BASE="$BASE_DN"
else
    echo "Could not detect ldapsearch command. Using default values for base DN and search bases."
    BASE_DN=$(echo "$AD_DOMAIN" | awk -F. '{print "DC="$1",DC="$2}')
    USER_BASE="CN=Users,$BASE_DN"
    GROUP_BASE="CN=Groups,$BASE_DN"
fi

echo "✓ Detected AD domain: $AD_DOMAIN"
echo "✓ Detected base DN: $BASE_DN"
echo "✓ Detected user search base: $USER_BASE"
echo "✓ Detected group search base: $GROUP_BASE"

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
echo "To activate the environment in the future:"
echo "  source venv/bin/activate"
echo
