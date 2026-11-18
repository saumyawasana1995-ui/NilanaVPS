# Installation and uninstallation commands

Run these commands from a regular Ubuntu account with `sudo` access. They download the installer to the current directory before running it, so you can inspect the script first. For an interactive root shell, run `sudo -i` and omit `sudo` from the commands below.

Choose the SSH tunnel installer **or** the VLESS installer. Both use TCP port 443, so do not install both stacks at the same time.

## SSH / Dropbear / Stunnel / Squid / BadVPN

### Full profile

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install.sh
sudo bash install.sh
```

### Lite profile

```bash
curl -fsSLo install-lite.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install-lite.sh
sudo bash install-lite.sh
```

To skip Squid, add `--no-squid` to the `bash` command. The full installer also accepts `--lite`, `--full`, `--no-upgrade`, `--no-reboot`, `--domain vpn.example.com`, and `-y` (non-interactive install).

### Update an existing SSH-stack installation

Download the current script, then run its update mode:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install.sh
sudo bash install.sh --update
```

This retains existing users, banner, and settings.

### Uninstall the SSH stack

Use the installed management command:

```bash
sudo menu uninstall
```

Alternatively, run `sudo menu`, choose **20) Uninstall Script**, then type `UNINSTALL` when prompted. The uninstaller asks whether to delete Nilana accounts and whether to remove Dropbear, Stunnel, and Squid packages. OpenSSH on port 22 is left in place.

## VLESS (Xray-core)

### Install

```bash
curl -fsSLo install-vless.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install-vless.sh
sudo bash install-vless.sh
```

The default is VLESS + REALITY on TCP 443. For WebSocket/TLS mode, use `sudo bash install-vless.sh --mode ws --domain vpn.example.com`.

### Update

After downloading the latest `install-vless.sh` as above, run:

```bash
sudo bash install-vless.sh --update
```

### Uninstall

```bash
sudo vless uninstall
```

Confirm the uninstall when prompted. OpenSSH on port 22 is not removed.

## Nilana Panel (optional; requires VLESS)

Download and install the panel after installing VLESS:

```bash
curl -fsSLo install-panel.sh https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main/install-panel.sh
sudo bash install-panel.sh
```

For public HTTPS access, choose a port and also permit that TCP port in your cloud firewall:

```bash
sudo bash install-panel.sh --public --port 8443
```

Uninstall only the panel (the VLESS installation is retained):

```bash
sudo bash install-panel.sh --uninstall
```
