#!/usr/bin/env bash
# =============================================================================
#  NILANA VPS  -  SSH / Dropbear / Stunnel (SSL) / Squid / BadVPN auto-installer
#
#  Supported : Ubuntu 20.04 / 22.04 / 24.04  (x86_64 and ARM64)
#  Tuned for : Oracle Cloud "Always Free" VPS (AMD E2.1.Micro and Ampere A1)
#
#  Ports     : OpenSSH 22 | Dropbear 442 555 | Stunnel 443 445
#              Squid 3128 8000 8080 | BadVPN-udpgw 7300
#
#  Based on "Debian_SSH_VPS_script" by Tharuka Sandaruwan (Apache-2.0), which
#  itself derives from xiihaiqal/AutoScriptVPS. Licensed under Apache-2.0.
#
#  Usage     : sudo bash install.sh [-y|--yes] [--no-upgrade] [-h|--help]
# =============================================================================
set -uo pipefail

NILANA_VERSION="2.0.0"

# ----------------------------------------------------------------- settings
SSH_PORT=22
DROPBEAR_PORTS=(442 555)
STUNNEL_MAP=("443:442" "445:555")          # public-ssl-port:dropbear-port
SQUID_PORTS=(3128 8000 8080)
UDPGW_PORT=7300
UDPGW_LISTEN="127.0.0.1"                   # use 0.0.0.0 only if you really want a public UDPGW
TIMEZONE="${NILANA_TZ:-Asia/Colombo}"
BADVPN_URLS=(
  "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz"
  "https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/badvpn/badvpn-1.999.128.tar.bz2"
)

ASSUME_YES=0
DO_UPGRADE=1
LOG=/var/log/nilana-install.log
FAILED=()

# ------------------------------------------------------------------ output
if [ -t 1 ]; then
  R=$'\e[31;1m'; G=$'\e[32;1m'; Y=$'\e[33;1m'; B=$'\e[34;1m'; C=$'\e[36;1m'; N=$'\e[0m'
else
  R=''; G=''; Y=''; B=''; C=''; N=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$C" "$N" "$G" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s[WARN]%s %s\n' "$Y" "$N" "$*"; }
fail() { printf '    %s[FAIL]%s %s\n' "$R" "$N" "$*"; FAILED+=("$*"); }
TEE_PID=""
finish() {   # flush the log pipe, then exit with the given code
  local rc=${1:-0}
  if [ -n "$TEE_PID" ]; then exec >&- 2>&-; wait "$TEE_PID" 2>/dev/null; fi
  exit "$rc"
}
die()  { printf '\n%s[ERROR]%s %s\n' "$R" "$N" "$*" >&2; finish 1; }

logo() {
  printf '%s' "$C"
  cat <<'EOF'
 _  _ ___ _      _   _  _   _    __   _____  ___
| \| |_ _| |    /_\ | \| | /_\   \ \ / / _ \/ __|
| .` || || |__ / _ \| .` |/ _ \   \ V /|  _/\__ \
|_|\_|___|____/_/ \_\_|\_/_/ \_\   \_/ |_|  |___/
EOF
  printf '%s' "$N"
  printf '%s      Fast  *  Secure  *  Stable  SSH Tunnel   v%s%s\n\n' "$Y" "$NILANA_VERSION" "$N"
}

usage() {
  cat <<EOF
Nilana VPS installer v$NILANA_VERSION

  sudo bash install.sh [options]

  -y, --yes        do not ask for confirmation
  --no-upgrade     skip "apt-get upgrade" (faster, but not recommended)
  -h, --help       show this help
EOF
}

for a in "$@"; do
  case $a in
    -y|--yes) ASSUME_YES=1 ;;
    --no-upgrade) DO_UPGRADE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# --------------------------------------------------------------- pre-flight
[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo bash install.sh"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1; TEE_PID=$!

clear 2>/dev/null || true
logo

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:20.04|ubuntu:22.04|ubuntu:24.04) ;;
  ubuntu:*|debian:*) warn "Untested release ${PRETTY_NAME:-?}: designed for Ubuntu 20.04 - 24.04. Continuing anyway." ;;
  *) die "Unsupported OS (${PRETTY_NAME:-unknown}). Use Ubuntu 20.04, 22.04 or 24.04." ;;
esac
[ -d /run/systemd/system ] || die "systemd is required (containers / WSL are not supported)."
info "OS: ${PRETTY_NAME:-$ID $VERSION_ID}   Arch: $(uname -m)   Kernel: $(uname -r)"

