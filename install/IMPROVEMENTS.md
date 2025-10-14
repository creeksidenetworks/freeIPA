# Improvements from centos.sh to install-ipa.sh

## Key Issues Fixed from CentOS 7 Script

### 1. **Repository Configuration**
- **Old Problem**: Missing IDM source configuration for Rocky 8/9
- **New Solution**: 
  ```bash
  # Enable IDM module for Rocky/RHEL 8/9
  dnf module enable -y idm:DL1
  dnf install -y epel-release
  ```

### 2. **Package Management**
- **Old**: Used `yum` directly with basic error handling
- **New**: Unified package management with dnf/yum detection and comprehensive error handling

### 3. **Command Line Interface**
- **Old**: Interactive prompts only
- **New**: Command-line arguments with validation:
  ```bash
  ./install-ipa.sh -h ipa.example.com -r -d MyDMPass123 -p MyAdminPass123
  ```

### 4. **Error Handling & Logging**
- **Old**: Basic error output
- **New**: Comprehensive logging with timestamps and error tracking:
  ```bash
  LOG_FILE="/tmp/install-ipa-$(date +%Y%m%d-%H%M%S).log"
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
  ```

### 5. **Password Management** 
- **Old**: Manual password entry
- **New**: Automatic generation with secure storage:
  ```bash
  generate_password() { openssl rand -base64 12 | tr -d "=+/" | cut -c1-12; }
  ```

### 6. **FreeRADIUS Configuration**
- **Old**: Basic LDAP integration
- **New**: Complete MS-CHAPv2 support with ipaNTHash:
  ```bash
  # Configure NT-Password attribute for MS-CHAPv2
  sed -i '/control:NT-Password/c\\t\tcontrol:NT-Password\t\t:= '\''ipaNTHash'\''' "$ldap_config"
  ```

### 7. **OS Detection**
- **Old**: Assumed CentOS 7 environment
- **New**: Proper Rocky Linux 8/9 and RHEL 8/9 detection:
  ```bash
  detect_os() {
    if [[ -f /etc/rocky-release ]]; then
      local version=$(grep -oE '[0-9]+' /etc/rocky-release | head -1)
      if [[ "$version" == "8" || "$version" == "9" ]]; then
        log "Detected Rocky Linux $version"
      fi
    fi
  }
  ```

## Architecture Improvements

### Modular Design
- **Functions**: Each major task has its own function
- **Separation**: Clear separation between standalone and replica installation
- **Reusability**: Helper functions can be reused across different installation modes

### Configuration Management
- **Centralized**: All configuration files in `/etc/creekside/radius/`  
- **Backup**: Original files are backed up before modification
- **Linking**: Symbolic links maintain system integrity

### Security Enhancements
- **Password Files**: Secure storage with restricted permissions (600)
- **Validation**: Input validation for FQDN and other parameters  
- **Logging**: Complete audit trail of installation steps

## Usage Comparison

### Old Script (centos.sh)
```bash
# Interactive only
sudo ./centos.sh
# Then navigate menus and enter values manually
```

### New Script (install-ipa.sh)
```bash
# Command line driven
sudo ./install-ipa.sh -h ipa.example.com                    # Standalone
sudo ./install-ipa.sh -h ipa2.example.com -r               # Replica  
sudo ./install-ipa.sh -h ipa.example.com -d pass -p pass   # Custom passwords
```

## Testing & Validation

The new script includes:
- Syntax validation (`bash -n`)
- Argument parsing validation
- OS compatibility checks
- Network configuration validation
- Service status verification

## Maintenance Benefits

1. **Easier Updates**: Modular design allows targeted updates
2. **Better Debugging**: Comprehensive logging helps troubleshoot issues
3. **Documentation**: Self-documenting with clear usage examples
4. **Automation Ready**: Can be integrated into automation pipelines