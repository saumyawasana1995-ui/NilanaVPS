#!/usr/bin/env bash
# =============================================================================
#  NILANA VPS - VLESS ONLY installer  (Xray-core, port 443)
#
#  * Only VLESS is installed. No SSH tunnel stack: no Dropbear, Stunnel,
#    Squid or BadVPN. OpenSSH on port 22 is left alone (admin access).
#  * Mode "reality" (default): VLESS + XTLS-Vision + REALITY on TCP 443.
#      No domain and no certificate needed, login by server IP.
#  * Mode "ws": VLESS + WebSocket + TLS on TCP 443 (self-signed certificate).
#      Use this when you want a domain / CDN (e.g. Cloudflare proxied) in front.
#  * User menu: add / renew / delete / lock users, account expiry, links + QR.
#
#  v1.1.0 additions (installed by a fresh install AND by --update):
#  * Xray uses its own cached DoH resolver (1.1.1.1 / 8.8.8.8), IPv4 only, so a
#    flaky VPS resolver or a broken IPv6 route can no longer make "connected
#    but no internet" happen.
#  * Kernel tuning: BBR + fq, bigger buffers, MTU probing (/etc/sysctl.d).
#  * nilana-netwatch: checks the internet path every minute and repairs it in
#    steps (DNS, network, Xray, last resort reboot). Log: /var/log/nilana-netwatch.log
#  * "Exit" feature: send adult-site domains out through a server in another
#    country (second server running this installer, or a SOCKS5 proxy).
#
#  Usage (as root):  bash install-vless.sh [options]
#    --mode reality|ws     transport (default: reality)
#    --sni  host           REALITY camouflage site (default: www.microsoft.com)
#    --domain host         host/domain used in client links (default: server IP)
#    --wspath /path        WebSocket path for ws mode (default: /nilana)
#    --no-block-torrent    do not block BitTorrent traffic
#    -y                    no questions
#    --update              update Xray + apply v1.1 fixes, keep users and settings
#  Ubuntu 20.04 / 22.04 / 24.04 / 26.04 / Debian 11+  (x86_64 and ARM64)
# =============================================================================
set -u

NV_VERSION="1.1.0"
CONF_DIR="/etc/nilana-vless"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
ASSET_DIR="/usr/local/share/xray"
LOG="/var/log/nilana-vless-install.log"

MODE="reality"
SNI="www.microsoft.com"
DOMAIN=""
WSPATH="/nilana"
BLOCK_TORRENT=1
ASSUME_YES=0
UPDATE_ONLY=0
PORT=443
XUSER="nilana-xray"

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; N=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)     MODE="${2:-}"; shift ;;
    --sni)      SNI="${2:-}"; shift ;;
    --domain)   DOMAIN="${2:-}"; shift ;;
    --wspath)   WSPATH="${2:-}"; shift ;;
    --no-block-torrent) BLOCK_TORRENT=0 ;;
    -y|--yes)   ASSUME_YES=1 ;;
    --update)   UPDATE_ONLY=1 ;;
    -h|--help)  sed -n '2,34p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i, then run the script again)."
case "$MODE" in reality|ws) ;; *) die "--mode must be 'reality' or 'ws'" ;; esac
[[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid --sni value"
[[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid --domain value"
[[ "$WSPATH" =~ ^/[A-Za-z0-9._/-]*$ ]] || die "Invalid --wspath (letters, digits . _ - / only)"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"; OS_NAME="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
case "$OS_ID" in ubuntu|debian) ;; *) warn "Untested OS ($OS_NAME); continuing." ;; esac
command -v systemctl >/dev/null || die "systemd is required."

case "$(uname -m)" in
  x86_64|amd64)  XARCH="64" ;;
  aarch64|arm64) XARCH="arm64-v8a" ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

ask_yes() { # prompt -> 0 if yes
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local a; read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- packages --
install_packages() {
  say "${C}==> Installing packages${N}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt update reported problems"
  apt-get install -y -qq curl jq unzip openssl ca-certificates qrencode iproute2 iptables >/dev/null \
    || die "Package installation failed (see $LOG)"
  ok "curl, jq, unzip, openssl, qrencode installed"
}

# -------------------------------------------------------------------- xray --
install_xray() {
  say "${C}==> Installing Xray-core${N}"
  local base="https://github.com/XTLS/Xray-core/releases/latest/download"
  local zip="Xray-linux-${XARCH}.zip" tmp want got
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/x.zip"  "$base/$zip"       || die "Could not download Xray ($base/$zip)"
  curl -fsSL --retry 3 -o "$tmp/x.dgst" "$base/$zip.dgst"  || die "Could not download Xray checksum"
  want="$(awk -F'= *' '/^SHA2-256/{print $2; exit}' "$tmp/x.dgst" | tr -d '[:space:]')"
  got="$(sha256sum "$tmp/x.zip" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || die "Xray checksum mismatch - aborting."
  unzip -oq "$tmp/x.zip" -d "$tmp" || die "Could not unzip Xray"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  mkdir -p "$ASSET_DIR"
  for f in geoip.dat geosite.dat; do      # domain lists (used by the Exit feature)
    [ -f "$tmp/$f" ] && install -m 644 "$tmp/$f" "$ASSET_DIR/$f"
  done
  rm -rf "$tmp"
  ok "$("$XRAY_BIN" version | head -1)"
}

# ------------------------------------------------------ network tuning -----
# BBR + fq, larger buffers, MTU probing, and a reliable DNS for the VPS itself.
tune_network() {
  say "${C}==> Network tuning (BBR, buffers, DNS)${N}"
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr > /etc/modules-load.d/nilana-bbr.conf 2>/dev/null || true
  cat > /etc/sysctl.d/99-nilana-net.conf <<'SYSCTL_EOF'
# Nilana VLESS - network tuning (safe defaults for a 1-4 GB VPS)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
# fixes "connects but pages hang" when a router on the path drops big packets
net.ipv4.tcp_mtu_probing = 1
# long distance (high RTT) links need bigger buffers; these are maximums only
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# a leading "-" means: ignore if this key does not exist on this kernel
-net.netfilter.nf_conntrack_max = 131072
SYSCTL_EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [ "$cc" = bbr ]; then ok "TCP congestion control: BBR (+fq)"
  else warn "BBR is not available on this kernel (using: ${cc:-unknown})"; fi

  if systemctl list-unit-files systemd-resolved.service 2>/dev/null | grep -q systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/nilana.conf <<'RESOLVED_EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 1.0.0.1 8.8.4.4
Cache=yes
DNSSEC=no
RESOLVED_EOF
    systemctl restart systemd-resolved >/dev/null 2>&1 && ok "System DNS: 1.1.1.1 / 8.8.8.8 (fallback 9.9.9.9)"
  fi
}

# ------------------------------------------------------------ watchdog -----
install_watchdog() {
  say "${C}==> Installing the network watchdog (nilana-netwatch)${N}"
  cat > /usr/local/bin/nilana-netwatch <<'NETWATCH_EOF'
#!/usr/bin/env bash
# nilana-netwatch - keeps the VPS internet path alive. Runs every minute (systemd timer).
#   nilana-netwatch          one silent check (what the timer runs)
#   nilana-netwatch --now    one check, with output
#   nilana-netwatch --diag   show every check + a diagnostic snapshot
# Repairs, in order: DNS -> network interface -> Xray -> (only if still dead for 15 min) reboot.
set -u
STATE_DIR=/var/lib/nilana-netwatch
RUN_DIR=/run/nilana-netwatch
LOG=/var/log/nilana-netwatch.log
SERVICE=nilana-vless
VERBOSE=0; MODE=check
case "${1:-}" in --now) VERBOSE=1 ;; --diag) VERBOSE=1; MODE=diag ;; esac
mkdir -p "$STATE_DIR" "$RUN_DIR"
exec 9>"$RUN_DIR/lock"; flock -n 9 || exit 0
PORT=443; [ -f /etc/nilana-vless/settings.env ] && . /etc/nilana-vless/settings.env
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

