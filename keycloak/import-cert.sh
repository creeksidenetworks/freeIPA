#!/bin/bash

echo "Starting certificate import process..."

# Define paths
CERT_FILE="/opt/keycloak/cert/ipa-ca.crt"
CACERTS_ORIG="/etc/pki/ca-trust/extracted/java/cacerts"
CACERTS_CUSTOM="/opt/keycloak/conf/cacerts"
ALIAS="freeipa-ca"

# Check if certificate file exists
if [ ! -f "$CERT_FILE" ]; then
    echo "WARNING: Certificate file not found at $CERT_FILE, skipping import"
else
    # Create custom cacerts if not exists
    if [ ! -f "$CACERTS_CUSTOM" ]; then
        echo "Creating custom cacerts..."
        cp "$CACERTS_ORIG" "$CACERTS_CUSTOM"
        chmod 644 "$CACERTS_CUSTOM"
    fi

    # Check if certificate already exists
    if keytool -list -keystore "$CACERTS_CUSTOM" -storepass changeit -alias "$ALIAS" >/dev/null 2>&1; then
        echo "✓ Certificate '$ALIAS' already exists in truststore."
    else
        echo "Importing FreeIPA CA certificate..."
        keytool -import -trustcacerts -alias "$ALIAS" \
            -file "$CERT_FILE" \
            -keystore "$CACERTS_CUSTOM" \
            -storepass changeit \
            -noprompt
        
        echo "✓ FreeIPA CA certificate imported successfully!"
    fi

    # Export Java options to use custom truststore
    export JAVA_OPTS_APPEND="$JAVA_OPTS_APPEND -Djavax.net.ssl.trustStore=$CACERTS_CUSTOM -Djavax.net.ssl.trustStorePassword=changeit"
    echo "✓ Java configured to use custom truststore"
fi

echo "Starting Keycloak..."
exec /opt/keycloak/bin/kc.sh "$@"
