#!/usr/bin/env bash
set -euo pipefail

##############################################
# 0) Verify OS is Ubuntu 24.04 (noble)
##############################################

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  echo "Error: cannot read /etc/os-release."
  exit 1
fi

if ! [[ "$ID" == "ubuntu" && ( "$VERSION_ID" == "24.04" || "${VERSION_CODENAME:-}" == "noble" ) ]]; then
  echo "Error: This installer only supports Ubuntu 24.04 (noble)."
  exit 1
fi

echo "[1/12] OS check OK (Ubuntu 24.04 / noble)."


##############################################
# 1) Ensure correct timezone
##############################################

echo "[2/12] Setting timezone to Europe/Amsterdam..."
sudo timedatectl set-timezone Europe/Amsterdam
sudo timedatectl set-ntp true


##############################################
# 2) FORCE REMOVE MONO + FIX BROKEN DPKG STATE
##############################################
# Cloud-init images often contain half-installed mono packages.
# dpkg --configure -a would normally try to COMPLETE Mono, so we block that.

echo "[3/12] Removing Mono + repairing dpkg state..."

# Stop unattended upgrade locks
sudo systemctl stop unattended-upgrades || true

# Force remove all mono packages WITHOUT dependency resolution
MONO_PACKAGES=$(dpkg -l | awk '/^(ii|hi|rc)/ && $2 ~ /(mono|cli-common|ca-certificates-mono)/ {print $2}')
if [[ -n "$MONO_PACKAGES" ]]; then
  echo "[INFO] Force-removing existing Mono packages..."
  sudo dpkg --remove --force-remove-reinstreq --force-depends $MONO_PACKAGES || true
  sudo dpkg --purge --force-all $MONO_PACKAGES || true
fi

# Clean apt state
sudo rm -f /var/lib/dpkg/updates/*
sudo rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock* /var/cache/apt/archives/lock || true

# DO NOT RUN apt -f install (would reinstall Mono)
# Instead only fix dpkg internal state:
sudo dpkg --configure -a || true

# Light autoremove AFTER purge
sudo apt-get autoremove -y || true


##############################################
# 3) Install Zabbix Repository
##############################################

echo "[4/12] Downloading Zabbix 7.4 repository package..."
REPO_DEB="zabbix-release_latest_7.4+ubuntu24.04_all.deb"
wget -q "https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/${REPO_DEB}"

echo "[5/12] Installing Zabbix repository..."
sudo dpkg -i "$REPO_DEB" || sudo dpkg --configure -a

echo "[6/12] Updating APT package index..."
sudo apt update -y


##############################################
# 4) Install Zabbix Proxy (AFTER repo)
##############################################

echo "[7/12] Installing Zabbix Proxy (SQLite)..."
sudo apt install -y zabbix-proxy-sqlite3


##############################################
# 5) Parse optional --server argument or ask interactively
##############################################

echo "[8/12] Configure Zabbix Server IP..."

ZBX_SERVER_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server|-s)
      if [[ -n "${2:-}" ]]; then
        ZBX_SERVER_IP="$2"
        shift 2
      else
        echo "ERROR: Missing value after --server"
        exit 1
      fi
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$ZBX_SERVER_IP" ]]; then
  echo
  read -rp "Enter the IP address of the Main Zabbix Server (IPv4): " ZBX_SERVER_IP
fi

if ! [[ "$ZBX_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: Invalid IPv4 address: $ZBX_SERVER_IP"
  exit 1
fi

echo "[INFO] Using Zabbix Server IP: ${ZBX_SERVER_IP}"


##############################################
# 5b) Determine hostname automatically
##############################################

PROXY_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
echo "[INFO] Using system hostname: ${PROXY_HOSTNAME}"


##############################################
# 6) Paths
##############################################
CONF="/etc/zabbix/zabbix_proxy.conf"
PSK_FILE="/etc/zabbix/psk.key"
DB_PATH="/var/lib/zabbix/zabbix_proxy.sqlite3"
LOG_FILE="/var/log/zabbix/zabbix_proxy.log"
OVERRIDE_DIR="/etc/systemd/system/zabbix-proxy.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"


##############################################
# 7) Create required directories
##############################################

echo "[9/12] Preparing directories..."
sudo install -d -m 0755 /etc/zabbix /var/lib/zabbix /var/log/zabbix
sudo chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix || true


##############################################
# 8) Generate PSK (show BEFORE starting proxy)
##############################################

echo "[10/12] Generating TLS PSK..."

if command -v openssl >/dev/null 2>&1; then
  PSK_VAL="$(openssl rand -hex 32)"
else
  PSK_VAL="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

echo "$PSK_VAL" | sudo tee "$PSK_FILE" >/dev/null
sudo chmod 600 "$PSK_FILE"


##############################################
# 9) Systemd override (Type=forking)
##############################################

echo "[11/12] Applying systemd override..."

sudo mkdir -p "$OVERRIDE_DIR"
sudo tee "$OVERRIDE_FILE" >/dev/null <<'EOF'
[Service]
Type=forking
PIDFile=/run/zabbix/zabbix_proxy.pid

ExecStart=
ExecStart=/usr/sbin/zabbix_proxy -c /etc/zabbix/zabbix_proxy.conf

ExecStop=
ExecStop=/bin/kill -TERM $MAINPID
EOF

sudo systemctl daemon-reload


##############################################
# 10) Write proxy config
##############################################

echo "[12/12] Writing Zabbix Proxy configuration..."

sudo tee "$CONF" >/dev/null <<EOF
ProxyMode=0
Server=${ZBX_SERVER_IP}
Hostname=${PROXY_HOSTNAME}

DBName=${DB_PATH}

LogType=file
LogFile=${LOG_FILE}
DebugLevel=3

ProxyOfflineBuffer=24
ProxyBufferMode=hybrid
ProxyMemoryBufferSize=16M
ProxyConfigFrequency=30
DataSenderFrequency=1

TLSConnect=psk
TLSPSKIdentity=${PROXY_HOSTNAME}
TLSPSKFile=${PSK_FILE}

User=zabbix
EOF

sudo chown zabbix:zabbix "$CONF" "$PSK_FILE"


##############################################
# 11) SHOW PSK BEFORE starting proxy (your requirement)
##############################################

echo
echo "=============================================="
echo "   ZABBIX PROXY REGISTRATION INFORMATION"
echo "=============================================="
echo "Proxy Name:        ${PROXY_HOSTNAME}"
echo "TLS PSK Identity:  ${PROXY_HOSTNAME}"
echo "TLS PSK Value:"
echo "    ${PSK_VAL}"
echo "=============================================="
echo "Zabbix Proxy configuration written to:"
echo "  $CONF"
echo "PSK stored in:"
echo "  $PSK_FILE"
echo "=============================================="
echo ">>> Proxy will start now <<<"
echo


##############################################
# 12) Start proxy service
##############################################
sudo systemctl enable zabbix-proxy --now
sudo systemctl restart zabbix-proxy

echo
systemctl status zabbix-proxy --no-pager -l || true