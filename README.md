# Nilana VPS

One-command **SSH / Dropbear / SSL (Stunnel) / Squid / BadVPN-udpgw** installer with a user-management menu,
custom server banner, account expiry and optional one-device-per-account limiting.

* **Ubuntu 20.04 · 22.04 · 24.04** (x86_64 and ARM64)
* Tuned for **Oracle Cloud Always Free** VPS (AMD Micro and Ampere A1)

| Service       | Port(s)          |
|---------------|------------------|
| OpenSSH       | 22               |
| Dropbear      | 442, 555         |
| Stunnel (SSL) | 443 → 442, 445 → 555 |
| Squid         | 3128, 8000, 8080 |
| BadVPN-udpgw  | 7300 (127.0.0.1) |

## Install

Log in to the VPS and run as root (`sudo -i` first on Oracle's `ubuntu` user):

```bash
wget -O install.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install.sh
sudo bash install.sh
```

If you are already root, use:

```bash
wget -O install.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install.sh
bash install.sh
```

Options: `-y` (no questions) · `--no-upgrade` (skip `apt upgrade`) · `--update` (update an existing install,
keeps users/banner/settings) · `--reset-banner`.
Everything is logged to `/var/log/nilana-install.log`. The installer is safe to re-run.

### Oracle Cloud: one manual step

Oracle blocks traffic **before** it reaches your VM, so the script cannot open this for you.
Console → *Networking → Virtual Cloud Networks → your VCN → Security Lists → Add Ingress Rules*:

* Source CIDR `0.0.0.0/0`, protocol **TCP**, destination ports `442,443,445,555,3128,8000,8080`
  (port 22 is already open).

The installer already opens the same ports in the VM's own firewall (Oracle Ubuntu images ship an
`iptables` REJECT rule that `ufw` does not override) and saves them so they survive a reboot.

## Use

Type `menu` (or `nilana`) as root:

```
 1) Ports List              9) Online Users
 2) Add User               10) Multi-login Limit ON/OFF
 3) Renew User             11) Services Status
 4) Delete User            12) Restart All Services
 5) Lock / Unlock User     13) Banner Settings
 6) Users List             14) Speedtest
 7) Expired Users          15) Monitor (htop)
 8) Active Users           16) Change User Password
17) Update Server IP       18) Repair Stunnel (SSL)
19) Update Script          20) Uninstall Script
 0) Quit
```

Shortcuts: `menu update` · `menu uninstall` · `menu repair`.

* **Repair Stunnel** rebuilds the certificate, config, systemd service and boot link from scratch and shows the
  log if it still fails. Manual check: `systemctl status nilana-stunnel` and `journalctl -u nilana-stunnel -n 30 --no-pager`.
* **Update Script** downloads `install.sh` from your GitHub, checks it, shows installed vs. available version and
  re-runs it in `--update` mode (your users, banner and settings are kept). Before publishing, set
  `UPDATE_URL_DEFAULT` near the top of `install.sh` to your raw URL
  (`https://raw.githubusercontent.com/<user>/Nilana-VPS/main/install.sh`); otherwise the menu asks for it once.
  Only point it at a repository you control – the script runs as root.
* **Uninstall Script** (type `UNINSTALL` to confirm) removes services, menu, firewall rules and settings, and
  restores the original SSH config, banner and Squid config. Optionally deletes all Nilana accounts and the
  packages. Port 22 is never touched.
* Accounts are tunnel-only (`/bin/false`, no home directory). "Days" can be `30` or a date `2027-01-31`.
* Expired accounts are locked automatically (checked every 30 min) and disconnected.
* **Multi-login limit** (default OFF): when ON, only the newest connection of each account stays online.
  Admin accounts such as `ubuntu` are never touched.
* **Banner**: `/etc/issue.net` is shown by OpenSSH and Dropbear. Menu → *Banner Settings* switches between
  the colourful HTML banner (rendered by HTTP-tunnel apps) and a plain-text one, or lets you edit it.
  Keep it **under 2000 bytes** – Dropbear silently ignores larger banners.
* **Squid** only forwards `CONNECT` requests to this server itself (not an open proxy).
  If your public IP changes, run menu → *Update Server IP*.
* **BadVPN** listens on `127.0.0.1:7300` (use it *through* the SSH tunnel, "UDPGW 127.0.0.1:7300").
  To expose it publicly, set `UDPGW_LISTEN="0.0.0.0"` at the top of `install.sh` before installing.

## What was fixed compared with Debian_SSH_VPS_script

| Problem in the original | Fix |
|---|---|
| `apt-get install … python …` – package no longer exists on Ubuntu 20.04+, so the **whole** command failed | removed; Python 3 is used only where needed |
| `systemd-sysv-install enable stunnel4` fails: Ubuntu 22.04/24.04 ship the stunnel4 init script in a *disabled* state | Nilana never enables the distro init script; it masks it and runs its own unit |
| Stunnel not coming back after a reboot | unit has no start-rate limit and pre-start checks, boot-enable is verified (link created by hand if `systemctl enable` fails), firewall persistence is verified |
| `stunnel.conf` defined two sections both named `[dropbear]` | unique section names |
| `squid.conf` used `hierarchy_stoplist` / `manager` (removed in Squid ≥ 4) → Squid would not start | clean config valid on Squid 4, 5 and 6 |
| Squid ACL used `ifconfig` (not installed) → empty IP; and on Oracle the public IP is not on the NIC | public IP from the internet + private IP from `ip route`, both allowed |
| `rc.local` with a `/dev/nul` typo and useless NAT rules | proper `nilana-badvpn.service` |
| `ufw enable` (interactive prompt) – and ufw cannot beat Oracle's default iptables REJECT rule | ports inserted into iptables (or ufw if it is active) and persisted |
| Oracle cloud-init disables SSH password login | drop-in `00-nilana.conf` re-enables it and sets the banner |
| Ookla `packagecloud` repo script breaks on newer Ubuntu | `speedtest-cli` from apt |
| Interactive `needrestart` / dpkg prompts, apt lock held by unattended-upgrades | non-interactive mode, lock wait |
| Dangerous clean-up lines (`rm *.txt`, `apt purge bind*`, `rm /tmp/*.txt` in the menu) | removed |
| Menu quit after every action, accepted only day counts, listed wrong users | rewritten (loop, dates, only Nilana accounts) |
| Expiry not enforced by Dropbear; autokill needed `auth.log` and a 12-line cron spam | expiry timer + journald-based limiter (systemd timers) |
| Three near-identical scripts | one installer, features toggled in the menu |

## Tested

Verified in a clean **Ubuntu 24.04 x86_64** sandbox by running this installer and starting the daemons with the
generated unit commands: all 9 ports listen; SSH logins succeed through OpenSSH 22, Dropbear 442/555,
Stunnel 443/445 and Squid 3128/8000/8080 (each reaching the UDPGW port through the tunnel); the banner is
delivered; wrong passwords are rejected; Squid refuses foreign destinations; the installer is re-runnable.
The Dropbear options were also checked against the Ubuntu 20.04 and 22.04 Dropbear packages.
The sandbox has no running systemd, so unit start-up, the ARM build and the Oracle VCN rules were **not** exercised –
check `menu → Services Status` after installing.

## Credits & license

Apache-2.0 (see `LICENSE`). Derived from *Debian_SSH_VPS_script* by Tharuka Sandaruwan, which is based on
*AutoScriptVPS* by xiihaiqal. BadVPN by Ambroz Bizjak (`badvpn/` holds the 1.999.128 source as an offline fallback).
Use only on servers you own, and make sure your use complies with your provider's terms.
