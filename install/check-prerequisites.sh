#!/bin/bash

# ==============================================================================
# FreeIPA Installation Prerequisites Check Script
# ==============================================================================
# This script validates system prerequisites before running the main installation
# ==============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
WARNINGS=0

print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "PASS")
            echo -e "[${GREEN}✓${NC}] $message"
            ((CHECKS_PASSED++))
            ;;
        "FAIL")
            echo -e "[${RED}✗${NC}] $message"
            ((CHECKS_FAILED++))
            ;;
        "WARN")
            echo -e "[${YELLOW}⚠${NC}] $message"
            ((WARNINGS++))
            ;;
        "INFO")
            echo -e "[${YELLOW}ℹ${NC}] $message"
            ;;
    esac
}

print_header() {
    echo "========================================"
    echo " FreeIPA Prerequisites Check"
    echo "========================================"
    echo
}

check_os_support() {
    echo "Checking Operating System Support..."
    
    if [[ -f /etc/rocky-release ]]; then
        local version=$(grep -oE '[0-9]+' /etc/rocky-release | head -1)
        if [[ "$version" == "8" || "$version" == "9" ]]; then
            print_status "PASS" "Rocky Linux $version detected"
        else
            print_status "FAIL" "Unsupported Rocky Linux version: $version"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        if grep -q "Red Hat Enterprise Linux" /etc/redhat-release; then
            local version=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
            if [[ "$version" == "8" || "$version" == "9" ]]; then
                print_status "PASS" "RHEL $version detected"
            else
                print_status "FAIL" "Unsupported RHEL version: $version"
            fi
        else
            print_status "FAIL" "Unsupported Red Hat variant"
        fi
    else
        print_status "FAIL" "Unsupported operating system"
    fi
}

check_root_privileges() {
    echo
    echo "Checking User Privileges..."
    
    if [[ $EUID -eq 0 ]]; then
        print_status "PASS" "Running as root"
    else
        print_status "FAIL" "Must run as root (use sudo)"
    fi
}

check_memory() {
    echo
    echo "Checking System Resources..."
    
    local memory_mb=$(free -m | awk 'NR==2{print $2}')
    if [[ $memory_mb -ge 2048 ]]; then
        print_status "PASS" "Memory: ${memory_mb}MB (>= 2GB required)"
    elif [[ $memory_mb -ge 1024 ]]; then
        print_status "WARN" "Memory: ${memory_mb}MB (2GB+ recommended, 1GB minimum)"
    else
        print_status "FAIL" "Memory: ${memory_mb}MB (insufficient, 1GB minimum required)"
    fi
}

check_disk_space() {
    local root_space=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [[ $root_space -ge 10 ]]; then
        print_status "PASS" "Disk space: ${root_space}GB available (>= 10GB required)"
    elif [[ $root_space -ge 5 ]]; then
        print_status "WARN" "Disk space: ${root_space}GB available (10GB+ recommended)"
    else
        print_status "FAIL" "Disk space: ${root_space}GB available (insufficient, 10GB minimum required)"
    fi
}

