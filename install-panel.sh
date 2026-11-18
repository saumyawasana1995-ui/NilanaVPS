#!/usr/bin/env bash
# =============================================================================
#  NILANA PANEL installer - web panel for Nilana VLESS servers
#
#  Dashboard (CPU / RAM / disk / network), user management (add, renew, lock,
#  delete, VLESS link + QR), per-user traffic, service log and restart.
#
#  Usage (as root, after install-vless.sh):
#    bash install-panel.sh                  # private: panel listens on 127.0.0.1 only
#    bash install-panel.sh --public         # HTTPS (self-signed) on a random high port
#    bash install-panel.sh --public --port 8443
#    bash install-panel.sh --domain nilana.ddns.net [--email you@mail.com]
#        public HTTPS with a free Let's Encrypt certificate (auto-renewed)
#  Other options:  --password 'secret'   --uninstall
# =============================================================================
set -u
PANEL_DIR="/etc/nilana-panel"
DATA_DIR="/var/lib/nilana-panel"
BIN="/usr/local/bin/nilana-panel.py"
PUBLIC=0; PORT=0; PASSWORD=""; UNINSTALL=0; DOMAIN=""; EMAIL=""

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; N=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --public)    PUBLIC=1 ;;
    --port)      PORT="${2:-}"; shift ;;
    --password)  PASSWORD="${2:-}"; shift ;;
    --domain)    DOMAIN="${2:-}"; PUBLIC=1; shift ;;
    --email)     EMAIL="${2:-}"; shift ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[ "$(id -u)" -eq 0 ] || die "Run as root."
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[ "$PORT" -eq 0 ] || { [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ]; } || die "--port must be 1024-65535"
[ -z "$DOMAIN" ] || [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || die "--domain is not a valid host name"
[ -z "$EMAIL" ] || [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die "--email is not valid"
[ -z "$DOMAIN" ] || [ "$PORT" -ne 0 ] || PORT=8443
[ "$PORT" -ne 443 ] || die "Port 443 is used by VLESS. Pick another port."
[ -z "$PASSWORD" ] || [ "${#PASSWORD}" -ge 8 ] || die "--password needs at least 8 characters"

close_port() {
  local p="$1"
  iptables  -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
  ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
  command -v ufw >/dev/null 2>&1 && ufw delete allow "$p"/tcp >/dev/null 2>&1
  return 0
}

open_port() {
  local p="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p"/tcp >/dev/null
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT
    command -v ip6tables >/dev/null 2>&1 && { ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null; }
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1
    elif ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -q "Status: active"; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1
      command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    fi
  fi
}

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -f "$PANEL_DIR/panel.json" ]; then
    op="$(python3 -c "import json;print(json.load(open('$PANEL_DIR/panel.json'))['port'])" 2>/dev/null)"
    [ -n "$op" ] && close_port "$op"
  fi
  systemctl disable --now nilana-panel >/dev/null 2>&1
  rm -f /etc/systemd/system/nilana-panel.service "$BIN" /usr/local/bin/nilana-panel
  rm -rf "$PANEL_DIR" "$DATA_DIR"
  systemctl daemon-reload
  ok "Nilana Panel removed. VLESS was not touched."
  exit 0
fi

# ---- requirements -----------------------------------------------------------
[ -f /etc/nilana-vless/settings.env ] && [ -x /usr/local/bin/nilana-vless ] \
  || die "Nilana VLESS is not installed. Run install-vless.sh first."

if ! grep -q 'api-in' /usr/local/bin/nilana-vless 2>/dev/null; then
  # the panel needs the traffic-stats API that newer install-vless.sh adds to the Xray config
  here="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$here/install-vless.sh" ]; then
    say "${C}==> Updating Nilana VLESS (adds the traffic statistics API)${N}"
    bash "$here/install-vless.sh" --update || die "install-vless.sh --update failed"
  else
    die "Your installed VLESS menu is too old. Put the latest install-vless.sh next to this file, or run: bash install-vless.sh --update"
  fi
fi

say "${C}==> Installing packages${N}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3 openssl qrencode curl >/dev/null || die "apt install failed"
PY="$(command -v python3)"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' || die "Python 3.8+ is required"

# ---- Let's Encrypt certificate (only with --domain) ---------------------------
LE_CERT=""; LE_KEY=""
if [ -n "$DOMAIN" ]; then
  say "${C}==> Let's Encrypt certificate for $DOMAIN${N}"
  apt-get install -y -qq certbot >/dev/null || die "Could not install certbot"
  MYIP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null)"
  DIP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  [ -n "$DIP" ] || die "$DOMAIN does not resolve yet. Point its A record to this server ($MYIP) and run again."
  if [ -n "$MYIP" ] && [ "$DIP" != "$MYIP" ]; then
    die "$DOMAIN points to $DIP but this server is $MYIP. Fix the A record (wait a few minutes) and run again."
  fi
  if [ -n "$(ss -H -ltn 'sport = :80' 2>/dev/null)" ]; then
    die "Port 80 is in use. Let's Encrypt needs it free for the HTTP challenge (and for renewals every ~60 days)."
  fi
  open_port 80
  warn "Make sure TCP 80 is also allowed in your cloud firewall (Oracle: VCN > Security Lists > Ingress, 0.0.0.0/0, TCP 80)."
  mailarg=(--register-unsafely-without-email); [ -n "$EMAIL" ] && mailarg=(--email "$EMAIL")
  certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --non-interactive --agree-tos "${mailarg[@]}" \
      --deploy-hook "systemctl restart nilana-panel" \
    || die "Certificate request failed (see the certbot message above). Check the DNS record and TCP 80, then run again."
  LE_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"; LE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ] || die "Certificate files not found after certbot."
  systemctl enable --now certbot.timer >/dev/null 2>&1 || warn "certbot.timer not found - renew manually with: certbot renew"
  ok "Certificate issued; automatic renewal is on (test: certbot renew --dry-run)"
fi

# ---- install files ------------------------------------------------------------
mkdir -p "$PANEL_DIR" "$DATA_DIR"
chmod 700 "$PANEL_DIR" "$DATA_DIR"
cat > "$BIN" <<'PANEL_PY_EOF'
#!/usr/bin/env python3
"""Nilana Panel - web panel for Nilana VLESS (Xray-core) servers.

Python 3 standard library only. Works on top of install-vless.sh:
it edits the same users.db (with the same lock), asks `nilana-vless render`
to rebuild the Xray config and restarts Xray only when the config changed.

Commands:  serve | init | passwd | info
"""
import base64
import collections
import datetime
import fcntl
import getpass
import hashlib
import hmac
import http.server
import json
import os
import platform
import random
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

VERSION = "1.0.0"
PANEL_DIR = os.environ.get("NILANA_PANEL_DIR", "/etc/nilana-panel")
DATA_DIR = os.environ.get("NILANA_PANEL_DATA", "/var/lib/nilana-panel")
VLESS_DIR = os.environ.get("NILANA_VLESS_DIR", "/etc/nilana-vless")
XRAY_BIN = os.environ.get("NILANA_XRAY_BIN", "/usr/local/bin/xray")
XRAY_CFG = os.environ.get("NILANA_XRAY_CFG", "/usr/local/etc/xray/config.json")
VLESS_CLI = os.environ.get("NILANA_VLESS_CLI", "/usr/local/bin/nilana-vless")
LOCK_PATH = os.environ.get("NILANA_VLESS_LOCK", "/run/nilana-vless.lock")
NO_SERVICE = os.environ.get("NILANA_NO_SERVICE") == "1"
SERVICE = "nilana-vless"
API_ADDR = "127.0.0.1:10085"
SESSION_TTL = 12 * 3600
ACTIVE_WINDOW = 90          # seconds without traffic before a user stops showing as "active now"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,20}$")

USERS_DB = os.path.join(VLESS_DIR, "users.db")
SETTINGS_ENV = os.path.join(VLESS_DIR, "settings.env")
CONF_PATH = os.path.join(PANEL_DIR, "panel.json")
TRAFFIC_PATH = os.path.join(DATA_DIR, "traffic.json")


class ApiError(Exception):
    def __init__(self, msg, code=400):
        super().__init__(msg)
        self.msg, self.code = msg, code


# ------------------------------------------------------------------ helpers --
def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def atomic_write(path, text, mode=0o600):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp-%s" % secrets.token_hex(4))
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def run(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        class R:  # minimal stand-in
            returncode, stdout, stderr = 127, "", str(e)
        return R()


class FileLock:
    """flock(2) on the same file the bash menu uses, so both sides serialize."""
    def __enter__(self):
        self.f = open(LOCK_PATH, "a+")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


MUTEX = threading.Lock()


# ------------------------------------------------------------ panel config --
def hash_pw(pw, salt=None, iters=300000):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), iters).hex()
    return {"salt": salt, "hash": h, "iters": iters}


def check_pw(pw, rec):
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(rec["salt"]), rec["iters"]).hex()
    return hmac.compare_digest(h, rec["hash"])


def load_conf():
    with open(CONF_PATH) as f:
        return json.load(f)


