# Keycloak with FreeIPA Backend Setup

## Starting the Services

```bash
cd /root/freeIPA/keycloak
docker-compose up -d
```

## Initial Configuration

### 1. Access Keycloak Admin Console
- URL: http://localhost:8080 or http://keycloak.innosilicon.com:8080
- Username: `admin`
- Password: `admin_password`

**Important:** Change the admin password after first login!

### 2. Configure FreeIPA LDAP User Federation

After logging in to Keycloak:

1. **Navigate to User Federation**
   - Click on "Configure" → "User Federation"
   - Click "Add provider" → Select "ldap"

2. **Configure LDAP Settings**
   - **Console Display Name**: FreeIPA
   - **Vendor**: Red Hat Directory Server
   - **Connection URL**: `ldap://ipa1.inno.lcl:389`
   - **Bind DN**: `uid=ldapauth,cn=sysaccounts,cn=etc,dc=inno,dc=lcl`
   - **Bind Credential**: `ZRJokBADxuct`

3. **LDAP Searching and Updating**
   - **Edit Mode**: READ_ONLY (recommended) or WRITABLE
   - **Users DN**: `cn=users,cn=accounts,dc=inno,dc=lcl`
   - **Username LDAP attribute**: `uid`
   - **RDN LDAP attribute**: `uid`
   - **UUID LDAP attribute**: `ipaUniqueID`
   - **User Object Classes**: `inetOrgPerson, organizationalPerson`
   - **Search Scope**: Subtree

4. **Enable StartTLS**
   - **Use Truststore SPI**: Only for ldaps
   - **Connection Pooling**: ON
   - **Connection Timeout**: 5000
   - **Read Timeout**: 5000

5. **Synchronization Settings**
   - **Import Users**: ON
   - **Sync Registrations**: OFF (for READ_ONLY mode)
   - **Batch Size**: 1000

6. **Click "Save"**

7. **Test Connection**
   - Click "Test connection" button
   - Click "Test authentication" button
   - Both should succeed

8. **Synchronize Users**
   - Click "Synchronize all users" to import users from FreeIPA

### 3. Configure Group Mapping (Optional)

1. Go to the "Mappers" tab of your LDAP provider
2. Click "Create"
3. Configure group mapper:
   - **Name**: groups
   - **Mapper Type**: group-ldap-mapper
   - **LDAP Groups DN**: `cn=groups,cn=accounts,dc=inno,dc=lcl`
   - **Group Name LDAP Attribute**: `cn`
   - **Group Object Classes**: `groupOfNames`
   - **Membership LDAP Attribute**: `member`
   - **Membership Attribute Type**: DN
   - **Mode**: READ_ONLY
   - **User Groups Retrieve Strategy**: LOAD_GROUPS_BY_MEMBER_ATTRIBUTE

4. Click "Save"
5. Click "Sync LDAP Groups to Keycloak"

## FreeIPA Connection Details

Based on your FreeIPA configuration:

- **LDAP Server**: ipa1.inno.lcl (accessible via host-gateway)
- **Base DN**: cn=accounts,dc=inno,dc=lcl
- **Users Base**: cn=users,cn=accounts,dc=inno,dc=lcl
- **Groups Base**: cn=groups,cn=accounts,dc=inno,dc=lcl
- **Service Account**: uid=ldapauth,cn=sysaccounts,cn=etc,dc=inno,dc=lcl
- **Username Attribute**: uid
- **Mail Attribute**: mail
- **Display Name Attribute**: displayName

## Configuring Nginx Proxy Manager

To access Keycloak via HTTPS through Nginx Proxy Manager:

1. Access NPM at http://localhost:81
2. Add a new Proxy Host:
   - **Domain Names**: keycloak.innosilicon.com
   - **Scheme**: http
   - **Forward Hostname/IP**: keycloak
   - **Forward Port**: 8080
   - **Enable**: Websockets Support, Block Common Exploits
3. Configure SSL certificate (Let's Encrypt or custom)

## Container Management

```bash
# View logs
docker-compose logs -f keycloak

# Restart services
docker-compose restart

# Stop services
docker-compose down

# Stop and remove volumes (WARNING: deletes database)
docker-compose down -v
```

## Troubleshooting

### LDAP Connection Issues
- Ensure FreeIPA server (ipa1.inno.lcl) is accessible from the Docker container
- Check if the service account credentials are correct
- Verify the base DN and search filters

### Database Issues
- Check PostgreSQL logs: `docker-compose logs postgres`
- Ensure PostgreSQL is fully started before Keycloak connects

### Network Issues
- Verify the `extra_hosts` mapping for ipa1.inno.lcl
- You may need to update this to the actual IP address if host-gateway doesn't work

## Security Recommendations

1. **Change default passwords** in docker-compose.yml:
   - KEYCLOAK_ADMIN_PASSWORD
   - POSTGRES_PASSWORD

2. **Use secrets management** for production deployments

3. **Enable HTTPS** and disable HTTP in production

4. **Restrict network access** to PostgreSQL

5. **Regular backups** of PostgreSQL database

## Additional Resources

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Keycloak LDAP Federation](https://www.keycloak.org/docs/latest/server_admin/#_ldap)
- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)
