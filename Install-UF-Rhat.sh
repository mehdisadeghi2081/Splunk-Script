
#!/bin/bash

###############################################################################
# Splunk Universal Forwarder - RHEL Family
# ManageEngine Endpoint Central Deployment
# Run as: ROOT
# Service Account: ROOT
# Supported: RHEL / Oracle Linux / AlmaLinux / Rocky Linux / CentOS Stream
# ./install_splunk_uf.sh /opt/software/splunkforwarder.rpm
###############################################################################

set -Eeuo pipefail
umask 077

# ----------------------------- CONFIGURATION --------------------------------

SPLUNK_HOME="/opt/splunkforwarder"

DEPLOYMENT_SERVER="192.168.1.1:8089"

PACKAGE_PATH="${1:-/opt/software/splunkforwarder.rpm}"

SERVICE_NAME="SplunkForwarder"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

LOG_FILE="/var/log/splunk-uf-install.log"

# Set this through the deployment environment for a NEW installation.
# Do not put a real password directly in this script.
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"

# -----------------------------------------------------------------------------


# ----------------------------- LOGGING --------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%F %T')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

trap 'fail "Unexpected error at line $LINENO"' ERR


# ----------------------------- ROOT CHECK -----------------------------------

log "Starting Splunk UF installation"

if [[ "$EUID" -ne 0 ]]; then
    fail "This script must run as root"
fi

log "Running with root privileges"


# ----------------------------- OS CHECK -------------------------------------

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot identify operating system"
fi

source /etc/os-release

log "Detected OS: ${PRETTY_NAME:-Unknown}"

case "${ID:-}" in
    rhel|ol|rocky|almalinux|centos)
        log "Supported operating system detected"
        ;;
    *)
        case " ${ID_LIKE:-} " in
            *" rhel "*|*" fedora "*)
                log "RHEL-compatible operating system detected"
                ;;
            *)
                fail "Unsupported operating system: ${ID:-unknown}"
                ;;
        esac
        ;;
esac


# ----------------------------- PACKAGE MANAGER ------------------------------

if command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
else
    fail "Neither dnf nor yum is available"
fi

log "Package manager: $PKG_MANAGER"


# ----------------------------- PACKAGE CHECK --------------------------------

if [[ ! -f "$PACKAGE_PATH" ]]; then
    fail "RPM package not found: $PACKAGE_PATH"
fi

log "RPM package found: $PACKAGE_PATH"

if ! rpm -qp "$PACKAGE_PATH" >/dev/null 2>&1; then
    fail "Invalid RPM package"
fi

PACKAGE_NAME="$(rpm -qp --queryformat '%{NAME}' "$PACKAGE_PATH")"

log "RPM package name: $PACKAGE_NAME"


# ----------------------------- INSTALLATION ---------------------------------

if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then

    log "Existing Splunk installation detected"

    "$SPLUNK_HOME/bin/splunk" stop || true

    log "Skipping package installation"

else

    log "Installing Splunk Universal Forwarder"

    "$PKG_MANAGER" install -y "$PACKAGE_PATH" ||
        fail "Splunk RPM installation failed"

fi


# ----------------------------- SPLUNK VALIDATION ----------------------------

if [[ ! -x "$SPLUNK_HOME/bin/splunk" ]]; then
    fail "Splunk binary not found at $SPLUNK_HOME/bin/splunk"
fi

log "Splunk binary validated"


# ----------------------------- INITIAL ADMIN SETUP --------------------------

SEED_FILE="$SPLUNK_HOME/etc/system/local/user-seed.conf"
PASSWD_FILE="$SPLUNK_HOME/etc/passwd"

mkdir -p "$SPLUNK_HOME/etc/system/local"

if [[ ! -s "$PASSWD_FILE" ]]; then

    log "Initial Splunk administrator setup required"

    if [[ -z "$SPLUNK_ADMIN_PASSWORD" ]]; then
        fail "SPLUNK_ADMIN_PASSWORD must be provided for a fresh installation"
    fi

    if [[ "$SPLUNK_ADMIN_PASSWORD" == "CHANGE_ME" ]]; then
        fail "Default administrator password is not allowed"
    fi

    cat > "$SEED_FILE" <<EOF
[user_info]
USERNAME = admin
PASSWORD = ${SPLUNK_ADMIN_PASSWORD}
EOF

    chmod 600 "$SEED_FILE"

    log "Initial administrator seed file created"

