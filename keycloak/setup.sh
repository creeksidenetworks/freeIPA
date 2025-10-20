#!/bin/bash

# Keycloak with FreeIPA Integration Setup Script
# This script sets up Keycloak with FreeIPA backend authentication

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_header "Keycloak with FreeIPA Integration Setup"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null; then
    print_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Create environment file from example
if [ ! -f ".env" ]; then
    print_status "Creating environment file from example..."
    cp .env.example .env
    print_warning "Please edit .env file with your actual passwords and configuration!"
    print_warning "Especially change the default passwords and FreeIPA bind password."
fi

# Check if FreeIPA is running
print_status "Checking FreeIPA status..."
if systemctl is-active --quiet ipa; then
    print_status "FreeIPA is running"
else
    print_error "FreeIPA is not running. Please start FreeIPA first."
    exit 1
fi

# Create necessary firewall rules
print_status "Configuring firewall for Keycloak..."
firewall-cmd --permanent --add-port=8080/tcp || true
firewall-cmd --reload || true

# Pull Docker images
print_status "Pulling Docker images..."
docker-compose pull

# Start services
print_status "Starting Keycloak services..."
docker-compose up -d

# Wait for services to be ready
print_status "Waiting for services to start..."
sleep 30

# Check if services are running
if docker-compose ps | grep -q "Up"; then
    print_status "Keycloak services are starting up..."
    
    print_status "Waiting for Keycloak to be fully ready..."
    timeout=300
    counter=0
    while [ $counter -lt $timeout ]; do
        if curl -s http://localhost:8080/health/ready > /dev/null; then
            print_status "Keycloak is ready!"
            break
        fi
        sleep 10
        counter=$((counter + 10))
        echo -n "."
    done
    echo
    
    if [ $counter -ge $timeout ]; then
        print_error "Keycloak failed to start within $timeout seconds"
        exit 1
    fi
    
    print_header "Setup Complete!"
    echo
    print_status "Keycloak is now running and accessible at:"
    echo "  URL: http://ipa1.icm.lcl:8080"
    echo "  Admin Console: http://ipa1.icm.lcl:8080/admin"
    echo "  Username: admin"
    echo "  Password: Check your .env file for KEYCLOAK_ADMIN_PASSWORD"
    echo
    print_status "FreeIPA Realm is configured at:"
    echo "  http://ipa1.icm.lcl:8080/realms/freeipa"
    echo
    print_warning "Next steps:"
    echo "1. Edit .env file with correct passwords"
    echo "2. Update LDAP bind password in realm configuration"
    echo "3. Test user authentication"
    echo "4. Configure SSL certificates for production"
    
else
    print_error "Failed to start Keycloak services"
    docker-compose logs
    exit 1
fi