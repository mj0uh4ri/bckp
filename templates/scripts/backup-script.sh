!/usr/bin/env bash
set -euo pipefail
set -x

# Expect environment variables:
# RESTIC_REPOSITORY, RESTIC_PASSWORD, BACKUP_PATHS, USER_PASSWORD, SFTP_PASSWORD
# Load environment variables (if not already sourced by cron)
if [[ -f "$HOME/restic.env" ]]; then
  . "$HOME/restic.env"
fi


LOG_FILE=${LOG_FILE:-/var/log/restic-backup.log}
mkdir -p "$(dirname "$LOG_FILE")"
#exec >>"$LOG_FILE" 2>&1

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(timestamp)] === Starting Restic backup ==="

# Safety checks
if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
  echo "[$(timestamp)] ❌ Missing RESTIC_REPOSITORY or RESTIC_PASSWORD"
  exit 1
fi

if [[ -z "${BACKUP_PATHS:-}" ]]; then
  echo "[$(timestamp)] ⚠️ No backup paths specified."
  exit 0
fi

read -r -a PATHS <<< "$BACKUP_PATHS"

# --- Option 1: SSH keys (recommended)
# if restic backup "${PATHS[@]}" --tag automated; then
#   echo "[$(timestamp)] ✅ Backup completed successfully."
# else
#   echo "[$(timestamp)] ❌ Backup failed."
#   exit 1
# fi

# --- Option 2: Fallback with sshpass (if needed)
restic -r "$RESTIC_REPOSITORY" backup "${PATHS[@]}" --verbose --tag automated

# Retention
# Retention cleanup – machine-specific values
restic forget \
  --keep-hourly "${KEEP_HOURLY:-0}" \
  --keep-daily "${KEEP_DAILY:-7}" \
  --keep-weekly "${KEEP_WEEKLY:-4}" \
  --keep-monthly "${KEEP_MONTHLY:-6}" \
  --keep-yearly "${KEEP_YEARLY:-1}" \
  --prune

restic check --read-data-subset=1/50
echo "[$(timestamp)] Retention applied: H=${KEEP_HOURLY:-0}, D=${KEEP_DAILY:-7}, W=${KEEP_WEEKLY:-4}, M=${KEEP_MONTHLY:-6}, Y=${KEEP_YEARLY:-1}"



