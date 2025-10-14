# FreeIPA Installation Script for Rocky Linux 8/9

This script automates the installation and configuration of FreeIPA server with FreeRADIUS integration on Rocky Linux 8 and 9.

## Features

- **Standalone FreeIPA Server**: Installs a primary FreeIPA server with DNS, CA, and AD trust support
- **Replica FreeIPA Server**: Installs a FreeIPA replica server  
- **FreeRADIUS Integration**: Configures FreeRADIUS with LDAP backend using ipaNTHash for MS-CHAPv2 authentication
- **Rocky Linux Support**: Properly configures IDM repositories for Rocky Linux 8/9
- **Automated Configuration**: Handles hostname, firewall, and network configuration
- **Password Management**: Generates secure random passwords if not provided

## Prerequisites

- Rocky Linux 8 or 9 (or RHEL 8/9)
- Static IP address configured
- Root privileges
- Proper DNS resolution (recommended)
- At least 2GB RAM and 10GB disk space

## Usage

```bash
# Make script executable
chmod +x install-ipa.sh

# Install standalone FreeIPA server
sudo ./install-ipa.sh -h ipa.example.com

# Install replica server
sudo ./install-ipa.sh -h ipa2.example.com -r

# Install with custom passwords
sudo ./install-ipa.sh -h ipa.example.com -d MyDMPassword123 -p MyAdminPassword123
```

## Arguments

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `-h <fqdn>` | IPA FQDN | Yes | `-h ipa.example.com` |
| `-r` | Replica mode | No | `-r` |
| `-d <password>` | Directory Manager password | No | `-d MyDMPass123` |
| `-p <password>` | Admin password | No | `-p MyAdminPass123` |

## What Gets Installed

### Standalone Mode
- FreeIPA server with DNS and CA
- AD trust support
- FreeRADIUS with LDAP authentication
- MS-CHAPv2 support using ipaNTHash
- Group membership in RADIUS replies

### Replica Mode
- FreeIPA replica server
- DNS and CA replication
- AD trust support
- FreeRADIUS (basic installation)

## Post-Installation

After successful installation:

1. **Web Interface**: Access at `https://<your-fqdn>`
2. **Admin Login**: Username `admin`, password from installation log
3. **RADIUS Testing**: Use the generated client secret for RADIUS authentication
4. **Log Files**: Check `/tmp/install-ipa-*.log` for detailed logs
5. **Passwords**: Saved to `/tmp/install-ipa-*.log.passwords`

## Directory Structure

The script creates configuration files in `/etc/creekside/radius/`:
- `radius-ldap.cfg` - LDAP authentication configuration
- `radius-clients.conf` - RADIUS clients configuration  
- `radius-default.cfg` - Default site configuration
- `mods-eap.conf` - EAP module configuration

## Firewall Configuration

The script automatically opens these services:
- `ntp` - Time synchronization
- `dns` - DNS service
- `freeipa-ldap` - LDAP
- `freeipa-ldaps` - LDAP over SSL
- `freeipa-replication` - IPA replication
- `freeipa-trust` - AD trust
- `radius` - RADIUS authentication

## Troubleshooting

### Common Issues

1. **DNS Resolution**: Ensure proper DNS setup before installation
2. **Static IP**: Script requires static IP configuration
3. **Firewall**: Check if firewalld is running and configured
4. **SELinux**: Ensure SELinux is not blocking services

### Log Analysis

```bash
# Check installation logs
tail -f /tmp/install-ipa-*.log

# Check FreeIPA status
ipactl status

# Check FreeRADIUS status
systemctl status radiusd
radiusd -X  # Debug mode
```

### Service Management

```bash
# FreeIPA services
ipactl start|stop|restart|status

# FreeRADIUS service
systemctl start|stop|restart|status radiusd

# Individual service status
systemctl status named-pkcs11 dirsrv@REALM httpd kadmin krb5kdc
```

## Security Notes

- Generated passwords are saved in `/tmp/install-ipa-*.log.passwords`
- Secure this file and move it to a safe location
- Change default passwords after installation
- Review RADIUS client configurations for your environment
- Enable additional security features as needed

## References

- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)
- [FreeRADIUS Documentation](https://freeradius.org/documentation/)
- [Rocky Linux Documentation](https://docs.rockylinux.org/)