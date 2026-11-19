# Nilana Panel

Web panel for the Nilana VLESS server: dashboard (CPU / RAM / disk / network), users (add, renew, lock, delete,
VLESS link + QR), per-user traffic, service log and restart, and one-click VPS updates. Python 3 standard library only, no extra packages.

## Install (as root)

Put `install-vless.sh` and `install-panel.sh` in the same folder.

    bash install-panel.sh            # private: 127.0.0.1 only (recommended)
    bash install-panel.sh --public   # HTTPS with a self-signed certificate on a random high port

If your VLESS install is older, the panel installer runs `install-vless.sh --update` first (adds the traffic stats API;
users and settings are kept).

Domain mode (trusted certificate, no browser warning):

    bash install-panel.sh --domain nilana.ddns.net --email you@example.com

The domain's A record must already point to the VPS, and TCP 80 must be free and allowed in the cloud firewall
(Let's Encrypt uses it to issue and renew the certificate). The panel is then at https://nilana.ddns.net:8443.

Private mode: `ssh -L PORT:127.0.0.1:PORT root@SERVER_IP`, then open http://127.0.0.1:PORT.
Public mode: open https://SERVER_IP:PORT and also allow that TCP port in your cloud firewall.

## Upgrade an existing panel (v1.1.0)

Keep both scripts in one folder and run, as root:

    bash install-vless.sh --update     # network fix + tuning (optional but recommended)
    bash install-panel.sh              # keeps your password, port and users

## Update tab (new)

Shows how many system packages are waiting (and how many are security updates), the installed and newest Xray
version, and has one button that can:

- **System packages (apt):** refreshes the package lists and installs updates. Nothing is removed. Config files you
  changed are kept. A half-finished earlier install is repaired and retried once.
- **Xray core:** downloads the newest release, verifies its checksum, restarts the VPN service (users reconnect).
- **Restart afterwards if needed:** only if the updates ask for a restart (new kernel). It starts 1 minute after the
  update ends; cancel on the server with `shutdown -c`.

The update runs as its own system job, so it keeps going if you close the page or the panel restarts. Live output and
a "Last update" report stay on the page. Refuses to start with less than 300 MB free disk. Log: `/var/lib/nilana-panel/update.log`.
Services are not restarted behind your back; if a restart is needed you get a "Restart now" banner.

## What was fixed in v1.1.0

- **Password box losing letters:** the page refreshed itself every 3 seconds, even on the sign-in screen. Each refresh
  got "not signed in" and cleared the box while you typed. Now it refreshes only while signed in, and never twice at once.
- Sign-in is a real form (Enter, phone "Go" key and password managers work), with a Show/Hide button and a Caps Lock hint.
  Fields use 16 px text so iPhones no longer zoom in.
- Clear messages instead of "Failed to fetch"; requests time out instead of hanging.

## Errors and debugging

- Every server error shows a short reference (for example `ref 3fa91c`); the full traceback with that reference is in
  `journalctl -u nilana-panel`.
- Errors inside the web page are reported to the same journal (`browser error: ...`).
- Background-thread crashes and hard crashes are logged (Python faulthandler).
- The service uses a systemd watchdog: it asks its own web server for `/api/me` every 10 s and tells systemd it is alive.
  If the panel ever hangs (not just crashes), systemd restarts it within about a minute.

## Maintenance tab

- **Scheduled reboot:** daily at the time you choose (default 00:00). Uses a systemd timer, so it survives reboots.
  It never reboots twice in a row (skipped if the server booted less than 10 minutes ago).
- **Auto cleanup:** daily or every Sunday: apt cache, unused packages, old logs and journal, crash dumps,
  and optionally users expired for more than N days (locked users are never deleted). "Run cleanup now" and a last-run report are included.
- **Timezone:** schedules use the server clock. Set it to Asia/Colombo so "midnight" means Sri Lanka midnight.

## Manage

    nilana-panel passwd      # reset the panel password
    nilana-panel info        # port / mode
    systemctl status nilana-panel
    bash install-panel.sh --uninstall

## Security

Password login (PBKDF2), HttpOnly + SameSite=Strict session cookie (Secure in HTTPS mode), 12 h sessions,
5 wrong passwords lock sign-in for 5 min, CSRF header + Origin check, strict Content-Security-Policy.
