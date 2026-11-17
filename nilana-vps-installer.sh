#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
backup_once() {
  local file=$1
  if [[ -e "$file" && ! -e "${file}.nilana.bak" ]]; then
    cp -a -- "$file" "${file}.nilana.bak"
  fi
}

[[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'
[[ -r /etc/os-release ]] || die 'Cannot identify operating system.'
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || die 'Ubuntu 20.04, 22.04, or 24.04 is required.'
case "${VERSION_ID:-}" in 20.04|22.04|24.04) ;; *) die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}" ;; esac

# Optional trusted client CIDR for public Squid and BadVPN listeners.
# Leave empty (the default) to bind both services to loopback only.
NILANA_ALLOWED_CIDR=${NILANA_ALLOWED_CIDR:-}
if [[ -n "$NILANA_ALLOWED_CIDR" ]] && ! python3 - "$NILANA_ALLOWED_CIDR" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
PY
then
  die 'NILANA_ALLOWED_CIDR must be a valid IPv4 or IPv6 CIDR, e.g. 198.51.100.8/32.'
fi

log 'Installing packages'
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl openssl openssh-server dropbear stunnel4 squid \
  fail2ban build-essential cmake pkg-config libssl-dev libcap-dev python3

log 'Writing Nilana VPS login banner'
backup_once /etc/issue.net
cat >/etc/issue.net <<'BANNER'
 _   _ _ _          _   _   _   _ ____  ____
| \ | (_) | _____  | \ | | | | | |  _ \/ ___|
|  \| | | |/ / _ \ |  \| | | | | | |_) \___ \
| |\  | |   <  __/ | |\  | | |_| |  __/ ___) |
|_| \_|_|_|\_\___| |_| \_|  \___/|_|   |____/

Nilana VPS | Authorized access only
BANNER
chmod 0644 /etc/issue.net

log 'Configuring OpenSSH without changing existing authentication policy'
install -d -m 0755 /etc/ssh/sshd_config.d
backup_once /etc/ssh/sshd_config.d/00-nilana.conf
cat >/etc/ssh/sshd_config.d/00-nilana.conf <<'SSHCONF'
Port 22
Banner /etc/issue.net
SSHCONF
if ! grep -Eq '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config; then
  # Ubuntu's stock config normally has Include already. If absent, insert it first
  # so the Nilana drop-in is read before other settings.
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
/usr/sbin/sshd -t
systemctl enable ssh
systemctl reload ssh || systemctl restart ssh

log 'Configuring Dropbear on 442 and 555'
backup_once /etc/default/dropbear
cat >/etc/default/dropbear <<'DROPBEAR'
# Nilana VPS Dropbear listeners
NO_START=0
DROPBEAR_PORT=442
DROPBEAR_EXTRA_ARGS="-p 555 -b /etc/issue.net"
DROPBEAR
systemctl enable dropbear
systemctl restart dropbear

log 'Creating a self-signed TLS certificate for Stunnel'
install -d -m 0750 /etc/stunnel
if [[ ! -s /etc/stunnel/nilana.pem ]]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj '/CN=Nilana VPS' \
    -keyout /etc/stunnel/nilana.key \
    -out /etc/stunnel/nilana.crt
  cat /etc/stunnel/nilana.key /etc/stunnel/nilana.crt >/etc/stunnel/nilana.pem
fi
chmod 0640 /etc/stunnel/nilana.pem
chown root:stunnel4 /etc/stunnel/nilana.pem 2>/dev/null || true
backup_once /etc/stunnel/stunnel.conf
cat >/etc/stunnel/stunnel.conf <<'STUNNEL'
foreground = yes

[ssh-tls]
accept = 0.0.0.0:443
connect = 127.0.0.1:22
cert = /etc/stunnel/nilana.pem

[dropbear-tls]
accept = 0.0.0.0:445
connect = 127.0.0.1:442
cert = /etc/stunnel/nilana.pem
STUNNEL
if [[ -f /etc/default/stunnel4 ]]; then
  backup_once /etc/default/stunnel4
  if grep -q '^ENABLED=' /etc/default/stunnel4; then
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
  else
    printf '\nENABLED=1\n' >>/etc/default/stunnel4
  fi
fi
systemctl enable stunnel4
systemctl restart stunnel4