say() { [ "$VERBOSE" = 1 ] && printf '%s\n' "$*"; return 0; }
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; say "$*"; }

tcp_ok()      { timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null; }
check_ip()    { tcp_ok 1.1.1.1 443 || tcp_ok 8.8.8.8 443 || tcp_ok 9.9.9.9 443; }
check_dns()   { timeout 6 getent ahostsv4 www.google.com >/dev/null 2>&1 || timeout 6 getent ahostsv4 www.cloudflare.com >/dev/null 2>&1; }
check_https() { curl -4 -fsS -m 10 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null \
                || curl -4 -fsS -m 10 -o /dev/null https://cp.cloudflare.com/generate_204 2>/dev/null; }
check_svc()   { systemctl cat "$SERVICE" >/dev/null 2>&1 || return 0   # not installed: nothing to check
                systemctl is-active --quiet "$SERVICE" && ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; }

snapshot() {
  echo "--- snapshot ---"
  ip -br addr 2>&1; ip -4 route 2>&1
  resolvectl status 2>/dev/null | head -20
  free -m | head -2
  echo "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a)/$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo n/a)"
  echo "load: $(cut -d' ' -f1-3 /proc/loadavg)   uptime: $(cut -d. -f1 /proc/uptime)s"
  ss -s 2>/dev/null | head -3
  journalctl -u "$SERVICE" -n 8 --no-pager 2>/dev/null
  journalctl -k -n 200 --no-pager 2>/dev/null | grep -i -E 'oom|out of memory|conntrack|link (is )?down|tx timeout' | tail -5
  echo "--- end ---"
}

restart_net() {
  if systemctl is-active --quiet systemd-networkd; then
    local ifc
    ifc="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [ -n "$ifc" ] && command -v networkctl >/dev/null 2>&1; then
      networkctl reconfigure "$ifc" >/dev/null 2>&1 || systemctl restart systemd-networkd
    else
      systemctl restart systemd-networkd
    fi
  elif systemctl is-active --quiet NetworkManager; then
    systemctl restart NetworkManager
  fi
}
fix_dns()  { resolvectl flush-caches >/dev/null 2>&1; [ "$1" -ge 2 ] && systemctl restart systemd-resolved >/dev/null 2>&1; }
fix_svc()  { systemctl cat "$SERVICE" >/dev/null 2>&1 && systemctl restart "$SERVICE"; }

if [ "$MODE" = diag ]; then
  for c in ip dns https svc; do
    if "check_$c"; then printf '%-6s OK\n' "$c"; else printf '%-6s FAIL\n' "$c"; fi
  done
  snapshot; exit 0
fi

class=ok
if   ! check_ip;    then class=ip
elif ! check_dns;   then class=dns
elif ! check_https; then class=https
elif ! check_svc;   then class=svc
fi

n="$(cat "$RUN_DIR/fails" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
if [ "$class" = ok ]; then
  if [ "$n" -ge 2 ]; then
    log "RECOVERED after $n failed checks - restarting $SERVICE to clear stale connections"
    fix_svc
  fi
  echo 0 > "$RUN_DIR/fails"
  say "Network OK (internet, DNS, HTTPS and $SERVICE all fine)"
  exit 0
fi

n=$((n+1)); echo "$n" > "$RUN_DIR/fails"
log "FAIL #$n  problem=$class"
[ "$n" -eq 1 ] && snapshot >> "$LOG" 2>&1

case "$class" in
  dns)   fix_dns "$n"; [ "$n" -eq 4 ] && { log "action: restart network"; restart_net; } ;;
  ip)    case "$n" in
           2) log "action: re-apply network config"; restart_net ;;
           3) log "action: restart network + DNS"; restart_net; fix_dns 2 ;;
           5) log "action: restart $SERVICE"; fix_svc ;;
         esac ;;
  https) case "$n" in
           2) log "action: restart network"; restart_net ;;
           4) log "action: restart $SERVICE"; fix_svc ;;
         esac ;;
  svc)   log "action: restart $SERVICE"; fix_svc ;;
esac

if [ "$n" -ge 15 ]; then   # dead for 15 minutes: reboot, but never more than once per 6 hours
  now="$(date +%s)"; last="$(cat "$STATE_DIR/last-reboot" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  up="$(cut -d. -f1 /proc/uptime)"
  if [ $((now-last)) -gt 21600 ] && [ "$up" -gt 900 ]; then
    echo "$now" > "$STATE_DIR/last-reboot"
    log "action: REBOOT (no internet for $n minutes)"
    systemctl reboot
  fi
fi
exit 0
NETWATCH_EOF
  chmod 755 /usr/local/bin/nilana-netwatch
  cat > /etc/systemd/system/nilana-netwatch.service <<'EOF'
