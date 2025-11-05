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
if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" || -z "${BACKUP_GROUPS:-}" ]]; then
  echo "[$(timestamp)] ❌ Missing required environment variables"
  exit 1
fi

GROUP_FILTER="${1:-}"  # Optional argument for a specific group
groups=$(echo "$BACKUP_GROUPS" | jq -c '.[]')

for group in $groups; do
  name=$(echo "$group" | jq -r '.name')

  # If called with an argument, skip other groups
  if [[ -n "$GROUP_FILTER" && "$GROUP_FILTER" != "$name" ]]; then
    continue
  fi

  paths=$(echo "$group" | jq -r '.paths | join(" ")')
  retention=$(echo "$group" | jq -r '.retention')

  echo "[$(timestamp)] → Backing up group [$name] ($paths)"
  if restic -r "$RESTIC_REPOSITORY" backup $patsh --tag "$name" --verbose; then
    echo "[$(timestamp)] ✅ Backup for group [$name] completed."
  else
    echo "[$(timestamp)] ❌ Backup for group [$name] failed."
    continue
  fi

  # Apply retention
  HOURLY=$(echo "$retention" | jq -r '.keep_hourly // 0')
  DAILY=$(echo "$retention" | jq -r '.keep_daily // 7')
  WEEKLY=$(echo "$retention" | jq -r '.keep_weekly // 4')
  MONTHLY=$(echo "$retention" | jq -r '.keep_monthly // 6')
  YEARLY=$(echo "$retention" | jq -r '.keep_yearly // 1')

  echo "[$(timestamp)] 🧹 Applying retention for [$name]"
  restic forget \
    --tag "$name" \
    --keep-hourly "$HOURLY" \
    --keep-daily "$DAILY" \
    --keep-weekly "$WEEKLY" \
    --keep-monthly "$MONTHLY" \
    --keep-yearly "$YEARLY" \
    --prune
done

restic check --read-data-subset=5%
echo "[$(timestamp)] ✅ All backups done."