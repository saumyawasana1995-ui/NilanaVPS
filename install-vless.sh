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
#  Usage (as root):  bash install-vless.sh [options]
#    --mode reality|ws     transport (default: reality)
#    --sni  host           REALITY camouflage site (default: www.microsoft.com)
#    --domain host         host/domain used in client links (default: server IP)
#    --wspath /path        WebSocket path for ws mode (default: /nilana)
#    --no-block-torrent    do not block BitTorrent traffic
#    -y                    no questions
#    --update              update Xray only, keep users and settings
#  Ubuntu 20.04 / 22.04 / 24.04 / Debian 11+  (x86_64 and ARM64)
# =============================================================================
set -u

VERSION="1.0.0"
CONF_DIR="/etc/nilana-vless"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
LOG="/var/log/nilana-vless-install.log"

MODE="reality"
SNI="www.microsoft.com"
DOMAIN=""
WSPATH="/nilana"
BLOCK_TORRENT=1
ASSUME_YES=0
UPDATE_ONLY=0
PORT=443

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
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
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

. /etc/os-release 2>/dev/null || true
case "${ID:-}" in ubuntu|debian) ;; *) warn "Untested OS (${PRETTY_NAME:-unknown}); continuing." ;; esac
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
  unzip -oq "$tmp/x.zip" xray -d "$tmp" || die "Could not unzip Xray"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  ok "$("$XRAY_BIN" version | head -1)"
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
    chown root:nogroup "$CONF_DIR/key.pem" "$CONF_DIR/cert.pem"
    chmod 640 "$CONF_DIR/key.pem"; chmod 644 "$CONF_DIR/cert.pem"
  fi

  cat > "$CONF_DIR/settings.env" <<EOF
VERSION="$VERSION"
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
User=nobody
Group=nogroup
ExecStartPre=-+/usr/local/bin/nilana-vless render
ExecStart=$XRAY_BIN run -config $XRAY_ETC/config.json
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=3
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

  tmp="$(mktemp --suffix=.json)"
  jq -n --argjson clients "$clients" --argjson stream "$stream" \
        --argjson port "$PORT" --argjson bt "${BLOCK_TORRENT:-1}" '
    {
      log: {loglevel:"warning"},
      inbounds: [{
        tag:"vless-in", listen:"0.0.0.0", port:$port, protocol:"vless",
        settings:{clients:$clients, decryption:"none"},
        streamSettings:$stream,
        sniffing:{enabled:true, destOverride:["http","tls"], routeOnly:true}
      }],
      outbounds: [{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}],
      routing: {
        domainStrategy:"IPOnDemand",
        rules: ([
          {type:"field", outboundTag:"block",
           ip:["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"]}
        ] + (if $bt==1 then [{type:"field", outboundTag:"block", protocol:["bittorrent"]}] else [] end))
      }
    }' > "$tmp" || { rm -f "$tmp"; return 1; }

  if [ -x "$XRAY_BIN" ] && ! "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
    echo "${R}Generated config failed validation - keeping the old one.${N}"
    "$XRAY_BIN" run -test -config "$tmp" 2>&1 | tail -5
    rm -f "$tmp"; return 1
  fi
  mkdir -p "$(dirname "$XRAY_CFG")"
  if [ -f "$XRAY_CFG" ] && cmp -s "$tmp" "$XRAY_CFG"; then rm -f "$tmp"; return 2; fi
  install -m 640 "$tmp" "$XRAY_CFG"; rm -f "$tmp"
  chown root:nogroup "$XRAY_CFG" 2>/dev/null || true
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
  unzip -oq "$tmp/x.zip" xray -d "$tmp" && install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  svc restart "$SERVICE"
  echo "${G}$("$XRAY_BIN" version | head -1)${N}"
}

uninstall() {
  read -r -p "Type UNINSTALL to remove Nilana VLESS: " a
  [ "$a" = UNINSTALL ] || { echo "Cancelled."; return; }
  systemctl disable --now nilana-vless nilana-vless-expire.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/nilana-vless.service /etc/systemd/system/nilana-vless-expire.service \
        /etc/systemd/system/nilana-vless-expire.timer
  systemctl daemon-reload
  iptables  -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  ip6tables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
  command -v ufw >/dev/null 2>&1 && ufw delete allow "$PORT"/tcp >/dev/null 2>&1
  rm -rf "$CONF_DIR" /usr/local/etc/xray "$XRAY_BIN" /usr/local/bin/nilana-vless /usr/local/bin/vless
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
    echo " 0) Quit"
    echo
    read -r -p "Select: " c || exit 0
    case "$c" in
      1) add_user ;;     2) renew_user ;;  3) delete_user ;;  4) lock_user ;;
      5) list_users ;;   6) show_user ;;   7) status ;;        8) svc restart "$SERVICE"; echo "Restarted." ;;
      9) change_host ;; 10) change_sni ;; 11) update_xray ;;  12) uninstall ;;
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
  *) echo "Usage: nilana-vless [menu|add|list|expire|update|uninstall]"; exit 1 ;;
esac
MENU_EOF
  chmod 755 /usr/local/bin/nilana-vless
  ln -sf /usr/local/bin/nilana-vless /usr/local/bin/vless
}

# -------------------------------------------------------------------- main --
say "${C}Nilana VLESS installer v$VERSION${N}"

if [ "$UPDATE_ONLY" -eq 1 ]; then
  [ -f "$CONF_DIR/settings.env" ] || die "No existing install found."
  install_packages
  install_xray
  write_menu
  write_service
  systemctl daemon-reload
  systemctl restart nilana-vless
  ok "Updated. Users and settings were kept."
  exit 0
fi

if [ -f "$CONF_DIR/settings.env" ]; then
  warn "An installation already exists. Use --update to update it, or run 'vless' to manage it."
  exit 1
fi

check_port
install_packages
install_xray
gen_settings
write_menu
write_service
open_firewall

# first render with no users so the service can start
/usr/local/bin/nilana-vless render >/dev/null 2>&1 || die "Could not generate the Xray config."
systemctl enable --now nilana-vless >/dev/null 2>&1
systemctl enable --now nilana-vless-expire.timer >/dev/null 2>&1
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