[Unit]
Description=Nilana network watchdog (check + self-repair)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nilana-netwatch
TimeoutStartSec=120
Nice=10
EOF
  cat > /etc/systemd/system/nilana-netwatch.timer <<'EOF'
[Unit]
Description=Nilana network watchdog - every minute

[Timer]
OnBootSec=3min
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now nilana-netwatch.timer >/dev/null 2>&1 \
    && ok "Watchdog active: checks every minute, log in /var/log/nilana-netwatch.log" \
    || warn "Could not enable nilana-netwatch.timer"
}

# ----------------------------------------------------------------- network --
public_ip() {
  local u ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}

check_port() {
  local who
  who="$(ss -H -ltnp "sport = :$PORT" 2>/dev/null)"
  [ -z "$who" ] && return 0
  if systemctl is-active --quiet nilana-vless; then return 0; fi   # our own service
  warn "Port $PORT is already in use:"; say "$who"
  if systemctl is-active --quiet nilana-stunnel 2>/dev/null; then
    say "That is the old Nilana SSL tunnel (Stunnel)."
    if ask_yes "Stop and disable nilana-stunnel so VLESS can use port $PORT?"; then
      systemctl disable --now nilana-stunnel >/dev/null 2>&1
      sleep 1
    fi
  fi
  [ -z "$(ss -H -ltnp "sport = :$PORT" 2>/dev/null)" ] || die "Port $PORT is still busy. Free it and run the script again."
}

open_firewall() {
  say "${C}==> Opening TCP $PORT in the firewall${N}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT"/tcp >/dev/null && ok "ufw: allowed $PORT/tcp"
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT
    if command -v ip6tables >/dev/null 2>&1; then
      ip6tables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1
    else
      if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -q "Status: active"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
      fi
    fi
    ok "iptables: allowed $PORT/tcp (saved for reboot)"
  fi
}

# ------------------------------------------------------- service account --
ensure_user() {
  id "$XUSER" >/dev/null 2>&1 && return 0
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$XUSER" \
    || die "Could not create the service user $XUSER"
  ok "Created service user $XUSER"
}

fix_perms() { # config and certificate must be readable by the service user, nobody else
  [ -f "$XRAY_ETC/config.json" ] && chown root:"$XUSER" "$XRAY_ETC/config.json"
  local f
  for f in cert.pem key.pem; do
    [ -f "$CONF_DIR/$f" ] && chown root:"$XUSER" "$CONF_DIR/$f"
  done
  return 0
}

# ---------------------------------------------------------------- settings --
gen_settings() {
  say "${C}==> Creating settings${N}"
  mkdir -p "$CONF_DIR" "$XRAY_ETC"
  chmod 755 "$CONF_DIR"
  local ip host priv pub sid kout
  ip="$(public_ip)" || ip=""
  host="${DOMAIN:-$ip}"
  if [ -z "$host" ]; then
    read -r -p "Could not detect the public IP. Enter the server IP or domain: " host
    [ -n "$host" ] || die "A host is required."
  fi

  PRIVKEY=""; PUBKEY=""; SHORTID=""; FLOW=""
  if [ "$MODE" = reality ]; then
    kout="$("$XRAY_BIN" x25519 2>&1)"
    priv="$(printf '%s\n' "$kout" | awk -F': *' 'tolower($1) ~ /^private/ {print $2; exit}' | tr -d '[:space:]')"
    pub="$( printf '%s\n' "$kout" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' | tr -d '[:space:]')"
    [ -n "$priv" ] && [ -n "$pub" ] || die "Could not generate REALITY keys: $kout"
    sid="$(openssl rand -hex 8)"
    PRIVKEY="$priv"; PUBKEY="$pub"; SHORTID="$sid"; FLOW="xtls-rprx-vision"
  else
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
      -subj "/CN=$host" -addext "subjectAltName=DNS:$host,IP:${ip:-127.0.0.1}" >/dev/null 2>&1 \
      || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
           -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" -subj "/CN=$host" >/dev/null 2>&1 \
      || die "Could not create the TLS certificate"
    chown root:"$XUSER" "$CONF_DIR/key.pem" "$CONF_DIR/cert.pem"
    chmod 640 "$CONF_DIR/key.pem"; chmod 644 "$CONF_DIR/cert.pem"
  fi

  cat > "$CONF_DIR/settings.env" <<EOF
VERSION="$NV_VERSION"
MODE="$MODE"
HOST="$host"
PORT="$PORT"
SNI="$SNI"
DEST="$SNI:443"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
FLOW="$FLOW"
WSPATH="$WSPATH"
BLOCK_TORRENT="$BLOCK_TORRENT"
EOF
  chmod 600 "$CONF_DIR/settings.env"
  touch "$CONF_DIR/users.db"; chmod 600 "$CONF_DIR/users.db"
  ok "Mode: $MODE   Host: $host   Port: $PORT"
}

