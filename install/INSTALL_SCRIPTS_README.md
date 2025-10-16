# FreeIPA and FreeRADIUS Installation Scripts

This directory contains scripts to install and configure FreeIPA server and FreeRADIUS on Rocky Linux 8/9.

## Scripts

### 1. install-ipa.sh
Installs FreeIPA server (standalone or replica mode).

**Usage:**
```bash
sudo ./install-ipa.sh -h <fqdn> [-r] [-d <dm_password>] [-p <admin_password>]
```

**Arguments:**
- `-h <fqdn>` : IPA FQDN (e.g., ipa.example.com) - **REQUIRED**
- `-r` : Replica mode (default is standalone)
- `-d <password>` : Directory Manager password (random if not provided for standalone, optional for replica)
- `-p <password>` : Admin password (random if not provided for standalone, required for replica)
- `-?` : Show help

**Examples:**
```bash
# Install standalone FreeIPA server
sudo ./install-ipa.sh -h ipa.example.com

# Install replica server
sudo ./install-ipa.sh -h ipa2.example.com -r -p MyAdminPass123

# Install replica WITH Directory Manager password (recommended for FreeRADIUS)
sudo ./install-ipa.sh -h ipa2.example.com -r -p MyAdminPass123 -d MyDMPass123

# Install with custom passwords
sudo ./install-ipa.sh -h ipa.example.com -d MyDMPass123 -p MyAdminPass123
```

**What it does:**
- Installs FreeIPA server with DNS, CA, and AD trust support
- Configures hostname and firewall
- Generates random passwords if not provided
- Saves all secrets to `/etc/ipa/secrets`
- For replicas: joins domain as client, then promotes to replica
- **Important for replicas:** If you provide `-d` option, the Directory Manager password will be stored in `/etc/ipa/secrets` for later use by `install-radius.sh`. The DM password is shared across all servers in the FreeIPA domain.

### 2. install-radius.sh
Installs and configures FreeRADIUS to use FreeIPA LDAP backend.

**Prerequisites:**
- FreeIPA server must be installed and running
- Run this script AFTER install-ipa.sh

**Usage:**
```bash
sudo ./install-radius.sh [-d <dm_password>] [-s <radius_secret>]
```

**Arguments:**
- `-d <password>` : Directory Manager password (reads from `/etc/ipa/secrets` if not provided)
- `-s <secret>` : RADIUS client secret (random if not provided)
- `-?` : Show help

**Examples:**
```bash
# Use passwords from /etc/ipa/secrets
sudo ./install-radius.sh

# Specify Directory Manager password
sudo ./install-radius.sh -d MyDMPass123

# Specify both passwords
sudo ./install-radius.sh -d MyDMPass123 -s MyRadiusSecret123
```

**What it does:**
- Installs FreeRADIUS packages (freeradius, freeradius-ldap, freeradius-krb5, freeradius-utils)
- Creates IPA-specific LDAP module configuration (`/etc/raddb/mods-available/ipa-ldap`)
- Configures RADIUS clients (`/etc/raddb/clients.conf`)
- Creates IPA site configuration (`/etc/raddb/sites-available/ipa`)
- Enables MS-CHAPv2 authentication using ipaNTHash from LDAP
- Extracts group membership from LDAP and adds as RADIUS Class attributes
- Generates RADIUS certificates
- Saves RADIUS secret to `/etc/ipa/secrets`

## Installation Workflow

### For Standalone FreeIPA Server:
```bash
# Step 1: Install FreeIPA
sudo ./install-ipa.sh -h ipa.example.com

# Step 2: Install FreeRADIUS
sudo ./install-radius.sh
```

### For Replica Server:
```bash
# Step 1: Install FreeIPA replica (with DM password for FreeRADIUS)
sudo ./install-ipa.sh -h ipa2.example.com -r -p AdminPassword -d DMPassword

# Step 2: Install FreeRADIUS (will read DM password from /etc/ipa/secrets)
sudo ./install-radius.sh
```

**Note:** If you didn't provide `-d` option during replica installation, you can:
- Manually edit `/etc/ipa/secrets` to add the Directory Manager password
- Or use `./install-radius.sh -d DMPassword` to provide it during RADIUS installation

## Configuration Files

### FreeIPA
- **Secrets:** `/etc/ipa/secrets` - Contains Directory Manager and Admin passwords
- **Configuration:** `/etc/ipa/default.conf` - FreeIPA client configuration

