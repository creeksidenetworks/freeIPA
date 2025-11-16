# Random Password Generation Feature

## Overview
The AD-FreeIPA sync tool now automatically generates random passwords for newly created users and saves them to a CSV file for secure distribution.

## What's New

### 1. Automatic Password Generation
- When a new user is created during sync, a secure random password is automatically generated
- Password is 16 characters long by default
- Contains uppercase, lowercase, digits, and special characters
- Uses Python's `secrets` module for cryptographically strong randomness

### 2. CSV Export
- All newly created users with their passwords are saved to a CSV file
- File format: `new_users_passwords_YYYYMMDD_HHMMSS.csv`
- Columns: `username`, `email`, `password`
- File is created automatically after sync completes (only if not in dry-run mode)

## Usage

Simply run the sync command as usual:

```bash
./ad_sync.py sync --config config.yaml
```

After the sync completes, you'll see a message like:

```
✓ Saved 5 user passwords to: new_users_passwords_20251116_143022.csv
  Please secure this file and distribute passwords to users safely.
```

## Security Considerations

1. **Secure the CSV file**: The password file contains sensitive information
   - Set appropriate file permissions: `chmod 600 new_users_passwords_*.csv`
   - Store in a secure location
   - Delete after passwords are distributed

2. **Password Distribution**: 
   - Distribute passwords to users through secure channels (not email)
   - Encourage users to change passwords on first login

3. **Password Strength**:
   - Default 16-character passwords
   - Includes multiple character types for strong security
   - Uses cryptographically secure random generation

## CSV File Example

```csv
username,email,password
jdoe,jdoe@example.com,Xk9@mP2#qL8$wR4%
asmith,asmith@example.com,Tn6!bV1&hQ5^jD3*
```

## Technical Details

### Code Changes

1. **New Imports**:
   - `secrets` - Cryptographically strong random number generation
   - `string` - Character sets for password generation
   - `csv` - CSV file writing
   - `datetime` - Timestamp for filename

2. **New Function**: `generate_random_password(length=16)`
   - Generates secure passwords with mixed character types
   - Shuffles characters to avoid predictable patterns

3. **Modified `ADSync.__init__`**:
   - Added `self.new_users_passwords` list to track new users
   - Added `self.csv_file` with timestamped filename

4. **Modified `sync_users` method**:
   - Generates password for each new user
   - Sets password via FreeIPA API
   - Tracks username, email, and password for CSV export

5. **New Method**: `save_passwords_to_csv()`
   - Writes collected passwords to CSV file
   - Only runs if new users were created

6. **Modified `sync` method**:
   - Calls `save_passwords_to_csv()` after sync completes
   - Skipped in dry-run mode

## Notes

- Passwords are only generated for **newly created** users
- Existing users are not affected
- Dry-run mode does not generate passwords or create CSV files
- If password setting fails for a user, a warning is logged but sync continues
- Each sync creates a new CSV file with a unique timestamp