def save_conf(c):
    atomic_write(CONF_PATH, json.dumps(c, indent=2))


CONF = {}


def make_token():
    payload = b64(json.dumps({"exp": int(time.time()) + SESSION_TTL, "k": CONF["pw"]["hash"][:12]}).encode())
    sig = b64(hmac.new(bytes.fromhex(CONF["secret"]), payload.encode(), "sha256").digest())
    return payload + "." + sig


def token_ok(tok):
    try:
        payload, sig = tok.split(".", 1)
        want = b64(hmac.new(bytes.fromhex(CONF["secret"]), payload.encode(), "sha256").digest())
        if not hmac.compare_digest(sig, want):
            return False
        data = json.loads(unb64(payload))
        return data["exp"] > time.time() and data["k"] == CONF["pw"]["hash"][:12]
    except Exception:
        return False


# ------------------------------------------------------------- vless data --
def read_settings():
    s = {}
    try:
        with open(SETTINGS_ENV) as f:
            for line in f:
                m = re.match(r'^([A-Z_0-9]+)="(.*)"\s*$', line.strip())
                if m:
                    s[m.group(1)] = m.group(2)
    except OSError:
        pass
    return s


def read_users():
    users = []
    try:
        with open(USERS_DB) as f:
            for ln in f.read().splitlines():
                p = ln.split("|")
                if len(p) >= 4 and p[0]:
                    users.append({"name": p[0], "uuid": p[1], "expiry": p[2], "status": p[3]})
    except OSError:
        pass
    return users


def write_users(users):
    text = "".join("%s|%s|%s|%s\n" % (u["name"], u["uuid"], u["expiry"], u["status"]) for u in users)
    atomic_write(USERS_DB, text)


def user_state(u, today):
    if u["status"] == "locked":
        return "locked"
    if u["status"] == "expired":
        return "expired"
    if u["expiry"] != "never" and u["expiry"] < today:
        return "expired"
    return "active"


def days_left(u, today):
    if u["expiry"] == "never":
        return None
    try:
        return (datetime.date.fromisoformat(u["expiry"]) - datetime.date.fromisoformat(today)).days
    except ValueError:
        return None


def calc_expiry(val, base=None):
    base = base or datetime.date.today()
    v = str(val).strip().lower()
    if v == "never":
        return "never"
    if re.fullmatch(r"\d{1,4}", v):
        d = int(v)
        if not 1 <= d <= 3650:
            raise ApiError("Days must be between 1 and 3650")
        return (base + datetime.timedelta(days=d)).isoformat()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        try:
            return datetime.date.fromisoformat(v).isoformat()
        except ValueError:
            pass
    raise ApiError("Enter days (e.g. 30), a date (YYYY-MM-DD) or 'never'")


def make_link(u, s):
    host, port = s.get("HOST", ""), s.get("PORT", "443")
    tag = urllib.parse.quote("Nilana-" + u["name"])
    if s.get("MODE") == "reality":
        return ("vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s"
                "&type=tcp&headerType=none#%s" % (u["uuid"], host, port, s.get("FLOW", ""), s.get("SNI", ""),
                                                  s.get("PUBKEY", ""), s.get("SHORTID", ""), tag))
    path = urllib.parse.quote(s.get("WSPATH", "/"), safe="")
    return ("vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&host=%s"
            "&path=%s&allowInsecure=1#%s" % (u["uuid"], host, port, host, host, path, tag))