if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
  echo
  read -rp "Install Nilana VPS now? [Y/n] " ans
  [[ ${ans:-y} =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# --------------------------------------------------------------------- apt
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_get() { apt-get "${APT_OPTS[@]}" "$@"; }

# Never let package postinst scripts start half-configured daemons.
POLICY=/usr/sbin/policy-rc.d; POLICY_MADE=0
block_services() {
  if [ ! -e "$POLICY" ]; then printf '#!/bin/sh\nexit 101\n' >"$POLICY"; chmod +x "$POLICY"; POLICY_MADE=1; fi
}
allow_services() { [ "$POLICY_MADE" = 1 ] && rm -f "$POLICY"; POLICY_MADE=0; }
trap allow_services EXIT

step "Updating package lists"
block_services
apt_get update || apt_get -o Acquire::ForceIPv4=true update || warn "apt update reported errors"
if [ "$DO_UPGRADE" -eq 1 ]; then
  step "Upgrading installed packages (this can take a few minutes)"
  apt_get upgrade || warn "apt upgrade reported errors"
fi

step "Installing base tools"
apt_get install ca-certificates curl wget openssl iproute2 procps psmisc python3 nano htop iptables \
  || die "Could not install base packages. Check your internet / apt sources."
apt_get install speedtest-cli >/dev/null 2>&1 || warn "speedtest-cli not available (menu speedtest disabled)"

# ------------------------------------------------------------- IP detection
step "Detecting server addresses"
PUBIP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://checkip.amazonaws.com; do
  PUBIP=$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')
  [[ $PUBIP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  PUBIP=""
done
PRIVIP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
[ -n "$PUBIP" ] || { PUBIP=$PRIVIP; warn "Could not detect the public IP - using $PRIVIP. Fix later with: menu -> Update Server IP"; }
[ -n "$PUBIP" ] || die "No IPv4 address found."
ok "Public IP: $PUBIP   Private IP: ${PRIVIP:-n/a}"

# ---------------------------------------------------------- time / sysctl
step "System tuning"
if timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -fs "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; then
  ok "Timezone: $TIMEZONE"
fi
modprobe tcp_bbr 2>/dev/null || true
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  cat >/etc/sysctl.d/99-nilana.conf <<'EOF'
# Nilana VPS network tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
EOF
  sysctl -q -p /etc/sysctl.d/99-nilana.conf >/dev/null 2>&1 && ok "TCP BBR enabled"
else
  info "BBR not available on this kernel - skipped"
fi

mkdir -p /etc/nilana

# ------------------------------------------------------------------ banner
step "Installing server banner"
cat >/etc/nilana/banner.html <<'__NILANA_BANNER_HTML__'
<p style="text-align:center"><span style="color:#00e5ff"><b>&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;</b></span></p>
<h1 style="text-align:center"><span style="color:#00e5ff"><b>&#9700; NILANA VPS &#9699;</b></span></h1>
<p style="text-align:center"><span style="color:#ffd600"><b>Fast &bull; Secure &bull; Stable</b></span></p>
<p style="text-align:center"><span style="color:#00ff88"><b>WELCOME!</b></span></p>
<p style="text-align:center"><span style="color:#ff4081">&#10004; Gaming &amp; VoIP supported (UDPGW 7300)</span></p>
<p style="text-align:center"><span style="color:#ff4081">&#10004; High speed SSH / SSL / Proxy tunnel</span></p>
<p style="text-align:center"><span style="color:#ff1744"><b>RULES</b></span></p>
<p style="text-align:center"><span style="color:#ffffff">&#10008; No DDoS &bull; No hacking &bull; No spamming</span></p>
<p style="text-align:center"><span style="color:#ffffff">&#10008; No torrent &bull; No illegal activity</span></p>
<p style="text-align:center"><span style="color:#b388ff">Abuse = account banned without notice</span></p>
<p style="text-align:center"><span style="color:#00e5ff"><b>&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;&#9473;</b></span></p>
<p style="text-align:center"><span style="color:#00ff88">Powered by <b>Nilana VPS</b></span></p>
__NILANA_BANNER_HTML__
cat >/etc/nilana/banner.txt <<'__NILANA_BANNER_TXT__'

  ================================================
              N I L A N A    V P S
          Fast  *  Secure  *  Stable  Tunnel
  ================================================
   [+] Gaming & VoIP supported (UDPGW 7300)
   [+] High speed SSH / SSL / Proxy tunnel
  ------------------------------------------------
   [-] No DDoS, hacking or spamming
   [-] No torrent or illegal activity
       Abuse = account banned without notice
  ================================================
__NILANA_BANNER_TXT__
[ -f /etc/nilana/issue.net.orig ] || { [ -f /etc/issue.net ] && cp /etc/issue.net /etc/nilana/issue.net.orig; }
cp /etc/nilana/banner.html /etc/issue.net
ok "Banner installed (/etc/issue.net, $(wc -c </etc/issue.net) bytes)"

# ----------------------------------------------------------------- OpenSSH
step "Configuring OpenSSH (port $SSH_PORT)"
command -v sshd >/dev/null 2>&1 || apt_get install openssh-server || fail "openssh-server missing"
mkdir -p /etc/ssh/sshd_config.d
if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
cat >/etc/ssh/sshd_config.d/00-nilana.conf <<'EOF'
# Nilana VPS  (read before every other file, first value wins)
Banner /etc/issue.net
PasswordAuthentication yes
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 4
MaxStartups 50:30:200
MaxSessions 200
UseDNS no
EOF
mkdir -p /run/sshd
if sshd -t 2>/tmp/nilana-sshd-test; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  ok "OpenSSH reloaded (password login + banner enabled)"
else
  rm -f /etc/ssh/sshd_config.d/00-nilana.conf
  fail "sshd config test failed - changes reverted: $(head -n1 /tmp/nilana-sshd-test)"
fi
# login shells that Dropbear/OpenSSH accept for tunnel-only accounts
for sh in /bin/false /usr/sbin/nologin; do grep -qxF "$sh" /etc/shells || echo "$sh" >>/etc/shells; done

# ---------------------------------------------------------------- Dropbear
step "Installing Dropbear (ports ${DROPBEAR_PORTS[*]})"
apt_get install dropbear-bin || fail "dropbear-bin could not be installed"
DROPBEAR_BIN=$(command -v dropbear || true); [ -x "${DROPBEAR_BIN:-}" ] || DROPBEAR_BIN=/usr/sbin/dropbear
mkdir -p /etc/dropbear
genkey() { [ -s "$2" ] || dropbearkey -t "$1" ${3:+-s "$3"} -f "$2" >/dev/null 2>&1; }
genkey rsa     /etc/dropbear/dropbear_rsa_host_key     2048
genkey ecdsa   /etc/dropbear/dropbear_ecdsa_host_key   256
genkey ed25519 /etc/dropbear/dropbear_ed25519_host_key ""
DB_ARGS=""; for p in "${DROPBEAR_PORTS[@]}"; do DB_ARGS+=" -p $p"; done
# the distro "dropbear" init script/service must not fight with ours
systemctl stop dropbear.service 2>/dev/null; systemctl mask dropbear.service >/dev/null 2>&1
cat >/etc/systemd/system/nilana-dropbear.service <<EOF
[Unit]
Description=Nilana VPS - Dropbear SSH (ports ${DROPBEAR_PORTS[*]})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DROPBEAR_BIN -F -E -w -K 30$DB_ARGS -b /etc/issue.net
Restart=always
RestartSec=2
# restarting the service must not disconnect users that are already online
KillMode=process
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
ok "Dropbear service written"

# ----------------------------------------------------------------- Stunnel
step "Installing Stunnel / SSL (ports $(printf '%s ' "${STUNNEL_MAP[@]%%:*}" | sed 's/ $//'))"
install_stunnel() {
  apt_get install stunnel4 && return 0
  warn "stunnel4 postinst failed (known update-rc.d / systemd-sysv-install problem) - repairing"
  # Ubuntu 22.04+/24.04 ship the init script in a "disabled" state and the
  # package's own 'enable' step can abort. We do not use that init script at all
  # (Nilana uses its own systemd unit), so neutralise update-rc.d and finish configuring.
  local shim; shim=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' >"$shim/update-rc.d"; chmod +x "$shim/update-rc.d"
  PATH="$shim:$PATH" dpkg --configure -a
  PATH="$shim:$PATH" apt_get -f install
  rm -rf "$shim"
  dpkg -s stunnel4 2>/dev/null | grep -q '^Status: install ok installed'
}
install_stunnel || fail "stunnel4 could not be installed"
STUNNEL_BIN=$(command -v stunnel4 || true); [ -x "${STUNNEL_BIN:-}" ] || STUNNEL_BIN=/usr/bin/stunnel4
# Disable the distro stunnel4 init service entirely (avoids systemd-sysv-install)
systemctl stop stunnel4.service 2>/dev/null; systemctl mask stunnel4.service >/dev/null 2>&1
[ -f /etc/default/stunnel4 ] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/stunnel4

if [ ! -s /etc/stunnel/nilana.pem ]; then
  mkdir -p /etc/stunnel
  tmpk=$(mktemp); tmpc=$(mktemp)
  if openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
       -subj "/C=LK/O=Nilana VPS/CN=nilana-vps" -keyout "$tmpk" -out "$tmpc" >/dev/null 2>&1; then
    ( umask 077; cat "$tmpk" "$tmpc" >/etc/stunnel/nilana.pem )
    ok "TLS certificate generated (valid 10 years)"
  else
    fail "openssl could not create the TLS certificate"
  fi
  rm -f "$tmpk" "$tmpc"
fi
chmod 600 /etc/stunnel/nilana.pem 2>/dev/null

{
  echo "# Nilana VPS - Stunnel: TLS in front of Dropbear"
  echo "foreground = yes"
  echo "cert = /etc/stunnel/nilana.pem"
  echo "client = no"
  if id stunnel4 >/dev/null 2>&1; then echo "setuid = stunnel4"; echo "setgid = stunnel4"; fi
  echo "debug = 4"
  echo "socket = a:SO_REUSEADDR=1"
  echo "socket = l:TCP_NODELAY=1"
  echo "socket = r:TCP_NODELAY=1"
  for m in "${STUNNEL_MAP[@]}"; do
    echo; echo "[nilana-ssl-${m%%:*}]"; echo "accept = ${m%%:*}"; echo "connect = 127.0.0.1:${m##*:}"
  done
} >/etc/nilana/stunnel.conf
cat >/etc/systemd/system/nilana-stunnel.service <<EOF
[Unit]
Description=Nilana VPS - Stunnel SSL ($(printf '%s ' "${STUNNEL_MAP[@]}"))
After=network-online.target nilana-dropbear.service
Wants=network-online.target nilana-dropbear.service

[Service]
Type=simple
ExecStart=$STUNNEL_BIN /etc/nilana/stunnel.conf
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
ok "Stunnel service written"

# ------------------------------------------------------------------- Squid
step "Installing Squid proxy (ports ${SQUID_PORTS[*]})"
apt_get install squid || fail "squid could not be installed"
[ -f /etc/squid/squid.conf.orig ] || { [ -f /etc/squid/squid.conf ] && cp /etc/squid/squid.conf /etc/squid/squid.conf.orig; }
{
  echo "# generated by Nilana VPS - do not edit (use menu: Update Server IP)"
  echo "acl nilana_self dst 127.0.0.1/32"
  [ -n "$PRIVIP" ] && [ "$PRIVIP" != "$PUBIP" ] && echo "acl nilana_self dst $PRIVIP/32"
  echo "acl nilana_self dst $PUBIP/32"
} >/etc/squid/nilana-dst.conf
{
  echo "# Nilana VPS - Squid (HTTP CONNECT gateway to this server only)"
  for p in "${SQUID_PORTS[@]}"; do echo "http_port $p"; done
  cat <<'EOF'

include /etc/squid/nilana-dst.conf

# Only allow tunnels that end on this very server (SSH / Dropbear / Stunnel ...)
http_access allow nilana_self
http_access deny all

forwarded_for delete
cache deny all
cache_mem 8 MB
access_log none
shutdown_lifetime 3 seconds
visible_hostname NilanaVPS
coredump_dir /var/spool/squid
EOF
} >/etc/squid/squid.conf
if squid -k parse >/tmp/nilana-squid-parse 2>&1 || grep -qi 'completed' /tmp/nilana-squid-parse; then
  ok "Squid configuration is valid"
else
  fail "Squid config check failed: $(grep -iE 'error|fatal' /tmp/nilana-squid-parse | head -n2 | tr '\n' ' ')"
fi

# ------------------------------------------------------------------ BadVPN
step "Building BadVPN-udpgw (port $UDPGW_PORT)"
install_badvpn() {
  [ -x /usr/local/bin/badvpn-udpgw ] && { ok "badvpn-udpgw already installed"; return 0; }
  apt_get install build-essential cmake || { warn "build tools missing"; return 1; }
  local work here tarball="" f url
  work=$(mktemp -d)
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)
  for f in "$here"/badvpn/badvpn-*.tar.*; do [ -f "$f" ] && { tarball=$f; break; }; done
  if [ -z "$tarball" ]; then
    for url in "${BADVPN_URLS[@]}"; do
      if curl -fsSL --retry 3 --max-time 120 -o "$work/badvpn.tar" "$url" && tar -tf "$work/badvpn.tar" >/dev/null 2>&1; then
        tarball="$work/badvpn.tar"; break
      fi
    done
  fi
  [ -n "$tarball" ] || { warn "could not obtain BadVPN sources"; rm -rf "$work"; return 1; }
  mkdir -p "$work/src" "$work/build"
  tar -xf "$tarball" -C "$work/src" --strip-components=1 || { rm -rf "$work"; return 1; }
  ( cd "$work/build" \
    && cmake "$work/src" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 \
    && make -j2 >/dev/null 2>&1 && make install >/dev/null 2>&1 ) || { rm -rf "$work"; return 1; }
  rm -rf "$work"
  [ -x /usr/local/bin/badvpn-udpgw ]
}
if install_badvpn; then
  pkill -x badvpn-udpgw 2>/dev/null   # leftovers from the old rc.local based script
  cat >/etc/systemd/system/nilana-badvpn.service <<EOF
[Unit]
Description=Nilana VPS - BadVPN UDP gateway (${UDPGW_LISTEN}:${UDPGW_PORT})
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr ${UDPGW_LISTEN}:${UDPGW_PORT} --max-clients 1000 --max-connections-for-client 20 --client-socket-sndbuf 1048576 --loglevel warning
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  ok "BadVPN service written"
else
  fail "BadVPN-udpgw could not be built"
fi

# --------------------------------------------------------- tools and menu
step "Installing management menu"
cat >/usr/local/sbin/nilana-online <<'__NILANA_ONLINE__'
#!/usr/bin/env python3
"""
Nilana VPS - session tool

  nilana-online                 show online users (OpenSSH + Dropbear)
  nilana-online --kick-extra    keep only the newest session of every Nilana user
  nilana-online --kick-user U   disconnect every session of user U
  nilana-online --expire        lock expired Nilana accounts and disconnect them

"Nilana users" are the accounts created by the menu (GECOS field = NilanaVPS).
Admin accounts such as ubuntu/opc are never touched.
"""
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time

MARK = "NilanaVPS"
RUN_DIR = "/run/nilana"
STATE = RUN_DIR + "/dropbear-map.json"
CURSOR = RUN_DIR + "/dropbear.cursor"
LOCK = RUN_DIR + "/lock"
DROPBEAR_UNIT = "nilana-dropbear.service"
SSH_PORTS = {"22"}
DB_PORTS = {"442", "555"}

# optional overrides from /etc/nilana/server.conf
try:
    with open("/etc/nilana/server.conf") as fh:
        for line in fh:
            m = re.match(r'^(SSH_PORT|DROPBEAR_PORTS)="?([^"\n]*)"?$', line.strip())
            if m:
                ports = set(m.group(2).split())
                if m.group(1) == "SSH_PORT":
                    SSH_PORTS = ports or SSH_PORTS
                else:
                    DB_PORTS = ports or DB_PORTS
except OSError:
    pass


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def nilana_users():
    users = set()
    for line in run(["getent", "passwd"]).splitlines():
        f = line.split(":")
        if len(f) >= 5 and f[4].split(",")[0] == MARK:
            users.add(f[0])
    return users


def shadow_entries():
    out = {}
    try:
        with open("/etc/shadow") as fh:
            for line in fh:
                f = line.rstrip("\n").split(":")
                if len(f) >= 8:
                    out[f[0]] = f
    except OSError:
        pass
    return out


def process_table():
    """pid -> (etimes, user, args)"""
    table = {}
    for line in run(["ps", "-eo", "pid=,etimes=,user:32=,args="]).splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
    return table


def clean_ip(addr):
    ip = addr.rsplit(":", 1)[0].strip("[]")
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    return ip


def established(ports):
    """yield (local_port, peer_ip, peer_port, [pids]) for established sockets"""
    expr = "( " + " or ".join("sport = :%s" % p for p in sorted(ports)) + " )"
    out = run(["ss", "-H", "-t", "-n", "-p", "state", "established"] + expr.split(" "))
    for line in out.splitlines():
        tok = line.split()
        if len(tok) < 4:
            continue
        local, peer = tok[2], tok[3]
        pids = [int(x) for x in re.findall(r"pid=(\d+)", line)]
        yield local.rsplit(":", 1)[1], clean_ip(peer), peer.rsplit(":", 1)[1], pids


def load_state():
    try:
        with open(STATE) as fh:
            return {int(k): v for k, v in json.load(fh).items()}
    except (OSError, ValueError):
        return {}


def update_dropbear_map(alive_pids):
    """Learn pid -> user from the dropbear journal (incrementally via a cursor)."""
    os.makedirs(RUN_DIR, exist_ok=True)
    state = load_state()
    cmd = ["journalctl", "-u", DROPBEAR_UNIT, "-o", "json", "--no-pager",
           "--cursor-file", CURSOR]
    if not os.path.exists(CURSOR):
        cmd += ["-n", "20000"]
    rx = re.compile(r"auth succeeded for '([^']+)'")
    for line in run(cmd).splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        msg = j.get("MESSAGE")
        if not isinstance(msg, str):
            continue
        m = rx.search(msg)
        if not m:
            continue
        pid = j.get("_PID")
        if pid is None:
            p = re.search(r"\[(\d+)\]", msg)
            pid = p.group(1) if p else None
        if pid is not None and str(pid).isdigit():
            state[int(pid)] = m.group(1)
    state = {p: u for p, u in state.items() if p in alive_pids}
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({str(k): v for k, v in state.items()}, fh)
    os.replace(tmp, STATE)
    return state


def collect_sessions():
    """list of dicts: user, service, ip, age, pid"""
    procs = process_table()
    sessions = []

    # --- OpenSSH: one "[priv]" monitor process per authenticated connection
    rx = re.compile(r"^sshd(?:-session)?: (\S+) \[priv\]")
    for _, ip, _, pids in established(SSH_PORTS):
        for pid in pids:
            info = procs.get(pid)
            if not info:
                continue
            m = rx.match(info[2])
            if m and m.group(1) != "unknown":
                sessions.append({"user": m.group(1), "service": "OpenSSH", "ip": ip,
                                 "age": info[0], "pid": pid})
                break

    # --- Dropbear: one forked process per connection
    db = []
    for _, ip, _, pids in established(DB_PORTS):
        for pid in pids:
            info = procs.get(pid)
            if info and "dropbear" in info[2]:
                db.append((pid, ip, info[0]))
                break
    if db:
        state = update_dropbear_map({p for p, _, _ in db})
        for pid, ip, age in db:
            user = state.get(pid)
            if user:
                sessions.append({"user": user, "service": "Dropbear", "ip": ip,
                                 "age": age, "pid": pid})
    return sessions


def fmt_age(sec):
    d, r = divmod(sec, 86400)
    h, r = divmod(r, 3600)
    m, s = divmod(r, 60)
    if d:
        return "%dd %02dh" % (d, h)
    if h:
        return "%dh %02dm" % (h, m)
    return "%dm %02ds" % (m, s)


def kill(pid):
    try:
        os.kill(pid, signal.SIGTERM)
        return True
    except OSError:
        return False


def cmd_show():
    sessions = collect_sessions()
    mine = nilana_users()
    print("\033[36m%-4s %-16s %-9s %-18s %s\033[0m" % ("#", "USER", "SERVICE", "IP", "ONLINE"))
    n = 0
    for s in sorted(sessions, key=lambda x: (x["user"], x["age"])):
        n += 1
        tag = "" if s["user"] in mine else " *"
        ip = s["ip"]
        if ip in ("127.0.0.1", "::1"):
            ip = "local (proxy)"
        print("%-4d %-16s %-9s %-18s %s" % (n, s["user"] + tag, s["service"], ip, fmt_age(s["age"])))
    print("\nTotal sessions: %d   (* = not a Nilana account)" % n)


def cmd_kick_extra():
    mine = nilana_users()
    by_user = {}
    for s in collect_sessions():
        if s["user"] in mine:
            by_user.setdefault(s["user"], []).append(s)
    for user, lst in by_user.items():
        if len(lst) < 2:
            continue
        lst.sort(key=lambda x: x["age"])       # newest first
        for old in lst[1:]:
            if kill(old["pid"]):
                print("multi-login: disconnected %s (%s %s pid %d)" %
                      (user, old["service"], old["ip"], old["pid"]))


def kick_user(user):
    n = 0
    for s in collect_sessions():
        if s["user"] == user and kill(s["pid"]):
            n += 1
    return n


def cmd_expire():
    today = int(time.time() // 86400)
    shadow = shadow_entries()
    for user in sorted(nilana_users()):
        f = shadow.get(user)
        if not f or not f[7].isdigit():
            continue
        if today > int(f[7]) and not f[1].startswith("!"):
            subprocess.run(["usermod", "-L", user])
            n = kick_user(user)
            print("expired: locked %s (disconnected %d session(s))" % (user, n))


def main():
    os.makedirs(RUN_DIR, exist_ok=True)
    lockfh = open(LOCK, "w")
    fcntl.flock(lockfh, fcntl.LOCK_EX)
    a = sys.argv[1:]
    if not a:
        cmd_show()
    elif a[0] == "--kick-extra":
        cmd_kick_extra()
    elif a[0] == "--kick-user" and len(a) == 2:
        print("disconnected %d session(s) of %s" % (kick_user(a[1]), a[1]))
    elif a[0] == "--expire":
        cmd_expire()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("run as root")
    main()
__NILANA_ONLINE__
chmod 755 /usr/local/sbin/nilana-online
cat >/usr/local/bin/menu <<'__NILANA_MENU__'
#!/usr/bin/env bash
# Nilana VPS - management menu  (command: menu  |  nilana)

[ "$(id -u)" -eq 0 ] || { echo "Please run as root:  sudo menu"; exit 1; }

CONF=/etc/nilana/server.conf
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
PUBIP=${PUBIP:-$(hostname -I 2>/dev/null | awk '{print $1}')}
SSH_PORT=${SSH_PORT:-22}
DROPBEAR_PORTS=${DROPBEAR_PORTS:-"442 555"}
STUNNEL_PORTS=${STUNNEL_PORTS:-"443 445"}
SQUID_PORTS=${SQUID_PORTS:-"3128 8000 8080"}
UDPGW_PORT=${UDPGW_PORT:-7300}
MARK="NilanaVPS"
SERVICES="ssh nilana-dropbear nilana-stunnel squid nilana-badvpn"

C0=$'\e[0m'; CR=$'\e[31;1m'; CG=$'\e[32;1m'; CY=$'\e[33;1m'; CC=$'\e[36;1m'; CBL=$'\e[34;1m'

logo() {
  printf '%s' "$CC"
  cat <<'EOF'
 _  _ ___ _      _   _  _   _    __   _____  ___
| \| |_ _| |    /_\ | \| | /_\   \ \ / / _ \/ __|
| .` || || |__ / _ \| .` |/ _ \   \ V /|  _/\__ \
|_|\_|___|____/_/ \_\_|\_/_/ \_\   \_/ |_|  |___/
EOF
  printf '%s' "$C0"
  printf '%s      Fast  *  Secure  *  Stable  SSH Tunnel%s\n' "$CY" "$C0"
}

line() { printf '%s------------------------------------------------%s\n' "$CC" "$C0"; }
pause() { echo; read -rp "Press Enter to return to the menu..." _; }
ok()   { printf '%s%s%s\n' "$CG" "$*" "$C0"; }
bad()  { printf '%s%s%s\n' "$CR" "$*" "$C0"; }

# ---------------------------------------------------------------- helpers
is_nilana_user() { [ "$(getent passwd "$1" | awk -F: '{split($5,a,","); print a[1]}')" = "$MARK" ]; }
nilana_users()   { getent passwd | awk -F: -v m="$MARK" '{split($5,a,","); if (a[1]==m) print $1}' | sort; }

# "30" -> today+30d ; "2026-12-31" -> that date ; prints YYYY-MM-DD
calc_expiry() {
  local in=$1
  if [[ $in =~ ^[0-9]+$ ]]; then
    date -d "+${in} days" +%F
  else
    date -d "$in" +%F 2>/dev/null
  fi
}

expiry_of() {  # user -> YYYY-MM-DD | never
  local d; d=$(getent shadow "$1" | cut -d: -f8)
  if [[ $d =~ ^[0-9]+$ ]]; then date -u -d "@$((d * 86400))" +%F; else echo never; fi
}

status_of() {  # user -> Active|Expired|Locked
  local f pw d today; f=$(getent shadow "$1")
  pw=$(cut -d: -f2 <<<"$f"); d=$(cut -d: -f8 <<<"$f"); today=$(( $(date +%s) / 86400 ))
  if [[ $d =~ ^[0-9]+$ ]] && (( today > d )); then echo Expired
  elif [[ $pw == '!'* ]]; then echo Locked
  else echo Active; fi
}

pick_user() {  # prompts, sets global U ; returns 1 when invalid
  read -rp "Enter username: " U
  if [ -z "$U" ] || ! is_nilana_user "$U"; then
    bad "User '$U' does not exist (or was not created by Nilana VPS)."; return 1
  fi
}

account_card() {  # user pass expiry
  clear; logo; line
  echo "  * Account Details *"; line
  printf '  %sHost / IP     :%s %s\n' "$CBL" "$C0" "$PUBIP"
  printf '  %sUsername      :%s %s\n' "$CBL" "$C0" "$1"
  [ -n "$2" ] && printf '  %sPassword      :%s %s\n' "$CBL" "$C0" "$2"
  printf '  %sExpires On    :%s %s\n' "$CG" "$C0" "$3"
  line
  printf '  OpenSSH   : %s\n  Dropbear  : %s\n  SSL (SNI) : %s\n  Squid     : %s\n  UDPGW     : 127.0.0.1:%s\n' \
    "$SSH_PORT" "${DROPBEAR_PORTS// /, }" "${STUNNEL_PORTS// /, }" "${SQUID_PORTS// /, }" "$UDPGW_PORT"
  line
}

# ---------------------------------------------------------------- users
add_user() {
  line; read -rp "※ Enter Username : " u
  if ! [[ $u =~ ^[a-z_][a-z0-9_-]{2,30}$ ]]; then
    bad "Invalid username (3-31 chars: a-z, 0-9, _ or -, must start with a letter)."; return; fi
  if getent passwd "$u" >/dev/null; then bad "Username '$u' already exists!"; return; fi
  read -rp "※ Enter Password : " p
  [ -n "$p" ] || { bad "Password cannot be empty."; return; }
  read -rp "※ Total Days To Exp Or Y-M-D : " e
  exp=$(calc_expiry "$e") || true
  [ -n "${exp:-}" ] || { bad "Invalid expiry. Use a number of days (30) or a date (2027-01-31)."; return; }
  if useradd -M -N -s /bin/false -c "$MARK" -e "$exp" "$u" && printf '%s:%s\n' "$u" "$p" | chpasswd; then
    account_card "$u" "$p" "$(date -d "$exp" +%d-%m-%Y)"
  else
    bad "Failed to create user."; userdel "$u" 2>/dev/null
  fi
}

renew_user() {
  line; pick_user || return
  echo "* Today                  : $(date +%F)"
  echo "* Current expiry         : $(expiry_of "$U")  ($(status_of "$U"))"
  read -rp "* Total Days To Exp Or Y-M-D : " e
  exp=$(calc_expiry "$e") || true
  [ -n "${exp:-}" ] || { bad "Invalid expiry."; return; }
  usermod -e "$exp" "$U" && usermod -U "$U" 2>/dev/null
  ok "Renewed. New expiry: $(date -d "$exp" +%d-%m-%Y)"
}

delete_user() {
  line; pick_user || return
  read -rp "Delete user '$U' → [y/N] : " a
  if [[ $a =~ ^[Yy]$ ]]; then
    nilana-online --kick-user "$U" >/dev/null 2>&1
    pkill -KILL -u "$U" 2>/dev/null
    userdel "$U" 2>/dev/null && ok "User $U deleted." || bad "Could not delete $U."
  else echo "Cancelled."; fi
}

lock_unlock_user() {
  line; pick_user || return
  if [ "$(status_of "$U")" = Locked ]; then
    usermod -U "$U" && ok "User $U unlocked."
  else
    usermod -L "$U" && nilana-online --kick-user "$U" >/dev/null 2>&1; ok "User $U locked and disconnected."
  fi
}

user_list() {  # $1 = all|active|expired
  local mode=$1 n=0 u st
  clear; line; printf '%-4s %-18s %-12s %s\n' "#" "USERNAME" "EXPIRES" "STATUS"; line
  while read -r u; do
    [ -n "$u" ] || continue
    st=$(status_of "$u")
    case $mode in
      active)  [ "$st" = Active ]  || continue ;;
      expired) [ "$st" = Expired ] || continue ;;
    esac
    n=$((n+1)); printf '%-4s %-18s %-12s %s\n' "$n." "$u" "$(expiry_of "$u")" "$st"
  done < <(nilana_users)
  line; echo "TOTAL: $n"; line
}

# ---------------------------------------------------------------- system
ports_list() {
  clear; logo; line
  printf '%s  OpenSSH Port : %s\n  Dropbear Port: %s\n  Stunnel Port : %s\n  Squid Port   : %s\n  Badvpn Port  : %s (local)\n%s' \
    "$CBL" "$SSH_PORT" "$DROPBEAR_PORTS" "$STUNNEL_PORTS" "$SQUID_PORTS" "$UDPGW_PORT" "$C0"
  line; echo "  Server IP    : $PUBIP"; line
}

services_status() {
  local s st p
  line
  for s in $SERVICES; do
    st=$(systemctl is-active "$s" 2>/dev/null)
    if [ "$st" = active ]; then printf '  %-18s %s%s%s\n' "$s" "$CG" "running" "$C0"
    else printf '  %-18s %s%s%s\n' "$s" "$CR" "${st:-not found}" "$C0"; fi
  done
  line; echo "  Listening ports:"
  for p in $SSH_PORT $DROPBEAR_PORTS $STUNNEL_PORTS $SQUID_PORTS; do
    if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then printf '   %s%-6s open%s\n' "$CG" "$p" "$C0"
    else printf '   %s%-6s CLOSED%s\n' "$CR" "$p" "$C0"; fi
  done
  if ss -H -lun "sport = :$UDPGW_PORT" 2>/dev/null | grep -q . || ss -H -ltn "sport = :$UDPGW_PORT" 2>/dev/null | grep -q .; then
    printf '   %s%-6s open (udpgw)%s\n' "$CG" "$UDPGW_PORT" "$C0"; else printf '   %s%-6s CLOSED (udpgw)%s\n' "$CR" "$UDPGW_PORT" "$C0"; fi
  line
}

restart_services() {
  local s
  for s in $SERVICES; do systemctl restart "$s" 2>/dev/null && ok "restarted $s" || bad "failed: $s"; done
}

limiter_toggle() {
  if systemctl is-enabled --quiet nilana-limiter.timer 2>/dev/null; then
    systemctl disable --now nilana-limiter.timer >/dev/null 2>&1
    ok "Multi-login limit: OFF  (users can connect from many devices)"
  else
    systemctl enable --now nilana-limiter.timer >/dev/null 2>&1
    ok "Multi-login limit: ON  (one active device per account, checked every 10 s)"
  fi
}

limiter_state() { systemctl is-enabled --quiet nilana-limiter.timer 2>/dev/null && echo "${CG}ON${C0}" || echo "${CR}OFF${C0}"; }

banner_menu() {
  line; echo " 1) Use colourful HTML banner (HTTP Injector / NetMod / HTTP Custom ...)"
  echo " 2) Use plain-text banner (PuTTY / terminal)"
  echo " 3) Edit current banner with nano"
  echo " 4) Back"; line
  read -rp "Choice: " b
  case $b in
    1) cp /etc/nilana/banner.html /etc/issue.net ;;
    2) cp /etc/nilana/banner.txt  /etc/issue.net ;;
    3) nano /etc/issue.net ;;
    *) return ;;
  esac
  local size; size=$(wc -c </etc/issue.net)
  if [ "$size" -gt 1900 ]; then bad "Banner is $size bytes. Dropbear ignores banners above 2000 bytes - please shorten it."; fi
  systemctl restart nilana-dropbear 2>/dev/null; systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  ok "Banner applied ($size bytes)."
}

