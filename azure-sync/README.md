# Azure Entra ID to FreeIPA Sync

A comprehensive synchronization tool that syncs users and groups from Azure Entra ID (formerly Azure AD) to FreeIPA, designed specifically for Rocky Linux 9 environments.

## Features

- **User Synchronization**: Automatically sync users from Azure Entra ID to FreeIPA
- **Group Synchronization**: Sync groups and group memberships
- **Temporary Passwords**: Generate secure temporary passwords for new users
- **Configurable Mapping**: Map Azure attributes to FreeIPA attributes
- **Backup Support**: Automatic backup before sync operations
- **Systemd Integration**: Run as a service with timer support for scheduled syncing
- **Comprehensive Logging**: Detailed logging with log rotation
- **Dry Run Mode**: Test sync operations without making changes
- **Security-First**: Secure configuration and password handling

## Quick Start

```bash
# 1. Clone and install
git clone https://github.com/creeksidenetworks/freeIPA.git
cd freeIPA
make install

# 2. Configure Azure credentials
sudo nano /etc/azure_sync.conf

# 3. Test configuration
make test

# 4. Enable automatic sync
sudo systemctl enable --now azure-freeipa-sync.timer

# 5. Monitor status
make monitor
```

> See [SETUP.md](SETUP.md) for detailed installation instructions.

## Prerequisites

- Rocky Linux 9 server
- FreeIPA server installed and configured
- Azure Entra ID tenant with appropriate permissions
- Python 3.9 or later
- Root access for installation and FreeIPA operations

## Installation

### 1. Clone the Repository

```bash
git clone <repository-url>
cd freeIPA
```

### 2. Run the Installation Script

```bash
chmod +x scripts/install.sh
sudo ./scripts/install.sh
```

The installation script will:
- Install required system dependencies
- Create installation directories
- Install Python dependencies
- Set up systemd services
- Configure log rotation
- Apply appropriate SELinux contexts

### 3. Configure Azure App Registration

Before configuring the sync tool, you need to create an Azure App Registration:

1. Go to Azure Portal → Azure Active Directory → App Registrations
2. Click "New registration"
3. Name: "FreeIPA Sync Tool"
4. Account types: "Accounts in this organizational directory only"
5. Click "Register"

After registration:
1. Note the **Application (client) ID** and **Directory (tenant) ID**
2. Go to "Certificates & secrets" → "New client secret"
3. Create a secret and note the **Value** (not the ID)

### 4. Configure API Permissions

In your App Registration:
1. Go to "API permissions"
2. Click "Add a permission" → "Microsoft Graph" → "Application permissions"
3. Add these permissions:
   - `User.Read.All`
   - `Group.Read.All`
   - `GroupMember.Read.All`
4. Click "Grant admin consent for [Your Organization]"

### 5. Configure the Sync Tool

Edit the configuration file:

```bash
sudo nano /etc/azure_sync.conf
```

Update the following sections:

```ini
[azure]
tenant_id="your-tenant-id-here"
client_id="your-client-id-here"
client_secret="your-client-secret-here"

[freeipa]
server="ipa.yourdomain.com"
domain="yourdomain.com" 
realm="YOURDOMAIN.COM"
admin_user="admin"
admin_password="your-freeipa-admin-password"
```

## Configuration Reference

### Azure Section
- `tenant_id`: Azure tenant ID from App Registration
- `client_id`: Application ID from App Registration  
- `client_secret`: Client secret value from App Registration
- `sync_groups`: Comma-separated list of specific groups to sync (optional)
- `user_filter`: OData filter for users (optional)

### FreeIPA Section
- `server`: FreeIPA server hostname
- `domain`: FreeIPA domain name
- `realm`: FreeIPA realm (usually uppercase domain)
- `admin_user`: FreeIPA admin username
- `admin_password`: FreeIPA admin password
- `default_shell`: Default shell for new users
- `default_home_base`: Base directory for home folders
- `temp_password_length`: Length of generated temporary passwords
- `password_expiry_days`: Days until password expires

### Sync Section
- `dry_run`: Set to `true` to test without making changes
- `log_level`: Logging level (DEBUG, INFO, WARNING, ERROR)
- `log_file`: Path to main log file
- `backup_enabled`: Enable/disable automatic backups
- `backup_directory`: Directory for backup files
- `batch_size`: Number of users to process in each batch
- `max_retries`: Maximum retry attempts for failed operations
- `retry_delay`: Delay between retry attempts (seconds)

### Mapping Section
Configure how Azure attributes map to FreeIPA attributes:

