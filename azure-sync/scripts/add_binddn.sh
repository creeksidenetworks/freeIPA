#!/bin/bash

# Check if the correct number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <userid> <password>"
    exit 1
fi

USERID=${1}
PASSWORD=${2}

# Extract the BASEDN from /etc/openldap/ldap.conf
BASEDN=$(grep -i '^BASE' /etc/openldap/ldap.conf | awk '{print $2}')

# Check if BASEDN was found
if [ -z "$BASEDN" ]; then
    echo "BASEDN not found in /etc/openldap/ldap.conf"
    exit 1
fi

# Check if the service account already exists
ipa user-find $USERID &>/dev/null
if [ $? -eq 0 ]; then
    echo "Service account $USERID already exists."
    exit 1
fi

BINDUID="${USERID},cn=sysaccounts,cn=etc,$BASEDN"

# Print out the new service account cn to be added
echo "The new service account cn to be added is: uid=${BINDUID}"

# Authenticate as admin to get access
echo "Please enter the admin password:"
kinit admin
if [ $? -ne 0 ]; then
    echo "Failed to authenticate as admin."
    exit 1
fi

# Add the service account
ldap_binddn_update_file=$(mktemp /tmp/ldap-binddn.update.XXXXXX)
cat <<EOF >$ldap_binddn_update_file
dn: uid=${BINDUID}
add:objectclass:account
add:objectclass:simplesecurityobject
add:uid:${USERID}
add:userPassword:${PASSWORD}
add:passwordExpirationTime:20491231000000Z
add:nsIdleTimeout:0
EOF

ipa-ldap-updater $ldap_binddn_update_file

# Verify the new service account using ldapsearch
ldapsearch -x -b "$BASEDN" -w ${PASSWORD} "(uid=${USERID})" &>/dev/null

# Check if the service account was added successfully
if [ $? -eq 0 ]; then
    echo "Service account $USERID added successfully."
else
    echo "Failed to add service account $USERID."
    exit 1
fi