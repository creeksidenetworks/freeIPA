#!/usr/bin/env python3
"""
AD-FreeIPA Sync - Simple synchronization tool
Syncs users, groups, and memberships from Windows Active Directory to FreeIPA
"""

import sys
import logging
import yaml
import argparse
import struct
import warnings
from typing import Dict, List, Optional
from ldap3 import Server, Connection, ALL, SUBTREE
from ldap3.core.exceptions import LDAPException
from python_freeipa import ClientMeta
from python_freeipa.exceptions import FreeIPAError, NotFound, DuplicateEntry
from urllib3.exceptions import InsecureRequestWarning

# Suppress InsecureRequestWarning when verify_ssl is disabled
warnings.filterwarnings('ignore', category=InsecureRequestWarning)


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('ad-sync.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


def sid_to_uid(sid_bytes: bytes, id_range_base: int = 200000) -> int:
    """
    Convert Windows SID to Unix UID using SSSD's algorithm
    
    This implements the same ID mapping algorithm used by SSSD/Winbind
    to generate consistent UIDs from Windows SIDs.
    
    Args:
        sid_bytes: Raw SID bytes from AD or string SID (S-1-5-21-...)
        id_range_base: Base offset for ID range (default 200000)
    
    Returns:
        Unix UID as integer
    """
    if not sid_bytes:
        return None
    
    try:
        # Check if SID is a string (S-1-5-21-...-RID)
        if isinstance(sid_bytes, str) and sid_bytes.startswith('S-'):
            parts = sid_bytes.split('-')
            if len(parts) >= 8:
                rid = int(parts[-1])  # Last part is the RID
                return id_range_base + rid
            return None
        
        # Binary SID processing
        if len(sid_bytes) < 12:
            return None
        
        # Ensure we have bytes
        if isinstance(sid_bytes, str):
            sid_bytes = sid_bytes.encode('latin-1')
        
        # Parse SID structure
        # Format: S-1-5-21-<domain>-<domain>-<domain>-<RID>
        revision = sid_bytes[0] if isinstance(sid_bytes[0], int) else ord(sid_bytes[0])
        sub_auth_count = sid_bytes[1] if isinstance(sid_bytes[1], int) else ord(sid_bytes[1])
        
        # Authority (6 bytes, big-endian)
        authority = struct.unpack('>Q', b'\x00\x00' + sid_bytes[2:8])[0]
        
        # Sub-authorities (little-endian 32-bit integers)
        sub_authorities = []
        for i in range(sub_auth_count):
            offset = 8 + (i * 4)
            sub_auth = struct.unpack('<I', sid_bytes[offset:offset + 4])[0]
            sub_authorities.append(sub_auth)
        
        if len(sub_authorities) == 0:
            return None
        
        # RID is the last sub-authority
        rid = sub_authorities[-1]
        
        # Calculate UID using SSSD algorithm:
        # UID = id_range_base + RID
        uid = id_range_base + rid
        
        return uid
        
    except Exception as e:
        logger.warning(f"Failed to parse SID: {e}")
        return None


def sid_to_string(sid_bytes: bytes) -> str:
    """Convert binary SID to string format (S-1-5-21-...) or return if already string"""
    if not sid_bytes:
        return None
    
    # If already a string, return it
    if isinstance(sid_bytes, str) and sid_bytes.startswith('S-'):
        return sid_bytes
    
    try:
        if len(sid_bytes) < 12:
            return None
        
        # Ensure we have bytes
        if isinstance(sid_bytes, str):
            sid_bytes = sid_bytes.encode('latin-1')
        
        revision = sid_bytes[0] if isinstance(sid_bytes[0], int) else ord(sid_bytes[0])
        sub_auth_count = sid_bytes[1] if isinstance(sid_bytes[1], int) else ord(sid_bytes[1])
        authority = struct.unpack('>Q', b'\x00\x00' + sid_bytes[2:8])[0]
        
        sid_string = f"S-{revision}-{authority}"
        
        for i in range(sub_auth_count):
            offset = 8 + (i * 4)
            sub_auth = struct.unpack('<I', sid_bytes[offset:offset + 4])[0]
            sid_string += f"-{sub_auth}"
        
        return sid_string
    except:
        return None


class ADSync:
    """Main synchronization class"""
    
    def __init__(self, config_file: str):
        """Load configuration"""
        with open(config_file, 'r') as f:
            self.config = yaml.safe_load(f)
        
        self.ad_conn = None
        self.ipa_client = None
        self.stats = {
            'users_created': 0,
            'users_updated': 0,
            'users_skipped': 0,
            'users_disabled': 0,
            'users_enabled': 0,
            'groups_created': 0,
            'groups_updated': 0,
            'memberships_added': 0
        }
    
    def connect_ad(self) -> bool:
        """Connect to Active Directory"""
        try:
            ad_config = self.config['active_directory']
            server = Server(ad_config['server'], port=ad_config.get('port', 389), 
                          use_ssl=ad_config.get('use_ssl', False), get_info=ALL)
            
            self.ad_conn = Connection(server, user=ad_config['bind_dn'],
                                     password=ad_config['bind_password'], auto_bind=True)
            
            logger.info(f"✓ Connected to Active Directory: {ad_config['server']}")
            return True
        except Exception as e:
            logger.error(f"✗ Failed to connect to AD: {e}")
            return False
    
    def connect_ipa(self) -> bool:
        """Connect to FreeIPA"""
        try:
            ipa_config = self.config['freeipa']
            self.ipa_client = ClientMeta(ipa_config['server'], 
                                        verify_ssl=ipa_config.get('verify_ssl', True))
            self.ipa_client.login(ipa_config['username'], ipa_config['password'])
            
            logger.info(f"✓ Connected to FreeIPA: {ipa_config['server']}")
            return True
        except Exception as e:
            logger.error(f"✗ Failed to connect to FreeIPA: {e}")
            return False
    
    def ensure_id_range(self) -> bool:
        """Ensure FreeIPA has an ID range for the configured id_range_base"""
        try:
            id_range_base = self.config['active_directory'].get('id_range_base', 200000)
            range_name = 'AD_SYNC_RANGE'
            range_size = 200000
            
            # Check if range exists
            try:
                result = self.ipa_client.idrange_show(range_name)
                logger.info(f"✓ ID range '{range_name}' already exists")
                return True
            except NotFound:
                # Range doesn't exist, create it
                logger.info(f"Creating ID range '{range_name}' for base {id_range_base}")
                
                # Calculate RID base - use the offset from the base
                # For id_range_base=1668600000, RID base should be 600000
                rid_base = (id_range_base % 1000000000) // 1000
                secondary_rid_base = 100000000 + rid_base
                
                self.ipa_client.idrange_add(
                    range_name,
                    ipabaseid=id_range_base,
                    ipaidrangesize=range_size,
                    ipabaserid=rid_base,
                    ipasecondarybaserid=secondary_rid_base
                )
                
                logger.info(f"✓ Created ID range '{range_name}' (base: {id_range_base}, size: {range_size})")
                logger.warning("NOTE: Directory server restart recommended. Run: systemctl restart dirsrv@*.service")
                return True
                
        except Exception as e:
            logger.warning(f"Could not ensure ID range: {e}")
            logger.warning("If you get SID generation errors, manually create the ID range:")
            logger.warning(f"  ipa idrange-add AD_SYNC_RANGE --base-id={id_range_base} --range-size=200000")
            return True  # Don't fail the sync for this
    
    def get_ad_users(self) -> List[Dict]:
        """Get users from Active Directory"""
        try:
            ad_config = self.config['active_directory']
            attributes = ['sAMAccountName', 'givenName', 'sn', 'mail', 'displayName',
                         'telephoneNumber', 'title', 'department', 'userAccountControl',
                         'uidNumber', 'gidNumber', 'loginShell', 'unixHomeDirectory',
                         'objectSid', 'primaryGroupID']
            
            self.ad_conn.search(
                search_base=ad_config['user_search_base'],
                search_filter=ad_config.get('user_filter', '(objectClass=user)'),
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            users = []
            id_range_base = ad_config.get('id_range_base', 200000)
            
            for entry in self.ad_conn.entries:
                if not hasattr(entry, 'sAMAccountName') or not entry.sAMAccountName.value:
                    continue
                
                # Track disabled status instead of skipping
                uac = entry.userAccountControl.value if hasattr(entry, 'userAccountControl') else 0
                is_disabled = bool(uac and (uac & 0x0002))
                
                # Track disabled status instead of skipping
                uac = entry.userAccountControl.value if hasattr(entry, 'userAccountControl') else 0
                is_disabled = bool(uac and (uac & 0x0002))
                
                user = {'dn': entry.entry_dn, 'attributes': {}}
                for attr in attributes:
                    if hasattr(entry, attr):
                        value = getattr(entry, attr).value
                        user['attributes'][attr] = value
                
                # Store disabled status
                user['attributes']['_is_disabled'] = is_disabled
                
                # Calculate UID/GID from SID if not explicitly set
                if 'objectSid' in user['attributes'] and user['attributes']['objectSid']:
                    sid_bytes = user['attributes']['objectSid']
                    sid_string = sid_to_string(sid_bytes)
                    
                    # Calculate UID from SID if uidNumber not set
                    if 'uidNumber' not in user['attributes'] or not user['attributes']['uidNumber']:
                        calculated_uid = sid_to_uid(sid_bytes, id_range_base)
                        if calculated_uid:
                            user['attributes']['uidNumber'] = calculated_uid
                            user['attributes']['_calculated_uid'] = True
                            logger.debug(f"Calculated UID {calculated_uid} for {user['attributes']['sAMAccountName']} from SID {sid_string}")
                    
                    # Calculate GID from primaryGroupID
                    if 'primaryGroupID' in user['attributes'] and user['attributes']['primaryGroupID']:
                        primary_gid = id_range_base + user['attributes']['primaryGroupID']
                        if 'gidNumber' not in user['attributes'] or not user['attributes']['gidNumber']:
                            user['attributes']['gidNumber'] = primary_gid
                            user['attributes']['_calculated_gid'] = True
                            logger.debug(f"Calculated GID {primary_gid} for {user['attributes']['sAMAccountName']} from primaryGroupID")
                
                users.append(user)
            
            logger.info(f"Retrieved {len(users)} users from AD")
            return users
        except Exception as e:
            logger.error(f"Failed to get AD users: {e}")
            return []
    
    def get_ad_groups(self) -> List[Dict]:
        """Get groups from Active Directory"""
        try:
            ad_config = self.config['active_directory']
            attributes = ['sAMAccountName', 'cn', 'description', 'member', 'gidNumber', 'objectSid']
            
            self.ad_conn.search(
                search_base=ad_config['group_search_base'],
                search_filter=ad_config.get('group_filter', '(objectClass=group)'),
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            groups = []
            id_range_base = ad_config.get('id_range_base', 200000)
            
            for entry in self.ad_conn.entries:
                if not hasattr(entry, 'sAMAccountName') or not entry.sAMAccountName.value:
                    continue
                
                group = {'dn': entry.entry_dn, 'attributes': {}}
                for attr in attributes:
                    if hasattr(entry, attr):
                        group['attributes'][attr] = getattr(entry, attr).value
                
                # Calculate GID from SID if not explicitly set
                if 'objectSid' in group['attributes'] and group['attributes']['objectSid']:
                    sid_bytes = group['attributes']['objectSid']
                    sid_string = sid_to_string(sid_bytes)
                    
                    if 'gidNumber' not in group['attributes'] or not group['attributes']['gidNumber']:
                        calculated_gid = sid_to_uid(sid_bytes, id_range_base)  # Same algorithm for GID
                        if calculated_gid:
                            group['attributes']['gidNumber'] = calculated_gid
                            group['attributes']['_calculated_gid'] = True
                            logger.debug(f"Calculated GID {calculated_gid} for {group['attributes']['sAMAccountName']} from SID {sid_string}")
                
                groups.append(group)
            
            logger.info(f"Retrieved {len(groups)} groups from AD")
            return groups
        except Exception as e:
            logger.error(f"Failed to get AD groups: {e}")
            return []
    
    def map_user_attributes(self, ad_user: Dict) -> Dict:
        """Map AD attributes to FreeIPA attributes"""
        mapping = self.config['sync']['user_attribute_mapping']
        ad_attrs = ad_user['attributes']
        ipa_user = {}
        
        for ad_attr, ipa_attr in mapping.items():
            if ad_attr in ad_attrs and ad_attrs[ad_attr]:
                value = ad_attrs[ad_attr]
                if isinstance(value, list):
                    value = value[0] if value else None
                if value:
                    ipa_user[ipa_attr] = value
        
        # If email is not set and default_email_domain is configured, construct email
        if 'mail' not in ipa_user or not ipa_user['mail']:
            default_domain = self.config['sync'].get('default_email_domain')
            if default_domain and 'uid' in ipa_user:
                ipa_user['mail'] = f"{ipa_user['uid']}@{default_domain}"
                logger.debug(f"Generated email: {ipa_user['mail']}")
        
        return ipa_user
    
    def should_sync_user(self, username: str) -> bool:
        """Check if user should be synced based on filters"""
        include_filter = self.config['sync'].get('user_include_filter', [])
        exclude_filter = self.config['sync'].get('user_exclude_filter', [])
        
        if include_filter and username not in include_filter:
            return False
        if exclude_filter and username in exclude_filter:
            return False
        return True
    
    def should_sync_group(self, groupname: str) -> bool:
        """Check if group should be synced based on filters"""
        include_filter = self.config['sync'].get('group_include_filter', [])
        exclude_filter = self.config['sync'].get('group_exclude_filter', [])
        
        if include_filter and groupname not in include_filter:
            return False
        if exclude_filter and groupname in exclude_filter:
            return False
        return True
    
    def sync_users(self, dry_run: bool = False, force: bool = False):
        """Sync users from AD to FreeIPA"""
        logger.info("=== Starting User Sync ===")
        users = self.get_ad_users()
        
        for ad_user in users:
            username = ad_user['attributes'].get('sAMAccountName')
            if not username or not self.should_sync_user(username):
                self.stats['users_skipped'] += 1
                continue
            
            ipa_user = self.map_user_attributes(ad_user)
            is_disabled = ad_user['attributes'].get('_is_disabled', False)
            
            try:
                # Check if user exists
                existing = self.ipa_client.user_show(username)
                user_exists = True
                
                # Update existing user (always update status, check force for other attributes)
                if dry_run:
                    status_str = "disabled" if is_disabled else "enabled"
                    logger.info(f"[DRY RUN] Would update user: {username} (status: {status_str})")
                else:
                    # Update attributes if force is enabled
                    if force:
                        params = {}
                        if 'givenname' in ipa_user:
                            params['o_givenname'] = ipa_user['givenname']
                        if 'sn' in ipa_user:
                            params['o_sn'] = ipa_user['sn']
                        if 'mail' in ipa_user:
                            params['o_mail'] = ipa_user['mail']
                        if 'telephonenumber' in ipa_user:
                            params['o_telephonenumber'] = ipa_user['telephonenumber']
                        if 'title' in ipa_user:
                            params['o_title'] = ipa_user['title']
                        if 'uidnumber' in ipa_user:
                            params['o_uidnumber'] = ipa_user['uidnumber']
                        if 'gidnumber' in ipa_user:
                            params['o_gidnumber'] = ipa_user['gidnumber']
                        if 'loginshell' in ipa_user:
                            params['o_loginshell'] = ipa_user['loginshell']
                        if 'homedirectory' in ipa_user:
                            params['o_homedirectory'] = ipa_user['homedirectory']
                        
                        if params:
                            self.ipa_client.user_mod(username, **params)
                    
                    # Always update disabled/enabled status
                    ipa_is_disabled = 'nsaccountlock' in existing and existing['nsaccountlock']
                    
                    if is_disabled and not ipa_is_disabled:
                        # Disable user in FreeIPA
                        self.ipa_client.user_disable(username)
                        logger.info(f"✓ Disabled user: {username}")
                        self.stats['users_disabled'] += 1
                    elif not is_disabled and ipa_is_disabled:
                        # Enable user in FreeIPA
                        self.ipa_client.user_enable(username)
                        logger.info(f"✓ Enabled user: {username}")
                        self.stats['users_enabled'] += 1
                    else:
                        status_str = "disabled" if is_disabled else "enabled"
                        if force:
                            logger.info(f"✓ Updated user: {username} (status: {status_str})")
                        else:
                            logger.debug(f"User {username} status unchanged ({status_str})")
                
                self.stats['users_updated'] += 1
                
            except NotFound:
                # User doesn't exist, create it
                user_exists = False
                
                if dry_run:
                    status_str = "disabled" if is_disabled else "enabled"
                    logger.info(f"[DRY RUN] Would create user: {username} (status: {status_str})")
                else:
                    # FreeIPA user_add requires: uid, givenname, sn, cn as positional args
                    uid = ipa_user.get('uid', username)
                    givenname = ipa_user.get('givenname', username)
                    sn = ipa_user.get('sn', username)
                    cn = ipa_user.get('cn', f"{givenname} {sn}")
                    
                    # Optional parameters
                    params = {}
                    if 'mail' in ipa_user:
                        params['o_mail'] = ipa_user['mail']
                    if 'telephonenumber' in ipa_user:
                        params['o_telephonenumber'] = ipa_user['telephonenumber']
                    if 'title' in ipa_user:
                        params['o_title'] = ipa_user['title']
                    if 'uidnumber' in ipa_user:
                        params['o_uidnumber'] = ipa_user['uidnumber']
                    if 'gidnumber' in ipa_user:
                        params['o_gidnumber'] = ipa_user['gidnumber']
                    if 'loginshell' in ipa_user:
                        params['o_loginshell'] = ipa_user['loginshell']
                    if 'homedirectory' in ipa_user:
                        params['o_homedirectory'] = ipa_user['homedirectory']
                    
                    self.ipa_client.user_add(uid, givenname, sn, cn, **params)
                    
                    # Set disabled status after creation if needed
                    if is_disabled:
                        self.ipa_client.user_disable(username)
                        logger.info(f"✓ Created user: {username} (disabled)")
                    else:
                        logger.info(f"✓ Created user: {username}")
                
                self.stats['users_created'] += 1
            
            except Exception as e:
                logger.error(f"✗ Failed to sync user {username}: {e}")
    
    def sync_groups(self, dry_run: bool = False, force: bool = False):
        """Sync groups from AD to FreeIPA"""
        logger.info("=== Starting Group Sync ===")
        groups = self.get_ad_groups()
        
        for ad_group in groups:
            groupname = ad_group['attributes'].get('sAMAccountName')
            if not groupname or not self.should_sync_group(groupname):
                continue
            
            # Sanitize group name - FreeIPA only allows letters, numbers, _, -, . and $
            # Replace spaces and other invalid chars with hyphen
            sanitized_groupname = groupname.replace(' ', '-').replace('(', '').replace(')', '')
            if sanitized_groupname != groupname:
                logger.debug(f"Sanitized group name: '{groupname}' -> '{sanitized_groupname}'")
                groupname = sanitized_groupname
            
            try:
                # Check if group exists
                existing = self.ipa_client.group_show(groupname)
                
                # Skip existing group unless force is enabled
                if not force:
                    logger.debug(f"Group {groupname} already exists, skipping (use --force-groups to update)")
                    self.stats['groups_updated'] += 1
                    continue
                
                if dry_run:
                    logger.info(f"[DRY RUN] Would update group: {groupname}")
                else:
                    logger.info(f"✓ Updated group: {groupname}")
                
                self.stats['groups_updated'] += 1
                
            except NotFound:
                # Group doesn't exist, create it
                if dry_run:
                    logger.info(f"[DRY RUN] Would create group: {groupname}")
                else:
                    description = ad_group['attributes'].get('description', '')
                    if isinstance(description, list):
                        description = description[0] if description else ''
                    
                    # FreeIPA group_add parameters
                    params = {}
                    if description:
                        params['o_description'] = description
                    if 'gidNumber' in ad_group['attributes']:
                        params['o_gidnumber'] = ad_group['attributes']['gidNumber']
                    
                    self.ipa_client.group_add(groupname, **params)
                    logger.info(f"✓ Created group: {groupname}")
                
                self.stats['groups_created'] += 1
            
            except Exception as e:
                logger.error(f"✗ Failed to sync group {groupname}: {e}")
    
    def sync_memberships(self, dry_run: bool = False):
        """Sync group memberships"""
        logger.info("=== Starting Membership Sync ===")
        groups = self.get_ad_groups()
        
        for ad_group in groups:
            groupname = ad_group['attributes'].get('sAMAccountName')
            if not groupname or not self.should_sync_group(groupname):
                continue
            
            # Sanitize group name to match what was created
            sanitized_groupname = groupname.replace(' ', '-').replace('(', '').replace(')', '')
            if sanitized_groupname != groupname:
                logger.debug(f"Using sanitized group name: '{groupname}' -> '{sanitized_groupname}'")
                groupname = sanitized_groupname
            
            members = ad_group['attributes'].get('member', [])
            if not isinstance(members, list):
                members = [members] if members else []
            
            # Separate users and groups by querying AD for each member's objectClass and sAMAccountName
            ad_usernames = set()
            ad_groupnames = set()
            
            for member_dn in members:
                # Query AD to get the sAMAccountName and objectClass
                try:
                    self.ad_conn.search(
                        search_base=self.config['active_directory']['base_dn'],
                        search_filter=f'(distinguishedName={member_dn})',
                        search_scope=SUBTREE,
                        attributes=['sAMAccountName', 'objectClass']
                    )
                    
                    if self.ad_conn.entries:
                        entry = self.ad_conn.entries[0]
                        sam_account_name = entry.sAMAccountName.value if hasattr(entry, 'sAMAccountName') else None
                        
                        if not sam_account_name:
                            logger.debug(f"No sAMAccountName for {member_dn}, skipping")
                            continue
                        
                        obj_classes = entry.objectClass.value
                        if isinstance(obj_classes, list):
                            obj_classes = [c.lower() for c in obj_classes]
                        else:
                            obj_classes = [obj_classes.lower()]
                        
                        if 'group' in obj_classes:
                            ad_groupnames.add(sam_account_name)
                        else:
                            ad_usernames.add(sam_account_name)
                    else:
                        logger.debug(f"Member not found: {member_dn}")
                except Exception as e:
                    logger.debug(f"Failed to query member {member_dn}: {e}")
            
            try:
                # Get current FreeIPA group members
                ipa_group = self.ipa_client.group_show(groupname)
                ipa_user_members = set(ipa_group.get('member_user', []))
                ipa_group_members = set(ipa_group.get('member_group', []))
                
                # Add missing user members
                for username in ad_usernames - ipa_user_members:
                    if dry_run:
                        logger.info(f"[DRY RUN] Would add user {username} to {groupname}")
                    else:
                        try:
                            self.ipa_client.group_add_member(groupname, o_user=username)
                            logger.info(f"✓ Added user {username} to {groupname}")
                            self.stats['memberships_added'] += 1
                        except Exception as e:
                            logger.error(f"✗ Failed to add user {username} to {groupname}: {e}")
                
                # Add missing group members
                for member_groupname in ad_groupnames - ipa_group_members:
                    if dry_run:
                        logger.info(f"[DRY RUN] Would add group {member_groupname} to {groupname}")
                    else:
                        try:
                            # Sanitize group name
                            group_to_add = member_groupname.replace(' ', '-').replace('(', '').replace(')', '')
                            self.ipa_client.group_add_member(groupname, o_group=group_to_add)
                            logger.info(f"✓ Added group {group_to_add} to {groupname}")
                            self.stats['memberships_added'] += 1
                        except Exception as e:
                            logger.error(f"✗ Failed to add group {member_groupname} to {groupname}: {e}")
            
            except Exception as e:
                logger.error(f"✗ Failed to sync memberships for {groupname}: {e}")
    
    def sync(self, dry_run: bool = False, force_users: bool = False, force_groups: bool = False):
        """Run full synchronization"""
        if dry_run:
            logger.info("=== DRY RUN MODE - No changes will be made ===")
        
        if not self.connect_ad() or not self.connect_ipa():
            return False
        
        # Ensure ID range exists for SID generation
        self.ensure_id_range()
        
        try:
            if self.config['sync'].get('sync_users', True):
                self.sync_users(dry_run, force_users)
            
            if self.config['sync'].get('sync_groups', True):
                self.sync_groups(dry_run, force_groups)
            
            if self.config['sync'].get('sync_group_memberships', True):
                self.sync_memberships(dry_run)
            
            # Print statistics
            logger.info("\n" + "="*60)
            logger.info("SYNC SUMMARY")
            logger.info("="*60)
            logger.info(f"Users Created:    {self.stats['users_created']}")
            logger.info(f"Users Updated:    {self.stats['users_updated']}")
            logger.info(f"Users Disabled:   {self.stats['users_disabled']}")
            logger.info(f"Users Enabled:    {self.stats['users_enabled']}")
            logger.info(f"Users Skipped:    {self.stats['users_skipped']}")
            logger.info(f"Groups Created:   {self.stats['groups_created']}")
            logger.info(f"Groups Updated:   {self.stats['groups_updated']}")
            logger.info(f"Memberships:      {self.stats['memberships_added']}")
            logger.info("="*60)
            
            return True
        
        finally:
            if self.ad_conn:
                self.ad_conn.unbind()
            logger.info("Disconnected")
    
    def test_connections(self):
        """Test AD and FreeIPA connections"""
        logger.info("Testing connections...")
        
        ad_ok = self.connect_ad()
        ipa_ok = self.connect_ipa()
        
        if ad_ok and ipa_ok:
            logger.info("✓ All connections successful!")
            if self.ad_conn:
                self.ad_conn.unbind()
            return True
        else:
            logger.error("\n✗ Connection test failed")
            return False
    
    def show_user_ids(self, username: str):
        """Show UID/GID calculation for a specific user"""
        if not self.connect_ad():
            return False
        
        try:
            ad_config = self.config['active_directory']
            attributes = ['sAMAccountName', 'objectSid', 'primaryGroupID', 'uidNumber', 'gidNumber']
            
            self.ad_conn.search(
                search_base=ad_config['user_search_base'],
                search_filter=f'(&(objectClass=user)(sAMAccountName={username}))',
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            if not self.ad_conn.entries:
                logger.error(f"User '{username}' not found in AD")
                return False
            
            entry = self.ad_conn.entries[0]
            
            logger.info("\n" + "="*70)
            logger.info(f"User: {username}")
            logger.info("="*70)
            
            if hasattr(entry, 'objectSid') and entry.objectSid.value:
                sid_value = entry.objectSid.value
                
                logger.debug(f"Raw SID type: {type(sid_value)}")
                
                # Check if SID is returned as string (S-1-5-21-...) or binary
                if isinstance(sid_value, str) and sid_value.startswith('S-'):
                    # SID is in string format: S-1-5-21-<sub>-<sub>-<sub>-<RID>
                    sid_string = sid_value
                    parts = sid_string.split('-')
                    if len(parts) >= 8:  # S-1-5-21-<sub>-<sub>-<sub>-<RID>
                        rid = int(parts[-1])  # Last part is the RID
                        
                        logger.info(f"SID:                {sid_string}")
                        logger.info(f"RID:                {rid}")
                        logger.info("")
                        
                        # Show what UID would be with current config
                        id_range_base = ad_config.get('id_range_base', 200000)
                        calculated_uid = id_range_base + rid
                        
                        logger.info(f"Current id_range_base: {id_range_base}")
                        logger.info(f"Calculated UID:        {calculated_uid}")
                        logger.info("")
                        
                        # Check if AD has explicit Unix attributes
                        if hasattr(entry, 'uidNumber') and entry.uidNumber.value:
                            logger.info(f"AD uidNumber:          {entry.uidNumber.value} (stored in AD)")
                        else:
                            logger.info(f"AD uidNumber:          Not set (using SID mapping)")
                        
                        if hasattr(entry, 'gidNumber') and entry.gidNumber.value:
                            logger.info(f"AD gidNumber:          {entry.gidNumber.value} (stored in AD)")
                        elif hasattr(entry, 'primaryGroupID') and entry.primaryGroupID.value:
                            primary_gid = id_range_base + entry.primaryGroupID.value
                            logger.info(f"AD gidNumber:          Not set")
                            logger.info(f"Primary Group ID:      {entry.primaryGroupID.value}")
                            logger.info(f"Calculated GID:        {primary_gid}")
                        
                        logger.info("")
                        logger.info("To match your existing Linux UID, calculate:")
                        logger.info(f"  id_range_base = <your_linux_uid> - {rid}")
                        logger.info("")
                        logger.info("Example: If 'id jtong' shows uid=1668601105")
                        example_result = 1668601105 - rid
                        logger.info(f"  id_range_base = 1668601105 - {rid} = {example_result}")
                        logger.info("")
                        logger.info("Update 'id_range_base' in config.yaml to match")
                    else:
                        logger.error(f"Unexpected SID format: {sid_string}")
                else:
                    # Binary SID format
                    sid_bytes = sid_value if isinstance(sid_value, bytes) else sid_value.encode('latin-1')
                    sid_string = sid_to_string(sid_bytes)
                    
                    # Parse RID
                    if len(sid_bytes) >= 12:
                        sub_auth_count = sid_bytes[1] if isinstance(sid_bytes[1], int) else ord(sid_bytes[1])
                        logger.debug(f"sub_auth_count: {sub_auth_count}")
                        offset = 8 + ((sub_auth_count - 1) * 4)
                        logger.debug(f"Trying to read RID at offset {offset}, buffer length: {len(sid_bytes)}")
                        rid = struct.unpack('<I', sid_bytes[offset:offset + 4])[0]
                        
                        logger.info(f"SID:                {sid_string}")
                        logger.info(f"RID:                {rid}")
                        logger.info("")
                        
                        # Show what UID would be with current config
                        id_range_base = ad_config.get('id_range_base', 200000)
                        calculated_uid = id_range_base + rid
                        
                        logger.info(f"Current id_range_base: {id_range_base}")
                        logger.info(f"Calculated UID:        {calculated_uid}")
                        logger.info("")
                        
                        # Check if AD has explicit Unix attributes
                        if hasattr(entry, 'uidNumber') and entry.uidNumber.value:
                            logger.info(f"AD uidNumber:          {entry.uidNumber.value} (stored in AD)")
                        else:
                            logger.info(f"AD uidNumber:          Not set (using SID mapping)")
                        
                        if hasattr(entry, 'gidNumber') and entry.gidNumber.value:
                            logger.info(f"AD gidNumber:          {entry.gidNumber.value} (stored in AD)")
                        elif hasattr(entry, 'primaryGroupID') and entry.primaryGroupID.value:
                            primary_gid = id_range_base + entry.primaryGroupID.value
                            logger.info(f"AD gidNumber:          Not set")
                            logger.info(f"Primary Group ID:      {entry.primaryGroupID.value}")
                            logger.info(f"Calculated GID:        {primary_gid}")
                        
                        logger.info("")
                        logger.info("To match your existing Linux UID, calculate:")
                        logger.info(f"  id_range_base = <your_linux_uid> - {rid}")
                        logger.info("")
                        logger.info("Example: If 'id jtong' shows uid=1668601105")
                        example_result = 1668601105 - rid
                        logger.info(f"  id_range_base = 1668601105 - {rid} = {example_result}")
                        logger.info("")
                        logger.info("Update 'id_range_base' in config.yaml to match")
            
            logger.info("="*70)
            
            return True
            
        except Exception as e:
            import traceback
            logger.error(f"Failed to get user info: {e}")
            logger.debug(traceback.format_exc())
            return False
        finally:
            if self.ad_conn:
                self.ad_conn.unbind()


def main():
    parser = argparse.ArgumentParser(description='AD-FreeIPA Sync Tool')
    parser.add_argument('command', choices=['sync', 'test', 'show-id'], 
                       help='Command to run: sync, test, or show-id')
    parser.add_argument('--config', '-c', default='config.yaml',
                       help='Configuration file (default: config.yaml)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Run in dry-run mode (no changes)')
    parser.add_argument('--force-users', action='store_true',
                       help='Force update existing users (default: skip existing users)')
    parser.add_argument('--force-groups', action='store_true',
                       help='Force update existing groups (default: skip existing groups)')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose output')
    parser.add_argument('--user', '-u', type=str,
                       help='Username (for show-id command)')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    try:
        sync = ADSync(args.config)
        
        if args.command == 'test':
            sys.exit(0 if sync.test_connections() else 1)
        
        elif args.command == 'show-id':
            if not args.user:
                logger.error("--user required for show-id command")
                logger.error("Example: ./ad_sync.py show-id --user jtong")
                sys.exit(1)
            sys.exit(0 if sync.show_user_ids(args.user) else 1)
        
        elif args.command == 'sync':
            sys.exit(0 if sync.sync(args.dry_run, args.force_users, args.force_groups) else 1)
    
    except FileNotFoundError:
        logger.error(f"Configuration file not found: {args.config}")
        sys.exit(1)
    except KeyboardInterrupt:
        logger.info("\nSync interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
