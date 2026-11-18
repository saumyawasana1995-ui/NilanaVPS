# Nilana Panel

Web panel for the Nilana VLESS server: dashboard (CPU / RAM / disk / network), users (add, renew, lock, delete,
VLESS link + QR), per-user traffic, service log and restart. Python 3 standard library only, no extra packages.

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

## Manage

    nilana-panel passwd      # reset the panel password
    nilana-panel info        # port / mode
    systemctl status nilana-panel
    bash install-panel.sh --uninstall

## Security

Password login (PBKDF2), HttpOnly + SameSite=Strict session cookie (Secure in HTTPS mode), 12 h sessions,
5 wrong passwords lock sign-in for 5 min, CSRF header + Origin check, strict Content-Security-Policy.
