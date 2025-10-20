#!/bin/bash

# Keycloak Management Script
# Provides common management operations for Keycloak deployment

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${BLUE}=== $1 ===${NC}"; }

show_help() {
    echo "Keycloak Management Script"
    echo
    echo "Usage: $0 [COMMAND]"
    echo
    echo "Commands:"
    echo "  start          Start Keycloak services"
    echo "  stop           Stop Keycloak services"
    echo "  restart        Restart Keycloak services"
    echo "  status         Show service status"
    echo "  logs           Show Keycloak logs"
    echo "  update         Update and restart services"
    echo "  backup         Backup Keycloak database"
    echo "  restore FILE   Restore database from backup"
    echo "  test-ldap      Test LDAP connection to FreeIPA"
    echo "  reset-admin    Reset admin password"
    echo "  clean          Remove all containers and volumes"
    echo "  help           Show this help message"
    echo
}

start_services() {
    print_header "Starting Keycloak Services"
    docker-compose up -d
    print_status "Services started. Checking health..."
    sleep 10
    docker-compose ps
}

stop_services() {
    print_header "Stopping Keycloak Services"
    docker-compose down
    print_status "Services stopped"
}

restart_services() {
    print_header "Restarting Keycloak Services"
    docker-compose restart
    print_status "Services restarted"
}

show_status() {
    print_header "Keycloak Service Status"
    docker-compose ps
    echo
    print_status "Health check:"
    if curl -s http://localhost:8080/health/ready > /dev/null; then
        echo "✅ Keycloak is healthy"
    else
        echo "❌ Keycloak is not responding"
    fi
}

show_logs() {
    print_header "Keycloak Logs"
    docker-compose logs -f keycloak
}

update_services() {
    print_header "Updating Keycloak Services"
    docker-compose pull
    docker-compose up -d
    print_status "Services updated and restarted"
}

backup_database() {
    print_header "Backing up Keycloak Database"
    BACKUP_FILE="keycloak-backup-$(date +%Y%m%d_%H%M%S).sql"
    docker-compose exec postgres pg_dump -U keycloak keycloak > "$BACKUP_FILE"
    print_status "Database backed up to: $BACKUP_FILE"
}

restore_database() {
    if [ -z "$1" ]; then
        print_error "Please specify backup file: $0 restore <backup-file>"
        exit 1
    fi
    
    if [ ! -f "$1" ]; then
        print_error "Backup file not found: $1"
        exit 1
    fi
    
    print_header "Restoring Keycloak Database"
    print_warning "This will overwrite the current database!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker-compose exec -T postgres psql -U keycloak -d keycloak < "$1"
        print_status "Database restored from: $1"
        print_status "Restarting Keycloak..."
        docker-compose restart keycloak
    else
        print_status "Restore cancelled"
    fi
}

test_ldap() {
    print_header "Testing LDAP Connection to FreeIPA"
    
    # Load environment variables
    if [ -f .env ]; then
        source .env
    fi
    
    LDAP_SERVER=${FREEIPA_SERVER:-ipa1.icm.lcl}
    BIND_DN=${FREEIPA_BIND_DN:-"uid=ldapauth,cn=users,cn=accounts,dc=icm,dc=lcl"}
    
    print_status "Testing connection to: $LDAP_SERVER"
    print_status "Using bind DN: $BIND_DN"
    
    if command -v ldapsearch &> /dev/null; then
        echo "Enter LDAP bind password:"
        ldapsearch -x -H "ldap://$LDAP_SERVER:389" -D "$BIND_DN" -W -b "cn=users,cn=accounts,dc=icm,dc=lcl" "(uid=admin)" dn
    else
        print_error "ldapsearch command not found. Install openldap-clients package."
    fi
}

reset_admin() {
    print_header "Resetting Keycloak Admin Password"
    
    echo "Enter new admin password:"
    read -s NEW_PASSWORD
    echo
    echo "Confirm password:"
    read -s CONFIRM_PASSWORD
    echo
    
    if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
        print_error "Passwords do not match"
        exit 1
    fi
    
    print_status "Updating admin password..."
    docker-compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin
    docker-compose exec keycloak /opt/keycloak/bin/kcadm.sh update users -r master --target-user admin --set credentials='[{"type":"password","value":"'$NEW_PASSWORD'","temporary":false}]'
    
    print_status "Admin password updated successfully"
}

clean_all() {
    print_header "Cleaning Keycloak Deployment"
    print_warning "This will remove all containers, volumes, and data!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker-compose down -v --remove-orphans
        docker system prune -f
        print_status "Cleanup complete"
    else
        print_status "Cleanup cancelled"
    fi
}

# Main script logic
case "$1" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    update)
        update_services
        ;;
    backup)
        backup_database
        ;;
    restore)
        restore_database "$2"
        ;;
    test-ldap)
        test_ldap
        ;;
    reset-admin)
        reset_admin
        ;;
    clean)
        clean_all
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac