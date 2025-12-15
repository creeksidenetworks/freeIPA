#!/usr/bin/env python3
"""
Azure Entra ID to FreeIPA Sync Script

This script synchronizes users and groups from Azure Entra ID to FreeIPA.
It handles user creation, group management, and assigns temporary passwords
for new users.

Requirements:
- Rocky Linux 9 with FreeIPA client/server installed
- Python 3.9+
- Required Python packages (see requirements.txt)

Author: FreeIPA Sync Tool
Version: 1.0.0
"""

import os
import sys

# Ensure system packages are preferred for FreeIPA compatibility
sys.path.insert(0, '/usr/lib64/python3.9/site-packages')
sys.path.insert(0, '/usr/lib/python3.9/site-packages')
import json
import logging
import secrets
import string
import configparser
import argparse
import time
import warnings
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple, Any
from pathlib import Path
import subprocess

# Suppress SSL warnings for self-signed certificates
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Third-party imports
try:
    import requests
    from msal import ConfidentialClientApplication
    from python_freeipa import ClientMeta
except ImportError as e:
    print(f"Missing required dependencies: {e}")
    print("Please install required packages: pip install -r requirements.txt")
    sys.exit(1)


class AzureFreeIPASync:
    """Main synchronization class for Azure Entra ID to FreeIPA sync."""
    
    def __init__(self, config_file: str):
        """Initialize the sync tool with configuration."""
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        
        # Setup logging
        self._setup_logging()
        
        # Initialize Azure and FreeIPA clients
        self.azure_client = None
        self.freeipa_client = None
        
        # Sync statistics
        self.stats = {
            'users_created': 0,
            'users_updated': 0,
            'users_errors': 0,
            'groups_created': 0,
            'groups_updated': 0,
            'groups_errors': 0,
            'start_time': None,
            'end_time': None
        }
        
        self.logger.info("Azure FreeIPA Sync initialized")
    
    def _setup_logging(self):
        """Setup logging configuration."""
        log_level = self.config.get('sync', 'log_level', fallback='INFO')
        log_file = self.config.get('sync', 'log_file', fallback='/var/log/azure_freeipa_sync.log')
        
        # Create log directory if it doesn't exist
        log_dir = os.path.dirname(log_file)
        if log_dir and not os.path.exists(log_dir):
            os.makedirs(log_dir, exist_ok=True)
        
        # Configure logging
        # Create formatters
        file_formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        console_formatter = logging.Formatter('%(asctime)s - %(message)s')
        
        # Create handlers
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(file_formatter)
        
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(console_formatter)
        
        # Configure root logger
        root_logger = logging.getLogger()
        root_logger.setLevel(getattr(logging, log_level.upper()))
        root_logger.addHandler(file_handler)
        root_logger.addHandler(console_handler)
        
        # Reduce verbosity of third-party libraries
        logging.getLogger('python_freeipa.client').setLevel(logging.WARNING)
        logging.getLogger('urllib3').setLevel(logging.WARNING)
        logging.getLogger('requests').setLevel(logging.WARNING)
        
        self.logger = logging.getLogger(__name__)
    
    def _initialize_azure_client(self) -> bool:
        """Initialize Azure Graph API client."""
        try:
            tenant_id = self.config.get('azure', 'tenant_id').strip('"')
            client_id = self.config.get('azure', 'client_id').strip('"')
            client_secret = self.config.get('azure', 'client_secret').strip('"')
            
            authority = f"https://login.microsoftonline.com/{tenant_id}"
            
            self.azure_client = ConfidentialClientApplication(
                client_id=client_id,
                client_credential=client_secret,
                authority=authority
            )
            
            # Test authentication
            scopes = ["https://graph.microsoft.com/.default"]
            result = self.azure_client.acquire_token_silent(scopes, account=None)
            
            if not result:
                result = self.azure_client.acquire_token_for_client(scopes=scopes)
            
            if "access_token" in result:
                self.access_token = result["access_token"]
                self.logger.info("Successfully authenticated with Azure")
                return True
            else:
                self.logger.error(f"Azure authentication failed: {result.get('error_description', 'Unknown error')}")
                return False
                
        except Exception as e:
            self.logger.error(f"Failed to initialize Azure client: {e}")
            return False
    
    def _initialize_freeipa_client(self) -> bool:
        """Initialize FreeIPA client connection."""
        try:
            server = self.config.get('freeipa', 'server').strip('"')
            
            # Check for bind_dn/bind_password (preferred) or fall back to admin_user/admin_password
            if self.config.has_option('freeipa', 'bind_dn'):
                bind_dn = self.config.get('freeipa', 'bind_dn').strip('"')
                bind_password = self.config.get('freeipa', 'bind_password').strip('"')
                # Extract username from DN for login (e.g., uid=ldapauth from the full DN)
                if 'uid=' in bind_dn:
                    admin_user = bind_dn.split('uid=')[1].split(',')[0]
                else:
                    admin_user = 'admin'
                admin_password = bind_password
            else:
                # Fallback to old format
                admin_user = self.config.get('freeipa', 'admin_user').strip('"')
                admin_password = self.config.get('freeipa', 'admin_password').strip('"')
            
            verify_ssl = self.config.getboolean('freeipa', 'verify_ssl', fallback=True)
            
            # Initialize FreeIPA client
            self.freeipa_client = ClientMeta(server, verify_ssl=verify_ssl)
            self.freeipa_client.login(admin_user, admin_password)
            
            self.logger.info("Successfully connected to FreeIPA")
            return True
            
        except Exception as e:
            self.logger.error(f"Failed to initialize FreeIPA client: {e}")
            return False
    
    def _make_graph_request(self, endpoint: str) -> Optional[Dict]:
        """Make a request to Microsoft Graph API."""
        try:
            headers = {
                'Authorization': f'Bearer {self.access_token}',
                'Content-Type': 'application/json'
            }
            
            response = requests.get(f"https://graph.microsoft.com/v1.0{endpoint}", headers=headers)
            response.raise_for_status()
            
            return response.json()
            
        except requests.exceptions.RequestException as e:
            self.logger.error(f"Graph API request failed for {endpoint}: {e}")
            return None
    
    def get_azure_users(self) -> List[Dict]:
        """Fetch all users from Azure Entra ID."""
        users = []
        endpoint = "/users"
        
        # Add user filter if configured
        user_filter = self.config.get('azure', 'user_filter', fallback='').strip('"')
        if user_filter:
            endpoint += f"?$filter={user_filter}"
        
        self.logger.info("Fetching users from Azure Entra ID")
        
        while endpoint:
            response = self._make_graph_request(endpoint)
            if not response:
                break
            
            users.extend(response.get('value', []))
            endpoint = response.get('@odata.nextLink', '').replace('https://graph.microsoft.com/v1.0', '')
            
            # Rate limiting
            time.sleep(0.1)
        
        self.logger.info(f"Retrieved {len(users)} users from Azure")
        return users
    
    def get_azure_groups(self) -> List[Dict]:
        """Fetch groups from Azure Entra ID."""
        groups = []
        endpoint = "/groups"
        
        # Filter by specific groups if configured
        sync_groups = self.config.get('azure', 'sync_groups', fallback='').strip('"')
        if sync_groups:
            group_list = [g.strip() for g in sync_groups.split(',')]
            group_filters = " or ".join([f"displayName eq '{group}'" for group in group_list])
            endpoint += f"?$filter={group_filters}"
        
        self.logger.info("Fetching groups from Azure Entra ID")
        
        while endpoint:
            response = self._make_graph_request(endpoint)
            if not response:
                break
            
            groups.extend(response.get('value', []))
            endpoint = response.get('@odata.nextLink', '').replace('https://graph.microsoft.com/v1.0', '')
            
            # Rate limiting
            time.sleep(0.1)
        
        self.logger.info(f"Retrieved {len(groups)} groups from Azure")
        return groups
    
    def get_group_members(self, group_id: str) -> List[str]:
        """Get members of a specific Azure group."""
        endpoint = f"/groups/{group_id}/members"
        members = []
        
        while endpoint:
            response = self._make_graph_request(endpoint)
            if not response:
                break
            
            for member in response.get('value', []):
                if member.get('@odata.type') == '#microsoft.graph.user':
                    members.append(member.get('userPrincipalName'))
            
            endpoint = response.get('@odata.nextLink', '').replace('https://graph.microsoft.com/v1.0', '')
            time.sleep(0.1)
        
        return members
    
    def _generate_temp_password(self) -> str:
        """Generate a secure temporary password."""
        length = int(self.config.get('freeipa', 'temp_password_length', fallback='12'))
        
        # Ensure password has mix of characters (exclude ^, /, and other bash-problematic chars)
        alphabet = string.ascii_letters + string.digits + "!@#$%&*-+=_"
        password = ''.join(secrets.choice(alphabet) for _ in range(length))
        
        # Ensure at least one of each type
        if not any(c.islower() for c in password):
            password = password[:-1] + secrets.choice(string.ascii_lowercase)
        if not any(c.isupper() for c in password):
            password = password[:-1] + secrets.choice(string.ascii_uppercase)
        if not any(c.isdigit() for c in password):
            password = password[:-1] + secrets.choice(string.digits)
        
        return password
    
    def _map_azure_to_freeipa_attributes(self, azure_user: Dict) -> Dict:
        """Map Azure user attributes to FreeIPA attributes."""
        freeipa_attrs = {}
        
        # Get mapping configuration
        mapping_section = self.config['mapping'] if 'mapping' in self.config else {}
        
        # Required attributes
        upn = azure_user.get('userPrincipalName', '')
        if upn:
            freeipa_attrs['uid'] = upn.split('@')[0]  # Use username part only
            freeipa_attrs['mail'] = upn
        
        # Map configured attributes
        for azure_attr, freeipa_attr in mapping_section.items():
            freeipa_attr = freeipa_attr.strip('"')
            if azure_attr in azure_user and azure_user[azure_attr]:
                freeipa_attrs[freeipa_attr] = azure_user[azure_attr]
        
        # Default values
        freeipa_attrs['loginshell'] = self.config.get('freeipa', 'default_shell', fallback='/bin/bash').strip('"')
        
        # Generate home directory
        home_base = self.config.get('freeipa', 'default_home_base', fallback='/home').strip('"')
        freeipa_attrs['homedirectory'] = f"{home_base}/{freeipa_attrs['uid']}"
        
        return freeipa_attrs
    
    def sync_user_to_freeipa(self, azure_user: Dict) -> bool:
        """Sync a single user from Azure to FreeIPA."""
        try:
            freeipa_attrs = self._map_azure_to_freeipa_attributes(azure_user)
            uid = freeipa_attrs.get('uid')
            
            if not uid:
                self.logger.error(f"No UID found for user: {azure_user.get('userPrincipalName', 'Unknown')}")
                return False
            
            # Check if user exists in FreeIPA
            try:
                existing_user = self.freeipa_client.user_show(uid)
                # User exists, skip updates but continue for group membership
                self.logger.info(f"User {uid} already exists, skipping user updates")
                
                return True
                
            except Exception as e:
                # Check if this is actually a "user not found" error
                if "not found" not in str(e).lower():
                    self.logger.error(f"Error checking user {uid}: {e}")
                    return False
                    
                # User doesn't exist, create new user
                self.logger.info(f"Creating new user: {uid}")
                
                # Generate temporary password
                temp_password = self._generate_temp_password()
                # Don't set password during user creation - will set it via user_mod after
                # This is required because NTHash won't be created unless a password change happens
                
                # Extract required positional parameters for user_add
                o_givenname = freeipa_attrs.get('givenname', azure_user.get('givenName', ''))
                o_sn = freeipa_attrs.get('sn', azure_user.get('surname', ''))
                o_cn = azure_user.get('displayName', f"{o_givenname} {o_sn}").strip()
                
                # Ensure we have minimum required data
                if not o_givenname:
                    o_givenname = uid  # fallback to username
                if not o_sn:
                    o_sn = uid  # fallback to username
                if not o_cn:
                    o_cn = f"{o_givenname} {o_sn}"
                
                # Remove from freeipa_attrs as they're positional parameters
                freeipa_attrs.pop('givenname', None)
                freeipa_attrs.pop('sn', None)
                freeipa_attrs.pop('uid', None)  # Remove uid as it's the first positional parameter
                freeipa_attrs.pop('userpassword', None)  # Don't set password during creation
                
                # Create user with required positional parameters (without password)
                self.freeipa_client.user_add(uid, o_givenname, o_sn, o_cn, **freeipa_attrs)
                self.logger.info(f"User {uid} created, now setting password via user_mod to generate NTHash")
                
                # Set password via user_mod after user creation to trigger NTHash generation
                try:
                    self.freeipa_client.user_mod(uid, o_userpassword=temp_password)
                    self.logger.info(f"Password set for {uid} via user_mod (NTHash will be generated)")
                except Exception as pwd_error:
                    self.logger.error(f"Failed to set password for {uid}: {pwd_error}")
                    # User was created but password failed - still count as created
                
                # Set password to never expire by clearing krbpasswordexpiration
                self._set_password_never_expire(uid)
                
                self.stats['users_created'] += 1
                self.logger.info(f"Created user {uid} with temporary password: {temp_password}")
                
                # Store password securely for admin notification
                self._log_new_user_password(uid, temp_password, azure_user.get('displayName', ''))
                
                return True
                
        except Exception as e:
            self.logger.error(f"Failed to sync user {azure_user.get('userPrincipalName', 'unknown')}: {e}")
            self.stats['users_errors'] += 1
            return False
    
    def _log_new_user_password(self, uid: str, password: str, display_name: str):
        """Log new user passwords to a secure file for admin reference."""
        try:
            password_log_file = "/var/log/freeipa_new_passwords.log"
            
            # Ensure secure permissions
            if not os.path.exists(password_log_file):
                with open(password_log_file, 'w') as f:
                    f.write("# FreeIPA New User Passwords - KEEP SECURE\n")
                os.chmod(password_log_file, 0o600)
            
            with open(password_log_file, 'a') as f:
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                f.write(f"{timestamp} | {uid} | {display_name} | {password}\n")
                
        except Exception as e:
            self.logger.error(f"Failed to log password for {uid}: {e}")
    
    def _set_password_never_expire(self, uid: str):
        """Set user password to never expire using the FreeIPA client API.
        
        This is important for synced users to avoid password expiration issues.
        NTHash generation requires a password change, and we don't want that password
        to immediately expire.
        
        Sets krbpasswordexpiration to a far future date (2099-12-31 23:59:59 UTC).
        """
        try:
            # Use the FreeIPA client API to set password expiration to far future
            # The format for krbpasswordexpiration is a datetime string
            far_future = "20991231235959Z"
            
            self.freeipa_client.user_mod(uid, o_krbpasswordexpiration=far_future)
            self.logger.info(f"Password for {uid} set to never expire (expires 2099-12-31)")
            
        except Exception as e:
            error_msg = str(e).lower()
            if "no modifications" in error_msg:
                self.logger.debug(f"Password expiration for {uid} already set correctly")
            else:
                self.logger.warning(f"Could not set password expiration for {uid}: {e}")
    
    def sync_group_to_freeipa(self, azure_group: Dict) -> bool:
        """Sync a group from Azure to FreeIPA."""
        try:
            group_name = azure_group['displayName'].lower().replace(' ', '-')
            description = azure_group.get('description', azure_group['displayName'])
            
            # Check if group exists
            try:
                existing_group = self.freeipa_client.group_show(group_name)
                self.logger.info(f"Group {group_name} already exists")
                
            except Exception:
                # Create new group
                self.logger.info(f"Creating new group: {group_name}")
                self.freeipa_client.group_add(group_name, description=description)
                self.stats['groups_created'] += 1
            
            # Sync group members
            azure_members = self.get_group_members(azure_group['id'])
            
            for member_upn in azure_members:
                try:
                    member_uid = member_upn.split('@')[0]
                    
                    # Check if user exists in FreeIPA
                    try:
                        self.freeipa_client.user_show(member_uid)
                        # Add user to group
                        self.freeipa_client.group_add_member(group_name, user=member_uid)
                        
                    except Exception:
                        self.logger.warning(f"User {member_uid} not found in FreeIPA, skipping group membership")
                        
                except Exception as e:
                    self.logger.error(f"Failed to add {member_upn} to group {group_name}: {e}")
            
            return True
            
        except Exception as e:
            self.logger.error(f"Failed to sync group {azure_group.get('displayName', 'unknown')}: {e}")
            self.stats['groups_errors'] += 1
            return False
    
    def create_backup(self) -> bool:
        """Create a backup of FreeIPA data before sync."""
        if not self.config.getboolean('sync', 'backup_enabled', fallback=True):
            return True
        
        try:
            backup_dir = self.config.get('sync', 'backup_directory', fallback='/var/backups/freeipa-sync').strip('"')
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            backup_file = f"{backup_dir}/freeipa_backup_{timestamp}.ldif"
            
            # Create backup directory
            os.makedirs(backup_dir, exist_ok=True)
            
            # Export LDAP data
            import subprocess
            cmd = f"ipa-backup --data --logs {backup_dir}/ipa_backup_{timestamp}"
            
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            
            if result.returncode == 0:
                self.logger.info(f"Backup created successfully: {backup_file}")
                return True
            else:
                self.logger.error(f"Backup failed: {result.stderr}")
                return False
                
        except Exception as e:
            self.logger.error(f"Failed to create backup: {e}")
            return False
    
    def run_sync(self, dry_run: bool = None) -> bool:
        """Run the complete synchronization process."""
        if dry_run is None:
            dry_run = self.config.getboolean('sync', 'dry_run', fallback=False)
        
        self.stats['start_time'] = datetime.now()
        
        try:
            self.logger.info(f"Starting Azure to FreeIPA sync (dry_run={dry_run})")
            
            # Initialize clients
            if not self._initialize_azure_client():
                return False
            
            if not self._initialize_freeipa_client():
                return False
            
            # Create backup
            if not dry_run:
                if not self.create_backup():
                    self.logger.warning("Backup failed, continuing with sync...")
            
            # Fetch Azure data
            azure_users = self.get_azure_users()
            azure_groups = self.get_azure_groups()
            
            if dry_run:
                self.logger.info("DRY RUN MODE - No changes will be made")
                self.logger.info(f"Would sync {len(azure_users)} users and {len(azure_groups)} groups")
                return True
            
            # Sync users
            batch_size = int(self.config.get('sync', 'batch_size', fallback='50'))
            
            for i in range(0, len(azure_users), batch_size):
                batch = azure_users[i:i + batch_size]
                self.logger.info(f"Processing user batch {i//batch_size + 1} ({len(batch)} users)")
                
                for user in batch:
                    self.sync_user_to_freeipa(user)
                
                # Small delay between batches
                time.sleep(1)
            
            # Sync groups
            for group in azure_groups:
                self.sync_group_to_freeipa(group)
                time.sleep(0.5)
            
            self.stats['end_time'] = datetime.now()
            self._print_sync_summary()
            
            return True
            
        except Exception as e:
            self.logger.error(f"Sync failed: {e}")
            return False
        
        finally:
            # Cleanup connections
            if self.freeipa_client:
                try:
                    # FreeIPA client cleanup if needed
                    pass
                except Exception:
                    pass
    
    def _print_sync_summary(self):
        """Print synchronization summary."""
        duration = self.stats['end_time'] - self.stats['start_time']
        
        summary = f"""
        
=== Azure FreeIPA Sync Summary ===
Start Time: {self.stats['start_time']}
End Time: {self.stats['end_time']}
Duration: {duration}

Users:
  Created: {self.stats['users_created']}
  Updated: {self.stats['users_updated']}
  Errors: {self.stats['users_errors']}

Groups:
  Created: {self.stats['groups_created']}
  Updated: {self.stats['groups_updated']}
  Errors: {self.stats['groups_errors']}

Total Success: {self.stats['users_created'] + self.stats['users_updated'] + self.stats['groups_created'] + self.stats['groups_updated']}
Total Errors: {self.stats['users_errors'] + self.stats['groups_errors']}
        """
        
        self.logger.info(summary)


def main():
    """Main entry point for the sync script."""
    parser = argparse.ArgumentParser(description='Azure Entra ID to FreeIPA Sync Tool')
    parser.add_argument(
        '-c', '--config',
        default='/opt/azure-freeipa-sync/azure_sync.conf',
        help='Configuration file path (default: /opt/azure-freeipa-sync/azure_sync.conf)'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Run in dry-run mode (no changes made)'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Enable verbose logging'
    )
    
    args = parser.parse_args()
    
    # Check if config file exists
    if not os.path.exists(args.config):
        print(f"Configuration file not found: {args.config}")
        print("Please create the configuration file or specify a different path with -c")
        return 1
    
    # Check if running as root (required for FreeIPA operations)
    if os.geteuid() != 0:
        print("This script must be run as root for FreeIPA operations")
        return 1
    
    try:
        # Initialize sync tool
        sync_tool = AzureFreeIPASync(args.config)
        
        # Run synchronization
        success = sync_tool.run_sync(dry_run=args.dry_run)
        
        return 0 if success else 1
        
    except KeyboardInterrupt:
        print("\nSync interrupted by user")
        return 1
    except Exception as e:
        print(f"Unexpected error: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())