# ----------------------------------------------------------------- service --
write_service() {
  cat > /etc/systemd/system/nilana-vless.service <<EOF
[Unit]
Description=Nilana VLESS (Xray-core)
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=$XUSER
Group=$XUSER
ExecStartPre=-+/usr/local/bin/nilana-vless render
ExecStart=$XRAY_BIN run -config $XRAY_ETC/config.json
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
Restart=always
RestartSec=3
OOMScoreAdjust=-500
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/nilana-vless-expire.service <<EOF
[Unit]
Description=Nilana VLESS - lock expired accounts

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nilana-vless expire
EOF
  cat > /etc/systemd/system/nilana-vless-expire.timer <<EOF
[Unit]
Description=Nilana VLESS - expiry check every 30 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

# ------------------------------------------------------------- menu script --
write_menu() {
  cat > /usr/local/bin/nilana-vless <<'MENU_EOF'
#!/usr/bin/env bash
# Nilana VLESS - management menu
set -u
CONF_DIR="${NILANA_VLESS_DIR:-/etc/nilana-vless}"
XRAY_BIN="${NILANA_XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CFG="${NILANA_XRAY_CFG:-/usr/local/etc/xray/config.json}"
SETTINGS="$CONF_DIR/settings.env"
USERS="$CONF_DIR/users.db"       # name|uuid|expiry(YYYY-MM-DD|never)|active|locked
SERVICE="nilana-vless"
LOCK="${NILANA_VLESS_LOCK:-/run/nilana-vless.lock}"
NOSVC="${NILANA_NO_SERVICE:-0}"
ASSET_DIR="${NILANA_ASSET_DIR:-/usr/local/share/xray}"
EXIT_FILE="$CONF_DIR/exit.json"            # outbound used for adult sites (see "Exit")
DOMAINS_FILE="$CONF_DIR/adult-domains.txt" # extra domains, one per line

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; N=$'\e[0m'
[ "$NOSVC" = 1 ] || [ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo -i)."; exit 1; }
[ -f "$SETTINGS" ] || { echo "Nilana VLESS is not installed."; exit 1; }
# shellcheck disable=SC1090
. "$SETTINGS"
touch "$USERS"

pause() { read -r -p "Press Enter to continue..." _ || exit 0; }
svc()   { [ "$NOSVC" = 1 ] || systemctl "$@"; }
today() { date +%F; }

# ---- config rendering ------------------------------------------------------
adult_domains_json() { # $1 = 1 to include geosite:category-porn -> JSON array of Xray domain rules
  local geo="$1" extra=""
  [ -f "$DOMAINS_FILE" ] && extra="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$DOMAINS_FILE" | grep -E '^[A-Za-z0-9.-]+$')"
  {
    [ "$geo" = 1 ] && echo "geosite:category-porn"
    [ -n "$extra" ] && printf '%s\n' "$extra" | sed 's/^/domain:/'
    true
  } | jq -R -s 'split("\n") | map(select(length>0))'
}

emit_config() { # outfile level exit_json(or null) domains_json clients_json stream_json
  local out="$1" level="$2" exitj="$3" doms="$4" clients="$5" stream="$6"
  jq -n --argjson clients "$clients" --argjson stream "$stream" \
        --argjson port "$PORT" --argjson bt "${BLOCK_TORRENT:-1}" \
        --argjson level "$level" --argjson exit "$exitj" --argjson doms "$doms" '
    ($exit != null and ($doms|length) > 0) as $route_exit |
    {
      log: {loglevel:"warning"},
      stats: {},
      api: {tag:"api", services:["StatsService"]},
      policy: {levels:{"0":{statsUserUplink:true, statsUserDownlink:true}}}
    }
    # own cached DoH resolver, IPv4 only; "localhost" (system DNS) stays as last resort
    + (if $level < 3 then {dns: ({
          servers:["https+local://1.1.1.1/dns-query","https+local://8.8.8.8/dns-query","localhost"],
          queryStrategy:"UseIPv4"
        } + (if $level < 2 then {serveStale:true, serveExpiredTTL:3600} else {} end))} else {} end)
    + {
      inbounds: ([{
        tag:"api-in", listen:"127.0.0.1", port:10085, protocol:"dokodemo-door",
        settings:{address:"127.0.0.1"}
      },{
        tag:"vless-in", listen:"0.0.0.0", port:$port, protocol:"vless",
        settings:{clients:$clients, decryption:"none"},
        streamSettings:$stream,
        sniffing:{enabled:true, destOverride:["http","tls"], routeOnly:true}
      }] + (if $exit != null then [{
        tag:"test-in", listen:"127.0.0.1", port:10086, protocol:"socks",
        settings:{auth:"noauth", udp:false}
      }] else [] end)),
      outbounds: ([
        ({protocol:"freedom", tag:"direct"}
          + (if $level < 3 then {streamSettings:{sockopt:{domainStrategy:"UseIPv4"}}} else {} end)),
        {protocol:"blackhole", tag:"block"}
      ] + (if $exit != null then [$exit + {tag:"exit"}] else [] end)),
      routing: {
        domainStrategy: (if $level < 3 then "IPIfNonMatch" else "IPOnDemand" end),
        rules: ([
          {type:"field", inboundTag:["api-in"], outboundTag:"api"}
        ]
        + (if $exit != null then [{type:"field", inboundTag:["test-in"], outboundTag:"exit"}] else [] end)
        + (if $route_exit then [{type:"field", domain:$doms, outboundTag:"exit"}] else [] end)
        + [{type:"field", outboundTag:"block",
            ip:["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"]}]
        + (if $bt==1 then [{type:"field", outboundTag:"block", protocol:["bittorrent"]}] else [] end))
      }
    }' > "$out"
}

render_config() {
  local clients stream tmp
  clients="$(awk -F'|' -v t="$(today)" \
      'NF>=4 && $4=="active" && ($3=="never" || $3>=t){print $1"|"$2}' "$USERS" \
    | jq -R -s --arg flow "$FLOW" '
        split("\n") | map(select(length>0) | split("|")
          | {id:.[1], email:.[0]} + (if $flow!="" then {flow:$flow} else {} end))')" || return 1

  if [ "$MODE" = reality ]; then
    stream="$(jq -n --arg dest "$DEST" --arg sni "$SNI" --arg pk "$PRIVKEY" --arg sid "$SHORTID" \
      '{network:"tcp",security:"reality",
        realitySettings:{show:false,dest:$dest,xver:0,serverNames:[$sni],privateKey:$pk,shortIds:[$sid]}}')"
  else
    stream="$(jq -n --arg path "$WSPATH" --arg d "$CONF_DIR" \
      '{network:"ws",security:"tls",
        tlsSettings:{alpn:["http/1.1"],certificates:[{certificateFile:($d+"/cert.pem"),keyFile:($d+"/key.pem")}]},
        wsSettings:{path:$path}}')"
  fi

  # Exit (optional): adult-site domains leave through another country
  local exitj="null" geo0=1 geo level doms done_ok=0
  if [ -s "$EXIT_FILE" ] && jq -e 'type=="object"' "$EXIT_FILE" >/dev/null 2>&1; then
    exitj="$(jq -c . "$EXIT_FILE")"
  fi
  { [ "${ADULT_GEOSITE:-1}" = 1 ] && [ -f "$ASSET_DIR/geosite.dat" ]; } || geo0=0

  tmp="$(mktemp --suffix=.json)"
  # level 0 = every feature. If this Xray build rejects something we step down, and
  # level 3 is the old v1.0 layout, so user management can never be broken by an upgrade.
  for level in 0 1 2 3; do
    geo=$geo0; [ "$level" -ge 1 ] && geo=0
    [ "$level" -eq 1 ] && [ "$geo0" -eq 0 ] && continue
    doms="$(adult_domains_json "$geo")" || doms="[]"
    emit_config "$tmp" "$level" "$exitj" "$doms" "$clients" "$stream" || { rm -f "$tmp"; return 1; }
    if [ ! -x "$XRAY_BIN" ]; then done_ok=1; break; fi
    if XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
      done_ok=1; break
    fi
  done
  if [ "$done_ok" -ne 1 ]; then
    echo "${R}Generated config failed validation - keeping the old one.${N}"
    XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$tmp" 2>&1 | tail -5
    rm -f "$tmp"; return 1
  fi
  [ "$level" -gt 0 ] && echo "${Y}Note: this Xray build needed a reduced config (level $level of 3). Run 'vless' -> Update Xray.${N}"
  mkdir -p "$(dirname "$XRAY_CFG")"
  if [ -f "$XRAY_CFG" ] && cmp -s "$tmp" "$XRAY_CFG"; then rm -f "$tmp"; return 2; fi
  install -m 640 "$tmp" "$XRAY_CFG"; rm -f "$tmp"
  chgrp "$(id -gn nilana-xray 2>/dev/null || echo nogroup)" "$XRAY_CFG" 2>/dev/null || true
  return 0
}

