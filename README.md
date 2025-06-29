-----

# IPFire Nextcloud Certificate Renewal Handler

This Bash script is designed to run on an IPFire firewall and automates the process of renewing Let's Encrypt certificates for a server located on the ORANGE network (DMZ).

It securely handles the temporary firewall modifications required for the ACME `http-01` challenge and restores all security settings upon completion or failure.

-----

## ⚙️ How It Works

The script follows a robust and secure sequence of operations:

1.  **Fetch Certificate Status**: It connects to the target server via SSH and runs `sudo certbot certificates` to get the real status of the currently installed certificate.
2.  **Check Expiry Date**: It parses the certificate's expiry date from the output and calculates the number of days remaining until it expires.
3.  **Conditional Renewal**: If the certificate is due for renewal (by default, within a 30-day threshold), it proceeds with the renewal process. If not, it logs the status and exits gracefully.
4.  **Open Firewall**: For the renewal, it temporarily opens the firewall by:
      * Disabling the IPFire **Location Block**.
      * Enabling a specific, pre-existing Port 80 forwarding rule that points to the target server.
5.  **Trigger Renewal**: It connects to the target server again via SSH and executes `sudo certbot renew` to perform the actual renewal.
6.  **Log Results**: The outcome of the renewal attempt (success or failure) is logged to `/var/log/cert_renewal.log`.
7.  **Critical Cleanup**: A `trap` is set to guarantee that a cleanup function runs whenever the script exits, for any reason. This function **always** restores the firewall to its secure state by re-enabling the Location Block and disabling the Port 80 forwarding rule.

-----

## 📋 Prerequisites & Installation

### Part 1: On the Target Server (e.g., Nextcloud)

1.  **Certbot Installed**: The Let's Encrypt `certbot` client must be installed and configured.
2.  **SSH Server**: An SSH server must be running and accessible from the IPFire's ORANGE interface.
3.  **Sudo Permissions (Crucial)**: The script executes `certbot` on the remote server using `sudo`, which will fail if it prompts for a password. You **must** configure the `sudoers` file to allow the SSH user to run commands without a password.
      * On the target server, run `sudo visudo`.
      * Add the following line at the end of the file, replacing `nextcloudadmin` with the actual username you will use for SSH. This grants `nextcloudadmin` passwordless `sudo` rights.
        ```
        nextcloudadmin ALL=(ALL) NOPASSWD: ALL
        ```

### Part 2: On the IPFire Firewall

1.  **Port Forward Rule**: Create a Port Forwarding rule in the IPFire WUI (`Firewall` -\> `Firewall Rules` -\> `New rule`).

      * **Source**: `Standard Networks` -\> `Any`
      * **NAT**: `Use Network Address Translation (NAT)` -\> `Destination NAT (Port Forwarding)`
      * **Destination**: `Firewall` -\> `RED`
      * **Protocol**: `TCP`
      * **Destination port**: `80`
      * **Forward to IP**: The IP address of your server (e.g., `192.168.1.10`).
      * **Forward to port**: `80`
      * **Remark**: Give it a unique and descriptive remark, like `"certbot-http-renewal"`. This remark is how the script identifies the rule.
      * **IMPORTANT**: Leave this rule **DISABLED** (unchecked). The script will enable it only when needed.

2.  **SSH Key-Based Login**: Set up SSH keys to allow the `root` user on IPFire to log into the target server without a password.

      * On IPFire, as `root`, run `ssh-keygen`.
      * Copy the public key to the target server:
      ```bash
      cat ~/.ssh/id_rsa.pub | ssh your_user@dmz_server_ip "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
      ```.

### Part 3: Install the Script on IPFire

1.  Place the `cert_renewal_handler.sh` script in `/usr/local/bin/` on the **IPFire router**.
2.  **Make it executable**: `chmod +x /usr/local/bin/cert_renewal_handler.sh`.
3.  **Test the Help Message**: `bash /usr/local/bin/cert_renewal_handler.sh --help`
4.  **Run the Full Script Manually**:
    ```bash
    bash /usr/local/bin/cert_renewal_handler.sh nextcloudadmin 192.168.1.10 "certbot-http-renewal"
    ```
5.  **Check the Log File**: Review the output in the log file for any errors.
    ```bash
    cat /var/log/cert_renewal.log
    ```

-----

## 🚀 Operation & Monitoring

### Schedule the Job

IPFire uses `fcron`. Edit the root user's schedule file:

```bash
nano /var/spool/fcron/root.fcrontab
```

Add this line to run the script twice a day, as recommended by Let's Encrypt:

```
# Check for Nextcloud certificate renewal twice daily
# Usage: bash <script_path> <ssh_user> <target_server_ip> <port_forward_remark>
15 2,14 * * * bash /usr/local/bin/cert_renewal_handler.sh nextcloudadmin 192.168.1.10 "certbot-http-renewal"
```

### Integrate Logs with the WUI

Make the script's logs viewable in the IPFire Web User Interface. This change is **update-proof**.

1.  On **IPFire**, edit `/etc/rc.d/rc.local`:
    ```bash
    nano /etc/rc.d/rc.local
    ```
2.  Add this code block to the end of the file:
    ```bash
    # Add an entry for the Certificate Renewal logs to the Log Summary page.
    CERT_LOG_CONFIG="cert_renewal:Certificate Renewal:/var/log/cert_renewal.log"
    LOG_SUMMARY_FILE="/var/log/logsummary.dat"
    if ! grep -q "$CERT_LOG_CONFIG" "$LOG_SUMMARY_FILE"; then
        echo "$CERT_LOG_CONFIG" >> "$LOG_SUMMARY_FILE"
    fi
    ```
3.  Run it once manually to apply immediately: `sh /etc/rc.d/rc.local`.
4.  You can now view the logs under `Logs` -\> `Log Summary` -\> `Certificate Renewal`.

> ### ⚠️ **Security Warning**
>
> This script is powerful and temporarily lowers your firewall's security. The cleanup function is designed to be robust, but it is **your responsibility** to test it and check the logs to confirm your firewall rules are always restored correctly.