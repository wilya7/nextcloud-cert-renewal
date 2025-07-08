#!/bin/bash
# =================================================================================
#           Nextcloud Certificate Renewal Handler for IPFire
#
# This script automates Let's Encrypt certificate renewal for a server
# on the ORANGE network.
#
#                               -- HOW IT WORKS --
#
# 1. It fetches the certificate details from the target server.
# 2. It parses the expiry date and checks if it's within 30 days.
# 3. If renewal is needed:
#    a. It enables a specific, pre-configured Port Forwarding rule (Port 80).
#    b. It temporarily disables the Location Block filter.
#    c. It triggers the real certificate renewal on the remote server.
#    d. It logs the outcome (success or failure).
# 4. CRITICALLY, it ensures BOTH the Port Forward and Location Block are
#    reverted to their secure, default states afterwards via a cleanup trap.
#
# =================================================================================

# --- Static Configuration ---
# Location for the log file on the IPFire machine.
LOG_FILE="/var/log/cert_renewal.log"
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
    echo "ERROR: Incorrect number of arguments. Use -h or --help for usage information."
    echo "Usage: $0 <ssh_user> <target_server_ip> <port_forward_remark>"
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
  echo "Error: This script must be run as root."
  exit 1
fi
# --- End of Script Setup ---


# --- Core Functions ---
# Logging function that prepends a timestamp to each log message.
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Reload the firewall, making any config changes active.
reload_firewall() {
    log "Reloading firewall to apply changes..."
    # We send all output (stdout and stderr) to the log file to keep the
    # console clean and capture any potential errors from the reload command.
    /etc/init.d/firewall reload >> "$LOG_FILE" 2>&1
}