apply() { # render and restart only when something changed
  render_config; local rc=$?
  case $rc in
    0) svc restart "$SERVICE" ;;
    2) : ;;
    *) return 1 ;;
  esac
  return 0
}

# ---- helpers ---------------------------------------------------------------
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,20}$ ]]; }
user_exists() { awk -F'|' -v n="$1" '$1==n{f=1} END{exit !f}' "$USERS"; }
get_field()  { awk -F'|' -v n="$1" -v i="$2" '$1==n{print $i; exit}' "$USERS"; }
# every write to users.db goes through flock + atomic replace (menu and expiry timer can run together)
db_edit() { # awk-args...
  (
    flock -w 30 9 || exit 1
    tmp="$(mktemp "$CONF_DIR/.users.XXXXXX")" || exit 1
    awk -F'|' -v OFS='|' "$@" "$USERS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$USERS" || { rm -f "$tmp"; exit 1; }
  ) 9>"$LOCK"
}
set_field()  { # name idx value
  db_edit -v n="$1" -v i="$2" -v v="$3" '$1==n{$i=v} {print}'
}
db_append() { # line
  ( flock -w 30 9 || exit 1; echo "$1" >> "$USERS" ) 9>"$LOCK"
}

calc_expiry() { # days | YYYY-MM-DD | never  [base-date]
  local in="$1" base="${2:-$(today)}"
  if [[ "$in" =~ ^[0-9]+$ ]]; then date -d "$base + $in days" +%F 2>/dev/null
  elif [[ "$in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then date -d "$in" +%F 2>/dev/null
  elif [ "$in" = never ]; then echo never
  else return 1; fi
}

urlenc_path() { printf '%s' "$1" | sed 's,/,%2F,g'; }

make_link() { # name uuid
  local name="$1" id="$2"
  if [ "$MODE" = reality ]; then
    echo "vless://${id}@${HOST}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#Nilana-${name}"
  else
    echo "vless://${id}@${HOST}:${PORT}?encryption=none&security=tls&sni=${HOST}&fp=chrome&alpn=http%2F1.1&type=ws&host=${HOST}&path=$(urlenc_path "$WSPATH")&allowInsecure=1#Nilana-${name}"
  fi
}

show_card() { # name
  local n="$1" id ex st link
  id="$(get_field "$n" 2)"; ex="$(get_field "$n" 3)"; st="$(get_field "$n" 4)"
  link="$(make_link "$n" "$id")"
  echo
  echo "${C}================ VLESS ACCOUNT ================${N}"
  echo " Name      : $n"
  echo " Status    : $st    Expires: $ex"
  echo " Address   : $HOST"
  echo " Port      : $PORT"
  echo " UUID      : $id"
  if [ "$MODE" = reality ]; then
    echo " Security  : reality   Flow: $FLOW"
    echo " SNI       : $SNI"
    echo " PublicKey : $PUBKEY"
    echo " ShortID   : $SHORTID"
    echo " Fingerprint: chrome   Network: tcp"
  else
    echo " Security  : tls (self-signed -> allow insecure)"
    echo " Network   : ws    Path: $WSPATH    Host/SNI: $HOST"
  fi
  echo "${C}-----------------------------------------------${N}"
  echo "$link"
  echo "${C}===============================================${N}"
  if command -v qrencode >/dev/null 2>&1; then
    echo; qrencode -t ANSIUTF8 "$link"
  fi
}

pick_user() { # prompt -> sets PICK
  PICK=""
  [ -s "$USERS" ] || { echo "No users yet."; return 1; }
  read -r -p "$1: " PICK
  user_exists "$PICK" || { echo "${R}User not found.${N}"; return 1; }
}

# ---- actions ---------------------------------------------------------------
add_user() {
  local n d ex id
  read -r -p "Username (letters, digits, _ -): " n
  valid_name "$n" || { echo "${R}Invalid name.${N}"; return; }
  user_exists "$n" && { echo "${R}User already exists.${N}"; return; }
  read -r -p "Days valid (e.g. 30), a date (2027-01-31) or 'never': " d
  ex="$(calc_expiry "$d")" || { echo "${R}Invalid days/date.${N}"; return; }
  id="$(cat /proc/sys/kernel/random/uuid)"
  db_append "${n}|${id}|${ex}|active" || { echo "${R}Could not write users.db${N}"; return; }
  apply && show_card "$n"
}

renew_user() {
  pick_user "User to renew" || return
  local cur ex d base
  cur="$(get_field "$PICK" 3)"
  read -r -p "Add how many days (or a date / 'never')? " d
  base="$(today)"; [[ "$cur" != never && "$cur" > "$base" ]] && base="$cur"
  ex="$(calc_expiry "$d" "$base")" || { echo "${R}Invalid days/date.${N}"; return; }
  set_field "$PICK" 3 "$ex"
  [ "$(get_field "$PICK" 4)" = expired ] && set_field "$PICK" 4 active
  apply && echo "${G}$PICK now expires: $ex${N}"
}

delete_user() {
  pick_user "User to delete" || return
  read -r -p "Delete '$PICK'? [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]] || return
  db_edit -v n="$PICK" '$1!=n {print}'
  apply && echo "${G}Deleted $PICK${N}"
}

lock_user() {
  pick_user "User to lock/unlock" || return
  case "$(get_field "$PICK" 4)" in
    active) set_field "$PICK" 4 locked;  echo "${Y}$PICK locked${N}" ;;
    *)      set_field "$PICK" 4 active;  echo "${G}$PICK unlocked${N}" ;;
  esac
  apply
}

