# Keycloak with FreeIPA Backend Setup Guide

## Overview

This guide provides step-by-step instructions for setting up Keycloak with FreeIPA LDAP backend, email OTP authentication, and Nginx Proxy Manager reverse proxy.

## Architecture

- **Keycloak**: Identity and Access Management (IAM)
- **PostgreSQL**: Keycloak database backend
- **FreeIPA**: LDAP user directory (authentication backend)
- **Nginx Proxy Manager**: Reverse proxy with SSL termination
- **Email OTP Extension**: Custom authenticator for email-based 2FA

## Prerequisites

- Docker and Docker Compose installed
- FreeIPA server running and accessible
- SMTP server for email delivery
- Domain name configured (keycloak.innosilicon.com)

## Initial Deployment

### 1. Start Services

```bash
cd /root/freeIPA/keycloak
docker compose up -d
```

This will start:
- PostgreSQL database
- Keycloak server
- Nginx Proxy Manager

### 2. Verify Services

```bash
docker ps
```

Expected containers:
- `keycloak` - Keycloak IAM server
- `keycloak-postgres` - PostgreSQL database
- `nginx-proxy-manager` - Reverse proxy

### 3. Access Keycloak

- **Internal**: http://localhost:8080
- **External**: https://keycloak.innosilicon.com (after NPM configuration)
- **Admin credentials**: 
  - Username: `admin`
  - Password: `admin_password` (from `.env` file)

**⚠️ IMPORTANT**: Change the admin password after first login!

## Realm Setup

### Create New Realm

1. Login to Keycloak Admin Console
2. Click the dropdown in the top-left (shows "master")
3. Click **"Create Realm"**
4. Configure:
   - **Realm name**: `innosilicon`
   - **Enabled**: ON
5. Click **"Create"**

### Configure Realm Settings

1. Go to **Realm settings**
2. **General tab**:
   - **Display name**: `Innosilicon`
   - **Frontend URL**: Leave empty (uses KC_HOSTNAME from environment)
   - **Require SSL**: External requests (recommended)

3. **Email tab** (for OTP and notifications):
   - **From**: `alert@innosilicon.com`
   - **From display name**: `Keycloak`
   - **Host**: `smtp.office365.com`
   - **Port**: `587`
   - **Authentication**: Enabled
   - **Username**: `alert@innosilicon.com`
   - **Password**: `psgymbjfwxbynrgb`
   - **Enable StartTLS**: Enabled
   - **Enable SSL**: Disabled
   - Click **"Save"**
   - Click **"Test connection"** to verify

## FreeIPA LDAP Integration

### Configure LDAP User Federation

1. Go to **User Federation**
2. Click **"Add provider"** → Select **"ldap"**

### LDAP Configuration

**General Settings:**
- **Console Display Name**: `FreeIPA`
- **Enabled**: ON
- **Vendor**: `Red Hat Directory Server`

**Connection and Authentication Settings:**
- **Connection URL**: `ldap://ipa1.inno.lcl:389`
- **Bind Type**: `simple`
- **Bind DN**: `uid=ldapauth,cn=sysaccounts,cn=etc,dc=inno,dc=lcl`
- **Bind Credential**: `ZRJokBADxuct` (your FreeIPA service account password)

**LDAP Searching and Updating:**
- **Edit Mode**: `READ_ONLY` (recommended - FreeIPA remains source of truth)
- **Users DN**: `cn=users,cn=accounts,dc=inno,dc=lcl`
- **Username LDAP attribute**: `uid`
- **RDN LDAP attribute**: `uid`
- **UUID LDAP attribute**: `ipaUniqueID`
- **User Object Classes**: `inetOrgPerson, organizationalPerson`
- **Search Scope**: `Subtree`

**Connection Settings:**
- **Use Truststore SPI**: `Only for ldaps`
- **Connection Pooling**: ON
- **Connection Timeout**: `5000`
- **Read Timeout**: `5000`

**Synchronization Settings:**
- **Import Users**: ON
- **Sync Registrations**: OFF (for READ_ONLY mode)
- **Periodic Full Sync**: ON
- **Full Sync Period**: `60000` (60 seconds, adjust as needed)
- **Batch Size**: `1000`

### Save and Test

1. Click **"Save"** at the bottom
2. Click **"Test connection"** → Should show success
3. Click **"Test authentication"** → Should show success
4. Click **"Sync all users"** → Should import all FreeIPA users

**Expected Result**: Message showing "X users added, Y users updated"

### Verify User Import

1. Go to **Users** (left menu)
2. Click **"View all users"**
3. You should see all imported FreeIPA users

