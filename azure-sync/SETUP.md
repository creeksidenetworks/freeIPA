# Azure FreeIPA Sync - Setup Guide

## Quick Start for Rocky Linux 9

### Step 1: Prepare Your Environment

```bash
# Update system
sudo dnf update -y

# Install required system packages
sudo dnf install -y python3 python3-pip python3-devel gcc openssl-devel libffi-devel krb5-devel git

# Ensure FreeIPA is installed and running
sudo systemctl status ipa
```

### Step 2: Clone and Install

```bash
# Clone the repository
git clone <your-repo-url>
cd freeIPA

# Run installation script
sudo chmod +x scripts/install.sh
sudo ./scripts/install.sh
```

### Step 3: Azure Configuration

1. **Create App Registration in Azure Portal:**
   - Go to Azure Active Directory → App Registrations
   - Click "New registration"
   - Name: "FreeIPA Sync Tool"
   - Click "Register"

2. **Note the following values:**
   - Application (client) ID
   - Directory (tenant) ID

3. **Create Client Secret:**
   - Go to "Certificates & secrets"
   - Click "New client secret"
   - Copy the secret VALUE (not the ID)

4. **Set API Permissions:**
   - Go to "API permissions"
   - Add "Microsoft Graph" → "Application permissions"
   - Add: `User.Read.All`, `Group.Read.All`, `GroupMember.Read.All`
   - Click "Grant admin consent"

### Step 4: Configure the Sync Tool

```bash
# Edit configuration file
sudo nano /etc/azure_sync.conf
```

**Minimum required configuration:**

```ini
[azure]
tenant_id="your-tenant-id-from-azure"
client_id="your-client-id-from-azure"
client_secret="your-client-secret-from-azure"

[freeipa]
server="your-freeipa-server.com"
domain="your-domain.com"
realm="YOUR-REALM.COM"
admin_user="admin"
admin_password="your-freeipa-admin-password"
```

### Step 5: Test and Validate

```bash
# Validate configuration
sudo python3 /opt/freeipa-sync/validate_config.py

# Test with dry run
sudo /opt/freeipa-sync/test_sync.sh

# If tests pass, run actual sync
cd /opt/freeipa-sync
sudo python3 azure_freeipa_sync.py
```

### Step 6: Enable Automatic Sync (Optional)

```bash
# Enable daily automatic sync
sudo systemctl start azure-freeipa-sync.timer
sudo systemctl enable azure-freeipa-sync.timer

# Check timer status
sudo systemctl status azure-freeipa-sync.timer
```

## Troubleshooting

### Common Azure Issues

**Authentication Failed:**
- Verify tenant ID, client ID, and client secret
- Ensure API permissions are granted with admin consent
- Check that the App Registration is in the correct tenant

**Permission Denied:**
- Verify the app has the required Graph API permissions
- Ensure admin consent has been granted
- Check that the service principal is not disabled

### Common FreeIPA Issues

**Connection Failed:**
- Verify FreeIPA service is running: `sudo systemctl status ipa`
- Check server hostname and port accessibility
- Verify admin credentials

**User Creation Failed:**
- Check FreeIPA domain and realm settings
- Verify admin user has sufficient privileges
- Check for conflicting usernames

### Log Files

```bash
# Main sync log
sudo tail -f /var/log/azure_freeipa_sync.log

# New user passwords (sensitive!)
sudo tail -f /var/log/freeipa_new_passwords.log

# System service logs
sudo journalctl -u azure-freeipa-sync.service -f
```

## Security Best Practices

1. **Secure Configuration Files:**
   ```bash
   sudo chmod 600 /etc/azure_sync.conf
   sudo chown root:root /etc/azure_sync.conf
   ```

2. **Monitor Password Log:**
   ```bash
   sudo chmod 600 /var/log/freeipa_new_passwords.log
   sudo chown root:root /var/log/freeipa_new_passwords.log
   ```

3. **Regular Security Updates:**
   ```bash
   sudo dnf update -y
   pip3 install --upgrade -r /opt/freeipa-sync/requirements.txt
   ```

## Advanced Configuration

### Custom Attribute Mapping

Edit the `[mapping]` section in `/etc/azure_sync.conf`:

```ini
[mapping]
givenName="givenname"
surname="sn"  
userPrincipalName="uid"
mail="mail"
department="departmentnumber"
jobTitle="title"
telephoneNumber="telephonenumber"
# Add custom mappings as needed
```

### Selective Group Sync

To sync only specific groups:

```ini
[azure]
sync_groups="Group1,Group2,Group3"
```

### User Filtering

To sync only users matching specific criteria:

```ini
[azure]
user_filter="startswith(userPrincipalName,'company')"
```

## Manual Commands

```bash
# Dry run (test mode)
sudo python3 /opt/freeipa-sync/azure_freeipa_sync.py --dry-run

# Verbose logging
sudo python3 /opt/freeipa-sync/azure_freeipa_sync.py --verbose

# Custom config file
sudo python3 /opt/freeipa-sync/azure_freeipa_sync.py -c /path/to/config.conf

# One-time sync
sudo systemctl start azure-freeipa-sync.service

# Check service status
sudo systemctl status azure-freeipa-sync.service
```