list_users() {
  echo
  printf '%-4s %-20s %-12s %-8s\n' "#" "USER" "EXPIRES" "STATUS"
  local i=0 n id ex st shown t; t="$(today)"
  while IFS='|' read -r n id ex st; do
    [ -n "$n" ] || continue
    i=$((i+1)); shown="$st"
    [ "$st" = active ] && [ "$ex" != never ] && [[ "$ex" < "$t" ]] && shown="EXPIRED"
    printf '%-4s %-20s %-12s %-8s\n' "$i" "$n" "$ex" "$shown"
  done < "$USERS"
  [ "$i" -eq 0 ] && echo "(no users)"
}

show_user() { pick_user "User to show" && show_card "$PICK"; }

expire_job() { # non-interactive, used by the systemd timer
  local t n id ex st snap; t="$(today)"
  snap="$(mktemp)"; cp "$USERS" "$snap"
  while IFS='|' read -r n id ex st; do
    [ "$st" = active ] && [ "$ex" != never ] && [[ "$ex" < "$t" ]] && set_field "$n" 4 expired
  done < "$snap"
  rm -f "$snap"
  apply
}

status() {
  echo
  svc --no-pager status "$SERVICE" 2>&1 | head -12
  echo
  echo "Listening on :$PORT ->"; ss -ltn "sport = :$PORT" 2>/dev/null | tail -n +2
}

change_host() {
  read -r -p "New server IP or domain: " h
  [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "${R}Invalid host.${N}"; return; }
  sed -i "s|^HOST=.*|HOST=\"$h\"|" "$SETTINGS"; HOST="$h"
  echo "${G}Host set to $h. Re-send the links to your users.${N}"
}

change_sni() {
  [ "$MODE" = reality ] || { echo "Only for reality mode."; return; }
  read -r -p "New REALITY camouflage site (TLS1.3 + h2, e.g. www.microsoft.com): " s
  [[ "$s" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "${R}Invalid name.${N}"; return; }
  sed -i "s|^SNI=.*|SNI=\"$s\"|; s|^DEST=.*|DEST=\"$s:443\"|" "$SETTINGS"
  SNI="$s"; DEST="$s:443"
  apply && echo "${G}SNI set to $s. Users must re-import their links.${N}"
}

update_xray() {
  local arch tmp want got base
  case "$(uname -m)" in x86_64|amd64) arch=64 ;; aarch64|arm64) arch=arm64-v8a ;; *) echo "Unsupported CPU"; return ;; esac
  base="https://github.com/XTLS/Xray-core/releases/latest/download"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/x.zip"  "$base/Xray-linux-$arch.zip"      || { echo "${R}Download failed${N}"; return; }
  curl -fsSL -o "$tmp/x.dgst" "$base/Xray-linux-$arch.zip.dgst" || { echo "${R}Checksum download failed${N}"; return; }
  want="$(awk -F'= *' '/^SHA2-256/{print $2; exit}' "$tmp/x.dgst" | tr -d '[:space:]')"
  got="$(sha256sum "$tmp/x.zip" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || { echo "${R}Checksum mismatch${N}"; rm -rf "$tmp"; return; }
  unzip -oq "$tmp/x.zip" -d "$tmp" && install -m 755 "$tmp/xray" "$XRAY_BIN"
  mkdir -p "$ASSET_DIR"
  for f in geoip.dat geosite.dat; do [ -f "$tmp/$f" ] && install -m 644 "$tmp/$f" "$ASSET_DIR/$f"; done
  rm -rf "$tmp"
  render_config >/dev/null 2>&1
  svc restart "$SERVICE"
  echo "${G}$("$XRAY_BIN" version | head -1)${N}"
}

# ---- exit: adult sites leave through another country ------------------------
urldecode() { local s="$1"; printf '%b' "${s//%/\\x}"; }
qparam()    { printf '%s' "$1" | tr '&' '\n' | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,""); print; exit}'; }

exit_outbound_from_link() { # vless://... or socks5://... -> outbound JSON on stdout, rc 1 if unusable
  local link="$1" body id rest hp q host port sec typ flow sni fp pbk sid path hh insec auth user pass
  case "$link" in
    vless://*)
      body="${link#vless://}"; body="${body%%#*}"
      id="${body%%@*}"; rest="${body#*@}"
      hp="${rest%%\?*}"; q=""; [[ "$rest" == *\?* ]] && q="${rest#*\?}"
      port="${hp##*:}"; host="${hp%:*}"; host="${host#[}"; host="${host%]}"
      [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]]   || { echo "Bad UUID in link" >&2; return 1; }
      [[ "$port" =~ ^[0-9]{1,5}$ ]]       || { echo "Bad port in link" >&2; return 1; }
      [[ "$host" =~ ^[A-Za-z0-9.:-]+$ ]]  || { echo "Bad host in link" >&2; return 1; }
      sec="$(qparam "$q" security)"; typ="$(qparam "$q" type)"; flow="$(qparam "$q" flow)"
      sni="$(urldecode "$(qparam "$q" sni)")"; fp="$(qparam "$q" fp)"
      pbk="$(qparam "$q" pbk)"; sid="$(qparam "$q" sid)"
      path="$(urldecode "$(qparam "$q" path)")"; hh="$(urldecode "$(qparam "$q" host)")"
      insec="$(qparam "$q" allowInsecure)"
      [ -n "$fp" ] || fp=chrome
      [ -n "$typ" ] || typ=tcp
      case "$typ" in tcp|ws) ;; *) echo "Only type=tcp or type=ws links are supported" >&2; return 1 ;; esac
      case "$sec" in
        reality) [ -n "$pbk" ] && [ -n "$sni" ] || { echo "REALITY link needs pbk= and sni=" >&2; return 1; } ;;
        tls|none|"") ;;
        *) echo "Unsupported security=$sec" >&2; return 1 ;;
      esac
      [ -n "$sec" ] || sec=none
      [ -n "$sni" ] || sni="$host"
      jq -n --arg host "$host" --argjson port "$port" --arg id "$id" --arg flow "$flow" \
            --arg sec "$sec" --arg typ "$typ" --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" \
            --arg sid "$sid" --arg path "$path" --arg hh "$hh" --arg insec "$insec" '
        {protocol:"vless",
         settings:{vnext:[{address:$host, port:$port,
                           users:[{id:$id, encryption:"none"} + (if $flow!="" then {flow:$flow} else {} end)]}]},
         streamSettings: ({network:$typ}
           + (if $sec=="reality" then {security:"reality",
                 realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:"/"}}
              elif $sec=="tls" then {security:"tls",
                 tlsSettings:({serverName:$sni, fingerprint:$fp}
                              + (if $insec=="1" or $insec=="true" then {allowInsecure:true} else {} end))}
              else {security:"none"} end)
           + (if $typ=="ws" then {wsSettings:({path:(if $path=="" then "/" else $path end)}
                                              + (if $hh!="" then {headers:{Host:$hh}} else {} end))} else {} end))}'
      ;;
    socks5://*|socks://*)
      body="${link#*://}"; body="${body%%#*}"; auth=""
      [[ "$body" == *@* ]] && { auth="${body%@*}"; body="${body##*@}"; }
      body="${body%%/*}"; port="${body##*:}"; host="${body%:*}"
      user="$auth"; pass=""; [[ "$auth" == *:* ]] && { user="${auth%%:*}"; pass="${auth#*:}"; }
      user="$(urldecode "$user")"; pass="$(urldecode "$pass")"
      [[ "$port" =~ ^[0-9]{1,5}$ ]]      || { echo "Bad port" >&2; return 1; }
      [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]]  || { echo "Bad host" >&2; return 1; }
      jq -n --arg host "$host" --argjson port "$port" --arg user "$user" --arg pass "$pass" '
        {protocol:"socks",
         settings:{servers:[{address:$host, port:$port}
                            + (if $user!="" then {users:[{user:$user, pass:$pass}]} else {} end)]}}'
      ;;
    *) echo "Link must start with vless:// or socks5://" >&2; return 1 ;;
  esac
}

