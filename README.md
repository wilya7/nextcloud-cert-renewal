-----

# 🛡️ Automated Let's Encrypt Renewal for IPFire DMZ

> This project provides a secure, automated script for renewing Let's Encrypt SSL certificates on a server located in an IPFire **ORANGE (DMZ)** network. It runs on the IPFire router itself and safely manages the temporary firewall changes required for the Let's Encrypt validation process.

-----

## How It Works ⚙️

The script follows a strict, safety-oriented procedure to handle certificate renewals.

| Step | Action | Purpose |
| :--- | :--- | :--- |
| 1. **Dry-Run** | Executes `certbot renew --dry-run` via SSH. | Checks if a renewal is necessary without making any system changes. |
| 2. **Modify** | If needed, it edits IPFire's own config files to enable the Port 80 NAT rule and disable the Location Block. | This is the **safest method**, as it uses IPFire's native functions, just like the WUI does. It avoids raw `iptables` commands. |
| 3. **Reload** | Triggers `/etc/init.d/firewall reload`. | Applies the temporary, less-secure settings. |
| 4. **Renew** | Executes the real `certbot renew` command on the remote server. | Performs the actual certificate renewal. |
| 5. **Cleanup** | **Guaranteed via a `trap`**, this function runs on any script exit (success or failure). It reverts all configuration changes and reloads the firewall. | Ensures your network is **always** returned to its secure state. |

-----

## 📋 Setup Checklist & Prerequisites

Make sure you have the following in place before you begin.

  - [ ] An up-and-running **IPFire router**.
  - [ ] A **Debian-based server** (e.g., Ubuntu) in the ORANGE (DMZ) zone.
  - [ ] `certbot` is installed and working on the DMZ server.
  - [ ] **Static IP addresses** are configured for both the IPFire ORANGE interface and the DMZ server.

-----

## 🛠️ Installation & Configuration

### Part 1: IPFire Port Forwarding Rule

Create a disabled-by-default NAT rule that the script can activate when needed.

1.  In the IPFire WUI, go to `Firewall` -\> `Firewall Rules` -\> `New rule`.
2.  **Source**: `Standard networks` -\> `Red`
3.  **NAT**: Check the `Use Network Address Translation (NAT)` box.
4.  **Destination**: The static IP of your DMZ server.
5.  **Protocol**: `TCP`, Destination Port `80`.
6.  **Remark**: `certbot-http-renewal`  *(This must match the script's configuration)*.
7.  ***Save the rule**, making sure it is **DISABLED** (unchecked).

### Part 2: Secure SSH Connection

Set up passwordless SSH access and harden the SSH server on your DMZ machine.

1.  **On IPFire**, generate an SSH key for root and copy it to the DMZ server:

    ```bash
    # Generate the key
    ssh-keygen -t rsa -b 4096

    # Copy the key (use your DMZ server's user and IP)
    ssh-copy-id your_user@dmz_server_ip
    ```

2.  **On the DMZ Server**, edit `/etc/ssh/sshd_config` to add a layered defense:

    ```bash
    # Layer 1: Tell SSH to only listen on this server's specific IP address.
    ListenAddress 192.168.1.10  #<-- Use DMZ Server's IP

    # Layer 2: Only allow 'your_user' to log in, and ONLY from IPFire's IP.
    AllowUsers your_user@192.168.1.1 #<-- Use IPFire's ORANGE IP
    ```

3.  **Restart the SSH service** on the DMZ server: `sudo systemctl restart sshd`

### Part 3: Install the Script on IPFire

1.  Place the `cert_renewal_handler.sh` script in `/usr/local/sbin/` on the **IPFire router**.
2.  Make it executable: `chmod +x /usr/local/sbin/cert_renewal_handler.sh`.
3.  **Edit the script's configuration variables** at the top to match your setup.

-----

## 🚀 Operation & Monitoring

### Schedule the Job

IPFire uses `fcron`. Edit the root user's schedule file:

```bash
nano /var/spool/fcron/root.fcrontab
```

Add this line to run the script twice a day, as recommended by Let's Encrypt:

```
# Check for certificate renewal twice daily
15 2,14 * * * /usr/local/sbin/cert_renewal_handler.sh
```

### Integrate Logs with the WUI

Make the script's logs viewable in the IPFire WUI. This change is **update-proof**.

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
