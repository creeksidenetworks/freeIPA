# join-ipa.sh

This script automates joining a Rocky Linux system to a FreeIPA domain.

## Usage

```bash
sudo ./join-ipa.sh <ipa_server> -u <admin_user> -p <admin_pwd> [-h <hostname>]
```

### Arguments
- `<ipa_server>`: The FreeIPA server address (required)
- `-u <admin_user>`: FreeIPA admin username (required)
- `-p <admin_pwd>`: FreeIPA admin password (required)
- `-h <hostname>`: (Optional) Set the system hostname before joining FreeIPA

## Example

```bash
sudo ./join-ipa.sh ipa.example.com -u admin -p secret123 -h rocky-host01
```

## Notes
- You must run this script as root.
- The script will check for `ipa-client` and install it if missing.
- If `ipa-client` installation fails, you will be prompted to install it manually.
- If the `-h` option is provided, the system hostname will be updated before joining FreeIPA.

## Troubleshooting
- Ensure network connectivity to the FreeIPA server.
- Make sure the admin credentials are correct.
- If you encounter issues, check the output for error messages and resolve them as indicated.