```ini
[mapping]
givenName="givenname"
surname="sn"
userPrincipalName="uid"
mail="mail"
department="departmentnumber"
jobTitle="title"
telephoneNumber="telephonenumber"
```

## Usage

### Test Configuration

```bash
sudo /opt/freeipa-sync/test_sync.sh
```

### Manual Sync (Dry Run)

```bash
cd /opt/freeipa-sync
sudo python3 azure_freeipa_sync.py --dry-run
```

### Manual Sync (Production)

```bash
cd /opt/freeipa-sync  
sudo python3 azure_freeipa_sync.py
```

### Enable Automatic Daily Sync

```bash
sudo systemctl start azure-freeipa-sync.timer
sudo systemctl enable azure-freeipa-sync.timer
```

### Check Service Status

```bash
sudo systemctl status azure-freeipa-sync.timer
sudo systemctl status azure-freeipa-sync.service
```

### View Logs

```bash
# Main sync log
sudo tail -f /var/log/azure_freeipa_sync.log

# New user passwords (SECURE - only for admin reference)
sudo tail -f /var/log/freeipa_new_passwords.log

# Service logs
sudo journalctl -u azure-freeipa-sync.service -f
```

## Security Considerations

### File Permissions
- Configuration file: `600` (root only)
- Password log: `600` (root only)  
- Script files: `755` (executable by all, writable by root)

### Password Security
- Temporary passwords are generated with secure random methods
- Passwords are logged to a secure file for administrative reference
- Users are forced to change password on first login
- Password expiry can be configured

### Network Security
- All Azure API communication uses HTTPS
- FreeIPA API uses secure protocols
- Consider firewall rules for FreeIPA access

## Troubleshooting

### Common Issues

1. **Authentication Errors**
   - Verify Azure App Registration permissions
   - Check tenant ID, client ID, and client secret
   - Ensure admin consent is granted

2. **FreeIPA Connection Issues**
   - Verify FreeIPA service is running: `systemctl status ipa`
   - Check FreeIPA admin credentials
   - Verify server hostname and realm settings

3. **Permission Errors**
   - Ensure script is run as root
   - Check SELinux contexts if enabled
   - Verify file permissions on config and log files

### Debug Mode

Run with verbose logging:

```bash
sudo python3 azure_freeipa_sync.py --verbose --dry-run
```

### Log Analysis

Check logs for specific error patterns:

```bash
# Check for authentication errors
sudo grep -i "auth" /var/log/azure_freeipa_sync.log

# Check for user creation issues
sudo grep -i "user" /var/log/azure_freeipa_sync.log

# Check for group sync issues  
sudo grep -i "group" /var/log/azure_freeipa_sync.log
```

## Project Structure

### Source Repository
```
freeIPA/
├── README.md                           # Main documentation
├── SETUP.md                           # Quick start guide
├── LICENSE                            # License file
├── requirements.txt                   # Python dependencies
├── src/                              # Source code
│   ├── azure_freeipa_sync.py         # Main sync application
│   └── validate_config.py            # Configuration validator
├── scripts/                          # Installation & management
│   ├── install.sh                    # Installation script
│   ├── uninstall.sh                  # Uninstall script
│   ├── monitor.sh                    # Monitoring script
│   └── add_binddn.sh                 # Legacy script
├── config/                           # Configuration templates
│   ├── azure_sync.conf.example       # Configuration template
│   └── systemd/                      # Systemd service files
│       ├── azure-freeipa-sync.service
│       └── azure-freeipa-sync.timer
└── docs/                             # Additional documentation
```

### Installation Layout
```
/opt/freeipa-sync/
├── azure_freeipa_sync.py    # Main sync script
├── validate_config.py       # Configuration validator
├── monitor.sh              # Monitor script
└── test_sync.sh            # Test script

/etc/
└── azure_sync.conf         # Configuration file

/var/log/
├── azure_freeipa_sync.log  # Main log file
└── freeipa_new_passwords.log # New user passwords (secure)

/var/backups/freeipa-sync/   # Backup directory

/etc/systemd/system/
├── azure-freeipa-sync.service # Systemd service
└── azure-freeipa-sync.timer   # Systemd timer
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly on Rocky Linux 9
5. Submit a pull request

## License

See LICENSE file for details.

## Support

For issues and questions:
1. Check the troubleshooting section
2. Review log files for error details
3. Create an issue in the repository with:
   - Rocky Linux version
   - FreeIPA version
   - Error logs (sanitized)
   - Configuration (without secrets)
