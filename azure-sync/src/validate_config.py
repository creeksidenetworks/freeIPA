#!/usr/bin/env python3
"""
Configuration Validator for Azure FreeIPA Sync

This script validates the configuration file and tests connectivity
to both Azure Entra ID and FreeIPA before running the sync.
"""

import os
import sys
import configparser
import argparse
from pathlib import Path

def validate_config_file(config_path: str) -> bool:
    """Validate the configuration file format and required sections."""
    if not os.path.exists(config_path):
        print(f"❌ Configuration file not found: {config_path}")
        return False
    
    config = configparser.ConfigParser()
    try:
        config.read(config_path)
    except Exception as e:
        print(f"❌ Error reading configuration file: {e}")
        return False
    
    # Check required sections
    required_sections = ['azure', 'freeipa', 'sync', 'mapping']
    missing_sections = []
    
    for section in required_sections:
        if section not in config.sections():
            missing_sections.append(section)
    
    if missing_sections:
        print(f"❌ Missing required sections: {', '.join(missing_sections)}")
        return False
    
    # Check required Azure settings
    azure_required = ['tenant_id', 'client_id', 'client_secret']
    for setting in azure_required:
        if not config.get('azure', setting, fallback='').strip('"'):
            print(f"❌ Missing Azure setting: {setting}")
            return False
    
    # Check required FreeIPA settings
    freeipa_required = ['server', 'domain', 'realm', 'admin_user', 'admin_password']
    for setting in freeipa_required:
        if not config.get('freeipa', setting, fallback='').strip('"'):
            print(f"❌ Missing FreeIPA setting: {setting}")
            return False
    
    print("✓ Configuration file format is valid")
    return True

def test_azure_connectivity(config: configparser.ConfigParser) -> bool:
    """Test connectivity to Azure Entra ID."""
    try:
        from msal import ConfidentialClientApplication
        import requests
        
        tenant_id = config.get('azure', 'tenant_id').strip('"')
        client_id = config.get('azure', 'client_id').strip('"')
        client_secret = config.get('azure', 'client_secret').strip('"')
        
        authority = f"https://login.microsoftonline.com/{tenant_id}"
        
        app = ConfidentialClientApplication(
            client_id=client_id,
            client_credential=client_secret,
            authority=authority
        )
        
        scopes = ["https://graph.microsoft.com/.default"]
        result = app.acquire_token_for_client(scopes=scopes)
        
        if "access_token" in result:
            # Test a simple Graph API call
            headers = {
                'Authorization': f'Bearer {result["access_token"]}',
                'Content-Type': 'application/json'
            }
            
            response = requests.get(
                "https://graph.microsoft.com/v1.0/users?$top=1",
                headers=headers
            )
            
            if response.status_code == 200:
                print("✓ Azure Entra ID connectivity successful")
                return True
            else:
                print(f"❌ Azure Graph API test failed: {response.status_code}")
                return False
        else:
            print(f"❌ Azure authentication failed: {result.get('error_description', 'Unknown error')}")
            return False
            
    except ImportError as e:
        print(f"❌ Missing Azure dependencies: {e}")
        return False
    except Exception as e:
        print(f"❌ Azure connectivity test failed: {e}")
        return False

def test_freeipa_connectivity(config: configparser.ConfigParser) -> bool:
    """Test connectivity to FreeIPA."""
    try:
        from python_freeipa import ClientMeta
        
        server = config.get('freeipa', 'server').strip('"')
        admin_user = config.get('freeipa', 'admin_user').strip('"')
        admin_password = config.get('freeipa', 'admin_password').strip('"')
        
        client = ClientMeta(server, verify_ssl=True)
        client.login(admin_user, admin_password)
        
        # Test a simple API call
        result = client.user_find()
        
        print("✓ FreeIPA connectivity successful")
        return True
        
    except ImportError as e:
        print(f"❌ Missing FreeIPA dependencies: {e}")
        return False
    except Exception as e:
        print(f"❌ FreeIPA connectivity test failed: {e}")
        return False

def check_system_requirements() -> bool:
    """Check system requirements."""
    issues = []
    
    # Check if running as root
    if os.geteuid() != 0:
        issues.append("Must run as root for FreeIPA operations")
    
    # Check Python version
    if sys.version_info < (3, 9):
        issues.append("Python 3.9+ is required")
    
    # Check for FreeIPA installation
    if not Path("/usr/bin/ipa").exists():
        issues.append("FreeIPA client tools not found")
    
    # Check log directory permissions
    log_dir = "/var/log"
    if not os.access(log_dir, os.W_OK):
        issues.append(f"Cannot write to log directory: {log_dir}")
    
    if issues:
        print("❌ System requirement issues:")
        for issue in issues:
            print(f"   - {issue}")
        return False
    
    print("✓ System requirements check passed")
    return True

def main():
    """Main validation function."""
    parser = argparse.ArgumentParser(description='Validate Azure FreeIPA Sync Configuration')
    parser.add_argument(
        '-c', '--config',
        default='/etc/azure_sync.conf',
        help='Configuration file path'
    )
    parser.add_argument(
        '--skip-connectivity',
        action='store_true',
        help='Skip connectivity tests'
    )
    
    args = parser.parse_args()
    
    print("Azure FreeIPA Sync - Configuration Validator")
    print("=" * 45)
    
    success = True
    
    # System requirements check
    if not check_system_requirements():
        success = False
    
    # Configuration file validation
    if not validate_config_file(args.config):
        success = False
        return 1
    
    # Load configuration for connectivity tests
    config = configparser.ConfigParser()
    config.read(args.config)
    
    if not args.skip_connectivity:
        print("\nTesting connectivity...")
        
        # Test Azure connectivity
        if not test_azure_connectivity(config):
            success = False
        
        # Test FreeIPA connectivity  
        if not test_freeipa_connectivity(config):
            success = False
    
    print("\n" + "=" * 45)
    if success:
        print("✅ All validation checks passed!")
        print("The sync tool is ready to use.")
    else:
        print("❌ Validation failed!")
        print("Please fix the issues above before running the sync.")
    
    return 0 if success else 1

if __name__ == "__main__":
    sys.exit(main())