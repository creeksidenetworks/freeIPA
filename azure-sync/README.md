# Azure FreeIPA Sync

A simple, reliable tool to synchronize users and groups from Azure Entra ID (formerly Azure Active Directory) to FreeIPA.

## Features

- ✅ **User Sync**: Creates new users from Azure, preserves existing users
- ✅ **Group Sync**: Synchronizes group memberships 
- ✅ **Safe Operation**: Dry-run mode, preserves existing user data
- ✅ **Flexible Configuration**: Customizable attribute mapping
- ✅ **Production Ready**: Logging, error handling, SSL support
- ✅ **Automated Installation**: Interactive setup with guided configuration
- ✅ **Scheduled Sync**: Systemd timer for automatic synchronization

## Quick Start

### 1. Prerequisites

- FreeIPA server installed and configured
- Azure Entra ID tenant with admin access
- Root access to the FreeIPA server

### 2. Azure App Registration

Before installation, create an Azure App Registration:

1. Go to **Azure Portal** → **Azure Active Directory** → **App Registrations**
2. Click **"New registration"**
   - Name: "FreeIPA Sync Tool"
   - Account types: "Accounts in this organizational directory only"
3. Click **"Register"**
4. Note the following (you'll need these during installation):
   - **Application (client) ID**
   - **Directory (tenant) ID**
5. Go to **"Certificates & secrets"** → **"New client secret"**
   - Create a secret and note the **Value** (not the Secret ID)
6. Go to **"API permissions"**
   - Click **"Add a permission"** → **"Microsoft Graph"** → **"Application permissions"**
   - Add these permissions:
     - `User.Read.All`
     - `Group.Read.All`
     - `GroupMember.Read.All`
   - Click **"Grant admin consent for [Your Organization]"**

### 3. Installation

```bash
# Navigate to the azure-sync directory
cd /opt/freeIPA/azure-sync

# Run the interactive installation script
sudo ./install.sh
```

The installation script will:
- ✅ Verify you're running on a FreeIPA server
- ✅ Check and install required dependencies (Python 3, pip3)
- ✅ Auto-detect FreeIPA server configuration
- ✅ Auto-retrieve admin credentials from `/etc/ipa/secrets`
- ✅ Prompt for Azure App Registration details
- ✅ Generate configuration file at `/opt/azure-freeipa-sync/azure_sync.conf`
- ✅ Install the sync script and create symlink
- ✅ Set up systemd timer for automated sync
- ✅ Display usage instructions

### 4. Test Configuration

```bash
# Test with dry-run (no changes made)
azure-freeipa-sync --dry-run
```

### 5. Run Sync

```bash
# Perform actual sync
azure-freeipa-sync
```

## Usage

### Manual Sync

```bash
# Dry run (preview changes without applying)
azure-freeipa-sync --dry-run

# Dry run with verbose logging
azure-freeipa-sync --dry-run --verbose

# Production sync
azure-freeipa-sync

# Use custom config file
azure-freeipa-sync -c /path/to/config.conf

# View help
azure-freeipa-sync --help
```

### Automated Sync (Systemd Timer)

The installation script creates a systemd timer for scheduled synchronization:

```bash
# Check timer status
systemctl status azure-freeipa-sync.timer

# View timer schedule
systemctl list-timers azure-freeipa-sync.timer

# Manually trigger sync
systemctl start azure-freeipa-sync.service

# View service logs
journalctl -u azure-freeipa-sync.service -f

# Disable automatic sync
systemctl stop azure-freeipa-sync.timer
systemctl disable azure-freeipa-sync.timer
```

## Configuration

The installation script automatically creates the configuration file at:
```
/opt/azure-freeipa-sync/azure_sync.conf
```

### Manual Configuration (if needed)

```bash
# Edit configuration
sudo nano /opt/azure-freeipa-sync/azure_sync.conf
```

### Configuration Format

```ini
[azure]
client_id = your-azure-app-client-id
client_secret = your-azure-app-client-secret  
tenant_id = your-azure-tenant-id

[freeipa]
server = ipa.yourdomain.com
domain = yourdomain.com
realm = YOURDOMAIN.COM
bind_dn = uid=admin,cn=users,cn=accounts,dc=yourdomain,dc=com
bind_password = your-admin-password

[sync]
default_shell = /bin/bash
home_directory = /home
log_file = /var/log/azure-freeipa-sync.log
dry_run = false
```

### Configuration Options

#### Azure Section
- `client_id`: Azure App Registration Client ID (GUID format)
- `client_secret`: Azure App Registration Client Secret
- `tenant_id`: Azure Tenant ID (GUID format)
- `sync_groups`: Comma-separated list of specific groups to sync (optional)

#### FreeIPA Section  
- `server`: FreeIPA server hostname (auto-detected from `/etc/ipa/default.conf`)
- `domain`: FreeIPA domain (auto-detected)
- `realm`: Kerberos realm (auto-detected, usually uppercase domain)
- `bind_dn`: LDAP bind DN for authentication
- `bind_password`: Password for bind DN (auto-retrieved from `/etc/ipa/secrets`)

**Note**: The installation script automatically uses the admin account for user/group management. System accounts (like ldapauth) cannot manage users and groups in FreeIPA.

#### Sync Section
- `default_shell`: Default shell for new users (default: `/bin/bash`)
- `home_directory`: Base directory for home folders (default: `/home`)
- `log_file`: Path to log file (default: `/var/log/azure-freeipa-sync.log`)
- `dry_run`: Set to `true` to test without making changes (default: `false`)

## Logs

### View Sync Logs

```bash
# Main sync log
tail -f /var/log/azure-freeipa-sync.log

# Service logs (systemd)
journalctl -u azure-freeipa-sync.service -f

# View last 100 lines
tail -n 100 /var/log/azure-freeipa-sync.log
```
- `admin_user`: FreeIPA admin username
- `admin_password`: FreeIPA admin password
- `verify_ssl`: Set to `false` for self-signed certificates

### Sync Section
- `log_level`: Logging level (DEBUG, INFO, WARNING, ERROR)
- `log_file`: Path to log file
- `dry_run`: Default mode (true/false)

## Scheduling

To run sync automatically, create a cron job:

```bash
# Edit crontab
crontab -e

# Add daily sync at 2 AM
0 2 * * * /usr/local/bin/azure-freeipa-sync -c /etc/azure-freeipa-sync/azure_sync.conf >/dev/null 2>&1
```

## Troubleshooting

### Common Issues

**1. SSL Certificate Errors**
```bash
# If using self-signed certificates, this is expected
# The sync tool handles this automatically
```

**2. Permission Errors**
- Ensure Azure app has required permissions with admin consent granted
- Verify the admin account is being used (not system accounts like ldapauth)
- Check that the admin password from `/etc/ipa/secrets` is correct

**3. Authentication Failures**
```bash
# Verify admin credentials
kinit admin
ipa user-find --all

# Check if password in config matches
grep "bind_password" /opt/azure-freeipa-sync/azure_sync.conf
```

**4. "System account cannot manage users" warning**
- This is expected behavior - system accounts (ldapauth) in `cn=sysaccounts` cannot create/manage users
- The installation script automatically switches to admin account
- Admin account is required for user/group synchronization

**5. Azure App Registration Issues**
```bash
# Verify permissions are granted
- Go to Azure Portal → App Registrations → Your App
- Check API permissions show "Granted for [Organization]"
- Ensure using Application permissions, not Delegated
```

### Debug Mode

```bash
# Run with verbose output
azure-freeipa-sync --dry-run --verbose

# Check what would be synced without making changes
azure-freeipa-sync --dry-run | tee sync-preview.txt
```

### Log Analysis

```bash
# Check for authentication errors
grep -i "auth\|error\|fail" /var/log/azure-freeipa-sync.log

# Check for user creation
grep -i "created\|user" /var/log/azure-freeipa-sync.log

# Check for group sync
grep -i "group" /var/log/azure-freeipa-sync.log

# View last sync run
tail -n 50 /var/log/azure-freeipa-sync.log
```

## File Locations

```
/opt/azure-freeipa-sync/
├── azure_freeipa_sync.py          # Main sync script
└── azure_sync.conf                # Configuration file (auto-generated)

/usr/local/bin/
└── azure-freeipa-sync             # Symlink to main script

/var/log/
└── azure-freeipa-sync.log         # Sync log file

/etc/systemd/system/
├── azure-freeipa-sync.service     # Systemd service unit
└── azure-freeipa-sync.timer       # Systemd timer unit

/etc/ipa/
├── default.conf                   # FreeIPA config (auto-detected)
└── secrets                        # FreeIPA passwords (auto-retrieved)
```

## Security

- Configuration file permissions: `600` (root only)
- Admin credentials auto-retrieved from `/etc/ipa/secrets`
- Azure client secret stored securely in config file
- All API communication uses HTTPS/SSL
- No credentials stored in logs

## License

MIT License - See LICENSE file for details.

## Support

For issues and questions:
- Check logs: `/var/log/azure-freeipa-sync.log`
- Test with `--dry-run` flag first
- Review this README for troubleshooting steps
