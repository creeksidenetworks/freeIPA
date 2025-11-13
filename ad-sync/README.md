# AD-FreeIPA Sync

Simple tool to synchronize users, groups, and memberships from Windows Active Directory to FreeIPA.

## Quick Start

### 1. Install

**Requirements:**
- Python 3.6+
- Root/sudo access (for installing system packages)
- System packages: `python3-devel`, `gcc`, `krb5-devel`, `openldap-devel`

**Installation:**

```bash
sudo bash install.sh
```

This will:
- Install required system packages (gcc, python3-devel, krb5-devel, openldap-devel)
- Create a Python virtual environment
- Install Python packages (ldap3, python-freeipa, pyyaml)
- Create a `config.yaml` template

**Note:** The script auto-detects your Linux distribution (RHEL/CentOS/Fedora/Ubuntu/Debian) and installs the appropriate packages.

### 2. Configure

Edit `config.yaml` with your settings:

```yaml
active_directory:
  server: "ldap://ad.example.com"
  bind_dn: "CN=Service Account,CN=Users,DC=example,DC=com"
  bind_password: "your_password"
  user_search_base: "CN=Users,DC=example,DC=com"
  group_search_base: "CN=Groups,DC=example,DC=com"

freeipa:
  server: "ipa.example.com"
  username: "admin"
  password: "your_password"
```

#### Unix UID/GID Synchronization

**Option 1: AD has explicit Unix attributes (IdM for Unix)**

If Active Directory has **Identity Management for Unix** enabled with explicit uidNumber/gidNumber attributes:

```yaml
sync:
  user_attribute_mapping:
    uidNumber: uidnumber        # Unix UID
    gidNumber: gidnumber        # Unix GID
    loginShell: loginshell      # Unix shell
    unixHomeDirectory: homedirectory
```

**Option 2: AD uses SID-to-UID mapping (SSSD/Winbind style)**

If your AD-joined Linux servers use automatic ID mapping (like SSSD), the script will calculate UIDs/GIDs from Windows SIDs to match your existing Linux systems.

**First, find your ID range base:**

```bash
# Check your current UID on an AD-joined Linux server
id your_username
# Example output: uid=1668601105(your_username) gid=1668600513(domain users) ...

# Run the show-id command to see the calculation
./ad_sync.py show-id --user your_username
# This will show you the correct id_range_base value
```

**Then update config.yaml:**

```yaml
active_directory:
  id_range_base: 1668600000  # Use the value shown by show-id command
  
sync:
  user_attribute_mapping:
    uidNumber: uidnumber        # Will be calculated from SID
    gidNumber: gidnumber        # Will be calculated from SID
    loginShell: loginshell
    unixHomeDirectory: homedirectory
```

**Note:** The `id_range_base` ensures UIDs/GIDs in FreeIPA match what users already have on AD-joined Linux servers.

### 3. Test Connection

```bash
./ad_sync.py test
```

### 4. Sync

**Dry-run (preview only):**
```bash
./ad_sync.py sync --dry-run
```

**Live sync:**
```bash
./ad_sync.py sync
```

## Commands

```bash
./ad_sync.py test                        # Test AD and FreeIPA connections
./ad_sync.py show-id --user USERNAME     # Show UID/GID calculation for a user
./ad_sync.py sync                        # Run live sync
./ad_sync.py sync --dry-run              # Preview changes without applying
./ad_sync.py sync --force-users          # Force update existing users (default: skip)
./ad_sync.py sync --force-groups         # Force update existing groups (default: skip)
./ad_sync.py sync --verbose              # Detailed output
./ad_sync.py sync -c custom.yaml         # Use custom config file
```

**Note:** By default, existing users and groups are skipped. Use `--force-users` and/or `--force-groups` to update them.

## Configuration Options

### Filters

Include or exclude specific users/groups:

```yaml
sync:
  user_include_filter: ["user1", "user2"]  # Only sync these (empty = all)
  user_exclude_filter: ["admin", "guest"]  # Skip these
  group_include_filter: []                 # Only sync these (empty = all)
  group_exclude_filter: ["Domain Admins"]  # Skip these
```

### Attribute Mapping

Map AD attributes to FreeIPA attributes:

```yaml
sync:
  user_attribute_mapping:
    sAMAccountName: uid          # AD username -> FreeIPA uid
    givenName: givenname         # First name
    sn: sn                       # Last name
    mail: mail                   # Email
    displayName: cn              # Display name
    uidNumber: uidnumber         # Unix UID
    gidNumber: gidnumber         # Unix GID
```

### What Gets Synced

- ✓ Users (active accounts only)
- ✓ Groups
- ✓ Group memberships
- ✓ Unix UIDs/GIDs (if configured in AD)
- ✗ Passwords (not synced for security)
- ✗ Disabled accounts (automatically skipped)

## Creating AD Service Account

### Windows Server GUI Method:

1. **Open Active Directory Users and Computers**
   - Start → Administrative Tools → Active Directory Users and Computers

