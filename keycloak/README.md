# Keycloak with FreeIPA Integration

This directory contains a Docker Compose setup for deploying Keycloak with FreeIPA as the authentication backend. Users can login to Keycloak and update their passwords in FreeIPA.

## Features

- ✅ **Keycloak 23.0** with PostgreSQL backend
- ✅ **FreeIPA LDAP Integration** for user authentication  
- ✅ **Password Management** - Users can change passwords through Keycloak
- ✅ **User Federation** - Automatic user sync from FreeIPA
- ✅ **Production Ready** - Health checks, logging, restart policies

## Quick Start

### 1. Prerequisites

- FreeIPA server running and accessible
- Docker and Docker Compose installed
- Firewall port 8080 accessible

### 2. Configuration

```bash
# Copy environment template
cp .env.example .env

# Edit configuration
nano .env
```

Update these critical settings in `.env`:
- Change all default passwords
- Set correct FreeIPA LDAP bind password
- Verify FreeIPA server settings

### 3. Deploy

```bash
# Run the setup script
./setup.sh

# Or manually start services
docker-compose up -d
```

### 4. Access Keycloak

- **Admin Console**: http://ipa1.icm.lcl:8080/admin
- **FreeIPA Realm**: http://ipa1.icm.lcl:8080/realms/freeipa
- **Account Management**: http://ipa1.icm.lcl:8080/realms/freeipa/account

## Configuration Details

### FreeIPA LDAP Configuration

The realm is pre-configured with:
- **LDAP Server**: ipa1.icm.lcl:389
- **Base DN**: cn=users,cn=accounts,dc=icm,dc=lcl
- **Bind DN**: uid=ldapauth,cn=users,cn=accounts,dc=icm,dc=lcl
- **User Object Classes**: inetOrgPerson, organizationalPerson, person, top
- **Username Attribute**: uid
- **Password Updates**: Enabled via LDAP Password Modify Extended Operation

### User Attribute Mapping

| FreeIPA Attribute | Keycloak Attribute |
|-------------------|-------------------|
| givenName         | firstName         |
| sn                | lastName          |
| mail              | email             |
| uid               | username          |

## Password Management

Users can update their FreeIPA passwords through:

1. **Keycloak Account Console**:
   - Access: http://ipa1.icm.lcl:8080/realms/freeipa/account
   - Login with FreeIPA credentials
   - Navigate to "Personal info" → "Password"

2. **Custom Applications**:
   - Integrate with Keycloak's OpenID Connect
   - Use account management APIs

## Management Commands

```bash
# View service status
docker-compose ps

# View logs
docker-compose logs -f keycloak

# Restart services
docker-compose restart

# Stop services
docker-compose down

# Update and restart
docker-compose pull && docker-compose up -d
```

## Troubleshooting

### Common Issues

1. **LDAP Connection Failed**
   ```bash
   # Check FreeIPA LDAP service
   systemctl status dirsrv@ICM-LCL.service
   
   # Test LDAP bind
   ldapsearch -x -H ldap://ipa1.icm.lcl:389 -D "uid=ldapauth,cn=users,cn=accounts,dc=icm,dc=lcl" -W
   ```

2. **Keycloak Not Starting**
   ```bash
   # Check container logs
   docker-compose logs keycloak
   
   # Check database connection
   docker-compose logs postgres
   ```

3. **Password Updates Not Working**
   - Verify LDAP bind user has password modification rights
   - Check `usePasswordModifyExtendedOp` is enabled
   - Review Keycloak LDAP provider logs

### LDAP Bind User Setup

If you need to create/verify the LDAP bind user:

```bash
# Create bind user (if not exists)
ipa user-add ldapauth --first=LDAP --last=Auth --password

# Give password change permissions
ipa permission-add "Change user password" --bindtype=permission --right=write --attrs=userpassword

# Add to appropriate group or create custom role
```

## Security Considerations

- Change all default passwords in `.env`
- Use strong passwords for database and admin accounts
- Configure SSL/TLS for production (not included in this basic setup)
- Regularly update Docker images
- Monitor access logs
- Restrict network access to necessary ports only

## File Structure

```
keycloak/
├── docker-compose.yml          # Main deployment configuration
├── .env.example               # Environment template
├── setup.sh                   # Automated setup script
├── README.md                  # This documentation
└── config/
    ├── realms/
    │   └── freeipa-realm.json # Pre-configured FreeIPA realm
    ├── themes/                # Custom themes (optional)
    └── providers/             # Custom providers (optional)
```

## Production Deployment

For production use, consider:

1. **SSL/TLS Setup**: Configure reverse proxy (nginx/Apache) with proper certificates
2. **Database Security**: Use external PostgreSQL with proper credentials
3. **Backup Strategy**: Regular database and configuration backups
4. **Monitoring**: Set up health monitoring and log aggregation
5. **High Availability**: Deploy multiple Keycloak instances with load balancer
6. **Network Security**: Use internal networks and proper firewall rules

## Support

- Check logs: `docker-compose logs -f`
- Keycloak Documentation: https://www.keycloak.org/documentation
- FreeIPA Integration: https://www.keycloak.org/docs/latest/server_admin/#_ldap