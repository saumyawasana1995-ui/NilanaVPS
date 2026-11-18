# Nilana VLESS (VLESS only, port 443)

`install-vless.sh` replaces the SSH/Dropbear/Stunnel/Squid/BadVPN stack with **only VLESS (Xray-core) on TCP 443**.
OpenSSH on port 22 is left alone so you can still log in to the server.

## Install (as root)

```bash
bash install-vless.sh                 # VLESS + REALITY, login by server IP (recommended)
bash install-vless.sh --mode ws --domain vpn.example.com   # VLESS + WebSocket + TLS
```

Options: `--sni www.microsoft.com` (REALITY camouflage site) · `--wspath /nilana` · `--no-block-torrent` · `-y` · `--update` (update Xray, keep users).

If the old Nilana Stunnel is using port 443, the installer offers to stop and disable it.

**Cloud firewall:** also allow TCP 443 in your provider panel (Oracle: VCN → Security Lists → Ingress, `0.0.0.0/0`, TCP, 443).

## Use

Type `vless` (or `nilana-vless`) as root: add / renew / delete / lock users, users list, link + QR, status, restart,
change host, change REALITY SNI, update Xray, uninstall. Each user gets a `vless://` link and QR code.
Expired accounts are removed from the Xray config automatically (checked every 30 minutes; Xray restarts only when something changed).

## Modes

| | reality (default) | ws |
|---|---|---|
| Needs domain | no | optional (or IP + allow insecure) |
| Certificate | none | self-signed (use Cloudflare proxy "Full" for a trusted front) |
| Client flow | xtls-rprx-vision | none |
| Note | best choice on a bare IP | Xray marks WebSocket transport as deprecated |

Server-side safety: private/internal IP ranges (including the cloud metadata address) and BitTorrent are blocked in the outbound routing.
Client apps: v2rayNG, Hiddify, v2rayN, Streisand, Shadowrocket - anything that supports VLESS + REALITY.
