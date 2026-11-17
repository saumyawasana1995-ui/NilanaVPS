#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_PATH=/usr/local/sbin/nilana-vps
INSTALLER_PATH=/usr/local/sbin/nilana-install.sh
REPO_RAW=https://raw.githubusercontent.com/saumyawasana1995-ui/NilanaVPS/main
log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'; }

status() {
  printf '%-20s %s\n' SERVICE STATUS
  printf '%-20s %s\n' '--------------------' '------'
  local unit
  for unit in ssh nilana-dropbear nilana-stunnel squid nilana-badvpn; do
    if systemctl is-active --quiet "$unit"; then
      printf '%-20s %s\n' "$unit" active
    else
      printf '%-20s %s\n' "$unit" inactive
    fi
  done
  printf '\nListening sockets:\n'
  ss -lntup 2>/dev/null | grep -E ':(22|442|443|445|555|3128|7300|8000|8080)([[:space:]]|$)' || true
}

update_system() {
  require_root
  if [[ ${1:-} != --yes ]]; then
    [[ -t 0 ]] || die 'Non-interactive update requires: nilana-vps update --yes'
    cat <<'NOTICE'
This downloads the latest installer and manager scripts from the NilanaVPS
GitHub repository, validates their Bash syntax, then reruns the installer.
The installer reapplies Nilana-managed configuration and restarts its services.
It is designed to preserve user accounts; make a VPS snapshot/backup first.
NOTICE
    read -r -p 'Type UPDATE to continue: ' answer
    [[ $answer == UPDATE ]] || die 'Update cancelled.'
  fi

  local work
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN
  log 'Downloading the latest Nilana VPS scripts'
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
    "$REPO_RAW/install.sh" -o "$work/install.sh" || die 'Could not download the installer.'
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
    "$REPO_RAW/nilana-vps-manager.sh" -o "$work/nilana-vps-manager.sh" || die 'Could not download the manager.'
  bash -n "$work/install.sh" || die 'Downloaded installer failed Bash syntax validation; nothing was applied.'
  bash -n "$work/nilana-vps-manager.sh" || die 'Downloaded manager failed Bash syntax validation; nothing was applied.'

  install -D -m 0755 "$work/install.sh" "$INSTALLER_PATH"
  install -D -m 0755 "$work/nilana-vps-manager.sh" "$MANAGER_PATH"
  log 'Scripts validated and installed. Starting the latest installer now.'
  "$INSTALLER_PATH" --yes --no-upgrade
  log 'Update run finished. The installer refreshed the main menu and managed services.'
  printf 'If you were using the separate manager menu, exit and run %s again to load its updated copy.\n' "$MANAGER_PATH"
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

  log 'Stopping Nilana services'
  systemctl disable --now nilana-badvpn.service nilana-stunnel.service nilana-dropbear.service 2>/dev/null || true

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
    /etc/systemd/system/nilana-stunnel.service \
    /etc/systemd/system/nilana-dropbear.service \
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
  rm -f -- "$MANAGER_PATH" "$INSTALLER_PATH"

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
  nilana-vps                   Show the management menu
  nilana-vps status            Show service status and relevant listening sockets
  nilana-vps update            Download and run the latest Nilana VPS installer
  nilana-vps update --yes      Run update without interactive confirmation
  nilana-vps uninstall         Confirm and uninstall Nilana customizations
  nilana-vps uninstall --yes   Uninstall without interactive confirmation
  nilana-vps help              Show this help

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
    printf 'Run: nilana-vps status, nilana-vps update, or sudo nilana-vps uninstall\n'
    ;;
  status)
    status
    ;;
  update)
    update_system "${2:-}"
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
      printf '\n=== Nilana VPS Management ===\n1) Service status\n2) Update Nilana VPS\n3) Uninstall Nilana VPS\n0) Exit\n'
      read -r -p 'Select: ' choice
      case "$choice" in
        1) status ;;
        2) update_system ;;
        3) uninstall ;;
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
