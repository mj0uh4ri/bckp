#!/usr/bin/env bash
set -euo pipefail
# Restic Backup Script with autonomous Vault password retrieval
# This script expects these environment variables to be present (via ~/restic.env or environment):
#   VAULT_ADDR, VAULT_SECRET_PATH, VAULT_TOKEN, RESTIC_REPOSITORY, BACKUP_GROUPS
# It logs to LOG_FILE (defaults to /home/mjouhari/restic-backup.log)

# Load environment if present
if [[ -f "${HOME}/restic.env" ]]; then
  # shellcheck disable=SC1090
  source "${HOME}/restic.env"
fi

LOG_FILE="${LOG_FILE:-/home/mjouhari/restic-backup.log}"
mkdir -p "$(dirname "$LOG_FILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(timestamp)] === Starting Restic backup ===" | tee -a "$LOG_FILE"

# Basic validation
if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  echo "[$(timestamp)] ✗ ERROR: RESTIC_REPOSITORY not set" | tee -a "$LOG_FILE"
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "[$(timestamp)] ✗ ERROR: VAULT_ADDR not set" | tee -a "$LOG_FILE"
  exit 1
fi

if [[ -z "${VAULT_SECRET_PATH:-}" ]]; then
  echo "[$(timestamp)] ✗ ERROR: VAULT_SECRET_PATH not set" | tee -a "$LOG_FILE"
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "[$(timestamp)] ✗ ERROR: VAULT_TOKEN not set in user environment" | tee -a "$LOG_FILE"
  exit 1
fi

if [[ -z "${BACKUP_GROUPS:-}" ]]; then
  echo "[$(timestamp)] ✗ ERROR: BACKUP_GROUPS not set" | tee -a "$LOG_FILE"
  exit 1
fi

# Fetch password from Vault (supports vault CLI kv get)
# Prefer using the Vault CLI which will use VAULT_ADDR and VAULT_TOKEN from env
echo "[$(timestamp)] → Authenticating to Vault and fetching password..." | tee -a "$LOG_FILE"

RESTIC_PASSWORD=$(vault kv get -field=restic_pass "$VAULT_SECRET_PATH" 2>/dev/null) || {
  echo "[$(timestamp)] ✗ ERROR: Failed to fetch password from Vault" | tee -a "$LOG_FILE"
  exit 1
}

if [[ -z "$RESTIC_PASSWORD" ]]; then
  echo "[$(timestamp)] ✗ ERROR: Empty password retrieved from Vault" | tee -a "$LOG_FILE"
  exit 1
fi

echo "[$(timestamp)] ✓ Successfully authenticated to Vault" | tee -a "$LOG_FILE"
export RESTIC_PASSWORD

# Process backup groups
if [[ -n "${BACKUP_GROUPS_FILE:-}" && -f "${BACKUP_GROUPS_FILE}" ]]; then
  BACKUP_GROUPS=$(cat "${BACKUP_GROUPS_FILE}")
fi

groups=$(echo "$BACKUP_GROUPS" | jq -c '.[]') || {
  echo "[$(timestamp)] ✗ ERROR: Failed to parse BACKUP_GROUPS as JSON" | tee -a "$LOG_FILE"
  echo "[$(timestamp)]   If you used a file, ensure BACKUP_GROUPS_FILE points to it and it's readable." | tee -a "$LOG_FILE"
  echo "[$(timestamp)]   Raw BACKUP_GROUPS value:" | tee -a "$LOG_FILE"
  echo "$BACKUP_GROUPS" | head -40 | sed 's/^/    /' | tee -a "$LOG_FILE"
  exit 1
}

total_groups=0
successful_groups=0
failed_groups=0

for group in $groups; do
  total_groups=$((total_groups + 1))
  group_name=$(echo "$group" | jq -r '.name')
  paths=$(echo "$group" | jq -r '.paths | join(" ")')

  if [[ -z "$paths" ]]; then
    echo "[$(timestamp)] ⚠ WARNING: Group [$group_name] has no paths, skipping" | tee -a "$LOG_FILE"
    continue
  fi

  echo "[$(timestamp)] ▶ Backing up group [$group_name]" | tee -a "$LOG_FILE"
  echo "    Paths: $paths" | tee -a "$LOG_FILE"

  if restic -r "$RESTIC_REPOSITORY" backup $paths --tag "$group_name" 2>&1 | tee -a "$LOG_FILE"; then
    echo "[$(timestamp)] ✓ Backup for [$group_name] completed successfully" | tee -a "$LOG_FILE"
    successful_groups=$((successful_groups + 1))
  else
    echo "[$(timestamp)] ✗ Backup for [$group_name] FAILED" | tee -a "$LOG_FILE"
    failed_groups=$((failed_groups + 1))
    continue
  fi

  # Apply retention policy
  retention=$(echo "$group" | jq -r '.retention')
  HOURLY=$(echo "$retention" | jq -r '.keep_hourly // 0')
  DAILY=$(echo "$retention" | jq -r '.keep_daily // 7')
  WEEKLY=$(echo "$retention" | jq -r '.keep_weekly // 4')
  MONTHLY=$(echo "$retention" | jq -r '.keep_monthly // 6')
  YEARLY=$(echo "$retention" | jq -r '.keep_yearly // 1')

  echo "[$(timestamp)] 🧹 Applying retention policy for [$group_name]" | tee -a "$LOG_FILE"
  echo "    Keep: ${HOURLY} hourly, ${DAILY} daily, ${WEEKLY} weekly, ${MONTHLY} monthly, ${YEARLY} yearly" | tee -a "$LOG_FILE"

  if restic -r "$RESTIC_REPOSITORY" forget \
    --tag "$group_name" \
    --keep-hourly "$HOURLY" \
    --keep-daily "$DAILY" \
    --keep-weekly "$WEEKLY" \
    --keep-monthly "$MONTHLY" \
    --keep-yearly "$YEARLY" \
    --prune 2>&1 | tee -a "$LOG_FILE"; then
    echo "[$(timestamp)] ✓ Retention applied for [$group_name]" | tee -a "$LOG_FILE"
  else
    echo "[$(timestamp)] ⚠ WARNING: Retention failed for [$group_name], but backup succeeded" | tee -a "$LOG_FILE"
  fi

done

# Repository check
echo "[$(timestamp)] ▶ Running repository integrity check" | tee -a "$LOG_FILE"

if restic -r "$RESTIC_REPOSITORY" check --read-data-subset=5% 2>&1 | tee -a "$LOG_FILE"; then
  echo "[$(timestamp)] ✓ Repository integrity check passed" | tee -a "$LOG_FILE"
else
  echo "[$(timestamp)] ⚠ WARNING: Repository integrity check failed" | tee -a "$LOG_FILE"
fi

# Summary
echo "[$(timestamp)] ════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "[$(timestamp)] BACKUP SUMMARY" | tee -a "$LOG_FILE"
echo "[$(timestamp)]   Total groups: $total_groups" | tee -a "$LOG_FILE"
echo "[$(timestamp)]   Successful: $successful_groups" | tee -a "$LOG_FILE"
echo "[$(timestamp)]   Failed: $failed_groups" | tee -a "$LOG_FILE"

if [[ $failed_groups -eq 0 ]]; then
  echo "[$(timestamp)] ✓ All backups completed successfully" | tee -a "$LOG_FILE"
  echo "[$(timestamp)] ════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
  exit 0
else
  echo "[$(timestamp)] ✗ Some backups failed" | tee -a "$LOG_FILE"
  echo "[$(timestamp)] ════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
  exit 1
fi