## Email OTP Authentication Setup

### Email OTP Extension

The custom email OTP authenticator is located in:
- **Path**: `providers/keycloak-2fa-email-authenticator.jar`
- **Source**: https://github.com/mesutpiskin/keycloak-2fa-email-authenticator
- **Built with**: Java 21, Maven 3.9

This extension is automatically loaded via the Docker volume mount in `docker-compose.yml`.

### Configure Authentication Flow

#### 1. Create Custom Authentication Flow

1. Go to **Authentication** → **Flows**
2. Click **"Create flow"**
3. Configure:
   - **Name**: `Browser with Email OTP`
   - **Flow type**: `Basic flow`
   - **Description**: `Browser authentication with email OTP as second factor`
4. Click **"Create"**

#### 2. Add Authentication Steps

Click on your new flow, then add the following executions:

**Step 1: Cookie (Alternative)**
1. Click **"Add step"**
2. Select **"Cookie"**
3. Requirement: **Alternative**

**Step 2: Identity Provider Redirector (Alternative)**
1. Click **"Add step"**
2. Select **"Identity Provider Redirector"**
3. Requirement: **Alternative**

**Step 3: Create Subflow for Username/Password + OTP**
1. Click **"Add flow"**
2. Name: `Forms`
3. Requirement: **Alternative**

**Step 4: Inside the Forms subflow, add:**
1. Click **"Add step"** (inside Forms subflow)
2. Select **"Username Password Form"**
3. Requirement: **Required**

**Step 5: Add Email OTP**
1. Still inside Forms subflow, click **"Add step"**
2. Select **"Email Code"** or **"Email Code Form"**
3. Requirement: **Required**

#### 3. Bind the Flow

1. Go to **Authentication** → **Flows**
2. At the top, click on the **"Action"** menu (three dots)
3. Select **"Bind flow"**
4. Choose: **Browser flow**
5. Click **"Save"**

### OTP Configuration (Optional)

Go to **Authentication** → **Policies** → **OTP Policy**:

- **OTP Hash Algorithm**: `SHA256` (recommended)
- **Number of Digits**: `6`
- **OTP Token Period**: `300` seconds (5 minutes for email OTP)
- **Look Ahead Window**: `1`

Click **"Save"**

## Nginx Proxy Manager Configuration

### Access NPM Admin

- URL: http://your-server-ip:81
- Default credentials (first time only):
  - Email: `admin@example.com`
  - Password: `changeme`

### Add Keycloak Proxy Host

1. Go to **Hosts** → **Proxy Hosts**
2. Click **"Add Proxy Host"**

**Details Tab:**
- **Domain Names**: `keycloak.innosilicon.com`
- **Scheme**: `http`
- **Forward Hostname/IP**: `keycloak` (container name)
- **Forward Port**: `8080`
- **Cache Assets**: OFF
- **Block Common Exploits**: ON
- **Websockets Support**: ON

**SSL Tab:**
- **SSL Certificate**: Select existing or request new Let's Encrypt certificate
- **Force SSL**: ON
- **HTTP/2 Support**: ON
- **HSTS Enabled**: ON
- **HSTS Subdomains**: OFF

**Advanced Tab:**
Add the following custom Nginx configuration:

```nginx
proxy_buffer_size          128k;
proxy_buffers              4 256k;
proxy_busy_buffers_size    256k;

# Pass proper headers
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# Increase timeouts for Keycloak
proxy_connect_timeout 300s;
proxy_send_timeout 300s;
proxy_read_timeout 300s;
```

3. Click **"Save"**

### Verify Access

Access https://keycloak.innosilicon.com - you should see the Keycloak welcome page.

## Firewall Configuration

If using firewall (firewalld on Rocky Linux):

```bash
# Add Keycloak port (if accessing directly without proxy)
sudo firewall-cmd --permanent --add-port=8080/tcp

# NPM ports (should already be open)
# Port 80/443 for HTTP/HTTPS
# Port 81 for NPM admin console

# Reload firewall
sudo firewall-cmd --reload

# Verify
firewall-cmd --list-ports
```

## Testing the Setup

### Test User Login with Email OTP

1. Go to https://keycloak.innosilicon.com
2. Access the realm: `https://keycloak.innosilicon.com/realms/innosilicon/account`
3. Enter FreeIPA username (e.g., `jtong`)
4. Enter FreeIPA password
5. Check email for OTP code
6. Enter the OTP code
7. You should be logged in successfully

### Troubleshooting Login Issues

If login fails:

