# Authelia + FreeIPA + NGINX Proxy Manager Setup

Complete authentication solution using Authelia with FreeIPA LDAP backend and NGINX Proxy Manager for reverse proxy. No two-factor authentication required.

## Overview

- **Authelia**: Authentication and authorization server
- **FreeIPA**: LDAP backend for user authentication
- **Redis**: Session storage for Authelia
- **NGINX Proxy Manager**: Reverse proxy with web UI

## Prerequisites

- Docker and Docker Compose installed
- FreeIPA server accessible (hostname and credentials)
- Domain names configured and pointed to your server

## Quick Start

### 1. Configure Authelia

Edit `authelia/configuration.yml` and update these values:

```yaml
jwt_secret: CHANGE_ME_TO_RANDOM_STRING  # Generate with: openssl rand -base64 32
default_redirection_url: https://yourdomain.com

authentication_backend:
  ldap:
    url: ldap://your-freeipa-server.com:389
    base_dn: cn=accounts,dc=example,dc=com
    user: uid=admin,cn=users,cn=accounts,dc=example,dc=com
    password: your-freeipa-admin-password

access_control:
  rules:
    - domain: auth.yourdomain.com
      policy: bypass
    - domain: "*.yourdomain.com"
      policy: one_factor

session:
  domain: yourdomain.com
  secret: CHANGE_ME_TO_RANDOM_STRING  # Generate with: openssl rand -base64 32

storage:
  encryption_key: CHANGE_ME_TO_RANDOM_STRING  # Generate with: openssl rand -base64 32
```

**Important**: Replace all `CHANGE_ME_TO_RANDOM_STRING` with actual random strings.

### 2. Start Services

```bash
docker-compose up -d
```

This will start:
- NGINX Proxy Manager on ports 80, 443 (proxy) and 81 (web UI)
- Authelia on port 9091 (internal only)
- Redis (internal only)

### 3. Configure NGINX Proxy Manager

#### Access NPM Web UI
1. Open http://your-server-ip:81
2. Default login:
   - Email: `admin@example.com`
   - Password: `changeme`
3. Change the default credentials immediately

#### Create Authelia Proxy Host

1. Go to **Hosts** → **Proxy Hosts** → **Add Proxy Host**

2. **Details Tab:**
   - Domain Names: `auth.yourdomain.com`
   - Scheme: `http`
   - Forward Hostname: `authelia`
   - Forward Port: `9091`
   - ✅ Websockets Support
   - ✅ Block Common Exploits

3. **SSL Tab:**
   - ✅ Request a new SSL Certificate (or use existing)
   - ✅ Force SSL
   - ✅ HTTP/2 Support

4. **Save**

#### Protect Your Applications

For each application you want to protect with Authelia:

1. Create a new Proxy Host (or edit existing)
   - Domain Names: `app.yourdomain.com`
   - Forward to your application's hostname and port
   - Enable SSL

2. **Advanced Tab**, add:

```nginx
location /authelia {
    internal;
    set $upstream_authelia http://authelia:9091/api/verify;
    proxy_pass $upstream_authelia;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-Method $request_method;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

location / {
    auth_request /authelia;
    auth_request_set $target_url $scheme://$http_host$request_uri;
    auth_request_set $user $upstream_http_remote_user;
    auth_request_set $groups $upstream_http_remote_groups;
    auth_request_set $name $upstream_http_remote_name;
    auth_request_set $email $upstream_http_remote_email;
    
    proxy_set_header Remote-User $user;
    proxy_set_header Remote-Groups $groups;
    proxy_set_header Remote-Name $name;
    proxy_set_header Remote-Email $email;
    
    error_page 401 =302 https://auth.yourdomain.com/?rd=$target_url;
    
    # Your existing proxy configuration
    proxy_pass http://your-app:port;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

3. **Save**

## Testing

1. Visit `https://auth.yourdomain.com` - you should see the Authelia login page
2. Login with your FreeIPA credentials
3. Visit your protected application - you should be automatically authenticated
4. Sessions persist based on your configuration (default: 1 hour)

## FreeIPA LDAP Configuration

### Finding Your Base DN

If you're unsure of your FreeIPA Base DN:

```bash
# From your FreeIPA server
ldapsearch -x -b "" -s base namingContexts
```

### Testing LDAP Connection

```bash
# Test from Authelia container
docker exec -it authelia sh
ldapsearch -x -H ldap://your-freeipa-server:389 \
  -D "uid=admin,cn=users,cn=accounts,dc=example,dc=com" \
  -w "password" -b "cn=accounts,dc=example,dc=com" "(uid=username)"
```

### Common FreeIPA Base DNs

- Base DN: `cn=accounts,dc=example,dc=com`
- Users DN: `cn=users,cn=accounts,dc=example,dc=com`
- Groups DN: `cn=groups,cn=accounts,dc=example,dc=com`
- Admin User: `uid=admin,cn=users,cn=accounts,dc=example,dc=com`

## Troubleshooting

### View Authelia Logs
```bash
docker logs -f authelia
```

### View NPM Logs
```bash
docker logs -f nginx-proxy-manager
```

### Test Authelia API
```bash
curl -I http://localhost:9091/api/health
```

### Common Issues

1. **"Cannot connect to LDAP"**: Verify FreeIPA hostname, port, and credentials
2. **"Invalid session"**: Check Redis is running and session secrets are set
3. **"Access denied"**: Review access_control rules in configuration.yml
4. **NPM shows 502**: Ensure Authelia container is running and accessible

## Security Notes

- All secrets (jwt_secret, session secret, encryption_key) must be unique random strings
- Change NPM default password immediately
- Use SSL certificates for all domains
- FreeIPA should be accessible from Authelia container
- Session domain must match your root domain for SSO to work

## File Structure

```
.
├── docker-compose.yml           # Container orchestration
├── README.md                    # This file
├── authelia/
│   ├── configuration.yml        # Main Authelia config
│   └── users_database.yml       # Fallback user database
├── data/                        # NPM data (auto-created)
├── letsencrypt/                 # SSL certificates (auto-created)
└── redis/                       # Redis data (auto-created)
```

## Additional Configuration

### Enable Email Notifications

Replace the `notifier` section in `authelia/configuration.yml`:

```yaml
notifier:
  smtp:
    username: your-email@example.com
    password: your-smtp-password
    host: smtp.gmail.com
    port: 587
    sender: authelia@example.com
```

### Add Local User (Bypass LDAP)

Generate password hash:
```bash
docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'yourpassword'
```

Add to `authelia/users_database.yml`:
```yaml
users:
  admin:
    displayname: "Local Admin"
    password: "$argon2id$v=19$m=65536..."
    email: admin@example.com
    groups:
      - admins
```

## Support

For issues or questions:
- Authelia Docs: https://www.authelia.com/
- NPM Docs: https://nginxproxymanager.com/
- FreeIPA Docs: https://www.freeipa.org/