2. **Create New User**
   - Right-click on "Users" → New → User
   - Set username: `svc_ipa_sync`
   - Set a strong password
   - Check "Password never expires"
   - Uncheck "User must change password at next logon"

3. **Set Permissions (Read-Only)**
   - Right-click domain root (e.g., `example.com`) → Delegate Control
   - Add the service account
   - Select "Read all user information"
   - Click Next → Finish

4. **Get Distinguished Name**
   - Right-click the user → Properties → Attribute Editor
   - Find `distinguishedName`
   - Copy the value (e.g., `CN=svc_ipa_sync,CN=Users,DC=example,DC=com`)

### PowerShell Method:

```powershell
# Create service account
New-ADUser -Name "svc_ipa_sync" `
  -UserPrincipalName "svc_ipa_sync@example.com" `
  -AccountPassword (ConvertTo-SecureString "YourStrongPassword" -AsPlainText -Force) `
  -Enabled $true `
  -PasswordNeverExpires $true `
  -Description "FreeIPA Sync Service Account"

# Grant read permissions on domain
$domain = Get-ADDomain
$user = Get-ADUser -Identity "svc_ipa_sync"
$acl = Get-Acl "AD:\$($domain.DistinguishedName)"
$sid = [System.Security.Principal.SecurityIdentifier]$user.SID
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::GenericRead,
    [System.Security.AccessControl.AccessControlType]::Allow
)
$acl.AddAccessRule($ace)
Set-Acl "AD:\$($domain.DistinguishedName)" $acl

Write-Host "Service account created: CN=svc_ipa_sync,CN=Users,$($domain.DistinguishedName)"
```

### Enable Unix Attributes in AD (Optional)

If you want to sync Unix UIDs/GIDs:

1. **Install Identity Management for Unix**
   - Server Manager → Add Roles and Features
   - Select "Server for NIS" under Remote Server Administration Tools

2. **Enable Unix Attributes on Users**
   - Right-click user → Properties → Unix Attributes tab
   - Set UID, GID, login shell, home directory

3. **Or use PowerShell:**
```powershell
Set-ADUser username -Replace @{
    uidNumber=10001;
    gidNumber=10001;
    loginShell="/bin/bash";
    unixHomeDirectory="/home/username"
}
```

## Scheduling

### Cron (Linux)

```bash
# Edit crontab
crontab -e

# Add line to run daily at 2 AM
0 2 * * * cd /path/to/ad-sync && ./ad_sync.py sync >> sync.log 2>&1
```

### Systemd Timer

```bash
# Create service file: /etc/systemd/system/ad-sync.service
[Unit]
Description=AD-FreeIPA Sync

[Service]
Type=oneshot
WorkingDirectory=/path/to/ad-sync
ExecStart=/path/to/ad-sync/venv/bin/python /path/to/ad-sync/ad_sync.py sync

# Create timer file: /etc/systemd/system/ad-sync.timer
[Unit]
Description=AD-FreeIPA Sync Timer

[Timer]
OnCalendar=daily
OnCalendar=02:00

[Install]
WantedBy=timers.target

# Enable and start
sudo systemctl enable ad-sync.timer
sudo systemctl start ad-sync.timer
```

## Troubleshooting

### Connection Failed

```bash
# Test AD connection
ldapsearch -x -H ldap://ad.example.com -D "CN=svc,DC=example,DC=com" -W

# Test FreeIPA
kinit admin
ipa user-find
```

### No Users Found

- Verify `user_search_base` is correct
- Check service account has read permissions
- Review filters in config.yaml

### SSL Certificate Errors

```yaml
# For testing, disable SSL verification
freeipa:
  verify_ssl: false

# For production, install the CA certificate:
# curl -k https://ipa.example.com/ipa/config/ca.crt -o /etc/pki/ca-trust/source/anchors/ipa.crt
# update-ca-trust
```

### Different UIDs/GIDs

If users get different UIDs in FreeIPA than AD:
- AD likely doesn't have Unix attributes configured
- Enable "Identity Management for Unix" in AD
- Set uidNumber/gidNumber on AD users
- Or accept auto-assigned IDs (requires fixing file permissions)

## Logs

Logs are written to `ad-sync.log` in the same directory.

```bash
# View logs
tail -f ad-sync.log

# Search for errors
grep ERROR ad-sync.log
```

## Requirements

**System Requirements:**
- Linux (RHEL/CentOS/Fedora/Ubuntu/Debian)
- Python 3.6+
- Root/sudo access for installation
- System packages: `python3-devel`, `gcc`, `krb5-devel`, `openldap-devel`

**Network Requirements:**
- Network access to AD (LDAP/LDAPS)
- Network access to FreeIPA

**Account Requirements:**
- AD service account with read permissions
- FreeIPA admin account

## Files

```
ad-sync/
├── ad_sync.py       # Main script (single file)
├── install.sh       # Installation script
├── config.yaml      # Configuration file (created during install)
├── ad-sync.log      # Log file (created during sync)
└── README_SIMPLE.md # This file
```

## License

MIT License