1. **Check LDAP connection**: 
   - Go to User Federation → FreeIPA
   - Click "Test connection" and "Test authentication"

2. **Verify user exists**:
   - Go to Users → Search for the username
   - User should exist with FreeIPA federation link

3. **Check email configuration**:
   - Go to Realm Settings → Email
   - Click "Test connection"

4. **Review logs**:
   ```bash
   docker logs keycloak --tail 100
   ```

## Backup and Maintenance

### Backup PostgreSQL Database

```bash
docker exec keycloak-postgres pg_dump -U keycloak keycloak > keycloak_backup_$(date +%Y%m%d).sql
```

### Restore Database

```bash
cat keycloak_backup_YYYYMMDD.sql | docker exec -i keycloak-postgres psql -U keycloak -d keycloak
```

### Update Keycloak

1. Backup database first
2. Pull new image:
   ```bash
   docker compose pull keycloak
   ```
3. Restart:
   ```bash
   docker compose up -d keycloak
   ```

### LDAP Sync Management

Users are synced automatically every 60 seconds (configurable). To manually sync:

1. Go to **User Federation** → **FreeIPA**
2. Scroll to bottom
3. Click **"Sync all users"** or **"Sync changed users"**

## Security Recommendations

### 1. Change Default Passwords

Update in `.env` file:
- `KEYCLOAK_ADMIN_PASSWORD`
- `POSTGRES_PASSWORD`

Then recreate containers:
```bash
docker compose down
docker compose up -d
```

### 2. Enable HTTPS Only

In production, ensure:
- NPM force SSL is enabled
- `KC_HOSTNAME_STRICT_HTTPS=true` in docker-compose.yml
- Disable HTTP port 8080 exposure (remove from ports section)

### 3. Secure PostgreSQL

PostgreSQL is only accessible within the Docker network. Keep it that way - don't expose port 5432 externally.

### 4. Regular Updates

- Keep Keycloak, PostgreSQL, and NPM images updated
- Monitor security advisories
- Backup before updates

### 5. LDAP Service Account

The FreeIPA service account (`ldapauth`) has read-only access. Keep credentials secure:
- Store in `.env` file (gitignored)
- Use strong password
- Rotate periodically

## Configuration Files

### Environment Variables (.env)

```env
# PostgreSQL Database Configuration
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=change_this_password

# Keycloak Admin Credentials
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=change_this_password

# Keycloak HTTP Port
KEYCLOAK_HTTP_PORT=8080
```

### Docker Compose Structure

- **Services**: keycloak, postgres, npm
- **Networks**: keycloak_network (bridge)
- **Volumes**: 
  - postgres_data (persistent database)
  - ./providers (email OTP extension)
  - ./npm/data (NPM configuration)
  - ./npm/letsencrypt (SSL certificates)

## Additional Resources

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)
- [Nginx Proxy Manager](https://nginxproxymanager.com/guide/)
- [Email OTP Extension](https://github.com/mesutpiskin/keycloak-2fa-email-authenticator)

## Support and Troubleshooting

### Common Issues

**Issue**: Keycloak won't start after adding extension
- Check logs: `docker logs keycloak`
- Verify jar file is not corrupted: `ls -lh providers/`
- Remove bad jar files and restart

**Issue**: Email OTP not appearing in flows
- Verify extension is mounted: `docker exec keycloak ls /opt/keycloak/providers/`
- Restart Keycloak: `docker compose restart keycloak`
- Check Keycloak version compatibility

**Issue**: Users can't login with FreeIPA credentials
- Verify LDAP connection and authentication tests pass
- Check user exists in Keycloak: Users → Search
- Review Keycloak logs for authentication errors
- Verify FreeIPA server is accessible from container

**Issue**: Email OTP codes not received
- Test SMTP connection in Realm Settings → Email
- Check spam/junk folders
- Verify user has email attribute in FreeIPA
- Review Keycloak logs for SMTP errors

### Getting Logs

```bash
# Keycloak logs
docker logs keycloak --tail 100 -f

# PostgreSQL logs
docker logs keycloak-postgres --tail 100

# All services
docker compose logs -f
```

### Restart Services

```bash
# Restart all
docker compose restart

# Restart specific service
docker compose restart keycloak

# Full restart (recreate containers)
docker compose down
docker compose up -d
```

## Version Information

- **Keycloak**: 26.4.5
- **PostgreSQL**: 15
- **Nginx Proxy Manager**: latest
- **Email OTP Extension**: 1.0.0 (custom built)
- **FreeIPA**: (external, version varies)

---

**Last Updated**: November 16, 2025
**Maintained By**: Innosilicon IT Team
