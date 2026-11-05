
#!/bin/bash

###############################################################################
# Auditd Installation and Custom Rules Deployment
# Target OS: RHEL / Oracle Linux / AlmaLinux / Rocky Linux / CentOS Stream
# Deployment: ManageEngine Endpoint Central
# Execution: ROOT
#
# Usage:
# bash install_auditd_rhel.sh /path/to/custom-audit.rules
###############################################################################

set -Eeuo pipefail
umask 077

# ----------------------------- CONFIGURATION --------------------------------

RULES_SOURCE="${1:-}"

AUDIT_RULES_DIR="/etc/audit/rules.d"
AUDIT_RULES_FILE="${AUDIT_RULES_DIR}/99-custom.rules"

AUDIT_SERVICE="auditd"

# Matches the systemd unit created by the previous Splunk UF script.
SPLUNK_SERVICE="${SPLUNK_SERVICE:-SplunkForwarder}"

LOG_FILE="/var/log/auditd-deployment.log"

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

log "Starting Auditd deployment"

if [[ "$EUID" -ne 0 ]]; then
    fail "This script must run as root"
fi

log "Root privileges confirmed"


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
                fail "Unsupported OS: ${ID:-unknown}. RHEL family required."
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


# ----------------------------- RULE FILE CHECK ------------------------------

if [[ -z "$RULES_SOURCE" ]]; then
    fail "Usage: $0 /path/to/custom-audit.rules"
fi

if [[ ! -f "$RULES_SOURCE" ]]; then
    fail "Rules file not found: $RULES_SOURCE"
fi

if [[ ! -s "$RULES_SOURCE" ]]; then
    fail "Rules file is empty"
fi

log "Rules file found: $RULES_SOURCE"


# ----------------------------- INSTALL AUDITD -------------------------------

if rpm -q audit >/dev/null 2>&1; then

    log "Auditd package is already installed"

else

    log "Installing Auditd package"

    "$PKG_MANAGER" install -y audit ||
        fail "Auditd installation failed"

fi


# ----------------------------- VALIDATE BINARIES ----------------------------

if ! command -v auditctl >/dev/null 2>&1; then
    fail "auditctl command not found"
fi

if ! command -v augenrules >/dev/null 2>&1; then
    fail "augenrules command not found"
fi

log "Auditd binaries validated"


# ----------------------------- ENABLE AUDITD -------------------------------

log "Enabling Auditd service"

systemctl enable "$AUDIT_SERVICE" ||
    fail "Unable to enable Auditd service"

if ! systemctl is-active --quiet "$AUDIT_SERVICE"; then

    log "Starting Auditd service"

    systemctl start "$AUDIT_SERVICE" ||
        fail "Unable to start Auditd service"

fi

if ! systemctl is-active --quiet "$AUDIT_SERVICE"; then
    fail "Auditd service is not active"
fi

log "Auditd service is active"


# ----------------------------- CHECK IMMUTABLE MODE -------------------------

log "Checking current Audit subsystem status"

AUDIT_STATUS="$(auditctl -s 2>/dev/null)" ||
    fail "Unable to read Audit subsystem status"

AUDIT_ENABLED="$(awk '$1 == "enabled" {print $2}' <<< "$AUDIT_STATUS")"

log "Current Audit enabled status: ${AUDIT_ENABLED:-unknown}"

if [[ "$AUDIT_ENABLED" == "2" ]]; then
    fail "Audit rules are immutable (enabled=2). Reboot is required before changing rules."
fi


# ----------------------------- BACKUP EXISTING RULES ------------------------

mkdir -p "$AUDIT_RULES_DIR"

BACKUP_FILE=""

if [[ -f "$AUDIT_RULES_FILE" ]]; then

    BACKUP_FILE="${AUDIT_RULES_FILE}.backup.$(date +%Y%m%d%H%M%S)"

    cp -a "$AUDIT_RULES_FILE" "$BACKUP_FILE" ||
        fail "Unable to backup existing rules"

    log "Existing rules backed up: $BACKUP_FILE"

else

    log "No previous custom rules file found"

fi


# ----------------------------- DEPLOY NEW RULES ------------------------------

TEMP_RULES="${AUDIT_RULES_FILE}.tmp.$$"

cp "$RULES_SOURCE" "$TEMP_RULES" ||
    fail "Unable to copy new rules"

chown root:root "$TEMP_RULES"
chmod 640 "$TEMP_RULES"

mv -f "$TEMP_RULES" "$AUDIT_RULES_FILE" ||
    fail "Unable to deploy new rules"

log "New rules deployed to $AUDIT_RULES_FILE"


# ----------------------------- LOAD RULES -----------------------------------

log "Loading Audit rules using augenrules"

if augenrules --load; then

    log "Audit rules loaded successfully"

else

    log "ERROR: Unable to load new Audit rules"

    if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then

        log "Restoring previous rules"

        cp -a "$BACKUP_FILE" "$AUDIT_RULES_FILE"

    else

        log "Removing newly deployed rules"

        rm -f "$AUDIT_RULES_FILE"

    fi

    if augenrules --load; then
        log "Previous rules restored and reloaded"
    else
        log "CRITICAL: Previous rules could not be reloaded"
    fi

    fail "New Audit rules deployment failed"

fi


# ----------------------------- VERIFY RULES ---------------------------------

log "Verifying loaded Audit rules"

if ! auditctl -l; then
    fail "Unable to list active Audit rules"
fi

RULE_COUNT="$(auditctl -l | grep -vc '^No rules$' || true)"

log "Active Audit rule count: $RULE_COUNT"

if [[ "$RULE_COUNT" -eq 0 ]]; then
    log "WARNING: No active Audit rules detected"
fi


# ----------------------------- VERIFY AUDITD -------------------------------

if ! systemctl is-active --quiet "$AUDIT_SERVICE"; then
    fail "Auditd service is not active after rule loading"
fi

log "Auditd verification successful"


# ----------------------------- SPLUNK SERVICE CHECK -------------------------

log "Checking Splunk Universal Forwarder service"

if ! systemctl cat "$SPLUNK_SERVICE" >/dev/null 2>&1; then
    fail "Splunk service not found: $SPLUNK_SERVICE"
fi


# ----------------------------- RESTART SPLUNK -------------------------------

log "Restarting Splunk Universal Forwarder"

systemctl restart "$SPLUNK_SERVICE" ||
    fail "Unable to restart Splunk Universal Forwarder"

sleep 5

if ! systemctl is-active --quiet "$SPLUNK_SERVICE"; then
    fail "Splunk Universal Forwarder did not become active after restart"
fi

log "Splunk Universal Forwarder restarted successfully"


# ----------------------------- FINAL STATUS ---------------------------------

log "================ FINAL STATUS ================"

systemctl status "$AUDIT_SERVICE" --no-pager || true

systemctl status "$SPLUNK_SERVICE" --no-pager || true

log "Auditd rules file: $AUDIT_RULES_FILE"
log "Auditd service: ACTIVE"
log "Splunk service: ACTIVE"
log "Auditd rule count: $RULE_COUNT"
log "Log file: $LOG_FILE"

log "Auditd deployment completed successfully"

exit 0
