!/usr/bin/env bash
set -euo pipefail
set -x

# Expect environment variables:
# RESTIC_REPOSITORY, RESTIC_PASSWORD, BACKUP_PATHS, USER_PASSWORD, SFTP_PASSWORD

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
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
restic check --read-data-subset=5%



