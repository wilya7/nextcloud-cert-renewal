#!/bin/bash
# =================================================================================
#           Nextcloud Certificate Renewal Handler for IPFire
#
# This script automates Let's Encrypt certificate renewal for a server
# on the ORANGE network. It integrates with the system logger.
#
#                               -- HOW IT WORKS --
#
# 1. It fetches the certificate details from the target server.
# 2. It parses the expiry date and checks if it's within 30 days.
# 3. If renewal is needed:
#    a. It enables a specific, pre-configured Port Forwarding rule (Port 80).
#    b. It temporarily disables the Location Block filter.
#    c. It triggers the certificate renewal on the remote server.
#    d. It logs the outcome (success or failure) to the system log.
# 4. CRITICALLY, it ensures BOTH the Port Forward and Location Block are
#    reverted to their secure, default states afterwards via a cleanup trap.
#
# =================================================================================

# --- Static Configuration ---
# Path to the IPFire configuration files.
LOCATION_BLOCK_FILE="/var/ipfire/firewall/locationblock"
PORT_FORWARD_RULES_FILE="/var/ipfire/firewall/config"
# --- End of Static Configuration ---

# --- Argument Parsing ---
# Check for a help flag first.
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 <ssh_user> <target_server_ip> <port_forward_remark>"
    echo ""
    echo "This script automates Let's Encrypt certificate renewal for a server in the IPFire DMZ."
    echo "It checks the certificate's expiry date, and if renewal is needed, it temporarily"
    echo "modifies firewall rules, runs certbot on the remote server via SSH,"
    echo "and safely restores all security settings afterwards."
    echo ""
    echo "Arguments:"
    echo "  ssh_user              The username on the target server to connect with."
    echo "  target_server_ip      The IP address of the target server in the ORANGE zone."
    echo "  port_forward_remark   The unique 'Remark' of the Port 80 NAT rule in the IPFire WUI."
    echo ""
    exit 0
fi
# Check for the correct number of operational arguments.
if [ "$#" -ne 3 ]; then
    # These echos go to stderr, which is appropriate for console errors.
    echo "ERROR: Incorrect number of arguments. Use -h or --help for usage information." >&2
    echo "Usage: $0 <ssh_user> <target_server_ip> <port_forward_remark>" >&2
    exit 1
fi
# Assign command-line arguments to variables.
SSH_USER=$1
NEXTCLOUD_SERVER=$2
PORT_FORWARD_REMARK=$3
# --- End of Argument Parsing ---

# --- Script Setup ---
# Ensure we are running as the root user.
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi
# --- End of Script Setup ---


# --- Core Functions ---
# Logging function that sends messages to the system log with a specific tag.
log() {
    logger -t "CertRenewal" "$1"
}

# Reload the firewall, making any config changes active.
reload_firewall() {
    log "Reloading firewall to apply changes..."
    # All output is now handled by the system logger automatically.
    /etc/init.d/firewall reload
}

# Control the Location Block ON or OFF.
toggle_location_block() {
    local state=$1 # Takes one argument: "on" or "off"
    log "Turning Location Block ${state^^}..."
    if [ "$state" == "on" ]; then
        sed -i 's/LOCATIONBLOCK_ENABLED=off/LOCATIONBLOCK_ENABLED=on/' "$LOCATION_BLOCK_FILE"
    else
        sed -i 's/LOCATIONBLOCK_ENABLED=on/LOCATIONBLOCK_ENABLED=off/' "$LOCATION_BLOCK_FILE"
    fi
}

