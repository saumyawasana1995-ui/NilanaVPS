# Nilana VPS

A transparent installer for Ubuntu Server 20.04, 22.04, and 24.04. It configures OpenSSH, Dropbear, Stunnel, Squid, BadVPN UDP gateway, a Nilana login banner, Fail2ban, and optional BBR congestion control.

## Services and ports

| Service | Port(s) | Default exposure |
| --- | --- | --- |
| OpenSSH | TCP 22 | Public, using the existing SSH authentication policy |
| Dropbear | TCP 442, 555 | Public |
| Stunnel (TLS-wrapped SSH/Dropbear) | TCP 443, 445 | Public; self-signed certificate by default |
| Squid | TCP 3128, 8000, 8080 | Loopback only unless a trusted client CIDR is supplied |
| BadVPN UDP gateway | TCP 7300 | Loopback only unless a trusted client CIDR is supplied |

The installer does not change SSH password/root-login settings and does not reset or enable UFW. This avoids silently weakening SSH or risking a remote firewall lockout. Review your existing firewall and Oracle Cloud VCN rules before exposing listeners.

## Install

Review the installer before running it. Run from an existing SSH session with an alternate recovery path available:

```bash
sudo bash nilana-vps-installer.sh
```

To permit Squid and BadVPN from a **specific trusted client IP/CIDR**, set the environment variable when running the installer, for example:

```bash
sudo env NILANA_ALLOWED_CIDR=198.51.100.8/32 bash nilana-vps-installer.sh
```

Replace that documentation-only IP with your real trusted client address. Do not use `0.0.0.0/0` for an unauthenticated proxy or UDP gateway. Without the variable, both services listen on loopback only.

The installer creates a self-signed Stunnel certificate at `/etc/stunnel/nilana.pem`. SSH still performs user authentication through Stunnel; TLS certificate trust is separate. Replace the self-signed certificate with one issued for a domain you control before relying on server identity validation.

## VPS management and uninstall

Install the management command on the VPS:

```bash
sudo bash nilana-vps-manager.sh install
```

Then use:

```bash
nilana-vps                 # interactive menu
nilana-vps status          # service status and relevant listening sockets
sudo nilana-vps uninstall  # prompts for the word UNINSTALL
```

For unattended use, explicitly confirm:

```bash
sudo nilana-vps uninstall --yes
```

Uninstall stops/removes the Nilana BadVPN unit and binary, removes Nilana TLS certificates, restores configuration files saved as `.nilana.bak`, removes Nilana-only files that did not previously exist, reapplies sysctl settings, and reloads/restarts affected services where safe. If no backup exists for a service config, it leaves that config in place rather than guessing whether it belongs to another setup. It deliberately does not purge packages, alter firewall rules, remove OpenSSH, or change Oracle Cloud VCN rules.

## Oracle Cloud networking

Add only the ingress rules you need to the VCN security list or network security group. SSH/Dropbear/Stunnel ports may need inbound TCP rules (22, 442, 555, 443, 445). If you explicitly configured a trusted CIDR, proxy access should be limited to that source on TCP 3128, 8000, and 8080; BadVPN should likewise be limited to the trusted source on TCP 7300. The instance firewall must also permit intended connections. The installer deliberately does not rewrite firewall policy.

## Low latency

The installer enables Linux BBR and the `fq` queue discipline only when the running kernel advertises BBR support. This can improve throughput under some network conditions; it cannot lower physical round-trip time or guarantee a ping improvement. VPS region, client distance, route quality, and packet loss are usually more important. No aggressive buffer or TCP timeout overrides are applied.

## Check services

```bash
systemctl --no-pager --full status ssh dropbear stunnel4 squid nilana-badvpn fail2ban
ss -lntup
```

Review logs with `journalctl -u <service-name>`. Installer-created config backups use the `.nilana.bak` suffix when a prior file existed.

## License

MIT. See [LICENSE](LICENSE).