refresh_ip() {
  local new priv
  new=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null)
  priv=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
  if ! [[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then bad "Could not detect the public IP."; return; fi
  sed -i "s/^PUBIP=.*/PUBIP=$new/; s/^PRIVIP=.*/PRIVIP=$priv/" "$CONF"
  PUBIP=$new
  { echo "# generated by Nilana VPS - do not edit (use menu: Update Server IP)"
    echo "acl nilana_self dst 127.0.0.1/32"
    [ -n "$priv" ] && [ "$priv" != "$new" ] && echo "acl nilana_self dst $priv/32"
    echo "acl nilana_self dst $new/32"; } >/etc/squid/nilana-dst.conf
  systemctl restart squid && ok "Server IP is now $new (Squid ACL refreshed)."
}

# ---------------------------------------------------------------- main loop
main_menu() {
  while true; do
    clear; logo; line
    printf '  Server: %s    Multi-login limit: %s\n' "$PUBIP" "$(limiter_state)"; line
    cat <<EOF
   1) Ports List              9) Online Users
   2) Add User               10) Multi-login Limit ON/OFF
   3) Renew User             11) Services Status
   4) Delete User            12) Restart All Services
   5) Lock / Unlock User     13) Banner Settings
   6) Users List             14) Speedtest
   7) Expired Users          15) Monitor (htop)
   8) Active Users           16) Change User Password
  17) Update Server IP        0) Quit