# Control the Location Block ON or OFF.
toggle_location_block() {
    local state=$1 # Takes one argument: "on" or "off"
    log "Turning Location Block ${state^^}..."
    # We find the master key within the locationblock file and change its value.
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
    # First, verify the rule actually exists by checking for the unique remark (field 18)
    # and ensuring it is a 'dnat' rule (field 33). This is much safer.
    # The awk script will exit with success (0) if found, and failure (1) otherwise.
    if ! awk -F, -v remark="$PORT_FORWARD_REMARK" '{if ($18 == remark && $33 == "dnat") exit 0} ENDFILE {exit 1}' "$PORT_FORWARD_RULES_FILE"; then
        log "ERROR: Cannot find a DNAT rule with the remark '$PORT_FORWARD_REMARK'."
        log "Please check the rule in the WUI; remark must be unique and rule type must be DNAT."
        rm -f "$temp_file"
        exit 1
    fi
    # Use awk to find the line based on remark and rule type, then set the 4th field.
    if [ "$state" == "on" ]; then
        log "ENABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        awk -v remark="$PORT_FORWARD_REMARK" 'BEGIN{FS=OFS=","} {if($18==remark && $33=="dnat"){$4="ON"}; print}' "$PORT_FORWARD_RULES_FILE" > "$temp_file"
    else
        log "DISABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        awk -v remark="$PORT_FORWARD_REMARK" 'BEGIN{FS=OFS=","} {if($18==remark && $33=="dnat"){$4=""}; print}' "$PORT_FORWARD_RULES_FILE" > "$temp_file"
    fi
    # Atomically and safely replace the original file with the modified version.
    # We check that the temp file is not empty before overwriting the original.
    if [ -s "$temp_file" ]; then
        # Using cat and redirect is a safe way to preserve permissions
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
# It is designed to be idempotent, ensuring the firewall is always returned
# to a known, secure state, regardless of the script's state at exit.
cleanup() {
    log "--- Executing security cleanup ---"

    # --- Secure Port Forwarding ---
    # Unconditionally set the Port Forward rule state to 'off'. The underlying
    # awk command ensures the target field is always set to "" (disabled).
    log "Cleanup: Forcing Port Forward rule to DISABLED."
    toggle_port_forward "off"

    # --- Secure Location Block ---
    # Unconditionally set the Location Block to 'on'. The underlying sed
    # command ensures the final state is always LOCATIONBLOCK_ENABLED=on.
    log "Cleanup: Forcing Location Block to ENABLED."
    toggle_location_block "on"

    # --- Finalize ---
    # Reload the firewall to apply the secure configuration.
    reload_firewall
    log "Cleanup complete. Network secured."
}

# Register the cleanup function to be called on script exit (EXIT), hangup (HUP),
# interrupt (INT), quit (QUIT), or termination (TERM) signals for robustness.
trap cleanup EXIT HUP INT QUIT TERM
# --- End of Cleanup Function ---


# --- Main Script Logic (REWRITTEN) ---
log "--- Starting Nextcloud Certificate Renewal Check ---"

# Step 1: Get certificate expiry date from the remote server.
log "Fetching certificate status from $NEXTCLOUD_SERVER..."
CERT_INFO=$(ssh "$SSH_USER@$NEXTCLOUD_SERVER" "sudo certbot certificates" 2>&1)
if [ $? -ne 0 ]; then
    log "FAILURE: Could not connect or run certbot on $NEXTCLOUD_SERVER. SSH Error."
    log "--- SSH Output ---"
    echo "$CERT_INFO" >> "$LOG_FILE" # Log the actual error from SSH
    log "--------------------"
    exit 1
fi

# Step 2: Parse the expiry date and check if renewal is needed.
# This awk command finds the "Expiry Date" line, isolates the date string,
# and removes the "(VALID: ...)" part and any leading/trailing whitespace.

EXPIRY_DATE_STR=$(
  printf '%s\n' "$CERT_INFO" \
  | awk '
      /Expiry Date:/ {
        sub(/.*Expiry Date: /, "")      # drop everything through "Expiry Date: "
        sub(/\s*\(.*/, "")              # drop space + "(" + anything after
        gsub(/^[ \t]+|[ \t]+$/, "")     # trim leading/trailing whitespace
        if (length($0) > 0) print       # only print if we have content
        found = 1
      }
      END { if (!found) exit 1 }        # exit with error if not found
    '
)

# EXPIRY_DATE_STR=$(echo "$CERT_INFO" | awk -F'Expiry Date: ' '/Expiry Date:/ {print $2}' | cut -d'(' -f1 | sed 's/^[ \t]*//;s/[ \t]*$//')

if [ -z "$EXPIRY_DATE_STR" ]; then
    log "FAILURE: Could not parse expiry date from 'certbot certificates' output."
    log "--- Full output from certbot ---"
    echo "$CERT_INFO" >> "$LOG_FILE"
    log "--------------------------------"
    exit 1
fi

log "Found Expiry Date: $EXPIRY_DATE_STR"

# Convert expiry date and current date to seconds since epoch for comparison.
# This is a reliable way to compare dates in bash.
EXPIRY_SECONDS=$(date +%s -d "$EXPIRY_DATE_STR")
CURRENT_SECONDS=$(date +%s)
DAYS_LEFT=$(((EXPIRY_SECONDS - CURRENT_SECONDS) / 86400))

log "Certificate is valid for $DAYS_LEFT days."

# Define the renewal threshold in days (Let's Encrypt recommends renewing with 30 days left)
RENEWAL_THRESHOLD=30

if [ "$DAYS_LEFT" -le "$RENEWAL_THRESHOLD" ]; then
    log "Certificate is due for renewal ($DAYS_LEFT days remaining is <= $RENEWAL_THRESHOLD)."

    # Step 3: Open the firewall for the ACME challenge.
    log "Temporarily opening firewall for renewal..."
    toggle_location_block "off"
    toggle_port_forward "on"
    reload_firewall

    # Step 4: Perform the actual certificate renewal.
    log "Issuing REAL certificate renewal command on $NEXTCLOUD_SERVER..."
    if ssh "$SSH_USER@$NEXTCLOUD_SERVER" "sudo certbot renew --quiet" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: Certificate renewal completed successfully."
    else
        log "FAILURE: Certificate renewal failed. Check log for details from Certbot."
    fi
    # The cleanup trap will handle re-securing the firewall automatically.

else
    log "Certificate is not yet due for renewal. No action needed."
fi

log "--- Script Finished ---"
exit 0
