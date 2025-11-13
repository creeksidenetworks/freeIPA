#!/bin/bash
#
# AD-FreeIPA Sync Installation Script
# Installs dependencies and sets up the environment
#

set -e

echo "=========================================="
echo "AD-FreeIPA Sync - Installation"
echo "=========================================="
echo

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
if command -v dnf &> /dev/null; then
    # RHEL/CentOS/Fedora
    dnf install -y python3-devel gcc krb5-devel openldap-devel
elif command -v yum &> /dev/null; then
    # Older RHEL/CentOS
    yum install -y python3-devel gcc krb5-devel openldap-devel
elif command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    apt-get update
    apt-get install -y python3-dev gcc libkrb5-dev libldap2-dev libsasl2-dev
else
    echo "Warning: Could not detect package manager. Please install manually:"
    echo "  - python3-devel/python3-dev"
    echo "  - gcc"
    echo "  - krb5-devel/libkrb5-dev"
    echo "  - openldap-devel/libldap2-dev"
fi

# Create virtual environment
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
else
    echo "Virtual environment already exists"
fi

# Activate virtual environment
echo "Activating virtual environment..."
source venv/bin/activate

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip

# Install dependencies
echo "Installing dependencies..."
pip install ldap3 python-freeipa pyyaml

# Create config file if it doesn't exist
if [ ! -f "config.yaml" ]; then
    echo "Creating config.yaml from template..."
    cat > config.yaml << 'EOF'
# Active Directory Configuration
active_directory:
  server: "ldap://ad.example.com"
  port: 389
  use_ssl: false
  bind_dn: "CN=Service Account,CN=Users,DC=example,DC=com"
  bind_password: "your_ad_password"
  base_dn: "DC=example,DC=com"
  user_search_base: "CN=Users,DC=example,DC=com"
  group_search_base: "CN=Groups,DC=example,DC=com"
  user_filter: "(objectClass=user)"
  group_filter: "(objectClass=group)"

# FreeIPA Configuration
freeipa:
  server: "ipa.example.com"
  username: "admin"
  password: "your_ipa_password"
  verify_ssl: true

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
    echo "✓ Created config.yaml"
    echo "⚠ Please edit config.yaml with your AD and FreeIPA settings"
else
    echo "✓ config.yaml already exists"
fi

# Make script executable
chmod +x ad_sync.py

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
