# FreeIPA Installation Scripts

Automated installa### install-radius.sh
Installs FreeRADIUS with FreeIPA LDAP backend.

**Prerequisites:** FreeIPA must be installed first

**Arguments:**
- `-p <password>` - Admin password (reads from `/etc/ipa/secrets` if omitted)
- `-s <secret>` - RADIUS client secret (random if not provided)

**Examples:**
```bash
# Use passwords from /etc/ipa/secrets
sudo ./install-radius.sh

# Provide Admin password
sudo ./install-radius.sh -p MyAdminPass123
```FreeIPA server and FreeRADIUS on Rocky Linux 8/9.

## Quick Start

### Install Standalone FreeIPA Server
```bash
sudo ./install-ipa.sh -h ipa.example.com
```

### Install Replica Server
```bash
sudo ./install-ipa.sh -h ipa2.example.com -r -p AdminPassword
```

### Install FreeRADIUS (After FreeIPA)
```bash
sudo ./install-radius.sh
```

## Scripts

### install-ipa.sh
Installs FreeIPA server in standalone or replica mode.

**Arguments:**
- `-h <fqdn>` - IPA FQDN (required) - e.g., `ipa.example.com`
- `-r` - Replica mode (omit for standalone)
- `-p <password>` - Admin password (random if not provided)
- `-d <password>` - Directory Manager password (optional, not needed for FreeRADIUS)

**Examples:**
```bash
# Standalone with auto-generated passwords
sudo ./install-ipa.sh -h ipa.example.com

# Replica with admin password (recommended)
sudo ./install-ipa.sh -h ipa2.example.com -r -p MyAdminPass123

# Custom passwords (DM password optional)
sudo ./install-ipa.sh -h ipa.example.com -p MyAdminPass123
```

**What it does:**
- Checks if network interface has static IP (converts from DHCP if needed)
- Installs FreeIPA with DNS, CA, and AD trust
- Configures hostname and firewall
- For replicas: joins domain as client, promotes to replica
- Saves credentials to `/etc/ipa/secrets`

### install-radius.sh
Installs FreeRADIUS with FreeIPA LDAP backend.

**Prerequisites:** FreeIPA must be installed first

**Arguments:**
- `-a <password>` - Admin password (reads from `/etc/ipa/secrets` if omitted)
- `-s <secret>` - RADIUS client secret (random if not provided)

**Examples:**
```bash
# Use passwords from /etc/ipa/secrets
sudo ./install-radius.sh

# Provide Admin password
sudo ./install-radius.sh -a MyAdminPass123
```

**What it does:**
- Creates service account `rad-auth` in FreeIPA for RADIUS LDAP authentication
- Installs FreeRADIUS packages
- Configures LDAP authentication with ipaNTHash (MS-CHAPv2)
- Extracts group membership as RADIUS Class attributes
- Updates `/etc/ipa/secrets` with service account and RADIUS secrets

## Complete Installation Examples

### Standalone Server with RADIUS
```bash
# Step 1: Install FreeIPA
sudo ./install-ipa.sh -h ipa.example.com

# Step 2: Install FreeRADIUS
sudo ./install-radius.sh
```

### Replica Server with RADIUS
```bash
# Step 1: Install FreeIPA replica (admin password required)
sudo ./install-ipa.sh -h ipa2.example.com -r -p AdminPass

# Step 2: Install FreeRADIUS (will use admin credentials)
sudo ./install-radius.sh
```

## Post-Installation

**Access Web Interface:**
```
https://ipa.example.com
Username: admin
Password: (check /etc/ipa/secrets)
```

**Test RADIUS:**
```bash
radtest username password 127.0.0.1 0 <radius-secret>
```

**Check Status:**
```bash
ipactl status
systemctl status radiusd
```

**View Credentials:**
```bash
cat /etc/ipa/secrets
```

## Prerequisites

- Rocky Linux 8 or 9 (or RHEL 8/9)
- Network interface with IP address (can be DHCP, will be converted to static)
- Root privileges
- DNS resolution (for replicas)
- Min 2GB RAM, 10GB disk

## Firewall Ports

Automatically opened:
- DNS (53)
- LDAP/LDAPS (389/636)
- Kerberos (88, 464)
- HTTP/HTTPS (80/443)
- RADIUS (1812/1813)
- FreeIPA replication

## Troubleshooting

**Check logs:**
```bash
tail -f /tmp/install-ipa-*.log
tail -f /var/log/ipaserver-install.log
tail -f /var/log/ipaclient-install.log
```

**Test RADIUS in debug mode:**
```bash
systemctl stop radiusd
radiusd -X
```

**Uninstall client (to rejoin):**
```bash
ipa-client-install --uninstall
```

**Remove replica server (on primary):**
```bash
ipa server-del ipa2.example.com --force
```

## Configuration Files

**FreeIPA:**
- `/etc/ipa/default.conf` - IPA configuration
- `/etc/ipa/secrets` - Stored passwords

**FreeRADIUS:**
- `/etc/raddb/mods-available/ipa-ldap` - LDAP module (uses radauth service account)
- `/etc/raddb/sites-available/ipa` - IPA site config
- `/etc/raddb/clients.conf` - RADIUS clients

## Notes

- **Passwords**: Saved in `/etc/ipa/secrets` (mode 600)
- **Replicas**: Admin password required for domain join
- **Service Account**: FreeRADIUS uses `radauth` service account (not Directory Manager)
- **FreeRADIUS on replicas**: Requires admin password to create service account
- **Logs**: Keep installation logs for troubleshooting

## References

- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)
- [FreeRADIUS Documentation](https://freeradius.org/documentation/)