exit_country() { # [socks-proxy] -> two-letter country of the outgoing IP
  local px=() u c
  [ -n "${1:-}" ] && px=(-x "$1")
  for u in https://ipinfo.io/country https://ifconfig.co/country-iso https://api.country.is; do
    c="$(curl -4 -fsS -m 15 "${px[@]}" "$u" 2>/dev/null | tr -d '[:space:]"{}' | sed 's/^country://; s/,ip:.*//')"
    [[ "$c" =~ ^[A-Za-z]{2}$ ]] && { echo "${c^^}"; return 0; }
  done
  echo "?"; return 1
}

exit_test() {
  [ -s "$EXIT_FILE" ] || { echo "No exit configured."; return 1; }
  local d x
  d="$(exit_country)"; x="$(exit_country socks5h://127.0.0.1:10086)"
  echo "This VPS leaves the internet from : $d"
  echo "Adult sites leave the internet from: $x"
  if [ "$x" = "?" ]; then echo "${R}The exit did not answer. Check the link, that the other server is running, and its firewall.${N}"; return 1
  elif [ "$x" = "$d" ]; then echo "${Y}The exit is in the same country as this VPS, so it will not change what those sites see.${N}"
  else echo "${G}OK - adult sites will now see an IP from $x.${N}"; fi
}

exit_status() {
  if [ -s "$EXIT_FILE" ]; then
    echo "Exit: ON   -> $(jq -r '.protocol + "  " + ((.settings.vnext[0].address // .settings.servers[0].address) // "?")' "$EXIT_FILE")"
    echo "Domains routed: geosite:category-porn$( [ -f "$ASSET_DIR/geosite.dat" ] || echo ' (geosite.dat missing - run Update Xray)') + $DOMAINS_FILE"
  else
    echo "Exit: OFF (adult sites leave from this VPS directly)"
  fi
}

exit_set() { # link
  local ob
  ob="$(exit_outbound_from_link "$1")" || { echo "${R}Could not use that link.${N}"; return 1; }
  ( umask 077; printf '%s\n' "$ob" > "$EXIT_FILE" )
  if [ ! -f "$DOMAINS_FILE" ]; then
    cat > "$DOMAINS_FILE" <<'DOM_EOF'
# Extra domains that must leave through the Exit server (one per line, no http://).
# "example.com" also covers every sub-domain. The big built-in list (geosite:category-porn)
# is always used too; add video/CDN hosts here if a site loads but its videos do not.
DOM_EOF
  fi
  apply || { echo "${R}Config was not applied - exit removed again.${N}"; rm -f "$EXIT_FILE"; return 1; }
  echo "${G}Exit saved and applied.${N}"
  sleep 2; exit_test
}

exit_off() { rm -f "$EXIT_FILE"; apply && echo "${G}Exit removed.${N}"; }

exit_menu() {
  echo
  echo "${C}Adult-sites exit${N} - sends adult-site domains out through a server in another country,"
  echo "everything else keeps using this VPS (fast, direct)."
  echo; exit_status; echo
  echo " 1) Set exit from a link  (vless://... from a 2nd server running this installer, or socks5://user:pass@host:port)"
  echo " 2) Test exit"
  echo " 3) Edit extra domain list"
  echo " 4) Turn exit off"
  echo " 0) Back"
  read -r -p "Select: " c || return
  case "$c" in
    1) read -r -p "Paste link: " l; exit_set "$l" ;;
    2) exit_test ;;
    3) [ -f "$DOMAINS_FILE" ] || echo "# one domain per line" > "$DOMAINS_FILE"
       "${EDITOR:-nano}" "$DOMAINS_FILE" 2>/dev/null || vi "$DOMAINS_FILE"; apply ;;
    4) exit_off ;;
  esac
}

exit_cli() {
  case "${1:-status}" in
    set)    [ -n "${2:-}" ] || { echo "Usage: nilana-vless exit set <vless://...|socks5://...>"; return 1; }; exit_set "$2" ;;
    off)    exit_off ;;
    test)   exit_test ;;
    status) exit_status ;;
    *) echo "Usage: nilana-vless exit [set LINK|off|test|status]"; return 1 ;;
  esac
}