# Enable or disable our specific port forwarding rule.
toggle_port_forward() {
    local state=$1 # Takes one argument: "on" (enable) or "off" (disable)
    local temp_file
    # Create a temporary file safely.
    temp_file=$(mktemp) || { log "ERROR: Failed to create temp file for firewall modification."; exit 1; }
    # First, verify the rule actually exists by checking for the unique remark.
    if ! awk -F, -v remark="$PORT_FORWARD_REMARK" '{if ($18 == remark && $33 == "dnat") exit 0} ENDFILE {exit 1}' "$PORT_FORWARD_RULES_FILE"; then
        log "ERROR: Cannot find a DNAT rule with the remark '$PORT_FORWARD_REMARK'."
        log "Please check the rule in the WUI; remark must be unique and rule type must be DNAT."
        rm -f "$temp_file"
        exit 1
    fi
    # Use awk to find the line based on remark and rule type, then set the enabled/disabled field.
    if [ "$state" == "on" ]; then
        log "ENABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        awk -v remark="$PORT_FORWARD_REMARK" 'BEGIN{FS=OFS=","} {if($18==remark && $33=="dnat"){$4="ON"}; print}' "$PORT_FORWARD_RULES_FILE" > "$temp_file"
    else
        log "DISABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        awk -v remark="$PORT_FORWARD_REMARK" 'BEGIN{FS=OFS=","} {if($18==remark && $33=="dnat"){$4=""}; print}' "$PORT_FORWARD_RULES_FILE" > "$temp_file"
    fi
    # Atomically and safely replace the original file with the modified version.
    if [ -s "$temp_file" ]; then
        cat "$temp_file" > "$PORT_FORWARD_RULES_FILE"
        rm -f "$temp_file"
    else
        log "ERROR: Firewall rule modification failed, temporary file is empty. No changes made."
        rm -f "$temp_file"
        exit 1
    fi
}
# --- End of Core Functions ---


# --- Cleanup Function (CRITICAL FOR SECURITY) ---
# This function is registered with 'trap' to ALWAYS run when the script exits.
cleanup() {
    log "--- Executing security cleanup ---"
    log "Cleanup: Forcing Port Forward rule to DISABLED."
    toggle_port_forward "off"
    log "Cleanup: Forcing Location Block to ENABLED."
    toggle_location_block "on"
    reload_firewall
    log "Cleanup complete. Network secured."
}

# Register the cleanup function to be called on script exit for robustness.
trap cleanup EXIT HUP INT QUIT TERM
# --- End of Cleanup Function ---


# --- Main Script Logic ---
log "--- Starting Nextcloud Certificate Renewal Check ---"

# Step 1: Get certificate expiry date from the remote server.
log "Fetching certificate status from $NEXTCLOUD_SERVER..."
CERT_INFO=$(ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$NEXTCLOUD_SERVER" "check" 2>&1)
if [ $? -ne 0 ]; then
    log "FAILURE: Could not connect or run certbot on $NEXTCLOUD_SERVER. SSH Error."
    # Pipe the multi-line error output to logger to ensure it gets logged.
    printf '%s\n' "$CERT_INFO" | logger -t "CertRenewal"
    exit 1
fi

# Step 2: Parse the expiry date and check if renewal is needed.
EXPIRY_DATE_STR=$(
  printf '%s\n' "$CERT_INFO" \
  | awk '
      /Expiry Date:/ {
        sub(/.*Expiry Date: /, "")
        sub(/\s*\(.*/, "")
        gsub(/^[ \t]+|[ \t]+$/, "")
        if (length($0) > 0) print
        found = 1
      }
      END { if (!found) exit 1 }
    '
)

if [ -z "$EXPIRY_DATE_STR" ]; then
    log "FAILURE: Could not parse expiry date from 'certbot certificates' output."
    printf '%s\n' "$CERT_INFO" | logger -t "CertRenewal"
    exit 1
fi

log "Found Expiry Date: $EXPIRY_DATE_STR"

# Convert expiry date and current date to seconds since epoch for reliable comparison.
EXPIRY_SECONDS=$(date +%s -d "$EXPIRY_DATE_STR")
CURRENT_SECONDS=$(date +%s)
DAYS_LEFT=$(((EXPIRY_SECONDS - CURRENT_SECONDS) / 86400))

log "Certificate is valid for $DAYS_LEFT days."
RENEWAL_THRESHOLD=30

if [ "$DAYS_LEFT" -le "$RENEWAL_THRESHOLD" ]; then
    log "Certificate is due for renewal ($DAYS_LEFT days remaining is <= $RENEWAL_THRESHOLD)."
    # Step 3: Open the firewall for the ACME challenge.
    log "Temporarily opening firewall for renewal..."
    toggle_location_block "off"
    toggle_port_forward "on"
    reload_firewall

    # Step 4: Perform the actual certificate renewal.
    log "Issuing certificate renewal command on $NEXTCLOUD_SERVER..."
    if ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$NEXTCLOUD_SERVER" "renew"; then
        log "SUCCESS: Certificate renewal completed successfully."
    else
        log "FAILURE: Certificate renewal failed. Check system logs for details from Certbot."
    fi
    # The cleanup trap will handle re-securing the firewall automatically.
else
    log "Certificate is not yet due for renewal. No action needed."
fi

log "--- Script Finished ---"
exit 0
