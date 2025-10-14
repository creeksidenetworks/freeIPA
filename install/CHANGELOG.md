# Improvements from centos.sh to install-ipa.sh

## Key Issues Fixed from the Old Script

### 1. **Missing IDM Repository Configuration** (The main issue you mentioned)
**Old centos.sh**: Missing proper IDM module configuration for Rocky 8/9
```bash
# Old script was missing this critical step for Rocky/RHEL 8+
```

**New install-ipa.sh**: Proper IDM module setup
```bash
setup_repositories() {
    log "Setting up IDM module and repositories..."
    
    # Enable IDM module for Rocky/RHEL 8/9
    if command -v dnf >/dev/null 2>&1; then
        dnf module list idm 2>/dev/null | grep -q "idm" && dnf module enable -y idm:DL1 || true
        dnf install -y epel-release
    else
        yum install -y epel-release
    fi
    
    log "Repositories configured successfully"
}
```

### 2. **Modern Package Management**
**Old**: Mixed yum/dnf usage without proper detection
**New**: Intelligent package manager detection and usage

### 3. **Command Line Interface**
**Old**: Interactive prompts only
**New**: Full command-line argument support with validation
```bash
Usage: ./install-ipa.sh -h <fqdn> [-r] [-d <dm_password>] [-p <admin_password>]
```

### 4. **Error Handling and Logging**
**Old**: Basic error handling
**New**: Comprehensive logging with timestamps and structured error handling
```bash
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}
```

### 5. **OS Detection and Validation**
**Old**: Assumed CentOS 7
**New**: Proper Rocky Linux 8/9 and RHEL 8/9 detection
```bash
detect_os() {
    if [[ -f /etc/rocky-release ]]; then
        local version=$(grep -oE '[0-9]+' /etc/rocky-release | head -1)
        if [[ "$version" == "8" || "$version" == "9" ]]; then
            log "Detected Rocky Linux $version"
            return 0
        fi
    fi
    # ... additional OS detection logic
}
```

### 6. **Security Improvements**
**Old**: Passwords scattered in logs
**New**: Secure password file with proper permissions
```bash
save_passwords() {
    cat > "$LOG_FILE.passwords" << EOF
FreeIPA Installation Passwords
# ... password details
EOF
    chmod 600 "$LOG_FILE.passwords"
    log "Passwords saved to: $LOG_FILE.passwords"
}
```

### 7. **FreeRADIUS Configuration**
**Old**: Manual configuration steps
**New**: Automated and comprehensive RADIUS setup
```bash
configure_freeradius() {
    # Automated LDAP configuration
    # MS-CHAPv2 support with ipaNTHash
    # Group membership in RADIUS replies
    # Client configuration
    # Certificate generation
}
```

## Major Architectural Changes

| Aspect | Old centos.sh | New install-ipa.sh |
|--------|---------------|-------------------|
| **Target OS** | CentOS 7 | Rocky Linux 8/9, RHEL 8/9 |
| **Interface** | Interactive only | Command-line arguments |
| **Error Handling** | Basic | Comprehensive with logging |
| **Package Management** | yum focused | dnf/yum intelligent detection |
| **Repository Setup** | Missing IDM config | Proper IDM module enabling |
| **Password Management** | Inline prompts | Secure generation + file storage |
| **Modularity** | Monolithic functions | Clean, focused functions |
| **Documentation** | Minimal comments | Comprehensive docs + examples |

## Specific Technical Fixes

### IDM Module Configuration (Primary Fix)
The old script was missing the crucial IDM module enablement:
```bash
# This was missing in centos.sh but critical for Rocky 8/9
dnf module enable -y idm:DL1
```

### Package Installation Updates
Updated package lists for Rocky 8/9:
```bash
# Old packages that may not exist or have different names
# New verified package list for Rocky 8/9
local packages=(
    "bind" "bind-dyndb-ldap" "ipa-server" "ipa-server-dns" 
    "freeipa-server-trust-ad" "freeradius" "freeradius-ldap" 
    "freeradius-krb5" "freeradius-utils"
)
```

### Network Configuration Improvements
Better IP address detection and validation:
```bash
get_primary_ip() {
    local interface=$(get_primary_interface)
    [[ -z "$interface" ]] && error_exit "Could not determine primary network interface"
    
    ip -4 addr show "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}
```

## Usage Comparison

### Old Way (centos.sh)
```bash
# Interactive prompts throughout installation
# No command-line options
# Manual configuration steps
# OS-specific hardcoded paths
```

### New Way (install-ipa.sh)
```bash
# Standalone installation
sudo ./install-ipa.sh -h ipa.example.com

# Replica installation  
sudo ./install-ipa.sh -h ipa2.example.com -r

# With custom passwords
sudo ./install-ipa.sh -h ipa.example.com -d MyDMPass123 -p MyAdminPass123
```

## Benefits of the Rewrite

1. ✅ **Rocky Linux 8/9 Compatibility**: Proper IDM module configuration
2. ✅ **Automation Ready**: Command-line interface for scripts/CI
3. ✅ **Better Security**: Separate password files with proper permissions
4. ✅ **Error Recovery**: Detailed logging and error reporting
5. ✅ **Maintainability**: Clean, modular code structure
6. ✅ **Documentation**: Comprehensive usage examples and troubleshooting
7. ✅ **Validation**: Input validation and OS detection
8. ✅ **Modern Practices**: Uses current best practices for shell scripting

The new script addresses all the issues from the 5-year-old centos.sh while adding modern features and Rocky Linux 8/9 support.