# FreeIPA Replica Installation Process

## Overview

When installing a FreeIPA replica server, the script now follows the modern best practice approach:

```
Standalone Server → Client Join → Replica Promotion
```

## Step-by-Step Process

### 1. **Initial Validation**
- Validates FQDN format and network configuration
- Checks if server is already joined to domain
- Installs required packages including `ipa-client`

### 2. **Domain Join (ipa-client-install)**
```bash
# Automatic discovery or manual server specification
ipa-client-install \
    --server=primary-ipa.domain.com \
    --domain=domain.com \
    --realm=DOMAIN.COM \
    --hostname=replica.domain.com \
    --principal=admin \
    --password=AdminPassword \
    --mkhomedir \
    --unattended
```

### 3. **Host Group Membership** ⚠️ **CRITICAL STEP**
```bash
# Add to ipaservers group (REQUIRED for replica promotion)
ipa hostgroup-add-member ipaservers --hosts=replica.domain.com

# Verify membership before proceeding
ipa hostgroup-show ipaservers --hosts
```

**Why this is required:**
- The `ipaservers` hostgroup grants the necessary permissions for replica services
- Without this membership, `ipa-replica-install` will fail with permission errors
- The script automatically handles this step and verifies it

### 4. **Replica Promotion (ipa-replica-install)**
```bash
ipa-replica-install \
    --setup-adtrust \
    --setup-ca \
    --setup-dns \
    --mkhomedir \
    --allow-zone-overlap \
    --auto-reverse \
    --auto-forwarders \
    --unattended
```

## Usage Examples

### Basic Replica Installation
```bash
sudo ./install-ipa.sh -h ipa2.domain.com -r -p AdminPassword123
```

### Interactive Mode (prompts for password)
```bash
sudo ./install-ipa.sh -h ipa2.domain.com -r
# You'll be prompted for admin password during installation
```

## Prerequisites for Replica

1. **Existing FreeIPA Domain**: Primary server must be running and accessible
2. **DNS Resolution**: Must be able to resolve primary server FQDN
3. **Admin Credentials**: Valid admin username/password for domain join
4. **Network Access**: Ports 88, 464, 389, 636, 53, 80, 443 accessible
5. **Time Synchronization**: NTP configured and synchronized

## Automatic Server Discovery

The script attempts to discover the primary server automatically using DNS:

```bash
# Looks for SRV records
dig +short _ldap._tcp.domain.com SRV
```

If auto-discovery fails, you'll be prompted to enter the primary server FQDN manually.

## What Happens During Installation

### Client Join Phase
- Configures Kerberos client (`/etc/krb5.conf`)
- Sets up SSSD for authentication (`/etc/sssd/sssd.conf`)
- Configures NSS and PAM for IPA users
- Creates home directories automatically
- Obtains host certificate

### Replica Promotion Phase  
- Installs Directory Server (389-ds)
- Sets up CA replication (if primary has CA)
- Configures DNS replication
- Sets up Kerberos KDC
- Configures Apache for web interface
- Sets up AD trust components

## Verification

After successful installation:

```bash
# Check IPA services
ipactl status

# Verify replication
ipa-replica-conncheck

# Test authentication
kinit admin

# Check server list
ipa server-find
```

## Troubleshooting

### Common Issues

1. **DNS Resolution**: Ensure primary server is resolvable
   ```bash
   nslookup primary-ipa.domain.com
   ```

2. **Time Synchronization**: Check NTP sync
   ```bash
   chrony sources -v
   ```

3. **Firewall**: Verify ports are open
   ```bash
   firewall-cmd --list-services
   ```

4. **Kerberos**: Check ticket acquisition
   ```bash
   kinit admin
   klist
   ```

### Log Files

- **Client Join**: `/var/log/ipaclient-install.log`  
- **Replica Install**: `/var/log/ipareplica-install.log`
- **Script Logs**: `/tmp/install-ipa-*.log`

## Differences from Old Approach

### Old Method (centos.sh)
```bash
# Direct replica install (unreliable)
ipa-replica-install replica-file.tar.gz
```

### New Method (install-ipa.sh)  
```bash
# Modern approach: client join + promotion
ipa-client-install + ipa-replica-install
```

The new approach is more reliable and follows current FreeIPA best practices.