def sha_file(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def systemctl(*args):
    if NO_SERVICE:
        return None
    return run(["systemctl", *args], timeout=30)


def apply_config():
    """Rebuild Xray config from users.db; restart Xray only if it changed."""
    before = sha_file(XRAY_CFG)
    collect_traffic()                                  # flush counters before a possible restart
    r = run([VLESS_CLI, "render"], timeout=40)
    if r.returncode != 0:
        raise ApiError("Config rebuild failed: " + (r.stdout + r.stderr)[-300:].strip(), 500)
    if sha_file(XRAY_CFG) != before:
        systemctl("restart", SERVICE)


# ---------------------------------------------------------------- traffic --
TRAFFIC = {"users": {}}
TRAFFIC_LOCK = threading.Lock()


def load_traffic():
    global TRAFFIC
    try:
        with open(TRAFFIC_PATH) as f:
            TRAFFIC = json.load(f)
        TRAFFIC.setdefault("users", {})
    except (OSError, ValueError):
        TRAFFIC = {"users": {}}


def collect_traffic():
    r = run([XRAY_BIN, "api", "statsquery", "--server=" + API_ADDR, "-pattern", "user>>>", "-reset=true"], timeout=8)
    if r.returncode != 0:
        return
    try:
        stats = json.loads(r.stdout).get("stat") or []
    except ValueError:
        return
    now, changed = time.time(), False
    with TRAFFIC_LOCK:
        for s in stats:
            m = re.match(r"^user>>>(.+)>>>traffic>>>(uplink|downlink)$", s.get("name", ""))
            try:
                v = int(s.get("value", 0) or 0)
            except (TypeError, ValueError):
                continue
            if not m or v <= 0:
                continue
            rec = TRAFFIC["users"].setdefault(m.group(1), {"up": 0, "down": 0, "last": 0})
            rec["up" if m.group(2) == "uplink" else "down"] += v
            rec["last"] = now
            changed = True
        if changed:
            try:
                atomic_write(TRAFFIC_PATH, json.dumps(TRAFFIC))
            except OSError:
                pass


# ----------------------------------------------------------- system stats --
HIST = {k: collections.deque(maxlen=90) for k in ("cpu", "mem", "rx", "tx")}
SYS = {"cpu": 0.0, "rx_rate": 0.0, "tx_rate": 0.0, "rx_total": 0, "tx_total": 0}
SYS_LOCK = threading.Lock()


def read_cpu():
    with open("/proc/stat") as f:
        vals = list(map(int, f.readline().split()[1:]))
    return vals[3] + (vals[4] if len(vals) > 4 else 0), sum(vals)


def read_net():
    rx = tx = 0
    with open("/proc/net/dev") as f:
        for line in f.read().splitlines()[2:]:
            name, data = line.split(":", 1)
            if name.strip() == "lo":
                continue
            cols = data.split()
            rx += int(cols[0])
            tx += int(cols[8])
    return rx, tx


def read_mem():
    m = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            m[k] = int(v.split()[0]) * 1024
    total = m.get("MemTotal", 0)
    avail = m.get("MemAvailable", m.get("MemFree", 0))
    swap_t, swap_f = m.get("SwapTotal", 0), m.get("SwapFree", 0)
    return total, total - avail, swap_t, swap_t - swap_f


def sampler():
    try:
        idle0, tot0 = read_cpu()
        rx0, tx0 = read_net()
    except OSError:
        return
    t0, tick = time.time(), 0
    while True:
        time.sleep(2)
        try:
            idle1, tot1 = read_cpu()
            rx1, tx1 = read_net()
            now = time.time()
            dt = max(now - t0, 0.1)
            cpu = 100.0 * (1 - (idle1 - idle0) / max(tot1 - tot0, 1))
            rxr, txr = max(rx1 - rx0, 0) / dt, max(tx1 - tx0, 0) / dt
            total, used, _, _ = read_mem()
            with SYS_LOCK:
                SYS.update(cpu=cpu, rx_rate=rxr, tx_rate=txr, rx_total=rx1, tx_total=tx1)
                HIST["cpu"].append(round(cpu, 1))
                HIST["mem"].append(round(100.0 * used / max(total, 1), 1))
                HIST["rx"].append(round(rxr))
                HIST["tx"].append(round(txr))
            idle0, tot0, rx0, tx0, t0 = idle1, tot1, rx1, tx1, now
        except Exception:
            pass
        tick += 1
        if tick % 5 == 0:
            collect_traffic()


def xray_version():
    r = run([XRAY_BIN, "version"], timeout=5)
    return " ".join((r.stdout.splitlines() or [""])[0].split()[:2]) or "unknown" if r.returncode == 0 else "unknown"


XRAY_VER = ""


def xray_active():
    if NO_SERVICE:
        try:
            socket.create_connection(("127.0.0.1", 10085), timeout=1).close()
            return True
        except OSError:
            return False
    return run(["systemctl", "is-active", SERVICE], timeout=5).stdout.strip() == "active"


def os_name():
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.system()


def overview():
    s = read_settings()
    total, used, swap_t, swap_u = read_mem()
    du = shutil.disk_usage("/")
    today = datetime.date.today().isoformat()
    users = read_users()
    states = [user_state(u, today) for u in users]
    soon = 0
    for u, st in zip(users, states):
        d = days_left(u, today)
        if st == "active" and d is not None and d <= 7:
            soon += 1
    now = time.time()
    with TRAFFIC_LOCK:
        t_up = sum(r["up"] for r in TRAFFIC["users"].values())
        t_dn = sum(r["down"] for r in TRAFFIC["users"].values())
        live = sum(1 for r in TRAFFIC["users"].values() if now - r.get("last", 0) <= ACTIVE_WINDOW)
    with SYS_LOCK:
        sysd = dict(SYS)
        hist = {k: list(v) for k, v in HIST.items()}
    try:
        load = os.getloadavg()
    except OSError:
        load = (0, 0, 0)
    try:
        with open("/proc/uptime") as f:
            uptime = float(f.read().split()[0])
    except OSError:
        uptime = 0
    return {
        "host": socket.gethostname(), "os": os_name(), "kernel": platform.release(),
        "cores": os.cpu_count() or 1, "uptime": uptime, "load": load, "panel_version": VERSION,
        "cpu": round(sysd["cpu"], 1),
        "mem": {"total": total, "used": used, "pct": round(100.0 * used / max(total, 1), 1)},
        "swap": {"total": swap_t, "used": swap_u},
        "disk": {"total": du.total, "used": du.used, "pct": round(100.0 * du.used / max(du.total, 1), 1)},
        "net": {"rx_rate": sysd["rx_rate"], "tx_rate": sysd["tx_rate"],
                "rx_total": sysd["rx_total"], "tx_total": sysd["tx_total"]},
        "hist": hist,
        "xray": {"active": xray_active(), "version": XRAY_VER, "mode": s.get("MODE", "?"),
                 "port": s.get("PORT", "443"), "host": s.get("HOST", ""), "sni": s.get("SNI", "")},
        "users": {"total": len(users), "active": states.count("active"), "locked": states.count("locked"),
                  "expired": states.count("expired"), "expiring": soon,
                  "up": t_up, "down": t_dn, "live": live},
    }


def users_view():
    today = datetime.date.today().isoformat()
    now = time.time()
    out = []
    with TRAFFIC_LOCK:
        traffic = {k: dict(v) for k, v in TRAFFIC["users"].items()}
    for u in read_users():
        t = traffic.get(u["name"], {})
        last = t.get("last", 0)
        out.append({
            "name": u["name"], "uuid": u["uuid"], "expiry": u["expiry"],
            "state": user_state(u, today), "days_left": days_left(u, today),
            "up": t.get("up", 0), "down": t.get("down", 0),
            "last_seen": (now - last) if last else None,
            "live": bool(last and now - last <= ACTIVE_WINDOW),
        })
    return out


# ----------------------------------------------------------- user actions --
def find_user(users, name):
    for u in users:
        if u["name"] == name:
            return u
    raise ApiError("User not found", 404)


def need_name(body):
    name = str(body.get("name", ""))
    if not NAME_RE.match(name):
        raise ApiError("Name: 1-20 letters, digits, _ or -")
    return name


def act_add(body):
    name = need_name(body)
    expiry = calc_expiry(body.get("days", "30"))
    with MUTEX:
        with FileLock():
            users = read_users()
            if any(u["name"] == name for u in users):
                raise ApiError("User already exists", 409)
            users.append({"name": name, "uuid": str(__import__("uuid").uuid4()), "expiry": expiry, "status": "active"})
            write_users(users)
        apply_config()
    return {"ok": True}


def act_renew(body):
    name = need_name(body)
    with MUTEX:
        with FileLock():
            users = read_users()
            u = find_user(users, name)
            today = datetime.date.today()
            base = today
            if u["expiry"] not in ("never", "") and u["expiry"] > today.isoformat():
                base = datetime.date.fromisoformat(u["expiry"])
            u["expiry"] = calc_expiry(body.get("days", "30"), base)
            if u["status"] == "expired":
                u["status"] = "active"
            write_users(users)
        apply_config()
    return {"ok": True, "expiry": u["expiry"]}


def act_toggle(body):
    name = need_name(body)
    with MUTEX:
        with FileLock():
            users = read_users()
            u = find_user(users, name)
            u["status"] = "active" if u["status"] == "locked" else "locked"
            write_users(users)
        apply_config()
    return {"ok": True, "status": u["status"]}


def act_delete(body):
    name = need_name(body)
    with MUTEX:
        with FileLock():
            users = read_users()
            find_user(users, name)
            write_users([u for u in users if u["name"] != name])
        apply_config()
    with TRAFFIC_LOCK:
        TRAFFIC["users"].pop(name, None)
        atomic_write(TRAFFIC_PATH, json.dumps(TRAFFIC))
    return {"ok": True}


def act_reset_traffic(body):
    name = need_name(body)
    with TRAFFIC_LOCK:
        TRAFFIC["users"].pop(name, None)
        atomic_write(TRAFFIC_PATH, json.dumps(TRAFFIC))
    return {"ok": True}


def act_restart(_body):
    collect_traffic()
    r = systemctl("restart", SERVICE)
    if r is not None and r.returncode != 0:
        raise ApiError("Restart failed: " + r.stderr.strip()[:200], 500)
    return {"ok": True}


def act_password(body):
    old, new = str(body.get("old", "")), str(body.get("new", ""))
    if not check_pw(old, CONF["pw"]):
        raise ApiError("Current password is wrong", 403)
    if not 8 <= len(new) <= 128:
        raise ApiError("New password must be 8-128 characters")
    CONF["pw"] = hash_pw(new)
    save_conf(CONF)
    return {"ok": True}


def link_info(name):
    s = read_settings()
    u = find_user(read_users(), name)
    return {"link": make_link(u, s), "uuid": u["uuid"], "host": s.get("HOST"), "port": s.get("PORT", "443"),
            "mode": s.get("MODE"), "sni": s.get("SNI") if s.get("MODE") == "reality" else s.get("HOST"),
            "expiry": u["expiry"]}


def qr_svg(name):
    link = link_info(name)["link"]
    r = run(["qrencode", "-t", "SVG", "-m", "2", "-o", "-", link], timeout=8)
    if r.returncode != 0 or "<svg" not in r.stdout:
        raise ApiError("qrencode is not installed", 500)
    return r.stdout.encode()


def logs_text(lines):
    if NO_SERVICE:
        return "(journal not available in test mode)"
    lines = max(20, min(lines, 300))
    r = run(["journalctl", "-u", SERVICE, "-n", str(lines), "--no-pager", "-o", "short-iso"], timeout=10)
    return r.stdout or r.stderr or "(no log lines)"


# -------------------------------------------------------------- web server --
EMBEDDED_HTML = "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n<meta name=\"color-scheme\" content=\"light dark\">\n<meta name=\"robots\" content=\"noindex,nofollow\">\n<title>Nilana Panel</title>\n<style>\n:root{\n  --bg:#f4f6fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--soft:#f1f5f9;\n  --accent:#2563eb;--accent-text:#fff;--ok:#16a34a;--warn:#d97706;--bad:#dc2626;--shadow:0 1px 2px rgba(15,23,42,.06),0 4px 16px rgba(15,23,42,.05);\n  --rx:#2563eb;--tx:#f59e0b;\n}\n@media (prefers-color-scheme:dark){:root{\n  --bg:#0b1120;--card:#131c31;--text:#e5e9f4;--muted:#94a3b8;--line:#25304a;--soft:#1a2540;\n  --accent:#5b8def;--accent-text:#0b1120;--ok:#34d399;--warn:#fbbf24;--bad:#f87171;--shadow:none;\n  --rx:#5b8def;--tx:#fbbf24;\n}}\n*{box-sizing:border-box}\nhtml,body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 system-ui,-apple-system,\"Segoe UI\",Roboto,sans-serif;-webkit-text-size-adjust:100%}\nbody{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}\n.hidden{display:none!important}\n.tight{margin:6px 0 0}\n.block{width:100%}\n.mt{margin-top:14px}\nbutton,input,select,textarea{font:inherit;color:inherit}\nh1,h2,h3{margin:0;font-weight:650}\nh2{font-size:17px}\n.muted{color:var(--muted)}\n.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}\n.right{margin-left:auto}\n\n/* buttons / inputs */\n.btn{border:1px solid var(--line);background:var(--card);padding:8px 14px;border-radius:10px;cursor:pointer;font-weight:550;line-height:1.2}\n.btn:hover{background:var(--soft)}\n.btn:disabled{opacity:.55;cursor:default}\n.btn.primary{background:var(--accent);color:var(--accent-text);border-color:var(--accent)}\n.btn.primary:hover{filter:brightness(1.07)}\n.btn.danger{color:var(--bad)}\n.btn.sm{padding:5px 10px;font-size:13px;border-radius:8px}\n.input{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:var(--card)}\n.input:focus,.btn:focus-visible{outline:2px solid var(--accent);outline-offset:1px}\nlabel.f{display:block;margin:12px 0 4px;font-size:13px;color:var(--muted);font-weight:550}\n\n/* login */\n.center{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}\n.login{width:100%;max-width:360px}\n.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:18px}\n.logo{width:28px;height:28px;border-radius:9px;background:linear-gradient(135deg,var(--accent),#7c3aed);display:inline-block;position:relative}\n.logo::after{content:\"\";position:absolute;inset:8px;border-radius:50%;background:#fff;opacity:.92}\n.err{color:var(--bad);min-height:20px;margin-top:10px;font-size:14px}\n\n/* shell */\nheader{position:sticky;top:0;z-index:5;background:var(--card);border-bottom:1px solid var(--line);padding-top:env(safe-area-inset-top,0px);margin-top:calc(-1 * env(safe-area-inset-top,0px))}\n.bar{max-width:1120px;margin:0 auto;padding:10px 16px;display:flex;align-items:center;gap:14px}\nnav{display:flex;gap:4px;margin-left:12px}\nnav button{border:0;background:transparent;padding:8px 12px;border-radius:9px;cursor:pointer;color:var(--muted);font-weight:600}\nnav button.on{background:var(--soft);color:var(--text)}\nmain{max-width:1120px;margin:0 auto;padding:18px 16px 40px}\n.grid{display:grid;gap:14px}\n.g4{grid-template-columns:repeat(4,1fr)}\n.g2{grid-template-columns:repeat(2,1fr)}\n.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px;box-shadow:var(--shadow)}\n.card h3{font-size:13px;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.04em;margin-bottom:8px}\n.big{font-size:28px;font-weight:700;letter-spacing:-.02em}\n.sub{color:var(--muted);font-size:13px;margin-top:2px}\n.bartrack{height:8px;border-radius:6px;background:var(--soft);margin-top:10px;overflow:hidden}\n.barfill{height:100%;border-radius:6px;background:var(--accent);width:0}\n.barfill.warn{background:var(--warn)}\n.barfill.bad{background:var(--bad)}\n.spark{width:100%;height:70px;display:block;margin-top:6px}\n.legend{display:flex;gap:14px;font-size:13px;color:var(--muted);margin-top:6px;flex-wrap:wrap}\n.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:5px}\n.kv{display:grid;grid-template-columns:auto 1fr;gap:6px 16px;font-size:14px}\n.kv dt{color:var(--muted)}.kv dd{margin:0;word-break:break-all}\n.pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:99px;font-size:12.5px;font-weight:650;background:var(--soft)}\n.pill.ok{color:var(--ok)}.pill.bad{color:var(--bad)}.pill.warn{color:var(--warn)}.pill.mut{color:var(--muted)}\n.pill::before{content:\"\";width:7px;height:7px;border-radius:50%;background:currentColor}\n.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}\n.stack{display:grid;gap:14px}\n\n/* users */\n.toolbar{display:flex;gap:10px;margin-bottom:14px;flex-wrap:wrap}\n.toolbar .input{max-width:280px}\ntable{width:100%;border-collapse:collapse}\nth{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}\ntd{padding:11px 10px;border-bottom:1px solid var(--line);vertical-align:middle}\ntr:last-child td{border-bottom:0}\n.acts{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}\n.live{color:var(--ok);font-weight:650}\n.empty{padding:34px;text-align:center;color:var(--muted)}\n\n/* dialogs + toast */\ndialog{border:1px solid var(--line);border-radius:18px;background:var(--card);color:var(--text);padding:20px;width:min(440px,calc(100vw - 28px));box-shadow:0 20px 60px rgba(0,0,0,.35)}\ndialog::backdrop{background:rgba(2,6,23,.55)}\ndialog h2{margin-bottom:4px}\n.dlg-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:18px}\n.chips{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}\n.chip{border:1px solid var(--line);background:var(--soft);border-radius:99px;padding:4px 11px;font-size:13px;cursor:pointer}\n.chip:hover{border-color:var(--accent)}\n.qr{display:block;margin:12px auto;width:210px;height:210px;background:#fff;border-radius:14px;padding:8px}\ntextarea.link{width:100%;height:92px;resize:none;padding:10px;border:1px solid var(--line);border-radius:10px;background:var(--soft);font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}\n#toast{position:fixed;left:50%;bottom:calc(22px + env(safe-area-inset-bottom,0px));transform:translateX(-50%);background:#0f172a;color:#fff;padding:10px 16px;border-radius:12px;font-size:14px;z-index:50;max-width:calc(100vw - 28px);box-shadow:0 8px 30px rgba(0,0,0,.3)}\n#toast.bad{background:#b91c1c}\npre.log{margin:0;max-height:420px;overflow:auto;background:var(--soft);padding:12px;border-radius:12px;font-size:12px;line-height:1.5;white-space:pre-wrap;word-break:break-all}\n\n@media (max-width:860px){\n  .g4{grid-template-columns:repeat(2,1fr)}\n  .g2{grid-template-columns:1fr}\n  .bar{flex-wrap:wrap;gap:8px}\n  nav{order:3;width:100%;margin:0;overflow-x:auto}\n  nav button{flex:1;white-space:nowrap}\n  table,thead,tbody,tr,td{display:block}\n  thead{display:none}\n  tr{border:1px solid var(--line);border-radius:14px;padding:6px 12px;margin-bottom:10px;background:var(--card)}\n  td{border:0;padding:6px 0;display:flex;justify-content:space-between;gap:12px;align-items:center}\n  td::before{content:attr(data-l);color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}\n  td.actions{display:block;padding-top:10px}\n  td.actions::before{display:none}\n  .acts{justify-content:flex-start}\n  .big{font-size:24px}\n}\n</style>\n</head>\n<body>\n\n<div id=\"login\" class=\"center hidden\">\n  <div class=\"card login\">\n    <div class=\"brand\"><span class=\"logo\"></span>Nilana Panel</div>\n    <p class=\"muted tight\">Sign in to manage your VLESS server.</p>\n    <label class=\"f\" for=\"pw\">Password</label>\n    <input id=\"pw\" class=\"input\" type=\"password\" autocomplete=\"current-password\" autofocus>\n    <div id=\"loginErr\" class=\"err\"></div>\n    <button id=\"loginBtn\" class=\"btn primary block\" type=\"button\">Sign in</button>\n  </div>\n</div>\n\n<div id=\"app\" class=\"hidden\">\n  <header>\n    <div class=\"bar\">\n      <div class=\"brand\"><span class=\"logo\"></span>Nilana</div>\n      <nav id=\"tabs\">\n        <button data-tab=\"dash\" class=\"on\" type=\"button\">Dashboard</button>\n        <button data-tab=\"users\" type=\"button\">Users</button>\n        <button data-tab=\"server\" type=\"button\">Server</button>\n        <button data-tab=\"settings\" type=\"button\">Settings</button>\n      </nav>\n      <button id=\"logout\" class=\"btn sm right\" type=\"button\">Sign out</button>\n    </div>\n  </header>\n  <main>\n    <section id=\"v-dash\"></section>\n    <section id=\"v-users\" class=\"hidden\"></section>\n    <section id=\"v-server\" class=\"hidden\"></section>\n    <section id=\"v-settings\" class=\"hidden\"></section>\n  </main>\n</div>\n\n<dialog id=\"dlg\"></dialog>\n<div id=\"toast\" class=\"hidden\"></div>\n\n<script>\n\"use strict\";\nconst NS = \"http://www.w3.org/2000/svg\";\nconst $ = (s, r) => (r || document).querySelector(s);\nlet tab = \"dash\", USERS = [], OV = null, filter = \"\";\n\nfunction h(tag, attrs, ...kids) {\n  const e = document.createElement(tag);\n  for (const [k, v] of Object.entries(attrs || {})) {\n    if (v === false || v == null) continue;\n    if (k === \"class\") e.className = v;\n    else if (k.startsWith(\"on\")) e.addEventListener(k.slice(2), v);\n    else e.setAttribute(k, v);\n  }\n  for (const c of kids.flat()) { if (c == null || c === false) continue; e.append(c.nodeType ? c : document.createTextNode(String(c))); }\n  return e;\n}\nfunction fmtBytes(n) {\n  if (!n) return \"0 B\";\n  const u = [\"B\", \"KB\", \"MB\", \"GB\", \"TB\"]; let i = 0;\n  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }\n  return (n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)) + \" \" + u[i];\n}\nfunction fmtDur(s) {\n  s = Math.floor(s); const d = Math.floor(s / 86400), hr = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);\n  return d ? d + \"d \" + hr + \"h\" : hr ? hr + \"h \" + m + \"m\" : m + \"m\";\n}\nfunction ago(s) {\n  if (s == null) return \"never\";\n  if (s < 90) return \"now\";\n  if (s < 3600) return Math.floor(s / 60) + \" min ago\";\n  if (s < 86400) return Math.floor(s / 3600) + \" h ago\";\n  return Math.floor(s / 86400) + \" d ago\";\n}\nfunction toast(msg, bad) {\n  const t = $(\"#toast\"); t.textContent = msg; t.className = bad ? \"bad\" : \"\";\n  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.add(\"hidden\"), bad ? 5000 : 2600);\n}\nasync function api(path, body) {\n  const opt = body === undefined ? { credentials: \"same-origin\" } :\n    { method: \"POST\", credentials: \"same-origin\", headers: { \"Content-Type\": \"application/json\", \"X-Requested-With\": \"nilana\" }, body: JSON.stringify(body) };\n  const r = await fetch(path, opt);\n  const j = await r.json().catch(() => ({}));\n  if (r.status === 401 && path !== \"/api/login\") { showLogin(); throw new Error(\"Please sign in again\"); }\n  if (!r.ok) throw new Error(j.error || \"Request failed (\" + r.status + \")\");\n  return j;\n}\nasync function guard(fn) { try { return await fn(); } catch (e) { toast(e.message, true); } }\n\n/* ---------- charts ---------- */\nfunction spark(series, colors, maxv) {\n  const W = 300, H = 70, svg = document.createElementNS(NS, \"svg\");\n  svg.setAttribute(\"viewBox\", \"0 0 \" + W + \" \" + H); svg.setAttribute(\"preserveAspectRatio\", \"none\"); svg.setAttribute(\"class\", \"spark\");\n  const top = maxv || Math.max(1, ...series.flat());\n  series.forEach((vals, i) => {\n    if (vals.length < 2) return;\n    const step = W / (vals.length - 1);\n    const pts = vals.map((v, j) => (j * step).toFixed(1) + \",\" + (H - 3 - Math.min(v / top, 1) * (H - 8)).toFixed(1));\n    const area = document.createElementNS(NS, \"polygon\");\n    area.setAttribute(\"points\", \"0,\" + H + \" \" + pts.join(\" \") + \" \" + W + \",\" + H);\n    area.setAttribute(\"fill\", colors[i]); area.setAttribute(\"opacity\", \".13\");\n    const line = document.createElementNS(NS, \"polyline\");\n    line.setAttribute(\"points\", pts.join(\" \")); line.setAttribute(\"fill\", \"none\");\n    line.setAttribute(\"stroke\", colors[i]); line.setAttribute(\"stroke-width\", \"2\"); line.setAttribute(\"vector-effect\", \"non-scaling-stroke\");\n    line.setAttribute(\"stroke-linejoin\", \"round\");\n    svg.append(area, line);\n  });\n  return svg;\n}\nfunction meter(pct) {\n  const f = h(\"div\", { class: \"barfill\" + (pct >= 90 ? \" bad\" : pct >= 75 ? \" warn\" : \"\") });\n  f.style.width = Math.min(pct, 100) + \"%\";\n  return h(\"div\", { class: \"bartrack\" }, f);\n}\nfunction stat(title, big, sub, pct) {\n  return h(\"div\", { class: \"card\" }, h(\"h3\", {}, title), h(\"div\", { class: \"big\" }, big), h(\"div\", { class: \"sub\" }, sub), pct != null ? meter(pct) : null);\n}\n\n/* ---------- dashboard ---------- */\nfunction renderDash() {\n  const o = OV, root = $(\"#v-dash\");\n  if (!o) { root.replaceChildren(h(\"div\", { class: \"empty\" }, \"Loading...\")); return; }\n  const x = o.xray, u = o.users;\n  const rx = o.hist.rx, tx = o.hist.tx, nmax = Math.max(1024, ...rx, ...tx);\n  root.replaceChildren(h(\"div\", { class: \"stack\" },\n    h(\"div\", { class: \"grid g4\" },\n      stat(\"CPU\", o.cpu.toFixed(0) + \"%\", o.cores + \" core\" + (o.cores > 1 ? \"s\" : \"\") + \" \u00b7 load \" + o.load.map(v => v.toFixed(2)).join(\" \"), o.cpu),\n      stat(\"Memory\", o.mem.pct.toFixed(0) + \"%\", fmtBytes(o.mem.used) + \" of \" + fmtBytes(o.mem.total), o.mem.pct),\n      stat(\"Disk\", o.disk.pct.toFixed(0) + \"%\", fmtBytes(o.disk.used) + \" of \" + fmtBytes(o.disk.total), o.disk.pct),\n      stat(\"Uptime\", fmtDur(o.uptime), o.os)),\n    h(\"div\", { class: \"grid g2\" },\n      h(\"div\", { class: \"card\" }, h(\"div\", { class: \"row\" }, h(\"h3\", {}, \"Network\"), h(\"span\", { class: \"right sub\" }, \"last 3 min\")),\n        h(\"div\", { class: \"row\" },\n          h(\"div\", {}, h(\"div\", { class: \"big\" }, fmtBytes(o.net.rx_rate) + \"/s\"), h(\"div\", { class: \"sub\" }, \"\u2193 in \u00b7 total \" + fmtBytes(o.net.rx_total))),\n          h(\"div\", { class: \"right\" }, h(\"div\", { class: \"big\" }, fmtBytes(o.net.tx_rate) + \"/s\"), h(\"div\", { class: \"sub\" }, \"\u2191 out \u00b7 total \" + fmtBytes(o.net.tx_total)))),\n        spark([rx, tx], [\"var(--rx)\", \"var(--tx)\"], nmax),\n        h(\"div\", { class: \"legend\" }, h(\"span\", {}, h(\"i\", { class: \"dot\", \"data-c\": \"rx\" }), \"Download\"), h(\"span\", {}, h(\"i\", { class: \"dot\", \"data-c\": \"tx\" }), \"Upload\"))),\n      h(\"div\", { class: \"card\" }, h(\"div\", { class: \"row\" }, h(\"h3\", {}, \"VLESS service\"),\n          h(\"span\", { class: \"right pill \" + (x.active ? \"ok\" : \"bad\") }, x.active ? \"Running\" : \"Stopped\")),\n        h(\"dl\", { class: \"kv\" },\n          h(\"dt\", {}, \"Mode\"), h(\"dd\", {}, x.mode === \"reality\" ? \"VLESS + REALITY\" : \"VLESS + WebSocket + TLS\"),\n          h(\"dt\", {}, \"Address\"), h(\"dd\", {}, x.host + \":\" + x.port),\n          x.mode === \"reality\" ? [h(\"dt\", {}, \"SNI\"), h(\"dd\", {}, x.sni)] : null,\n          h(\"dt\", {}, \"Core\"), h(\"dd\", {}, x.version)),\n        h(\"div\", { class: \"row mt\" }, h(\"button\", { class: \"btn sm\", type: \"button\", onclick: restartXray }, \"Restart service\")))),\n    h(\"div\", { class: \"grid g4\" },\n      stat(\"Users\", u.total, u.active + \" active \u00b7 \" + u.locked + \" locked\"),\n      stat(\"Expired\", u.expired, u.expiring + \" expiring within 7 days\"),\n      stat(\"Active now\", u.live, \"connections in the last 90 s\"),\n      stat(\"Traffic used\", fmtBytes(u.up + u.down), \"\u2193 \" + fmtBytes(u.down) + \" \u00b7 \u2191 \" + fmtBytes(u.up)))));\n  root.querySelectorAll(\".dot\").forEach(d => { d.style.background = d.dataset.c === \"rx\" ? \"var(--rx)\" : \"var(--tx)\"; });\n}\nasync function restartXray() {\n  if (!await confirmDlg(\"Restart VLESS?\", \"All connected users will reconnect within a few seconds.\", \"Restart\")) return;\n  guard(async () => { await api(\"/api/service/restart\", {}); toast(\"Service restarted\"); setTimeout(refresh, 1500); });\n}\n\n/* ---------- users ---------- */\nconst STATE = { active: [\"ok\", \"Active\"], locked: [\"warn\", \"Locked\"], expired: [\"bad\", \"Expired\"] };\nfunction renderUsers() {\n  const root = $(\"#v-users\");\n  const q = filter.trim().toLowerCase();\n  const list = USERS.filter(u => !q || u.name.toLowerCase().includes(q));\n  const tool = h(\"div\", { class: \"toolbar\" },\n    h(\"input\", { class: \"input\", id: \"search\", placeholder: \"Search users\", value: filter, oninput: e => { filter = e.target.value; renderUsers(); $(\"#search\").focus(); $(\"#search\").setSelectionRange(filter.length, filter.length); } }),\n    h(\"button\", { class: \"btn primary right\", type: \"button\", onclick: addDlg }, \"+ Add user\"));\n  let body;\n  if (!list.length) body = h(\"div\", { class: \"empty\" }, USERS.length ? \"No user matches your search.\" : \"No users yet. Add your first user.\");\n  else body = h(\"table\", {},\n    h(\"thead\", {}, h(\"tr\", {}, [\"User\", \"Status\", \"Expires\", \"Traffic\", \"Last active\", \"\"].map(t => h(\"th\", {}, t)))),\n    h(\"tbody\", {}, list.map(u => {\n      const st = STATE[u.state];\n      const exp = u.expiry === \"never\" ? \"Never\" : u.expiry + (u.days_left == null || u.days_left > 3650 ? \"\" : u.days_left >= 0 ? \" (\" + u.days_left + \"d)\" : \" (expired)\");\n      return h(\"tr\", {},\n        h(\"td\", { \"data-l\": \"User\" }, h(\"b\", {}, u.name)),\n        h(\"td\", { \"data-l\": \"Status\" }, h(\"span\", { class: \"pill \" + st[0] }, st[1])),\n        h(\"td\", { \"data-l\": \"Expires\" }, exp),\n        h(\"td\", { \"data-l\": \"Traffic\" }, \"\u2193 \" + fmtBytes(u.down) + \"  \u2191 \" + fmtBytes(u.up)),\n        h(\"td\", { \"data-l\": \"Last active\" }, u.live ? h(\"span\", { class: \"live\" }, \"\u25cf online\") : ago(u.last_seen)),\n        h(\"td\", { class: \"actions\" }, h(\"div\", { class: \"acts\" },\n          h(\"button\", { class: \"btn sm\", type: \"button\", onclick: () => linkDlg(u.name) }, \"Link / QR\"),\n          h(\"button\", { class: \"btn sm\", type: \"button\", onclick: () => renewDlg(u) }, \"Renew\"),\n          h(\"button\", { class: \"btn sm\", type: \"button\", onclick: () => toggleUser(u) }, u.state === \"locked\" ? \"Unlock\" : \"Lock\"),\n          h(\"button\", { class: \"btn sm danger\", type: \"button\", onclick: () => deleteUser(u) }, \"Delete\"))));\n    })));\n  root.replaceChildren(tool, h(\"div\", { class: \"card\" }, body));\n}\nfunction toggleUser(u) {\n  guard(async () => { await api(\"/api/users/toggle\", { name: u.name }); toast(u.name + (u.state === \"locked\" ? \" unlocked\" : \" locked\")); await refresh(); });\n}\nasync function deleteUser(u) {\n  if (!await confirmDlg(\"Delete \" + u.name + \"?\", \"The account is removed and the user is disconnected. This cannot be undone.\", \"Delete\", true)) return;\n  guard(async () => { await api(\"/api/users/delete\", { name: u.name }); toast(u.name + \" deleted\"); await refresh(); });\n}\n\n/* ---------- dialogs ---------- */\nconst dlg = $(\"#dlg\");\nfunction openDlg(...kids) { dlg.replaceChildren(...kids); if (!dlg.open) dlg.showModal(); }\nfunction closeDlg() { if (dlg.open) dlg.close(); }\ndlg.addEventListener(\"click\", e => { if (e.target === dlg) closeDlg(); });\nfunction confirmDlg(title, text, okLabel, danger) {\n  return new Promise(res => {\n    openDlg(h(\"h2\", {}, title), h(\"p\", { class: \"muted\" }, text),\n      h(\"div\", { class: \"dlg-actions\" },\n        h(\"button\", { class: \"btn\", type: \"button\", onclick: () => { closeDlg(); res(false); } }, \"Cancel\"),\n        h(\"button\", { class: \"btn \" + (danger ? \"danger\" : \"primary\"), type: \"button\", onclick: () => { closeDlg(); res(true); } }, okLabel)));\n    dlg.addEventListener(\"close\", () => res(false), { once: true });\n  });\n}\nfunction daysField(initial) {\n  const inp = h(\"input\", { class: \"input\", id: \"daysIn\", value: initial, placeholder: \"30, 2026-12-31 or never\", autocomplete: \"off\" });\n  const chips = h(\"div\", { class: \"chips\" }, [[\"7 d\", \"7\"], [\"30 d\", \"30\"], [\"90 d\", \"90\"], [\"180 d\", \"180\"], [\"1 year\", \"365\"], [\"Never\", \"never\"]]\n    .map(([t, v]) => h(\"button\", { class: \"chip\", type: \"button\", onclick: () => { inp.value = v; } }, t)));\n  return [inp, chips];\n}\nfunction addDlg() {\n  const name = h(\"input\", { class: \"input\", id: \"nameIn\", maxlength: \"20\", placeholder: \"e.g. kasun\", autocomplete: \"off\" });\n  const [days, chips] = daysField(\"30\");\n  openDlg(h(\"h2\", {}, \"Add user\"), h(\"p\", { class: \"muted\" }, \"Letters, digits, _ and - only.\"),\n    h(\"label\", { class: \"f\", for: \"nameIn\" }, \"Username\"), name,\n    h(\"label\", { class: \"f\", for: \"daysIn\" }, \"Valid for (days, date or never)\"), days, chips,\n    h(\"div\", { class: \"dlg-actions\" },\n      h(\"button\", { class: \"btn\", type: \"button\", onclick: closeDlg }, \"Cancel\"),\n      h(\"button\", { class: \"btn primary\", type: \"button\", onclick: () => guard(async () => {\n        const n = name.value.trim();\n        await api(\"/api/users/add\", { name: n, days: days.value.trim() });\n        closeDlg(); toast(\"User \" + n + \" created\"); await refresh(); await linkDlg(n);\n      }) }, \"Create\")));\n  name.focus();\n}\nfunction renewDlg(u) {\n  const [days, chips] = daysField(\"30\");\n  openDlg(h(\"h2\", {}, \"Renew \" + u.name), h(\"p\", { class: \"muted\" }, \"Days are added to the current expiry (or to today if already expired).\"),\n    h(\"label\", { class: \"f\", for: \"daysIn\" }, \"Add days (or date / never)\"), days, chips,\n    h(\"div\", { class: \"dlg-actions\" },\n      h(\"button\", { class: \"btn\", type: \"button\", onclick: closeDlg }, \"Cancel\"),\n      h(\"button\", { class: \"btn primary\", type: \"button\", onclick: () => guard(async () => {\n        const r = await api(\"/api/users/renew\", { name: u.name, days: days.value.trim() });\n        closeDlg(); toast(u.name + \" now expires \" + r.expiry); await refresh();\n      }) }, \"Renew\")));\n}\nasync function linkDlg(name) {\n  await guard(async () => {\n    const d = await api(\"/api/link?name=\" + encodeURIComponent(name));\n    const ta = h(\"textarea\", { class: \"link\", readonly: \"readonly\" }); ta.value = d.link;\n    const copy = () => {\n      ta.select();\n      const ok = navigator.clipboard ? navigator.clipboard.writeText(d.link).then(() => true, () => false) : Promise.resolve(false);\n      ok.then(v => { if (!v) { try { document.execCommand(\"copy\"); } catch (e) { /* ignore */ } } toast(\"Link copied\"); });\n    };\n    openDlg(h(\"h2\", {}, name), h(\"div\", { class: \"muted\" }, \"Scan with v2rayNG, Hiddify, v2rayN, Streisand or Shadowrocket\"),\n      h(\"img\", { class: \"qr\", alt: \"QR code for \" + name, src: \"/api/qr?name=\" + encodeURIComponent(name) + \"&t=\" + Date.now() }),\n      h(\"dl\", { class: \"kv\" }, h(\"dt\", {}, \"Address\"), h(\"dd\", {}, d.host + \":\" + d.port), h(\"dt\", {}, \"UUID\"), h(\"dd\", { class: \"mono\" }, d.uuid),\n        h(\"dt\", {}, \"Expires\"), h(\"dd\", {}, d.expiry === \"never\" ? \"Never\" : d.expiry)),\n      h(\"label\", { class: \"f\" }, \"VLESS link\"), ta,\n      h(\"div\", { class: \"dlg-actions\" },\n        h(\"button\", { class: \"btn\", type: \"button\", onclick: closeDlg }, \"Close\"),\n        h(\"button\", { class: \"btn primary\", type: \"button\", onclick: copy }, \"Copy link\")));\n  });\n}\n\n/* ---------- server ---------- */\nasync function renderServer() {\n  const root = $(\"#v-server\");\n  if (!root.firstChild) root.replaceChildren(h(\"div\", { class: \"stack\" },\n    h(\"div\", { class: \"card\" }, h(\"div\", { class: \"row\" }, h(\"h2\", {}, \"VLESS service log\"),\n      h(\"button\", { class: \"btn sm right\", type: \"button\", onclick: renderServer }, \"Refresh\"),\n      h(\"button\", { class: \"btn sm\", type: \"button\", onclick: restartXray }, \"Restart service\")),\n      h(\"pre\", { class: \"log\", id: \"logbox\" }, \"Loading...\")),\n    h(\"div\", { class: \"card\" }, h(\"h3\", {}, \"Server\"), h(\"dl\", { class: \"kv\", id: \"srvinfo\" }))));\n  try {\n    const l = await api(\"/api/logs?lines=120\"); const box = $(\"#logbox\");\n    if (box) { const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 30; box.textContent = l.text; if (atEnd) box.scrollTop = box.scrollHeight; }\n  } catch (e) { /* shown by api */ }\n  if (OV && $(\"#srvinfo\")) $(\"#srvinfo\").replaceChildren(\n    h(\"dt\", {}, \"Hostname\"), h(\"dd\", {}, OV.host), h(\"dt\", {}, \"System\"), h(\"dd\", {}, OV.os + \" \u00b7 kernel \" + OV.kernel),\n    h(\"dt\", {}, \"Uptime\"), h(\"dd\", {}, fmtDur(OV.uptime)), h(\"dt\", {}, \"Swap\"), h(\"dd\", {}, OV.swap.total ? fmtBytes(OV.swap.used) + \" of \" + fmtBytes(OV.swap.total) : \"none\"),\n    h(\"dt\", {}, \"Xray core\"), h(\"dd\", {}, OV.xray.version), h(\"dt\", {}, \"Panel\"), h(\"dd\", {}, \"v\" + OV.panel_version));\n}\n\n/* ---------- settings ---------- */\nfunction renderSettings() {\n  const root = $(\"#v-settings\");\n  if (root.firstChild) return;\n  const o = h(\"input\", { class: \"input\", type: \"password\", id: \"oldpw\", autocomplete: \"current-password\" });\n  const n = h(\"input\", { class: \"input\", type: \"password\", id: \"newpw\", autocomplete: \"new-password\" });\n  const n2 = h(\"input\", { class: \"input\", type: \"password\", id: \"newpw2\", autocomplete: \"new-password\" });\n  root.replaceChildren(h(\"div\", { class: \"grid g2\" },\n    h(\"div\", { class: \"card\" }, h(\"h2\", {}, \"Change panel password\"),\n      h(\"label\", { class: \"f\", for: \"oldpw\" }, \"Current password\"), o,\n      h(\"label\", { class: \"f\", for: \"newpw\" }, \"New password (min 8 characters)\"), n,\n      h(\"label\", { class: \"f\", for: \"newpw2\" }, \"Repeat new password\"), n2,\n      h(\"div\", { class: \"dlg-actions\" }, h(\"button\", { class: \"btn primary\", type: \"button\", onclick: () => guard(async () => {\n        if (n.value !== n2.value) throw new Error(\"New passwords do not match\");\n        await api(\"/api/password\", { old: o.value, new: n.value });\n        o.value = n.value = n2.value = \"\"; toast(\"Password changed\");\n      }) }, \"Save password\"))),\n    h(\"div\", { class: \"card\" }, h(\"h2\", {}, \"Good to know\"),\n      h(\"p\", { class: \"muted\" }, \"Sessions last 12 hours and are signed out when the password changes. Five wrong passwords lock the sign-in for 5 minutes.\"),\n      h(\"p\", { class: \"muted\" }, \"Adding, renewing or deleting a user rebuilds the VLESS config. The service restarts only when the config actually changed, which briefly reconnects everyone.\"),\n      h(\"p\", { class: \"muted\" }, \"Forgot the password? Run  nilana-panel passwd  on the server.\"))));\n}\n\n/* ---------- plumbing ---------- */\nasync function refresh() {\n  if (document.hidden && refresh.auto) return;\n  try {\n    if (tab === \"dash\") { OV = await api(\"/api/overview\"); renderDash(); }\n    else if (tab === \"users\") { USERS = (await api(\"/api/users\")).users; if (!dlg.open && !(document.activeElement && document.activeElement.id === \"search\")) renderUsers(); }\n    else if (tab === \"server\") { if (!OV) OV = await api(\"/api/overview\"); await renderServer(); }\n  } catch (e) { /* api() already handled 401; keep the old view on transient errors */ }\n}\nfunction setTab(t) {\n  tab = t;\n  document.querySelectorAll(\"#tabs button\").forEach(b => b.classList.toggle(\"on\", b.dataset.tab === t));\n  [\"dash\", \"users\", \"server\", \"settings\"].forEach(v => $(\"#v-\" + v).classList.toggle(\"hidden\", v !== t));\n  if (t === \"users\") api(\"/api/users\").then(r => { USERS = r.users; renderUsers(); }).catch(() => {});\n  else if (t === \"settings\") renderSettings();\n  else refresh();\n}\nfunction showLogin() { $(\"#app\").classList.add(\"hidden\"); $(\"#login\").classList.remove(\"hidden\"); closeDlg(); $(\"#pw\").value = \"\"; $(\"#pw\").focus(); }\nfunction showApp() { $(\"#login\").classList.add(\"hidden\"); $(\"#app\").classList.remove(\"hidden\"); OV = null; [\"server\", \"settings\"].forEach(v => $(\"#v-\" + v).replaceChildren()); setTab(\"dash\"); }\nasync function doLogin() {\n  const b = $(\"#loginBtn\"); b.disabled = true; $(\"#loginErr\").textContent = \"\";\n  try { await api(\"/api/login\", { password: $(\"#pw\").value }); showApp(); }\n  catch (e) { $(\"#loginErr\").textContent = e.message; }\n  b.disabled = false;\n}\n$(\"#loginBtn\").addEventListener(\"click\", doLogin);\n$(\"#pw\").addEventListener(\"keydown\", e => { if (e.key === \"Enter\") doLogin(); });\n$(\"#logout\").addEventListener(\"click\", async () => { try { await api(\"/api/logout\", {}); } catch (e) { /* ignore */ } showLogin(); });\ndocument.querySelectorAll(\"#tabs button\").forEach(b => b.addEventListener(\"click\", () => setTab(b.dataset.tab)));\ndocument.addEventListener(\"visibilitychange\", () => { if (!document.hidden) refresh(); });\nsetInterval(() => { refresh.auto = true; refresh(); refresh.auto = false; }, 3000);\napi(\"/api/me\").then(m => { if (m.auth) showApp(); else showLogin(); }).catch(() => showLogin());\n</script>\n</body>\n</html>\n"


def load_html():
    if EMBEDDED_HTML:
        return EMBEDDED_HTML
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "panel.html")) as f:
        return f.read()