uninstall() {
  read -r -p "Type UNINSTALL to remove Nilana VLESS: " a
  [ "$a" = UNINSTALL ] || { echo "Cancelled."; return; }
  systemctl disable --now nilana-vless nilana-vless-expire.timer nilana-netwatch.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/nilana-vless.service /etc/systemd/system/nilana-vless-expire.service \
        /etc/systemd/system/nilana-vless-expire.timer /etc/systemd/system/nilana-netwatch.service \
        /etc/systemd/system/nilana-netwatch.timer /usr/local/bin/nilana-netwatch
  systemctl daemon-reload
  iptables  -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  ip6tables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
  command -v ufw >/dev/null 2>&1 && ufw delete allow "$PORT"/tcp >/dev/null 2>&1
  rm -rf "$CONF_DIR" /usr/local/etc/xray "$ASSET_DIR" "$XRAY_BIN" /usr/local/bin/nilana-vless /usr/local/bin/vless
  rm -f /etc/sysctl.d/99-nilana-net.conf /etc/modules-load.d/nilana-bbr.conf /etc/systemd/resolved.conf.d/nilana.conf
  userdel nilana-xray >/dev/null 2>&1
  echo "${G}Removed. Port 22 (SSH) was never touched.${N}"
  exit 0
}

menu() {
  while true; do
    clear 2>/dev/null
    echo "${C}=========== NILANA VLESS  (${MODE}, port ${PORT}) ===========${N}"
    echo " Host: $HOST"
    echo
    echo " 1) Add User              6) Show Link / QR"
    echo " 2) Renew User            7) Service Status"
    echo " 3) Delete User           8) Restart Service"
    echo " 4) Lock / Unlock User    9) Change Server Host (IP/domain)"
    echo " 5) Users List           10) Change REALITY SNI"
    echo "11) Update Xray          12) Uninstall"
    echo "13) Network check / repair now"
    echo "14) Adult-sites exit (other country)"
    echo " 0) Quit"
    echo
    read -r -p "Select: " c || exit 0
    case "$c" in
      1) add_user ;;     2) renew_user ;;  3) delete_user ;;  4) lock_user ;;
      5) list_users ;;   6) show_user ;;   7) status ;;        8) svc restart "$SERVICE"; echo "Restarted." ;;
      9) change_host ;; 10) change_sni ;; 11) update_xray ;;  12) uninstall ;;
      13) /usr/local/bin/nilana-netwatch --diag ;;
      14) exit_menu ;;
      0|q) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
    pause
  done
}

case "${1:-menu}" in
  menu)    menu ;;
  expire)  expire_job ;;
  render)  render_config; rc=$?; [ "$rc" -le 2 ] && [ "$rc" -ne 1 ] && exit 0; exit 1 ;;
  add)     add_user ;;
  list)    list_users ;;
  update)  update_xray ;;
  uninstall) uninstall ;;
  exit)    shift; exit_cli "$@" ;;
  netcheck) exec /usr/local/bin/nilana-netwatch --diag ;;
  *) echo "Usage: nilana-vless [menu|add|list|expire|update|exit|netcheck|uninstall]"; exit 1 ;;
esac
MENU_EOF
  chmod 755 /usr/local/bin/nilana-vless
  ln -sf /usr/local/bin/nilana-vless /usr/local/bin/vless
}

# -------------------------------------------------------------------- main --
say "${C}Nilana VLESS installer v$NV_VERSION${N}"

if [ "$UPDATE_ONLY" -eq 1 ]; then
  [ -f "$CONF_DIR/settings.env" ] || die "No existing install found."
  install_packages
  install_xray
  ensure_user
  fix_perms
  write_menu
  write_service
  systemctl daemon-reload
  sed -i "s|^VERSION=.*|VERSION=\"$NV_VERSION\"|" "$CONF_DIR/settings.env"
  tune_network
  install_watchdog
  rout="$(/usr/local/bin/nilana-vless render 2>&1)"; rrc=$?   # new menu version -> refresh the Xray config
  [ "$rrc" -le 2 ] && [ "$rrc" -ne 1 ] || { warn "Config generation failed:"; say "$rout"; }
  case "$rout" in *Note:*) say "$rout" ;; esac
  fix_perms
  systemctl restart nilana-vless
  sleep 2
  systemctl is-active --quiet nilana-vless || { journalctl -u nilana-vless -n 20 --no-pager; die "nilana-vless did not start after the update."; }
  ok "Updated. Users and settings were kept."
  say "  Network watchdog: nilana-netwatch --now      Exit for adult sites: vless -> option 14"
  exit 0
fi

if [ -f "$CONF_DIR/settings.env" ]; then
  warn "An installation already exists. Use --update to update it, or run 'vless' to manage it."
  exit 1
fi

check_port
install_packages
install_xray
ensure_user
gen_settings
write_menu
write_service
open_firewall
tune_network

# first render with no users so the service can start
/usr/local/bin/nilana-vless render >/dev/null 2>&1 || die "Could not generate the Xray config."
systemctl enable --now nilana-vless >/dev/null 2>&1
systemctl enable --now nilana-vless-expire.timer >/dev/null 2>&1
install_watchdog
systemctl is-enabled --quiet nilana-vless || { systemctl enable nilana-vless >/dev/null 2>&1; }
systemctl is-enabled --quiet nilana-vless || warn "nilana-vless is NOT enabled at boot - run: systemctl enable nilana-vless"
if command -v iptables >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
  if ! grep -qs -- "--dport $PORT" /etc/iptables/rules.v4 2>/dev/null; then
    warn "Port $PORT rule is not saved in /etc/iptables/rules.v4 - it may be lost after a reboot."
    warn "Fix: apt install iptables-persistent && netfilter-persistent save"
  fi
fi
sleep 2
if systemctl is-active --quiet nilana-vless; then
  ok "nilana-vless is running on TCP $PORT"
else
  journalctl -u nilana-vless -n 20 --no-pager
  die "Service did not start - see the log above."
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  say
  say "Let's create the first user."
  /usr/local/bin/nilana-vless add
fi

. "$CONF_DIR/settings.env"
say
say "${G}Done.${N}  Type ${C}vless${N} (or ${C}nilana-vless${N}) for the menu."
say
say "${Y}Cloud firewall:${N} also allow TCP ${PORT} in your provider's panel."
say "  Oracle Cloud: VCN -> Security Lists -> Add Ingress Rule -> 0.0.0.0/0, TCP, port ${PORT}."
if [ "$MODE" = ws ]; then
  say "${Y}WS mode:${N} the certificate is self-signed. Clients need 'allow insecure' (already in the link),"
  say "  or put a Cloudflare-proxied domain in front (SSL mode: Full)."
fi