EOF
    line
    read -rp " Choose [0-17]: " c
    clear
    case $c in
      1) ports_list ;;
      2) add_user ;;
      3) renew_user ;;
      4) delete_user ;;
      5) lock_unlock_user ;;
      6) user_list all ;;
      7) user_list expired ;;
      8) user_list active ;;
      9) nilana-online ;;
      10) limiter_toggle ;;
      11) services_status ;;
      12) restart_services ;;
      13) banner_menu ;;
      14) if command -v speedtest-cli >/dev/null; then speedtest-cli --simple; else bad "speedtest-cli not installed"; fi ;;
      15) htop ;;
      16) pick_user && passwd "$U" ;;
      17) refresh_ip ;;
      0|q|Q) clear; exit 0 ;;
      *) bad "Invalid option." ;;
    esac
    pause
  done
}

main_menu
__NILANA_MENU__
chmod 755 /usr/local/bin/menu
ln -sf /usr/local/bin/menu /usr/local/bin/nilana

cat >/etc/nilana/server.conf <<EOF
# Nilana VPS settings (read by the menu)
VERSION=$NILANA_VERSION
PUBIP=$PUBIP
PRIVIP=$PRIVIP
SSH_PORT=$SSH_PORT
DROPBEAR_PORTS="${DROPBEAR_PORTS[*]}"
STUNNEL_PORTS="$(printf '%s ' "${STUNNEL_MAP[@]%%:*}" | sed 's/ $//')"
SQUID_PORTS="${SQUID_PORTS[*]}"
UDPGW_PORT=$UDPGW_PORT
EOF

