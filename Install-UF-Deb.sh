#!/bin/bash
set -Eeuo pipefail
umask 077

# ========== CONFIGURATION ==========
DEPLOYMENT_SERVER="192.168.1.1:8089"

SPLUNK_USERNAME="admin"
SPLUNK_PASSWORD="CHANGE_ME"

SPLUNK_HOME="/opt/splunkforwarder"
PACKAGE="/opt/software/splunkforwarder.deb"
SERVICE_USER="splunkfwd"
SERVICE_GROUP="splunkfwd"
# ===================================

log() {
    echo "[$(date '+%F %T')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

[[ "$EUID" -eq 0 ]] || fail "Run as root"
[[ -f "$PACKAGE" ]] || fail "UF DEB package not found: $PACKAGE"
command -v dpkg >/dev/null 2>&1 || fail "dpkg not found"

# Install UF
if [[ ! -x "$SPLUNK_HOME/bin/splunk" ]]; then
    log "Installing Splunk Universal Forwarder"
    dpkg -i "$PACKAGE" || {
        command -v apt-get >/dev/null 2>&1 ||
            fail "Package installation failed"
        apt-get install -f -y ||
            fail "Dependency installation failed"
    }
fi

SPLUNK="$SPLUNK_HOME/bin/splunk"
[[ -x "$SPLUNK" ]] || fail "UF executable not found"

# Seed the first admin account before first startup.
# Do not overwrite an existing account database.
if [[ ! -s "$SPLUNK_HOME/etc/passwd" ]]; then
    mkdir -p "$SPLUNK_HOME/etc/system/local"

    cat > "$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = ${SPLUNK_USERNAME}
PASSWORD = ${SPLUNK_PASSWORD}
EOF

    chmod 600 "$SPLUNK_HOME/etc/system/local/user-seed.conf"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" \
        "$SPLUNK_HOME/etc/system/local"
fi

# Start UF
log "Starting Splunk UF"
"$SPLUNK" start --accept-license --answer-yes --no-prompt

# Configure Deployment Server
log "Configuring Deployment Server"
"$SPLUNK" set deploy-poll "$DEPLOYMENT_SERVER" \
    -auth "${SPLUNK_USERNAME}:${SPLUNK_PASSWORD}"

# Enable startup at boot
log "Checking Splunk boot-start service"

UNIT="SplunkForwarder.service"

if systemctl cat "$UNIT" >/dev/null 2>&1; then
    log "Existing systemd unit found: $UNIT"

    systemctl daemon-reload
    systemctl enable "$UNIT"

    log "Existing systemd service enabled successfully"
else
    log "Creating Splunk systemd service"

    "$SPLUNK_HOME/bin/splunk" enable boot-start \
        -systemd-managed 1 \
        -user splunkfwd \
        -group splunkfwd

    systemctl daemon-reload
    systemctl enable "$UNIT"

    log "Splunk systemd service created and enabled"
fi

# Verify
log "Checking UF status"
"$SPLUNK" status

log "Checking Deployment Client configuration"
"$SPLUNK" btool deploymentclient list --debug

log "Installation and configuration completed"
log "Deployment Server: $DEPLOYMENT_SERVER"
