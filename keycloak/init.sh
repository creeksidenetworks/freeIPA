#!/bin/bash
# Setup script to import FreeIPA CA certificate into Keycloak's truststore
# Automatically detects IPA server from .env file
# Run this once AFTER starting containers: ./init.sh

set -e

# Working directory for temporary files
TMP_DIR=$(mktemp -d -t keycloak-cert-setup.XXXXXX)
CERT_FILE="$TMP_DIR/ipa-ca.crt"
CONTAINER_NAME="keycloak"
CONTAINER_CERT_PATH="/tmp/ipa-ca.crt"
CONTAINER_CACERTS="/opt/keycloak/conf/cacerts"
ALIAS="freeipa-ca"

# Cleanup function to remove temp directory on exit
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        echo "Cleaning up temporary files..."
        rm -rf "$TMP_DIR"
        echo "✓ Cleanup complete"
    fi
}
trap cleanup EXIT

echo "=== FreeIPA CA Certificate Import Setup ==="
echo ""

# Check if Keycloak container is running
if ! docker ps | grep -q "$CONTAINER_NAME"; then
    echo "ERROR: Keycloak container is not running"
    echo "Please start the containers first with: docker compose up -d"
    exit 1
fi
echo "✓ Keycloak container is running"
echo ""

# Download certificate from FreeIPA
echo "Let's download the FreeIPA CA certificate."
echo ""

# Try to get FreeIPA server from .env file
if [ -f ".env" ]; then
    IPA_SERVER=$(grep "^FREEIPA_SERVER_HOST=" .env | cut -d '=' -f2)
    if [ -n "$IPA_SERVER" ]; then
        echo "Using FreeIPA server from .env: $IPA_SERVER"
    fi
fi

# Prompt if not found
if [ -z "$IPA_SERVER" ]; then
    read -p "Enter your FreeIPA server hostname or IP (e.g., ipa.example.com): " IPA_SERVER
fi

if [ -z "$IPA_SERVER" ]; then
    echo "ERROR: FreeIPA server hostname is required"
    exit 1
fi

echo ""
echo "Downloading CA certificate from http://$IPA_SERVER/ipa/config/ca.crt ..."

if curl -f -k -o "$CERT_FILE" "http://$IPA_SERVER/ipa/config/ca.crt" 2>/dev/null; then
    echo "✓ Certificate downloaded successfully"
else
    echo "ERROR: Failed to download certificate from http://$IPA_SERVER/ipa/config/ca.crt"
    echo ""
    echo "Please verify:"
    echo "  1. FreeIPA server hostname/IP is correct"
    echo "  2. Server is accessible from this machine"
    echo "  3. FreeIPA web interface is running"
    exit 1
fi

# Copy certificate to container
echo ""
echo "Copying certificate to Keycloak container..."
docker cp "$CERT_FILE" "$CONTAINER_NAME:$CONTAINER_CERT_PATH"
echo "✓ Certificate copied to container"

# Check if cacerts file exists, if not create it from system default
echo ""
echo "Checking if custom truststore exists..."
if ! docker exec "$CONTAINER_NAME" test -f "$CONTAINER_CACERTS"; then
    echo "Creating custom truststore from system default..."
    docker exec "$CONTAINER_NAME" bash -c "cp /etc/pki/ca-trust/extracted/java/cacerts $CONTAINER_CACERTS && chmod 644 $CONTAINER_CACERTS"
    echo "✓ Custom truststore created"
else
    echo "✓ Custom truststore exists"
fi

# Check if certificate already exists in truststore
echo ""
echo "Checking if FreeIPA CA certificate is already in truststore..."
if docker exec "$CONTAINER_NAME" keytool -list -keystore "$CONTAINER_CACERTS" -storepass changeit -alias "$ALIAS" >/dev/null 2>&1; then
    echo "✓ Certificate '$ALIAS' already exists in truststore"
    echo ""
    read -p "Certificate already imported. Re-import? [y/N]: " REIMPORT
    if [[ ! "$REIMPORT" =~ ^[Yy]$ ]]; then
        echo "Skipping import."
        exit 0
    fi
    # Delete existing certificate
    echo "Removing existing certificate..."
    docker exec "$CONTAINER_NAME" keytool -delete -keystore "$CONTAINER_CACERTS" -storepass changeit -alias "$ALIAS"
fi

# Import certificate
echo ""
echo "Importing FreeIPA CA certificate into truststore..."
docker exec "$CONTAINER_NAME" keytool -import -trustcacerts -alias "$ALIAS" \
    -file "$CONTAINER_CERT_PATH" \
    -keystore "$CONTAINER_CACERTS" \
    -storepass changeit \
    -noprompt

if [ $? -eq 0 ]; then
    echo "✓ Certificate imported successfully!"
else
    echo "ERROR: Failed to import certificate"
    exit 1
fi

# Verify
echo ""
echo "Verifying certificate import..."
docker exec "$CONTAINER_NAME" keytool -list -keystore "$CONTAINER_CACERTS" -storepass changeit -alias "$ALIAS" -v 2>&1 | head -10

echo ""
echo "=== Setup Complete ==="
echo ""
echo "The FreeIPA CA certificate has been imported into Keycloak's truststore."
echo ""
echo "⚠️  IMPORTANT: Restart Keycloak for changes to take effect:"
echo "   docker compose restart keycloak"
echo ""