cat >/etc/systemd/system/nilana-expire.service <<'EOF'
[Unit]
Description=Nilana VPS - lock expired accounts

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nilana-online --expire
EOF
cat >/etc/systemd/system/nilana-expire.timer <<'EOF'
[Unit]
Description=Nilana VPS - expiry check every 30 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF
cat >/etc/systemd/system/nilana-limiter.service <<'EOF'
[Unit]
Description=Nilana VPS - one active device per account

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nilana-online --kick-extra
EOF
cat >/etc/systemd/system/nilana-limiter.timer <<'EOF'
[Unit]
Description=Nilana VPS - multi-login check every 10 seconds

[Timer]
OnBootSec=1min
OnUnitActiveSec=10s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
cat >/etc/profile.d/nilana.sh <<'EOF'
# Nilana VPS hint for administrators
if [ -n "${PS1:-}" ] && [ "$(id -u)" -eq 0 ] && [ -x /usr/local/bin/menu ]; then
  printf '\n  \033[36;1mNILANA VPS\033[0m - type \033[33;1mmenu\033[0m to manage users and services\n\n'
fi
EOF
ok "menu installed  (type: menu)"

# ---------------------------------------------------------------- firewall
step "Opening firewall ports"
TCP_PORTS=("${DROPBEAR_PORTS[@]}" "${SQUID_PORTS[@]}")
for m in "${STUNNEL_MAP[@]}"; do TCP_PORTS+=("${m%%:*}"); done
TCP_PORTS+=("$SSH_PORT")
UDP_PORTS=()
if [ "$UDPGW_LISTEN" != "127.0.0.1" ]; then TCP_PORTS+=("$UDPGW_PORT"); UDP_PORTS+=("$UDPGW_PORT"); fi

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }
fw_open() {   # proto port
  local proto=$1 port=$2 b
  if ufw_active; then ufw allow "$port/$proto" >/dev/null 2>&1; return; fi
  for b in iptables ip6tables; do
    command -v "$b" >/dev/null 2>&1 || continue
    "$b" -w -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
      || "$b" -w -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  done
}
if ufw_active; then
  info "ufw is active - using ufw rules"
