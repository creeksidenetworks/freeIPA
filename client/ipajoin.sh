#!/bin/bash
# Usage: ipajoin.sh <ipa_server> -u <admin_user> -p <admin_pwd>


function usage() {
    echo "Usage: $0 <ipa_server> -u <admin_user> -p <admin_pwd>"
    exit 1
}

function main() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root. Exiting."
        exit 1
    fi

    if [ "$#" -lt 5 ]; then
        usage
    fi

    IPA_SERVER="$1"
    shift

    ADMIN_USER=""
    ADMIN_PWD=""
    HOSTNAME=""

    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            -u)
                ADMIN_USER="$2"
                shift; shift
            ;;
            -p)
                ADMIN_PWD="$2"
                shift; shift
            ;;
            -h)
                HOSTNAME="$2"
                shift; shift
            ;;
            *)
                echo "Unknown option: $key"
                usage
            ;;
        esac
    done

    if [ -z "$IPA_SERVER" ] || [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PWD" ]; then
        echo "Error: Missing required parameters."
        usage
    fi

    # Install necessary packages if not already installed
    NEEDED_PACKAGES=("realmd" "ipa-client" "sssd" "sssd-tools" "adcli" "oddjob" "oddjob-mkhomedir" "samba-common-tools")
    for pkg in "${NEEDED_PACKAGES[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            echo "$pkg not found. Installing $pkg."
            dnf install -ya "$pkg"
            if ! rpm -q "$pkg" >/dev/null 2>&1; then
                echo "$pkg installation failed. Please install $pkg manually and re-run this script."
                exit 1
            fi
        fi
    done

    # Discover IPA server and verify type
    echo "Discovering IPA server $IPA_SERVER..."
    REALM_INFO=$(realm discover "$IPA_SERVER" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$REALM_INFO" ] || ! echo "$REALM_INFO" | grep -qi 'type: kerberos' || ! echo "$REALM_INFO" | grep -qi 'server-software: ipa'; then
        echo "Failed to discover a valid FreeIPA server at $IPA_SERVER. Please check the server address, network connectivity, and ensure it is a FreeIPA server."
        exit 1
    else
        # Extract the realm name from the discovery output
        REALM=$(echo "$REALM_INFO" | grep -i 'realm-name' | awk -F: '{print $2}' | tr -d ' ')
        # Extract the domain name from the discovery output
        DOMAIN=$(echo "$REALM_INFO" | grep -i 'domain-name' | awk -F: '{print $2}' | tr -d ' ') 
        echo "✓ Found realm $REALM."
        echo "✓ Found domain $DOMAIN."
    fi


    IPA_JOIN_OPTIONS=(
        --server="$IPA_SERVER"
        --principal="$ADMIN_USER"
        --password="$ADMIN_PWD"
        --domain="$DOMAIN"
        --realm="$REALM"
        --mkhomedir
        --unattended
        --quiet
        --log-file="/var/log/ipajoin.log"
    )

    # If hostname is provided, update it
    if [ -n "$HOSTNAME" ]; then
        IPA_JOIN_OPTIONS+=("--hostname=$HOSTNAME")
    fi

    # Join the FreeIPA domain
    ipa-client-install "${IPA_JOIN_OPTIONS[@]}"
    if [ $? -eq 0 ]; then
        echo "Successfully joined $IPA_SERVER."
    else
        echo "Failed to join IPA domain. Please check the log file /var/log/ipajoin.log for more details."
        exit 2
    fi
    # Rest of the code to join the IPA server goes here...
}

main "$@"