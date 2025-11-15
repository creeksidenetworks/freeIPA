#!/bin/bash
# Quick Setup Script for Authelia + NPM + FreeIPA

set -e

echo "======================================"
echo "Authelia + NPM + FreeIPA Setup"
echo "======================================"
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "Creating .env file from template..."
    cp .env.example .env
    
    echo ""
    echo "⚠️  IMPORTANT: Please edit .env file with your settings:"
    echo "   - LDAP_BIND_PASSWORD"
    echo "   - AUTHELIA_JWT_SECRET"
    echo "   - AUTHELIA_SESSION_SECRET"
    echo "   - AUTHELIA_STORAGE_ENCRYPTION_KEY"
    echo ""
    echo "Generate secrets with: openssl rand -hex 32"
    echo ""
    read -p "Press Enter after you've updated .env file..."
fi

# Create directories
echo "Creating necessary directories..."
mkdir -p authelia redis npm/data npm/letsencrypt nginx-configs

# Set permissions
echo "Setting proper permissions..."
chmod 700 authelia
chmod 600 authelia/configuration.yml 2>/dev/null || true

# Generate secrets if needed
echo ""
echo "Here are three random secrets you can use:"
echo "Secret 1 (JWT): $(openssl rand -hex 32)"
echo "Secret 2 (Session): $(openssl rand -hex 32)"
echo "Secret 3 (Storage): $(openssl rand -hex 32)"
echo ""

# Ask if ready to start
read -p "Start Docker containers now? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting services..."
    docker-compose up -d
    
    echo ""
    echo "✅ Services started!"
    echo ""
    echo "Next steps:"
    echo "1. Access Nginx Proxy Manager: http://YOUR_IP:81"
    echo "   Default: admin@example.com / changeme"
    echo ""
    echo "2. Configure proxy hosts as described in README.md"
    echo ""
    echo "3. Test Authelia: https://auth.innosilicon.com"
    echo ""
    echo "View logs:"
    echo "  docker-compose logs -f authelia"
    echo "  docker-compose logs -f nginx-proxy-manager"
else
    echo ""
    echo "Setup complete! Start services when ready with:"
    echo "  docker-compose up -d"
fi
