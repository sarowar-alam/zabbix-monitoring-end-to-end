#!/bin/bash
# =============================================================================
# Zabbix Sender — Scheduled Task Lifecycle Wrapper (Linux)
# =============================================================================
# Wraps any shell command and reports its lifecycle status to Zabbix via sender.
#
# Alert lifecycle (dead man's switch pattern):
#   Task STARTS    → sends value 1 → Zabbix raises WARNING  "Task is running"
#   Task SUCCEEDS  → sends value 0 → WARNING auto-resolves  (OK)
#   Task FAILS     → sends value 2 → Zabbix raises HIGH     "Task FAILED"
#                                     stays HIGH until next successful run
#
# Trapper item key format: scheduled.task.status[<task-name>]
# Values: 0=OK/idle, 1=running, 2=failed
#
# Usage:
#   /opt/zabbix/task-linux.sh <TASK_NAME> <COMMAND> [ARGS...]
#
# Examples:
#   /opt/zabbix/task-linux.sh "nightly-backup"  "/usr/local/bin/backup.sh" --full
#   /opt/zabbix/task-linux.sh "db-maintenance"  "mysqldump -u root mydb > /tmp/dump.sql"
#
# Cron examples (edit with: crontab -e):
#   # Run nightly backup at 2am, report status to Zabbix
#   0 2 * * * /opt/zabbix/task-linux.sh "nightly-backup" "/usr/local/bin/backup.sh"
#
#   # Run DB maintenance every Sunday at 3am
#   0 3 * * 0 /opt/zabbix/task-linux.sh "db-maintenance" "/usr/local/bin/db-maint.sh"
#
# Configuration:
#   Reads /etc/zabbix/sender.conf — created by install-agent-linux-*.sh
#   Override by setting env vars: ZABBIX_TARGET_IP, ZABBIX_TARGET_PORT, ZABBIX_HOSTNAME
# =============================================================================

set -euo pipefail

# ── Config from sender.conf or environment ────────────────────────────────────
SENDER_CONF="/etc/zabbix/sender.conf"
if [[ -f "${SENDER_CONF}" ]]; then
  # shellcheck source=/dev/null
  source "${SENDER_CONF}"
fi

# Environment variable overrides (or defaults if sender.conf missing)
ZABBIX_TARGET_IP="${ZABBIX_TARGET_IP:-REPLACE_WITH_PROXY_OR_SERVER_IP}"
ZABBIX_TARGET_PORT="${ZABBIX_TARGET_PORT:-10051}"
ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-REPLACE_WITH_HOST_HOSTNAME}"

# ── Arguments ─────────────────────────────────────────────────────────────────
TASK_NAME="${1:?ERROR: First argument is required: task name (e.g. 'nightly-backup')}"
shift
if [[ $# -lt 1 ]]; then
  echo "ERROR: Second argument is required: the command to run." >&2
  echo "Usage: $0 <task-name> <command> [args...]" >&2
  exit 1
fi

ITEM_KEY="scheduled.task.status[${TASK_NAME}]"
LOG_PREFIX="[zabbix-task-wrapper][${TASK_NAME}]"

# ── Sender function ───────────────────────────────────────────────────────────
send_status() {
  local status_value="$1"  # 0=OK, 1=running, 2=failed
  local status_label
  case "${status_value}" in
    0) status_label="OK" ;;
    1) status_label="RUNNING" ;;
    2) status_label="FAILED" ;;
    *) status_label="UNKNOWN" ;;
  esac

  echo "${LOG_PREFIX} Sending status=${status_value} (${status_label}) to ${ZABBIX_TARGET_IP}:${ZABBIX_TARGET_PORT}"

  if command -v zabbix_sender &>/dev/null; then
    zabbix_sender \
      -z "${ZABBIX_TARGET_IP}" \
      -p "${ZABBIX_TARGET_PORT}" \
      -s "${ZABBIX_HOSTNAME}" \
      -k "${ITEM_KEY}" \
      -o "${status_value}" \
      --source-address "" 2>&1 | tail -1 || true
  else
    echo "${LOG_PREFIX} WARNING: zabbix_sender not found — status NOT sent." >&2
  fi
}

# ── Main Execution ─────────────────────────────────────────────────────────────
COMMAND=("$@")
echo "${LOG_PREFIX} Starting: ${COMMAND[*]}"

# Signal: task is starting
send_status 1

# Run the actual command
EXIT_CODE=0
"${COMMAND[@]}" || EXIT_CODE=$?

if [[ ${EXIT_CODE} -eq 0 ]]; then
  echo "${LOG_PREFIX} Completed successfully (exit 0)"
  send_status 0
else
  echo "${LOG_PREFIX} FAILED with exit code ${EXIT_CODE}" >&2
  send_status 2
fi

exit ${EXIT_CODE}
