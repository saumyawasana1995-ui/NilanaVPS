#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_PATH=/usr/local/sbin/nilana-vps
log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'; }

status() {
  printf '%-20s %s\n' SERVICE STATUS
  printf '%-20s %s\n' '--------------------' '------'
  local unit
  for unit in ssh dropbear stunnel4 squid nilana-badvpn fail2ban; do
    if systemctl is-active --quiet "$unit"; then
      printf '%-20s %s\n' "$unit" active
    else
      printf '%-20s %s\n' "$unit" inactive
    fi
  done
  printf '\nListening sockets:\n'
  ss -lntup 2>/dev/null | grep -E ':(22|442|443|445|555|3128|7300|8000|8080)([[:space:]]|$)' || true
}

restore_or_remove() {
  local file=$1
  if [[ -e "${file}.nilana.bak" ]]; then
    mv -f -- "${file}.nilana.bak" "$file"
    log "Restored $file"
  else
    case "$file" in
      /etc/issue.net|/etc/ssh/sshd_config.d/00-nilana.conf|/etc/fail2ban/jail.d/nilana.local|/etc/sysctl.d/99-nilana-network.conf)
        rm -f -- "$file"
        log "Removed $file"
        ;;
      *)
        log "No backup found for $file; left it in place. Review it manually if needed."
        ;;
    esac
  fi
}

uninstall() {
  require_root
  if [[ ${1:-} != --yes ]]; then
    [[ -t 0 ]] || die 'Non-interactive uninstall requires: nilana-vps uninstall --yes'
    read -r -p 'Restore/remove Nilana VPS customizations? Type UNINSTALL to continue: ' answer
    [[ $answer == UNINSTALL ]] || die 'Uninstall cancelled.'
  fi

  log 'Stopping Nilana BadVPN service'
  systemctl disable --now nilana-badvpn.service 2>/dev/null || true

  local file
  for file in \
    /etc/issue.net \
    /etc/ssh/sshd_config.d/00-nilana.conf \
    /etc/ssh/sshd_config \
    /etc/default/dropbear \
    /etc/stunnel/stunnel.conf \
    /etc/default/stunnel4 \
    /etc/squid/squid.conf \
    /etc/fail2ban/jail.d/nilana.local \
    /etc/sysctl.d/99-nilana-network.conf; do
    restore_or_remove "$file"
  done

  rm -f /etc/systemd/system/nilana-badvpn.service \
    /usr/local/sbin/nilana-udpgw \
    /etc/stunnel/nilana.pem /etc/stunnel/nilana.key /etc/stunnel/nilana.crt
  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true

  if command -v sshd >/dev/null 2>&1 && sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl try-restart ssh 2>/dev/null || true
  else
    log 'SSH config test failed; leaving the SSH daemon untouched.'
  fi
  systemctl try-restart dropbear stunnel4 squid fail2ban 2>/dev/null || true
  rm -f -- "$MANAGER_PATH"

  cat <<'DONE'

Nilana VPS customizations have been removed/restored where backups exist.
Packages and firewall rules were left unchanged. Packages are not purged because
some may have been present before Nilana or may be used by other software.
DONE
}

show_help() {
  cat <<'HELP'
Nilana VPS management

Usage:
  nilana-vps               Show an interactive management menu
  nilana-vps status        Show service status and relevant listening sockets
  nilana-vps uninstall     Confirm and uninstall Nilana customizations
  nilana-vps uninstall --yes  Confirm non-interactively
  nilana-vps help          Show this help

Install this command from the repository with:
  sudo bash nilana-vps-manager.sh install
HELP
}

case "${1:-menu}" in
  install)
    require_root
    [[ -f "$0" ]] || die 'Cannot locate manager script to install.'
    install -m 0755 -- "$0" "$MANAGER_PATH"
    log "Installed management command: $MANAGER_PATH"
    printf 'Run: nilana-vps status  or  sudo nilana-vps uninstall\n'
    ;;
  status)
    status
    ;;
  uninstall)
    uninstall "${2:-}"
    ;;
  help|-h|--help)
    show_help
    ;;
  menu)
    [[ -t 0 ]] || { show_help; exit 0; }
    while true; do
      printf '\n=== Nilana VPS Management ===\n1) Service status\n2) Uninstall Nilana VPS\n0) Exit\n'
      read -r -p 'Select: ' choice
      case "$choice" in
        1) status ;;
        2) uninstall ;;
        0) exit 0 ;;
        *) printf 'Invalid selection.\n' ;;
      esac
    done
    ;;
  *)
    show_help >&2
    exit 2
    ;;
esac
