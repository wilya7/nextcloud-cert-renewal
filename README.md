# IPFire Nextcloud Certificate Renewal Handler

Automates Let's Encrypt certificate renewal for a Nextcloud server on the ORANGE (DMZ) network, integrating secure SSH, sudo, and firewall orchestration with IPFire’s WUI.

## Script Purpose

The renewal handler script is designed to automate and safeguard the entire certificate renewal process for a web server hosted in your DMZ (ORANGE) network, where the TLS termination occurs on the server and not on the router. Specifically, it:

1. **Monitors Certificate Expiry**: SSHes into the DMZ server through a forced-command wrapper to run `certbot certificates` and parses the expiration date.
2. **Determines Renewal Need**: Compares the remaining validity against a configurable threshold (default: 30 days).
3. **Safely Prepares Firewall**: If renewal is required and HTTP-01 challenge is needed:

   * Uses the IPFire WUI backend commands (not raw iptables) to temporarily disable the geolocation block and enable the HTTP (port 80) NAT rule.
   * Reloads the firewall to apply changes.
4. **Triggers Renewal**: SSHes back through the same wrapper to invoke `certbot renew --quiet`, completing the HTTP-01 challenge.
5. **Ensures Cleanup**: Employs a trap on exit to restore the original geoblocking and NAT rule state, guaranteeing the firewall always returns to its secure baseline.
6. **Logs All Actions**: Records every step and any errors to the system log or a designated logfile, providing full auditability.

By leveraging the existing IPFire management interface and enforcing least-privilege SSH/sudo and wrapper constraints, the script ensures that firewall modifications occur only when strictly necessary and that no elevated shell or arbitrary commands can be executed on the DMZ server.

## Features

* **Secure SSH Access**: SSH forced-command wrapper limits operations to certificate checks and renewals only.
* **Least-Privilege Sudo**: Grants passwordless sudo exclusively for specific Certbot subcommands.
* **Firewall Orchestration**: Disables geolocation block and opens HTTP (port 80) via the IPFire WUI interface for HTTP‑01 validation, then restores original firewall settings.
* **Automated Scheduling**: Designed to run on a regular schedule (e.g., twice daily) to ensure certificates are renewed before expiry.

---

## 📋 Prerequisites

### On the DMZ Web Server

1. **Certbot** installed and initial certificates obtained.
2. **SSH Key Access**: Public key of your IPFire host installed in the target user’s `~/.ssh/authorized_keys`.
3. **SSH Server Configuration**: Create a drop-in file under `/etc/ssh/sshd_config.d/` (e.g., `certbot-renew.conf`; any name ending in `.conf` is fine) containing:

   ```text
   # Restrict SSH for Certbot renewals
   ListenAddress <DMZ_SERVER_IP>
   AllowUsers <SSH_USER>@<IPFIRE_ORANGE_IP>
   PubkeyAuthentication yes
   PasswordAuthentication no
   ChallengeResponseAuthentication no
   UsePAM no
   ```

   Then reload SSH:

   ```bash
   systemctl reload sshd
   ```
4. **Passwordless Sudo**: Grant the SSH user NOPASSWD rights for exactly the Certbot commands. Choose one method:

   * **visudo**:

     ```text
     <SSH_USER> ALL=(ALL) NOPASSWD: \
       /usr/bin/certbot certificates, \
       /usr/bin/certbot renew, \
       /usr/bin/certbot renew --quiet
     ```
   * **sudoers.d**: Create `/etc/sudoers.d/certbot-renew` with the same line above and set permissions to `0440`.

### On the IPFire Host

* **Disabled NAT Rule** for HTTP (port 80) forwarding to the DMZ server, identified by a unique remark string `<NAT_RULE_REMARK>`.
* **SSH Key Configuration**: In the DMZ server’s `authorized_keys`, prepend the IPFire host’s public key entry with:

  ```text
  command="/usr/local/bin/cert-renewal-wrapper.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty <key-type> <key-data> <SSH_USER>@ipfire
  ```

---

## ⚙️ Setup

### 1. Deploy the SSH Wrapper on the DMZ Server

Create the wrapper at `/usr/local/bin/cert-renewal-wrapper.sh` and make it executable:

```bash
#!/bin/bash
# cert-renewal-wrapper.sh
case "$SSH_ORIGINAL_COMMAND" in
  "check")
    sudo /usr/bin/certbot certificates
    ;;
  "renew")
    sudo /usr/bin/certbot renew --quiet
    ;;
  *)
    echo "ERROR: Invalid command"
    exit 1
    ;;
esac
```

### 2. Restrict SSH Key Usage

Ensure the wrapper is the only command allowed for that key, as shown above in **Prerequisites**.

### 3. Install the IPFire Handler Script

1. Copy your renewal handler script (e.g., `cert_renewal_handler.sh`) to the IPFire host’s `/usr/local/bin/` and make it executable:

   ```bash
   scp cert_renewal_handler.sh root@<IPFIRE_HOST>:/usr/local/bin/
   ssh root@<IPFIRE_HOST> chmod +x /usr/local/bin/cert_renewal_handler.sh
   ```
2. Edit the script’s invocation parameters to set:

   * `SSH_USER` → `<SSH_USER>`
   * `TARGET_SERVER` → `<DMZ_SERVER_IP>`
   * `PORT_FORWARD_REMARK` → `<NAT_RULE_REMARK>`

---

## 🚀 Usage

Run manually to verify connectivity and logic:

```bash
/usr/local/bin/cert_renewal_handler.sh <SSH_USER> <DMZ_SERVER_IP> "<NAT_RULE_REMARK>"
```

Automate via fcron (e.g., twice daily):

```cron
# m h dom mon dow command
0 */12 * * * /usr/local/bin/cert_renewal_handler.sh <SSH_USER> <DMZ_SERVER_IP> "<NAT_RULE_REMARK>"
```

---

## 🔄 How It Works

1. **Expiry Check**: SSH via forced wrapper and run `certbot certificates`; parse expiry date.
2. **Renewal Threshold**: If certificate expires in ≤30 days, IPFire:

   * Disables geoblocking.
   * Enables the HTTP NAT rule (`<NAT_RULE_REMARK>`).
   * Applies changes using the IPFire WUI interface, then reloads the firewall.
3. **Renewal**: SSH via forced wrapper to run `certbot renew --quiet`.
4. **Cleanup**: Trap ensures IPFire firewall settings are returned to their original state.
5. **Logging**: All actions and errors are logged to syslog or a dedicated log file if configured.

---

## 🔍 Maintenance & Auditing

* **Log Monitoring**: All script operations are logged to the central system log. Review these logs for errors or successful renewal confirmations under **Logs → System Logs** in the WUI, filtering by the tag `CertRenewal`.
* **Key Rotation**: Regularly rotate SSH keys and update `authorized_keys` entries.
* **Configuration Updates**: Update sudoers, wrapper script, and handler arguments when certbot paths or challenge methods change.

> ### ⚠️ **Security Warning**
>
> This script is powerful and temporarily lowers your firewall's security. The cleanup function is designed to be robust, but it is **your responsibility** to test it and check the logs to confirm your firewall rules are always restored correctly.

---

**License:** MIT © 2025
