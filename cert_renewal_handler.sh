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
# --- End of Static Configuration ---

# --- Argument Parsing ---
# This script requires three arguments to be passed from the command line:
# 1. The SSH username on the target server.
# 2. The IP address of the target server.
# 3. The unique remark used for the port forwarding rule.
if [ "$#" -ne 3 ]; then
    echo "ERROR: Incorrect number of arguments."
    echo "Usage: $0 <ssh_user> <target_server_ip> <port_forward_remark>"
    echo "Example: $0 nextcloudadmin 192.168.1.10 \"certbot-http-renewal\""
    exit 1
fi

# Assign command-line arguments to variables.
SSH_USER=$1
NEXTCLOUD_SERVER=$2
PORT_FORWARD_REMARK=$3
# --- End of Argument Parsing ---

# --- Script Setup ---

# Path to the IPFire configuration files.
LOCATION_SETTINGS_FILE="/var/ipfire/location/settings"
PORT_FORWARD_RULES_FILE="/var/ipfire/firewall/dnat"

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
    if [ "$state" == "on" ]; then
        sed -i 's/LOCATIONBLOCK_ENABLED=off/LOCATIONBLOCK_ENABLED=on/' "$LOCATION_SETTINGS_FILE"
    else
        sed -i 's/LOCATIONBLOCK_ENABLED=on/LOCATIONBLOCK_ENABLED=off/' "$LOCATION_SETTINGS_FILE"
    fi
}

# Enable or disable our specific port forwarding rule.
toggle_port_forward() {
    local state=$1 # Takes one argument: "on" (enable) or "off" (disable)

    # First, check if a rule with the specified remark actually exists in the file.
    if ! grep -q "$PORT_FORWARD_REMARK" "$PORT_FORWARD_RULES_FILE"; then
        log "ERROR: Cannot find a port forward rule with the remark '$PORT_FORWARD_REMARK'."
        log "Please create the rule in the WUI and set its remark correctly."
        # We exit here because without the rule, the script cannot succeed.
        exit 1
    fi

    if [ "$state" == "on" ]; then
        log "ENABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        # Use 'sed' to find the line containing our remark and uncomment it (s/^#//).
        # The -i flag edits the file in-place.
        sed -i "/$PORT_FORWARD_REMARK/s/^#//" "$PORT_FORWARD_RULES_FILE"
    else
        log "DISABLING Port Forward rule: '$PORT_FORWARD_REMARK'"
        # Use 'sed' to find the line and comment it (s/^/#/).
        # This will not add a second '#' if one already exists.
        sed -i "/$PORT_FORWARD_REMARK/s/^#*\(.*\)/#\1/" "$PORT_FORWARD_RULES_FILE"
    fi
}


# --- Cleanup Function (CRITICAL FOR SECURITY) ---
# This function is registered with 'trap' to ALWAYS run when the script exits.
cleanup() {
    log "--- Executing security cleanup ---"

    # --- Secure Port Forwarding ---
    # Always ensure the port forward rule is disabled.
    log "Cleanup: Making sure Port Forward rule is disabled."
    toggle_port_forward "off" # This will comment out the rule.

    # --- Secure Location Block ---
    # If the Location Block was turned off, turn it back on.
    if grep -q "LOCATIONBLOCK_ENABLED=off" "$LOCATION_SETTINGS_FILE"; then
        log "Cleanup: Re-enabling Location Block for security."
        toggle_location_block "on"
    else
        log "Cleanup: Location Block is already ON. No changes needed."
    fi

    # --- Finalize ---
    # The final, single reload applies all cleanup changes at once.
    reload_firewall
    log "Cleanup complete. Network secured."
}

# Register the cleanup function to be called on script exit.
trap cleanup EXIT


# --- Main Script Logic ---

log "--- Starting Nextcloud Certificate Renewal Check ---"

# Step 1: Check if renewal is needed using a dry-run.
log "Performing a dry-run renewal check on $NEXTCLOUD_SERVER..."
if ssh "$SSH_USER@$NEXTCLOUD_SERVER" "sudo certbot renew --dry-run" 2>&1 | grep -q "Congratulations, all simulated renewals succeeded"; then
    log "Dry-run successful. Certificate is not yet due for renewal."
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