log 'Configuring Squid with a deny-by-default client ACL'
backup_once /etc/squid/squid.conf
if [[ -n "$NILANA_ALLOWED_CIDR" ]]; then
  SQUID_BIND='0.0.0.0'
  SQUID_ACL="acl nilana_clients src $NILANA_ALLOWED_CIDR"
else
  SQUID_BIND='127.0.0.1'
  SQUID_ACL='acl nilana_clients src 127.0.0.1/32 ::1'
fi
cat >/etc/squid/squid.conf <<SQUID
# Nilana VPS proxy. Only loopback or NILANA_ALLOWED_CIDR is permitted.
visible_hostname NilanaVPS
http_port ${SQUID_BIND}:3128
http_port ${SQUID_BIND}:8000
http_port ${SQUID_BIND}:8080
${SQUID_ACL}
http_access allow nilana_clients
http_access deny all
cache deny all
access_log stdio:/var/log/squid/access.log
cache_log /var/log/squid/cache.log
SQUID
squid -k parse
systemctl enable squid
systemctl restart squid

log 'Building the pinned BadVPN 1.999.128 UDP gateway'
if [[ ! -x /usr/local/sbin/nilana-udpgw ]]; then
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' EXIT
  curl --fail --location --silent --show-error \
    https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.128.tar.gz \
    -o "$workdir/badvpn.tar.gz"
  tar -xzf "$workdir/badvpn.tar.gz" -C "$workdir"
  source_dir=$(find "$workdir" -maxdepth 1 -type d -name 'badvpn-*' -print -quit)
  [[ -n "$source_dir" ]] || die 'BadVPN source archive did not contain the expected directory.'
  cmake -S "$source_dir" -B "$workdir/build" \
    -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
  cmake --build "$workdir/build" --parallel "$(nproc)"
  udpgw=$(find "$workdir/build" -type f -name udpgw -perm /111 -print -quit)
  [[ -n "$udpgw" ]] || die 'BadVPN build completed but the udpgw executable was not found.'
  install -m 0755 "$udpgw" /usr/local/sbin/nilana-udpgw
fi

if [[ -n "$NILANA_ALLOWED_CIDR" ]]; then
  UDPGW_LISTEN='0.0.0.0:7300'
else
  UDPGW_LISTEN='127.0.0.1:7300'
fi
cat >/etc/systemd/system/nilana-badvpn.service <<UNIT
[Unit]
Description=Nilana VPS BadVPN UDP gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/nilana-udpgw --listen-addr ${UDPGW_LISTEN} --max-clients 256
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now nilana-badvpn.service

log 'Enabling Fail2ban SSH protection'
backup_once /etc/fail2ban/jail.d/nilana.local
install -d -m 0755 /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/nilana.local <<'FAIL2BAN'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 10m
FAIL2BAN
systemctl enable fail2ban
systemctl restart fail2ban

log 'Applying conservative, reversible BBR congestion-control setting when supported'
if modprobe tcp_bbr 2>/dev/null && sysctl -a 2>/dev/null | grep -q 'net.ipv4.tcp_available_congestion_control.*bbr'; then
  backup_once /etc/sysctl.d/99-nilana-network.conf
  cat >/etc/sysctl.d/99-nilana-network.conf <<'SYSCTL'
# BBR can improve throughput under some paths; it cannot reduce physical RTT.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
  sysctl --system >/dev/null
else
  printf 'BBR is unavailable in this kernel; leaving network defaults unchanged.\n'
fi

log 'Installation complete; checking service states'
for unit in ssh dropbear stunnel4 squid nilana-badvpn fail2ban; do
  if ! systemctl is-active --quiet "$unit"; then
    systemctl --no-pager --full status "$unit" || true
    die "Service $unit is not active; inspect its status above."
  fi
done

cat <<'DONE'

Nilana VPS services are running.
Listeners: SSH 22; Dropbear 442/555; Stunnel TLS 443/445;
           Squid 3128/8000/8080; BadVPN UDP gateway 7300.

Security defaults:
- Squid and BadVPN bind to loopback unless NILANA_ALLOWED_CIDR was set.
- SSH authentication policy was not weakened or changed.
- This installer does not reset or enable UFW, to avoid locking out remote admins.
- Add only required Oracle VCN rules, and restrict proxy/UDPGW ingress to trusted IPs.
- Stunnel currently uses a self-signed certificate; clients will not see a trusted identity.

BBR may help throughput on some paths, but cannot guarantee lower ping.
DONE