else
  echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections 2>/dev/null
  echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections 2>/dev/null
  command -v netfilter-persistent >/dev/null 2>&1 || apt_get install iptables-persistent >/dev/null 2>&1 \
    || warn "iptables-persistent missing - rules will not survive a reboot"
fi
for p in "${TCP_PORTS[@]}"; do fw_open tcp "$p"; done
for p in "${UDP_PORTS[@]}"; do fw_open udp "$p"; done
if ! ufw_active; then
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1 && ok "Firewall rules saved (persist after reboot)"
  else mkdir -p /etc/iptables && iptables-save >/etc/iptables/rules.v4; fi
fi
ok "Opened TCP: ${TCP_PORTS[*]}"

# ------------------------------------------------------------ start it all
step "Starting services"
allow_services
systemctl daemon-reload
for u in nilana-dropbear nilana-stunnel squid nilana-badvpn; do
  [ -f "/etc/systemd/system/$u.service" ] || [ "$u" = squid ] || continue
  systemctl enable "$u" >/dev/null 2>&1
  systemctl restart "$u" 2>/dev/null
done
systemctl enable --now nilana-expire.timer >/dev/null 2>&1
sleep 3

check_listen() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }
chk_unit() { if systemctl is-active --quiet "$1"; then ok "$1 is running"; else fail "$1 is NOT running  (journalctl -u $1 -n 20)"; fi; }
systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null && ok "OpenSSH is running" || fail "OpenSSH is NOT running"
chk_unit nilana-dropbear
chk_unit nilana-stunnel
chk_unit squid
[ -f /etc/systemd/system/nilana-badvpn.service ] && chk_unit nilana-badvpn
for p in "$SSH_PORT" "${DROPBEAR_PORTS[@]}" "${SQUID_PORTS[@]}"; do check_listen "$p" || fail "nothing is listening on TCP $p"; done
for m in "${STUNNEL_MAP[@]}"; do check_listen "${m%%:*}" || fail "nothing is listening on TCP ${m%%:*}"; done
check_listen "$UDPGW_PORT" || fail "nothing is listening on $UDPGW_PORT (badvpn-udpgw)"