### FreeRADIUS
- **LDAP Module:** `/etc/raddb/mods-available/ipa-ldap` - IPA-specific LDAP configuration
- **Site Config:** `/etc/raddb/sites-available/ipa` - IPA virtual server configuration
- **Clients:** `/etc/raddb/clients.conf` - RADIUS client definitions
- **Enabled Modules:** `/etc/raddb/mods-enabled/ipa-ldap` (symlink)
- **Enabled Sites:** `/etc/raddb/sites-enabled/ipa` (symlink)

### Secrets File Format (`/etc/ipa/secrets`)
```
# FreeIPA Installation Secrets
# Generated on: 2025-10-16 12:00:00

Directory Manager Password: <password>
Admin Password: <password>
RADIUS Client Secret: <secret>
```

## Testing RADIUS Authentication

After installation, test RADIUS authentication:

```bash
# Basic authentication test
radtest username password 127.0.0.1 0 <RADIUS_SECRET>

# Debug mode (see detailed output)
sudo radiusd -X
# In another terminal:
radtest username password 127.0.0.1 0 <RADIUS_SECRET>
```

The RADIUS response will include:
- **MS-CHAP-MPPE-Keys** - Encryption keys for MS-CHAPv2
- **Class attributes** - User's group memberships (e.g., "admins", "ipausers")

## Features

### FreeIPA Installation
- ✅ Standalone or replica mode
- ✅ DNS with auto-forwarders and reverse zones
- ✅ Integrated CA
- ✅ AD trust support
- ✅ Automatic password generation
- ✅ Firewall configuration
- ✅ Hostname configuration

### FreeRADIUS Configuration
- ✅ LDAP backend with Directory Manager authentication
- ✅ MS-CHAPv2 support using ipaNTHash
- ✅ Group membership extraction (memberOf → Class attributes)
- ✅ Separate IPA-specific configuration files
- ✅ Doesn't overwrite default FreeRADIUS configs
- ✅ Automatic certificate generation
- ✅ Support for localhost and network clients

## Troubleshooting

### FreeIPA Installation Issues
```bash
# Check FreeIPA status
sudo ipactl status

# View installation logs
cat /var/log/ipaserver-install.log
cat /tmp/install-ipa-*.log

# Check DNS
dig @localhost <domain>
```

### Replica Installation Issues
```bash
# Verify host is in ipaservers group
ipa hostgroup-show ipaservers

# Add host to ipaservers group manually
ipa hostgroup-add-member ipaservers --hosts=<fqdn>

# Check Kerberos ticket
klist
```

### FreeRADIUS Issues
```bash
# Check RADIUS status
sudo systemctl status radiusd

# Run in debug mode
sudo radiusd -X

# Check LDAP connection
ldapsearch -x -D "cn=Directory Manager" -W \
  -b "cn=accounts,dc=example,dc=com" "(uid=testuser)" ipaNTHash memberOf

# Verify configuration
sudo radiusd -C
```

### Common Errors

**Error:** "Directory Manager password required"
- **Solution:** Provide `-d` option or ensure `/etc/ipa/secrets` exists

**Error:** "Failed to start FreeRADIUS"
- **Solution:** Check `/var/log/radius/radius.log` for syntax errors

**Error:** "Host is not a member of ipaservers group"
- **Solution:** Manually add host: `ipa hostgroup-add-member ipaservers --hosts=<fqdn>`

## Security Notes

- All secrets are stored in `/etc/ipa/secrets` with 600 permissions (root only)
- Directory Manager password is used for LDAP authentication
- RADIUS client secret should be changed in production
- Default configuration allows RADIUS from any IP (0.0.0.0/0) - restrict in production

## Log Files

- FreeIPA installation: `/tmp/install-ipa-<timestamp>.log`
- FreeRADIUS installation: `/tmp/install-radius-<timestamp>.log`
- FreeIPA server logs: `/var/log/ipaserver-install.log`
- RADIUS logs: `/var/log/radius/radius.log`

## Support

For issues or questions:
1. Check logs in `/tmp/install-*.log`
2. Review FreeIPA logs: `/var/log/ipaserver-install.log`
3. Run RADIUS in debug mode: `sudo radiusd -X`
4. Check system logs: `journalctl -u radiusd -u ipa`