check_network_configuration() {
    echo
    echo "Checking Network Configuration..."
    
    # Check for primary interface
    local interface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$interface" ]]; then
        print_status "PASS" "Primary network interface: $interface"
        
        # Check for IP address
        local ip=$(ip -4 addr show "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        if [[ -n "$ip" ]]; then
            print_status "PASS" "IP address: $ip"
            
            # Check if it's static (simple heuristic)
            if ip addr show "$interface" | grep -q "dynamic"; then
                print_status "WARN" "Dynamic IP detected - static IP recommended for FreeIPA"
            else
                print_status "PASS" "Static IP configuration detected"
            fi
        else
            print_status "FAIL" "No IP address found on primary interface"
        fi
    else
        print_status "FAIL" "Cannot determine primary network interface"
    fi
}

check_dns_resolution() {
    echo
    echo "Checking DNS Configuration..."
    
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup google.com >/dev/null 2>&1; then
            print_status "PASS" "DNS resolution working"
        else
            print_status "FAIL" "DNS resolution not working"
        fi
    else
        print_status "WARN" "nslookup not available for DNS testing"
    fi
    
    # Check /etc/resolv.conf
    if [[ -f /etc/resolv.conf && -s /etc/resolv.conf ]]; then
        print_status "PASS" "/etc/resolv.conf exists and is not empty"
    else
        print_status "FAIL" "/etc/resolv.conf missing or empty"
    fi
}

check_firewall() {
    echo
    echo "Checking Firewall..."
    
    if systemctl is-enabled firewalld >/dev/null 2>&1; then
        if systemctl is-active firewalld >/dev/null 2>&1; then
            print_status "PASS" "Firewalld is active and enabled"
        else
            print_status "WARN" "Firewalld is enabled but not active"
        fi
    else
        print_status "WARN" "Firewalld is not enabled (will be enabled during installation)"
    fi
}

check_selinux() {
    echo
    echo "Checking SELinux..."
    
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_status=$(getenforce)
        case $selinux_status in
            "Enforcing")
                print_status "PASS" "SELinux is enforcing (recommended)"
                ;;
            "Permissive")
                print_status "WARN" "SELinux is permissive (enforcing recommended)"
                ;;
            "Disabled")
                print_status "WARN" "SELinux is disabled (enforcing recommended)"
                ;;
        esac
    else
        print_status "WARN" "Cannot determine SELinux status"
    fi
}

check_package_manager() {
    echo
    echo "Checking Package Manager..."
    
    if command -v dnf >/dev/null 2>&1; then
        print_status "PASS" "DNF package manager available"
    elif command -v yum >/dev/null 2>&1; then
        print_status "PASS" "YUM package manager available"
    else
        print_status "FAIL" "No supported package manager found"
    fi
}

check_existing_ipa() {
    echo
    echo "Checking for Existing FreeIPA Installation..."
    
    if [[ -f /etc/ipa/default.conf ]]; then
        print_status "WARN" "Existing FreeIPA configuration detected"
        print_status "INFO" "This may be a replica installation or reinstallation"
    else
        print_status "PASS" "No existing FreeIPA installation detected"
    fi
    
    if systemctl is-active ipa >/dev/null 2>&1; then
        print_status "WARN" "FreeIPA services are currently running"
    fi
}

check_hostname() {
    echo
    echo "Checking Hostname Configuration..."
    
    local hostname=$(hostname)
    local fqdn=$(hostname -f 2>/dev/null || echo "")
    
    if [[ -n "$hostname" ]]; then
        print_status "PASS" "Hostname: $hostname"
    else
        print_status "FAIL" "No hostname configured"
    fi
    
    if [[ -n "$fqdn" && "$fqdn" != "$hostname" && "$fqdn" =~ \. ]]; then
        print_status "PASS" "FQDN: $fqdn"
    else
        print_status "WARN" "FQDN not properly configured (will be set during installation)"
    fi
}

print_summary() {
    echo
    echo "========================================"
    echo " Prerequisites Check Summary"
    echo "========================================"
    echo -e "Checks passed: ${GREEN}$CHECKS_PASSED${NC}"
    echo -e "Checks failed: ${RED}$CHECKS_FAILED${NC}" 
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    echo
    
    if [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ System appears ready for FreeIPA installation${NC}"
        if [[ $WARNINGS -gt 0 ]]; then
            echo -e "${YELLOW}⚠ Please review warnings above${NC}"
        fi
    else
        echo -e "${RED}✗ System has issues that must be resolved before installation${NC}"
        echo "Please fix the failed checks and run this script again."
        exit 1
    fi
}

# Main execution
print_header
check_root_privileges
check_os_support
check_memory
check_disk_space
check_network_configuration
check_dns_resolution
check_hostname
check_firewall
check_selinux
check_package_manager
check_existing_ipa
print_summary