for u in nilana-dropbear nilana-stunnel squid nilana-badvpn; do
  systemctl is-failed --quiet "$u" && { warn "last log lines of $u:"; journalctl -u "$u" -n 6 --no-pager 2>/dev/null | sed 's/^/        /'; }
done

# ----------------------------------------------------------------- summary
echo
printf '%s================================================================%s\n' "$C" "$N"
logo
printf '  %sServer IP%s   : %s\n' "$B" "$N" "$PUBIP"
printf '  %sOpenSSH%s     : %s\n' "$B" "$N" "$SSH_PORT"
printf '  %sDropbear%s    : %s\n' "$B" "$N" "${DROPBEAR_PORTS[*]}"
printf '  %sStunnel SSL%s : %s\n' "$B" "$N" "$(printf '%s ' "${STUNNEL_MAP[@]%%:*}" | sed 's/ $//')"
printf '  %sSquid%s       : %s\n' "$B" "$N" "${SQUID_PORTS[*]}"
printf '  %sBadVPN UDPGW%s: %s:%s\n' "$B" "$N" "$UDPGW_LISTEN" "$UDPGW_PORT"
printf '%s================================================================%s\n' "$C" "$N"
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '  %sAll services are running.%s\n' "$G" "$N"
else
  printf '  %sSome parts need attention:%s\n' "$R" "$N"; for f in "${FAILED[@]}"; do printf '   - %s\n' "$f"; done
  printf '  Full log: %s\n' "$LOG"
fi
cat <<EOF

  ${Y}ORACLE CLOUD - one manual step (cannot be automated from inside the VM):${N}
  Console -> Networking -> Virtual Cloud Networks -> your VCN -> Security Lists
  -> Add Ingress Rules:  Source CIDR 0.0.0.0/0 , IP protocol TCP ,
  Destination ports:  442,443,445,555,3128,8000,8080   (22 is open by default)

  Create your first account:   ${G}menu${N}  ->  2) Add User
  Banner / multi-login / expiry are all inside the menu.
EOF
if [ -f /var/run/reboot-required ]; then
  warn "A reboot is recommended (kernel/libraries were upgraded):  sudo reboot"
fi
[ ${#FAILED[@]} -eq 0 ]; finish $?
