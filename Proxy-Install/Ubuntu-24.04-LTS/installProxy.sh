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
# 1) Ensure correct timezone (required for Active Proxy)
##############################################
echo "[2/12] Setting timezone to Europe/Amsterdam..."
sudo timedatectl set-timezone Europe/Amsterdam
sudo timedatectl set-ntp true


##############################################
# 2) Remove broken Mono dependencies (cloud-init issue)
#    Cloud-init minimal images sometimes come with partial Mono packages
#    which break dpkg/apt. Purge them early to avoid dependency hell.
##############################################
echo "[3/12] Removing preinstalled Mono packages (if any)..."
sudo apt-get purge -y 'mono-*' 'libmono-*' cli-common ca-certificates-mono || true
sudo apt-get autoremove -y || true
sudo dpkg --configure -a || true
sudo apt-get -f install -y || true


##############################################
# 3) Install Zabbix Repository (MUST be first)
##############################################
echo "[4/12] Downloading Zabbix 7.4 repository package..."
REPO_DEB="zabbix-release_latest_7.4+ubuntu24.04_all.deb"
wget -q "https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/${REPO_DEB}"

echo "[5/12] Installing Zabbix repository..."
sudo dpkg -i "$REPO_DEB" || sudo apt-get -f install -y

echo "[6/12] Updating APT package index..."
sudo apt update -y


##############################################
# 4) Install Zabbix Proxy (must happen AFTER repo)
##############################################
echo "[7/12] Installing Zabbix Proxy (SQLite)..."
sudo apt install -y zabbix-proxy-sqlite3


##############################################
# 5) Determine Zabbix Server IP (argument OR prompt)
##############################################
echo "[8/12] Configure Zabbix Server IP..."

ZBX_SERVER_IP=""

# Parse optional argument: --server <IP> or -s <IP>
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server|-s)
      if [[ -n "${2:-}" ]]; then
        ZBX_SERVER_IP="$2"
        shift 2
      else
        echo "ERROR: Missing value after --server"
        echo "Usage: sudo ./installProxy.sh [--server <IPv4>]"
        exit 1
      fi
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      echo "Usage: sudo ./installProxy.sh [--server <IPv4>]"
      exit 1
      ;;
  esac
done

# Prompt if not provided by argument
if [[ -z "$ZBX_SERVER_IP" ]]; then
  echo
  read -rp "Enter the IP address of the Main Zabbix Server (IPv4): " ZBX_SERVER_IP
fi

# Validate IPv4
if ! [[ "$ZBX_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: Invalid IPv4 address: $ZBX_SERVER_IP"
  exit 1
fi

echo "[INFO] Using Zabbix Server IP: ${ZBX_SERVER_IP}"


##############################################
# 5b) Get hostname / identity automatically
##############################################
PROXY_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
echo "[INFO] Using system hostname for identity: ${PROXY_HOSTNAME}"


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
sudo install -d -m 0755 /etc/zabbix
sudo install -d -m 0755 /var/lib/zabbix
sudo install -d -m 0755 /var/log/zabbix

if id zabbix >/dev/null 2>&1; then
  sudo chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix
fi


##############################################
# 8) Generate PSK (must be displayed BEFORE proxy start)
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
# 9) Apply systemd override (correct fork-mode)
##############################################
echo "[11/12] Applying systemd override (Type=forking)..."
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
##### ACTIVE PROXY #####
ProxyMode=0
Server=${ZBX_SERVER_IP}
Hostname=${PROXY_HOSTNAME}

##### DATABASE (SQLite) #####
DBName=${DB_PATH}

##### LOGGING #####
LogType=file
LogFile=${LOG_FILE}
DebugLevel=3

##### PERFORMANCE #####
ProxyOfflineBuffer=24
ProxyBufferMode=hybrid
ProxyMemoryBufferSize=16M
ProxyConfigFrequency=30
DataSenderFrequency=1

##### SECURITY (TLS PSK) #####
TLSConnect=psk
TLSPSKIdentity=${PROXY_HOSTNAME}
TLSPSKFile=${PSK_FILE}

##### SYSTEM #####
User=zabbix
EOF
sudo chown zabbix:zabbix "$CONF" "$PSK_FILE"


##############################################
# 11) IMPORTANT: SHOW PSK BEFORE STARTING PROXY
##############################################
echo
echo "=============================================="
echo "   ZABBIX PROXY REGISTRATION INFORMATION"
echo "=============================================="
echo
echo "Use these values in the Zabbix Frontend:"
echo
echo "Proxy Name (must match exactly):"
echo "    ${PROXY_HOSTNAME}"
echo
echo "TLS PSK Identity:"
echo "    ${PROXY_HOSTNAME}"
echo
echo "TLS PSK Value:"
echo "    ${PSK_VAL}"
echo
echo "=============================================="
echo "Files:"
echo " Config File : ${CONF}"
echo " PSK File    : ${PSK_FILE}"
echo " Override    : ${OVERRIDE_FILE}"
echo "=============================================="
echo
echo ">>> THE PROXY SERVICE WILL START NOW <<<"
echo


##############################################
# 12) Start Zabbix Proxy service
##############################################
sudo systemctl enable zabbix-proxy --now
sudo systemctl restart zabbix-proxy

echo
systemctl status zabbix-proxy --no-pager -l || true