HTML = load_html()

FAILS = {}   # ip -> [count, locked_until]
FAILS_LOCK = threading.Lock()


def csp_for(html):
    def h(tag):
        m = re.search(r"<%s>(.*?)</%s>" % (tag, tag), html, re.S)
        return "'sha256-%s'" % base64.b64encode(hashlib.sha256(m.group(1).encode()).digest()).decode()
    return ("default-src 'none'; script-src %s; style-src %s; img-src 'self'; connect-src 'self'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'" % (h("script"), h("style")))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "NilanaPanel"
    sys_version = ""
    timeout = 20

    def setup(self):
        super().setup()
        if getattr(self.server, "ctx", None):
            self.request.do_handshake()

    def log_message(self, *a):
        pass

    # ---- plumbing
    def _send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200, extra=None):
        self._send(code, json.dumps(obj).encode(), "application/json", extra)

    def _authed(self):
        c = self.headers.get("Cookie", "")
        m = re.search(r"(?:^|;\s*)nl_session=([A-Za-z0-9_.\-]+)", c)
        return bool(m and token_ok(m.group(1)))

    def _cookie(self, value, max_age):
        flags = "HttpOnly; SameSite=Strict; Path=/; Max-Age=%d" % max_age
        if CONF.get("tls"):
            flags += "; Secure"
        return {"Set-Cookie": "nl_session=%s; %s" % (value, flags)}

    def _body(self):
        if self.headers.get("X-Requested-With") != "nilana":
            raise ApiError("Bad request", 403)
        if "application/json" not in self.headers.get("Content-Type", ""):
            raise ApiError("Bad request", 415)
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlsplit(origin).netloc != self.headers.get("Host"):
            raise ApiError("Bad origin", 403)
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n > 8192:
            raise ApiError("Too large", 413)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            raise ApiError("Bad JSON")
        if not isinstance(data, dict):
            raise ApiError("Bad JSON")
        return data

    # ---- routes
    def do_GET(self):
        try:
            u = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(u.query)
            if u.path == "/":
                self._send(200, HTML.encode(), "text/html; charset=utf-8", {"Content-Security-Policy": CSP})
                return
            if u.path == "/api/me":
                self._json({"auth": self._authed(), "version": VERSION})
                return
            if not u.path.startswith("/api/"):
                self._json({"error": "Not found"}, 404)
                return
            if not self._authed():
                self._json({"error": "Not signed in"}, 401)
                return
            if u.path == "/api/overview":
                self._json(overview())
            elif u.path == "/api/users":
                self._json({"users": users_view()})
            elif u.path == "/api/link":
                name = need_name({"name": (q.get("name") or [""])[0]})
                self._json(link_info(name))
            elif u.path == "/api/qr":
                name = need_name({"name": (q.get("name") or [""])[0]})
                self._send(200, qr_svg(name), "image/svg+xml")
            elif u.path == "/api/logs":
                try:
                    n = int((q.get("lines") or ["100"])[0])
                except ValueError:
                    n = 100
                self._json({"text": logs_text(n)})
            else:
                self._json({"error": "Not found"}, 404)
        except ApiError as e:
            self._json({"error": e.msg}, e.code)
        except Exception as e:  # never leak a traceback to the client
            sys.stderr.write("GET error: %r\n" % (e,))
            self._json({"error": "Server error"}, 500)

    def do_POST(self):
        try:
            path = urllib.parse.urlsplit(self.path).path
            body = self._body()
            if path == "/api/login":
                return self._login(body)
            if not self._authed():
                self._json({"error": "Not signed in"}, 401)
                return
            routes = {"/api/users/add": act_add, "/api/users/renew": act_renew, "/api/users/toggle": act_toggle,
                      "/api/users/delete": act_delete, "/api/users/reset-traffic": act_reset_traffic,
                      "/api/service/restart": act_restart}
            if path == "/api/logout":
                self._json({"ok": True}, 200, self._cookie("", 0))
            elif path == "/api/password":
                res = act_password(body)
                self._json(res, 200, self._cookie(make_token(), SESSION_TTL))
            elif path in routes:
                self._json(routes[path](body))
            else:
                self._json({"error": "Not found"}, 404)
        except ApiError as e:
            self._json({"error": e.msg}, e.code)
        except Exception as e:
            sys.stderr.write("POST error: %r\n" % (e,))
            self._json({"error": "Server error"}, 500)

    def _login(self, body):
        ip = self.client_address[0]
        now = time.time()
        with FAILS_LOCK:
            cnt, until = FAILS.get(ip, [0, 0])
            if until > now:
                raise ApiError("Too many attempts. Try again in %d min." % (int(until - now) // 60 + 1), 429)
        if check_pw(str(body.get("password", ""))[:256], CONF["pw"]):
            with FAILS_LOCK:
                FAILS.pop(ip, None)
            self._json({"ok": True}, 200, self._cookie(make_token(), SESSION_TTL))
            return
        with FAILS_LOCK:
            cnt += 1
            FAILS[ip] = [cnt, now + 300 if cnt >= 5 else 0]
            if cnt >= 5:
                FAILS[ip][0] = 0
        time.sleep(0.6)
        raise ApiError("Wrong password", 401)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64
    ctx = None

    def get_request(self):
        sock, addr = self.socket.accept()
        if self.ctx:
            sock = self.ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
        return sock, addr

    def handle_error(self, request, client_address):
        pass  # TLS probes / port scanners: stay quiet


CSP = csp_for(HTML)


def serve():
    global CONF, XRAY_VER
    CONF = load_conf()
    load_traffic()
    XRAY_VER = xray_version()
    threading.Thread(target=sampler, daemon=True).start()
    srv = Server((CONF.get("bind", "127.0.0.1"), int(CONF["port"])), Handler)
    if CONF.get("tls"):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CONF.get("cert") or os.path.join(PANEL_DIR, "cert.pem"),
                            CONF.get("key") or os.path.join(PANEL_DIR, "key.pem"))
        srv.ctx = ctx
    print("Nilana Panel %s on %s:%s (tls=%s)" % (VERSION, CONF.get("bind"), CONF["port"], bool(CONF.get("tls"))), flush=True)
    srv.serve_forever()


# --------------------------------------------------------------------- cli --
def free_port():
    for _ in range(200):
        p = random.randint(20000, 60000)
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", p)) != 0:
                return p
    return 24680


def cmd_init(args):
    opts = {"port": 0, "public": False, "password": ""}
    it = iter(args)
    for a in it:
        if a == "--port":
            opts["port"] = int(next(it))
        elif a == "--public":
            opts["public"] = True
        elif a == "--password":
            opts["password"] = next(it)
    pw = opts["password"] or secrets.token_urlsafe(12)
    if len(pw) < 8:
        sys.exit("Password must be at least 8 characters")
    conf = {"port": opts["port"] or free_port(), "bind": "0.0.0.0" if opts["public"] else "127.0.0.1",
            "tls": opts["public"], "secret": secrets.token_hex(32), "pw": hash_pw(pw)}
    save_conf(conf)
    os.makedirs(DATA_DIR, exist_ok=True)
    print(json.dumps({"port": conf["port"], "password": pw, "public": opts["public"]}))


def cmd_setcert(args):
    """nilana-panel setcert CERT KEY [DOMAIN]  -> serve HTTPS publicly with this certificate"""
    if len(args) < 2 or not (os.path.isfile(args[0]) and os.path.isfile(args[1])):
        sys.exit("Usage: nilana-panel.py setcert CERT_FILE KEY_FILE [DOMAIN]")
    c = load_conf()
    c.update(tls=True, bind="0.0.0.0", cert=args[0], key=args[1])
    if len(args) > 2:
        c["domain"] = args[2]
    save_conf(c)
    print("ok")


def cmd_passwd():
    global CONF
    CONF = load_conf()
    pw = getpass.getpass("New panel password (min 8 chars): ")
    if len(pw) < 8 or pw != getpass.getpass("Repeat: "):
        sys.exit("Passwords differ or are too short.")
    CONF["pw"] = hash_pw(pw)
    save_conf(CONF)
    print("Password changed. Existing browser sessions are now signed out.")


def cmd_info():
    c = load_conf()
    print("Port: %s   Bind: %s   TLS: %s" % (c["port"], c["bind"], c["tls"]))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "serve":
        serve()
    elif cmd == "init":
        cmd_init(sys.argv[2:])
    elif cmd == "setcert":
        cmd_setcert(sys.argv[2:])
    elif cmd == "passwd":
        cmd_passwd()
    elif cmd == "info":
        cmd_info()
    else:
        sys.exit("Usage: nilana-panel [serve|passwd|info]")
PANEL_PY_EOF
chmod 755 "$BIN"
cat > /usr/local/bin/nilana-panel <<EOF
#!/bin/sh
exec $PY $BIN "\$@"
EOF
chmod 755 /usr/local/bin/nilana-panel

# ---- config (keep existing password/port on re-install) -----------------------
NEWPW=""
if [ -f "$PANEL_DIR/panel.json" ]; then
  say "Existing panel settings found - keeping password and port."
  warn "To switch between private and --public mode run: bash install-panel.sh --uninstall, then install again."
  PORT="$("$PY" -c "import json;print(json.load(open('$PANEL_DIR/panel.json'))['port'])")"
  PUBLIC="$("$PY" -c "import json;print(1 if json.load(open('$PANEL_DIR/panel.json'))['tls'] else 0)")"
else
  args=(init --port "$PORT")
  [ "$PUBLIC" -eq 1 ] && args+=(--public)
  [ -n "$PASSWORD" ] && args+=(--password "$PASSWORD")
  out="$("$PY" "$BIN" "${args[@]}")" || die "Could not create panel settings"
  PORT="$(printf '%s' "$out" | "$PY" -c "import sys,json;print(json.load(sys.stdin)['port'])")"
  NEWPW="$(printf '%s' "$out" | "$PY" -c "import sys,json;print(json.load(sys.stdin)['password'])")"
fi

if [ -n "$DOMAIN" ]; then
  "$PY" "$BIN" setcert "$LE_CERT" "$LE_KEY" "$DOMAIN" >/dev/null || die "Could not set the certificate"
  PUBLIC=1
  PORT="$("$PY" -c "import json;print(json.load(open('$PANEL_DIR/panel.json'))['port'])")"
elif [ "$PUBLIC" -eq 1 ] && [ ! -f "$PANEL_DIR/cert.pem" ]; then
  IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$PANEL_DIR/key.pem" -out "$PANEL_DIR/cert.pem" \
    -subj "/CN=${IP:-nilana-panel}" >/dev/null 2>&1 || die "Could not create the panel certificate"
  chmod 600 "$PANEL_DIR/key.pem" "$PANEL_DIR/cert.pem"
fi

# ---- service ------------------------------------------------------------------
cat > /etc/systemd/system/nilana-panel.service <<EOF
[Unit]
Description=Nilana Panel
After=network-online.target nilana-vless.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=$PY $BIN serve
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
[ "$PUBLIC" -eq 1 ] && { open_port "$PORT"; ok "Firewall: allowed TCP $PORT"; }

# make sure the running Xray config has the stats API (older installs)
if ! grep -q '"api-in"' /usr/local/etc/xray/config.json 2>/dev/null; then
  /usr/local/bin/nilana-vless render >/dev/null 2>&1
  systemctl restart nilana-vless >/dev/null 2>&1
fi

systemctl enable nilana-panel >/dev/null 2>&1
systemctl restart nilana-panel
sleep 2
systemctl is-active --quiet nilana-panel || { journalctl -u nilana-panel -n 20 --no-pager; die "Panel did not start."; }
systemctl is-enabled --quiet nilana-panel || warn "Panel is not enabled at boot: systemctl enable nilana-panel"
if [ "$PUBLIC" -eq 1 ] && command -v iptables >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
  grep -qs -- "--dport $PORT" /etc/iptables/rules.v4 2>/dev/null \
    || warn "Panel port rule is not saved in /etc/iptables/rules.v4 (lost after reboot). Fix: apt install iptables-persistent && netfilter-persistent save"
fi
ok "Nilana Panel is running"

IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
say
say "${G}============== NILANA PANEL ==============${N}"
if [ "$PUBLIC" -eq 1 ]; then
  if [ -n "$DOMAIN" ]; then
    say " URL      : https://${DOMAIN}:${PORT}"
    say " (trusted Let's Encrypt certificate - no browser warning)"
  else
    say " URL      : https://${IP}:${PORT}"
    say " (self-signed certificate: the browser shows a warning once - choose Advanced > Continue)"
  fi
  say " ${Y}Also allow TCP ${PORT} in your cloud firewall (Oracle: VCN > Security Lists).${N}"
else
  say " Private mode: only reachable from the server itself."
  say " On your PC run:   ssh -L ${PORT}:127.0.0.1:${PORT} root@${IP}"
  say " Then open:        http://127.0.0.1:${PORT}"
fi
if [ -n "$NEWPW" ]; then
  say " Password : ${C}${NEWPW}${N}   (change it in Settings; forgot it: nilana-panel passwd)"
fi
say "${G}==========================================${N}"