else

    log "Existing Splunk administrator database detected"

fi


# ----------------------------- DEPLOYMENT SERVER ----------------------------

DEPLOYMENT_FILE="$SPLUNK_HOME/etc/system/local/deploymentclient.conf"

if [[ -f "$DEPLOYMENT_FILE" ]]; then

    cp -a "$DEPLOYMENT_FILE" \
        "${DEPLOYMENT_FILE}.backup.$(date +%Y%m%d%H%M%S)"

    log "Existing deploymentclient.conf backed up"

fi

cat > "$DEPLOYMENT_FILE" <<EOF
[deployment-client]

[target-broker:deploymentServer]
targetUri = ${DEPLOYMENT_SERVER}
EOF

chmod 600 "$DEPLOYMENT_FILE"

log "Deployment Server configured: $DEPLOYMENT_SERVER"


# ----------------------------- SYSTEMD UNIT ---------------------------------

log "Creating systemd service"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME" || true
fi

if [[ -f "$UNIT_FILE" ]]; then
    cp -a "$UNIT_FILE" "${UNIT_FILE}.backup.$(date +%Y%m%d%H%M%S)"
fi

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Splunk Universal Forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${SPLUNK_HOME}/var/run/splunk/splunkd.pid

ExecStart=${SPLUNK_HOME}/bin/splunk start --no-prompt --answer-yes
ExecStop=${SPLUNK_HOME}/bin/splunk stop

Restart=on-failure
RestartSec=10
TimeoutStartSec=360
TimeoutStopSec=360

LimitNOFILE=65536

# No User or Group directive:
# Splunk runs as root.

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$UNIT_FILE"

systemctl daemon-reload

systemctl enable "$SERVICE_NAME"

log "Systemd service configured"


# ----------------------------- START SPLUNK ---------------------------------

log "Starting Splunk Universal Forwarder"

systemctl start "$SERVICE_NAME" ||
    fail "Unable to start Splunk service"

sleep 10

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    fail "Splunk systemd service is not active"
fi

log "Splunk service is active"


# ----------------------------- SEED CLEANUP ---------------------------------

if [[ -f "$SEED_FILE" && -s "$PASSWD_FILE" ]]; then

    rm -f "$SEED_FILE"

    log "Initial administrator seed file removed"

fi


# ----------------------------- DEPLOYMENT CHECK -----------------------------

log "Checking Deployment Server connectivity"

DS_HOST="${DEPLOYMENT_SERVER%:*}"
DS_PORT="${DEPLOYMENT_SERVER##*:}"

if timeout 5 bash -c ">/dev/tcp/${DS_HOST}/${DS_PORT}" 2>/dev/null; then
    log "Deployment Server TCP connection successful"
else
    log "WARNING: Cannot connect to Deployment Server ${DEPLOYMENT_SERVER}"
fi


# ----------------------------- FINAL CHECKS ---------------------------------

log "Checking Splunk process"

if pgrep -f "$SPLUNK_HOME/bin/splunkd" >/dev/null 2>&1; then
    log "Splunk daemon process is running"
else
    fail "Splunk daemon process not found"
fi

log "Checking service execution identity"

SERVICE_PID="$(systemctl show -p MainPID --value "$SERVICE_NAME")"

if [[ "$SERVICE_PID" =~ ^[0-9]+$ ]] && (( SERVICE_PID > 0 )); then

    PROCESS_USER="$(ps -o user= -p "$SERVICE_PID" | xargs)"

    log "Splunk service process owner: $PROCESS_USER"

    if [[ "$PROCESS_USER" != "root" ]]; then
        fail "Splunk service is not running as root"
    fi

else
    fail "Cannot determine Splunk service MainPID"
fi


log "Checking Splunk configuration"

"$SPLUNK_HOME/bin/splunk" btool deploymentclient list --debug ||
    log "WARNING: Unable to execute btool deploymentclient"


log "Checking systemd status"

systemctl status "$SERVICE_NAME" --no-pager || true


# ----------------------------- COMPLETION -----------------------------------

log "======================================================"
log "Splunk Universal Forwarder installation completed"
log "Installation path: $SPLUNK_HOME"
log "Execution user: root"
log "Deployment Server: $DEPLOYMENT_SERVER"
log "Systemd service: $SERVICE_NAME"
log "Log file: $LOG_FILE"
log "======================================================"

exit 0
