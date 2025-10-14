#!/bin/bash
#
# Azure FreeIPA Sync Monitor Script
#
# This script monitors the sync service and provides status information
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/azure_freeipa_sync.log"
PASSWORD_LOG="/var/log/freeipa_new_passwords.log"
SERVICE_NAME="azure-freeipa-sync"

echo -e "${BLUE}Azure FreeIPA Sync Monitor${NC}"
echo "=========================="

# Check if service exists
if ! systemctl list-unit-files | grep -q "${SERVICE_NAME}.service"; then
    echo -e "${RED}❌ Service not installed${NC}"
    exit 1
fi

# Service status
echo -e "${BLUE}Service Status:${NC}"
if systemctl is-active --quiet "${SERVICE_NAME}.timer"; then
    echo -e "  Timer: ${GREEN}Active${NC}"
else
    echo -e "  Timer: ${RED}Inactive${NC}"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}.timer"; then
    echo -e "  Timer Enabled: ${GREEN}Yes${NC}"
else
    echo -e "  Timer Enabled: ${RED}No${NC}"
fi

# Last run information
echo -e "\n${BLUE}Last Sync Information:${NC}"
if systemctl status "${SERVICE_NAME}.service" | grep -q "Active: inactive"; then
    LAST_RUN=$(systemctl show "${SERVICE_NAME}.service" -p ActiveExitTimestamp --value)
    if [ -n "$LAST_RUN" ] && [ "$LAST_RUN" != "n/a" ]; then
        echo "  Last completed: $LAST_RUN"
    else
        echo -e "  ${YELLOW}No previous runs found${NC}"
    fi
else
    echo -e "  ${YELLOW}Service currently running${NC}"
fi

# Timer schedule
echo -e "\n${BLUE}Timer Schedule:${NC}"
systemctl list-timers "${SERVICE_NAME}.timer" --no-pager 2>/dev/null | tail -n +2 | head -n 1

# Log file analysis
if [ -f "$LOG_FILE" ]; then
    echo -e "\n${BLUE}Recent Log Summary:${NC}"
    
    # Get log size
    LOG_SIZE=$(du -h "$LOG_FILE" | cut -f1)
    echo "  Log size: $LOG_SIZE"
    
    # Recent activity (last 24 hours)
    RECENT_LINES=$(grep "$(date -d '1 day ago' '+%Y-%m-%d')\|$(date '+%Y-%m-%d')" "$LOG_FILE" 2>/dev/null | wc -l)
    echo "  Recent entries (24h): $RECENT_LINES"
    
    # Last few entries
    echo -e "\n  ${BLUE}Last 5 log entries:${NC}"
    tail -5 "$LOG_FILE" 2>/dev/null | while read line; do
        if echo "$line" | grep -q "ERROR"; then
            echo -e "    ${RED}$line${NC}"
        elif echo "$line" | grep -q "WARNING"; then
            echo -e "    ${YELLOW}$line${NC}"
        elif echo "$line" | grep -q "INFO.*[Cc]ompleted\|[Ss]ummary"; then
            echo -e "    ${GREEN}$line${NC}"
        else
            echo "    $line"
        fi
    done
    
    # Recent errors
    ERROR_COUNT=$(grep "$(date '+%Y-%m-%d')" "$LOG_FILE" 2>/dev/null | grep -c "ERROR" || echo "0")
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo -e "\n  ${RED}❌ Today's errors: $ERROR_COUNT${NC}"
        echo "    Use: sudo grep ERROR $LOG_FILE | grep \"$(date '+%Y-%m-%d')\""
    else
        echo -e "  ${GREEN}✓ No errors today${NC}"
    fi
    
else
    echo -e "\n${YELLOW}Log file not found: $LOG_FILE${NC}"
fi

# New users created today
if [ -f "$PASSWORD_LOG" ]; then
    NEW_USERS_TODAY=$(grep "$(date '+%Y-%m-%d')" "$PASSWORD_LOG" 2>/dev/null | wc -l)
    echo -e "\n${BLUE}New Users:${NC}"
    if [ "$NEW_USERS_TODAY" -gt 0 ]; then
        echo -e "  ${GREEN}Users created today: $NEW_USERS_TODAY${NC}"
        echo -e "  ${YELLOW}⚠️  Check $PASSWORD_LOG for temporary passwords${NC}"
    else
        echo "  No new users created today"
    fi
fi

# Disk space check
echo -e "\n${BLUE}Storage Status:${NC}"
BACKUP_DIR="/var/backups/freeipa-sync"
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "Unknown")
    BACKUP_COUNT=$(find "$BACKUP_DIR" -name "*.tar.gz" 2>/dev/null | wc -l || echo "0")
    echo "  Backup directory: $BACKUP_SIZE ($BACKUP_COUNT backups)"
fi

# Show available disk space for logs and backups
echo "  Available space:"
df -h /var/log /var/backups 2>/dev/null | tail -n +2 | awk '{print "    " $6 ": " $4 " available"}'

# Quick actions
echo -e "\n${BLUE}Quick Actions:${NC}"
echo "  View live logs:     sudo tail -f $LOG_FILE"
echo "  Check service:      sudo systemctl status ${SERVICE_NAME}.service"
echo "  Run manual sync:    sudo systemctl start ${SERVICE_NAME}.service"
echo "  Enable timer:       sudo systemctl enable --now ${SERVICE_NAME}.timer"
echo "  Disable timer:      sudo systemctl disable --now ${SERVICE_NAME}.timer"

# Configuration check
echo -e "\n${BLUE}Configuration:${NC}"
if [ -f "/etc/azure_sync.conf" ]; then
    echo -e "  Config file: ${GREEN}Found${NC}"
    
    # Check if dry_run is enabled
    if grep -q "dry_run.*true" /etc/azure_sync.conf 2>/dev/null; then
        echo -e "  ${YELLOW}⚠️  Dry run mode is enabled${NC}"
    fi
    
    # Check backup setting
    if grep -q "backup_enabled.*false" /etc/azure_sync.conf 2>/dev/null; then
        echo -e "  ${YELLOW}⚠️  Backups are disabled${NC}"
    fi
else
    echo -e "  Config file: ${RED}Missing${NC}"
fi

echo ""