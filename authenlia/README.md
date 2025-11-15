# Authelia + Nginx Proxy Manager + FreeIPA Integration

This setup provides secure authentication for FreeIPA (`ipa1.innosilicon.com`) using Authelia with FreeIPA LDAP backend and Nginx Proxy Manager as the reverse proxy.

## Architecture

- **Authelia**: Authentication portal with FreeIPA LDAP integration
- **Nginx Proxy Manager**: Reverse proxy with SSL/TLS termination
- **Redis**: Session storage for Authelia
- **FreeIPA**: LDAP authentication backend

## Prerequisites

1. Docker and Docker Compose installed
2. FreeIPA server running at `ipa1.insc.lcl` (internal)
3. DNS records configured:
   - `auth.innosilicon.com` → Your server IP
   - `ipa1.innosilicon.com` → Your server IP
4. FreeIPA service account created for Authelia LDAP binding

## FreeIPA Setup

### 1. Create Service Account in FreeIPA

```bash
# SSH into your FreeIPA server
ssh admin@ipa1.insc.lcl

# Authenticate
kinit admin

# Create a service account for Authelia
ipa user-add authelia --first=Authelia --last=Service --shell=/sbin/nologin

# Set a password for the service account
ipa passwd authelia

# Optional: Create a group for users who can access through Authelia
ipa group-add authelia-users --desc="Users with Authelia access"
```

## Installation & Configuration

### 1. Clone and Configure

```bash
cd /root/freeIPA/authenlia

# Copy the example environment file
cp .env.example .env

# Edit the .env file with your settings
nano .env
```

### 2. Generate Secrets

Generate secure random secrets for Authelia:

```bash
# Generate secrets (run this 3 times for different values)
openssl rand -hex 32
```

Update the following in `.env`:
- `LDAP_BIND_PASSWORD`: Password for the FreeIPA service account
- `AUTHELIA_JWT_SECRET`: First generated secret
- `AUTHELIA_SESSION_SECRET`: Second generated secret
- `AUTHELIA_STORAGE_ENCRYPTION_KEY`: Third generated secret

### 3. Update Authelia Configuration

Edit `authelia/configuration.yml` and update:

1. **LDAP settings** (lines 48-75):
   - Verify `base_dn` matches your FreeIPA domain
   - Update `user` and `password` with service account credentials

2. **Session secret** (line 110):
   - Replace `YOUR_SESSION_SECRET_CHANGE_ME` with generated secret

3. **Storage encryption key** (line 134):
   - Replace `YOUR_STORAGE_ENCRYPTION_KEY_CHANGE_ME` with generated secret

4. **Access control rules** (lines 85-98):
   - Adjust groups (`admins`, `ipausers`) based on your FreeIPA groups
   - Change policy to `one_factor` if you don't want 2FA initially

### 4. Start Services

```bash
# Create necessary directories
mkdir -p authelia redis npm/data npm/letsencrypt nginx-configs

# Set proper permissions
chmod 700 authelia
chmod 600 authelia/configuration.yml

# Start all services
docker-compose up -d

# Check logs
docker-compose logs -f authelia
docker-compose logs -f nginx-proxy-manager
```

## Nginx Proxy Manager Configuration

### 1. Access NPM Admin Panel

1. Open browser: `http://YOUR_SERVER_IP:81`
2. Default credentials:
   - Email: `admin@example.com`
   - Password: `changeme`
3. **Change password immediately!**

### 2. Configure Authelia Proxy Host

**Add Proxy Host for Authelia:**

1. Go to **Hosts** → **Proxy Hosts** → **Add Proxy Host**
2. **Details Tab:**
   - Domain Names: `auth.innosilicon.com`
   - Scheme: `http`
   - Forward Hostname/IP: `authelia`
   - Forward Port: `9091`
   - Cache Assets: ✓
   - Block Common Exploits: ✓
   - Websockets Support: ✓

3. **SSL Tab:**
   - SSL Certificate: Request a new SSL Certificate with Let's Encrypt
   - Force SSL: ✓
   - HTTP/2 Support: ✓
   - HSTS Enabled: ✓
   - Email: Your email address
   - Agree to ToS: ✓

4. **Custom Nginx Configuration Tab:**
   ```nginx
   # Include the Authelia location block
   include /snippets/authelia-location.conf;
   ```

5. Save

### 3. Configure FreeIPA Proxy Host with Authelia Protection

**Add Proxy Host for FreeIPA:**

1. Go to **Hosts** → **Proxy Hosts** → **Add Proxy Host**
2. **Details Tab:**
   - Domain Names: `ipa1.innosilicon.com`
   - Scheme: `https`
   - Forward Hostname/IP: `ipa1.insc.lcl`
   - Forward Port: `443`
   - Cache Assets: ✗ (disabled for dynamic content)
   - Block Common Exploits: ✓
   - Websockets Support: ✓

3. **SSL Tab:**
   - SSL Certificate: Request a new SSL Certificate with Let's Encrypt
   - Force SSL: ✓
   - HTTP/2 Support: ✓
   - HSTS Enabled: ✓
   - Email: Your email address
   - Agree to ToS: ✓

4. **Custom Nginx Configuration Tab:**
   ```nginx
   # Include Authelia authentication
   include /snippets/authelia-location.conf;
   include /snippets/authelia-authrequest.conf;
   
   # Proxy SSL settings for backend
   proxy_ssl_verify off;
   proxy_ssl_server_name on;
   
   # Pass through original headers
   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   proxy_set_header X-Forwarded-Host $host;
   proxy_set_header X-Forwarded-Proto $scheme;
   ```

5. Save

## Testing

### 1. Test Authelia Portal

1. Open browser: `https://auth.innosilicon.com`
2. You should see the Authelia login page
3. Try logging in with a FreeIPA user account

### 2. Test FreeIPA Access

1. Open browser: `https://ipa1.innosilicon.com`
2. You should be redirected to Authelia login
3. After successful login, you'll be redirected back to FreeIPA

### 3. Test 2FA Setup (Optional)

If using `two_factor` policy:
1. After first login, Authelia will prompt to set up TOTP
2. Scan QR code with Google Authenticator or similar app
3. Enter the 6-digit code to verify

## Troubleshooting

### Check Authelia Logs

```bash
docker-compose logs -f authelia
```

### Common Issues

1. **LDAP Connection Failed**
   - Verify FreeIPA server is accessible: `ping ipa1.insc.lcl`
   - Check LDAP service account credentials
   - Verify base DN matches your FreeIPA domain

2. **Redirect Loop**
   - Check `session.domain` in `configuration.yml` is set to `innosilicon.com`
   - Verify auth endpoint in nginx configs uses correct domain

3. **SSL Certificate Issues**
   - Ensure ports 80 and 443 are open and accessible from internet
   - Check DNS records are pointing to your server
   - Review NPM logs: `docker-compose logs nginx-proxy-manager`

4. **Authentication Not Required**
   - Verify nginx configs are properly included in NPM
   - Check the `/snippets` volume mount in docker-compose.yml
   - Restart NPM: `docker-compose restart nginx-proxy-manager`

### Test LDAP Connection

```bash
# Test LDAP connection from Authelia container
docker exec -it authelia sh

# Install ldapsearch if needed
apk add openldap-clients

# Test LDAP bind
ldapsearch -x -H ldap://ipa1.insc.lcl \
  -D "uid=authelia,cn=users,cn=accounts,dc=insc,dc=lcl" \
  -w "YOUR_PASSWORD" \
  -b "dc=insc,dc=lcl" \
  "(uid=*)" uid
```

## Security Considerations

1. **Change all default passwords and secrets**
2. **Use strong passwords for FreeIPA service account**
3. **Enable two-factor authentication** (change policy from `one_factor` to `two_factor`)
4. **Regularly update Docker images**: `docker-compose pull && docker-compose up -d`
5. **Monitor logs** for suspicious activity
6. **Restrict access** by configuring appropriate FreeIPA groups
7. **Enable SMTP** in Authelia for password reset emails (production)

## Backup

Important files to backup:
- `authelia/configuration.yml`
- `authelia/db.sqlite3`
- `.env`
- `npm/data/database.sqlite`

```bash
# Backup script
tar -czf authelia-backup-$(date +%Y%m%d).tar.gz \
  authelia/configuration.yml \
  authelia/db.sqlite3 \
  authelia/users_database.yml \
  .env \
  npm/data
```

## Maintenance

### Update Services

```bash
# Pull latest images
docker-compose pull

# Restart services
docker-compose down
docker-compose up -d
```

### View Logs

```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f authelia
docker-compose logs -f nginx-proxy-manager
```

## Advanced Configuration

### Enable Email Notifications

Edit `authelia/configuration.yml` and uncomment the SMTP section (lines 145-158), then configure with your SMTP settings.

### Add More Protected Services

To protect additional services:
1. Add them to `access_control.rules` in `authelia/configuration.yml`
2. Create proxy host in NPM with same custom nginx config as FreeIPA
3. Adjust domain and forward settings accordingly

### Custom Branding

You can customize Authelia's appearance by adding custom CSS/logos. See [Authelia documentation](https://www.authelia.com/docs/configuration/miscellaneous.html#custom-branding) for details.

## References

- [Authelia Documentation](https://www.authelia.com)
- [Nginx Proxy Manager](https://nginxproxymanager.com)
- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)

## Support

For issues or questions:
1. Check logs for error messages
2. Review Authelia documentation
3. Verify FreeIPA LDAP connectivity
4. Check NPM proxy host configuration
