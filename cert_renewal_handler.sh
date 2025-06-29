#!/bin/bash
# =================================================================================
#
#           Nextcloud Certificate Renewal Handler for IPFire
#
# This script automates Let's Encrypt certificate renewal for a server
# on the ORANGE network.
#
#                               -- HOW IT WORKS --
#
# 1. It checks if the certificate is due for renewal using a 'dry-run'.
# 2. If renewal is needed:
#    a. It enables a specific, pre-configured Port Forwarding rule (Port 80).
#    b. It temporarily disables the Location Block filter.
# 3. It triggers the real certificate renewal on the remote server.
# 4. It logs the outcome (success or failure).
# 5. CRITICALLY, it ensures BOTH the Port Forward and Location Block are
#    reverted to their secure, default states afterwards.
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
    echo "It temporarily modifies firewall rules, runs certbot on the remote server via SSH,"
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
    # and ensuring it is a 'dnat' rule (field 32). This is much safer.
    # The awk script will exit with success (0) if found, and failure (1) otherwise.
    if ! awk -F, -v remark="$PORT_FORWARD_REMARK" '{if ($18 == remark && $32 == "dnat") exit 0} ENDFILE {exit 1}' "$PORT_FORWARD_RULES_FILE"; then
        log "ERROR: Cannot find a DNAT rule with the remark '$PORT_FORWARD_REMARK'."
        log "Please check the rule in the WUI; remark must be unique and rule type must be DNAT."
        rm -f "$temp_file"
        exit 1
    fi

    # Use awk to find the line based on remark and rule type, then set the 4th field.
    if [ "$state" == "on" ]; then
        log "ENABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        awk -v remark="$PORT_FORWARD_REMARK" 'BEGIN{FS=OFS=","} {if($18==remark && $32=="dnat"){$4="ON"}; print}' "$PORT_FORWARD_RULES_FILE" > "$temp_file"
    else
        log "DISABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        awk -v remark="$PORT_FORWARD_REMARK" 'BEGIN{FS=OFS=","} {if($18==remark && $32=="dnat"){$4=""}; print}' "$PORT_FORWARD_RULES_FILE" > "$temp_file"
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


# --- Cleanup Function (CRITICAL FOR SECURITY) ---
# This function is registered with 'trap' to ALWAYS run when the script exits.
cleanup() {
    log "--- Executing security cleanup ---"

    # --- Secure Port Forwarding ---
    log "Cleanup: Making sure Port Forward rule is disabled."
    toggle_port_forward "off"

    # --- Secure Location Block ---
    # Check if the master switch in the file is actually off before re-enabling.
    if grep -q "LOCATIONBLOCK_ENABLED=off" "$LOCATION_BLOCK_FILE"; then
        log "Cleanup: Re-enabling Location Block for security."
        toggle_location_block "on"
    else
        log "Cleanup: Location Block is already ON. No changes needed."
    fi

    # --- Finalize ---
    reload_firewall
    log "Cleanup complete. Network secured."
}

# Register the cleanup function to be called on script exit.
trap cleanup EXIT

# --- Main Script Logic ---
log "--- Starting Nextcloud Certificate Renewal Check ---"
# Step 1: Check if renewal is needed using a dry-run.
log "Performing a dry-run renewal check on $NEXTCLOUD_SERVER..."
# We check for certbot's "skipped" message. If found, we exit cleanly.
if ssh "$SSH_USER@$NEXTCLOUD_SERVER" "sudo certbot renew --dry-run" 2>&1 | grep -q "No renewals were attempted"; then
    log "Check complete. Certificate is not yet due for renewal."
    log "--- Script Finished ---"
    exit 0 # Exit gracefully. The 'trap' will still run cleanup as a precaution.
fi

log "Renewal is due or dry-run failed. Proceeding with live renewal attempt."

# Step 2: Temporarily open the firewall for the ACME challenge.
log "Preparing firewall for renewal..."
toggle_location_block "off" # Disable country blocking
toggle_port_forward "on"  # Enable the port 80 forward rule

# Apply the insecure settings with a single reload.
reload_firewall

# Step 3: Perform the actual certificate renewal.
log "Issuing REAL certificate renewal command on $NEXTCLOUD_SERVER..."
if ssh "$SSH_USER@$NEXTCLOUD_SERVER" "sudo certbot renew --quiet" >> "$LOG_FILE" 2>&1; then
    log "SUCCESS: Certificate renewal completed successfully."
else
    log "FAILURE: Certificate renewal failed. Check log for details from Certbot."
fi

# Step 4: Rely on the cleanup trap.
# The 'trap' command at the top of the script will automatically call the
# 'cleanup' function when the script exits here. This function will disable
# the port forward, re-enable location block, and reload the firewall.
log "Renewal attempt finished. Cleanup trap will now re-secure the firewall."
log "--- Script Finished ---"
exit 0
