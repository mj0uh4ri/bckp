#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Restic Backup Script with autonomous Vault password retrieval
#  Includes:
#    - Duration timing
#    - Repo free space logging
#    - Local free space logging
#    - Structured metrics file
#    - Reduced log noise
#    - GROUP SEGMENTATION: Pass group name as argument to run only that group
# ==========================================================

# Load environment if present
if [[ -f "${HOME}/restic.env" ]]; then
  # shellcheck disable=SC1090
  source "${HOME}/restic.env"
fi

# ========== FIX: Handle BACKUP_GROUPS as file or string ==========
if [[ -f "$BACKUP_GROUPS" ]]; then
  # If BACKUP_GROUPS is a file path, read it
  BACKUP_GROUPS=$(cat "$BACKUP_GROUPS")
elif [[ -n "${BACKUP_GROUPS_FILE:-}" && -f "${BACKUP_GROUPS_FILE}" ]]; then
  # Alternative: explicit BACKUP_GROUPS_FILE variable
  BACKUP_GROUPS=$(cat "${BACKUP_GROUPS_FILE}")
fi


LOG_FILE="${LOG_FILE:-/home/mjouhari/restic-backup.log}"
METRICS_FILE="/home/mjouhari/restic-metrics.json"
mkdir -p "$(dirname "$LOG_FILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
ts_unix() { date +%s; }

start_time=$(ts_unix)

echo "[$(timestamp)] === Starting Restic backup ===" | tee -a "$LOG_FILE"

# ==========================================================
# GROUP ARGUMENT HANDLING (NEW)
# ==========================================================

BACKUP_GROUP_FILTER="${1:-}"  # Optional first argument: group name

if [[ -n "$BACKUP_GROUP_FILTER" ]]; then
  echo "[$(timestamp)] ℹ️  Group filter specified: [$BACKUP_GROUP_FILTER]" | tee -a "$LOG_FILE"
else
  echo "[$(timestamp)] ℹ️  No group filter specified - will process all groups" | tee -a "$LOG_FILE"
fi

# ----------------------------------------------------------
# BASIC VALIDATION
# ----------------------------------------------------------
required_vars=(RESTIC_REPOSITORY VAULT_ADDR VAULT_SECRET_PATH VAULT_TOKEN BACKUP_GROUPS)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "[$(timestamp)] ✗ ERROR: $var is not set" | tee -a "$LOG_FILE"
    exit 1
  fi
done

# ----------------------------------------------------------
# FETCH PASSWORD FROM VAULT
# ----------------------------------------------------------
echo "[$(timestamp)] ↓ Authenticating to Vault..." | tee -a "$LOG_FILE"

RESTIC_PASSWORD=$(vault kv get -field=restic_pass "$VAULT_SECRET_PATH" 2>/dev/null) || {
  echo "[$(timestamp)] ✗ ERROR: Failed to fetch password from Vault" | tee -a "$LOG_FILE"
  exit 1
}

if [[ -z "$RESTIC_PASSWORD" ]]; then
  echo "[$(timestamp)] ✗ ERROR: Empty password retrieved from Vault" | tee -a "$LOG_FILE"
  exit 1
fi

export RESTIC_PASSWORD
echo "[$(timestamp)] ✓ Vault authentication OK" | tee -a "$LOG_FILE"

# If groups provided via file
if [[ -n "${BACKUP_GROUPS_FILE:-}" && -f "${BACKUP_GROUPS_FILE}" ]]; then
  BACKUP_GROUPS=$(cat "${BACKUP_GROUPS_FILE}")
fi

# ==========================================================
# PARSE AND FILTER GROUPS (NEW LOGIC)
# ==========================================================

all_groups=$(echo "$BACKUP_GROUPS" | jq -c '.[]')

# If group filter is specified, filter the groups
if [[ -n "$BACKUP_GROUP_FILTER" ]]; then
  groups=$(echo "$all_groups" | jq -c --arg grp "$BACKUP_GROUP_FILTER" 'select(.name == $grp)')
  
  if [[ -z "$groups" ]]; then
    echo "[$(timestamp)] ✗ ERROR: Group '$BACKUP_GROUP_FILTER' not found in BACKUP_GROUPS" | tee -a "$LOG_FILE"
    echo "[$(timestamp)]   Available groups:" | tee -a "$LOG_FILE"
    echo "$all_groups" | jq -r '.name' | sed 's/^/     - /' | tee -a "$LOG_FILE"
    exit 1
  fi
  
  echo "[$(timestamp)] ✓ Running ONLY group: [$BACKUP_GROUP_FILTER]" | tee -a "$LOG_FILE"
else
  groups="$all_groups"
  group_count=$(echo "$all_groups" | wc -l)
  echo "[$(timestamp)] ✓ Running ALL $group_count group(s)" | tee -a "$LOG_FILE"
fi

total_groups=0
successful_groups=0
failed_groups=0

# ==========================================================
#  LOOP ON BACKUP GROUPS
# ==========================================================

for group in $groups; do
  total_groups=$((total_groups + 1))
  group_name=$(echo "$group" | jq -r '.name')
  paths=$(echo "$group" | jq -r '.paths | join(" ")')

  # --------------------------------------------------------
  # Skip empty path group
  # --------------------------------------------------------
  if [[ -z "$paths" ]]; then
    echo "[$(timestamp)] ⚠  WARNING: Group [$group_name] has no paths, skipping" | tee -a "$LOG_FILE"
    continue
  fi

  echo "[$(timestamp)] ▶ Starting backup group [$group_name]" | tee -a "$LOG_FILE"
  echo "[$(timestamp)]   Paths: $paths" | tee -a "$LOG_FILE"

  group_start=$(ts_unix)

  # --------------------------------------------------------
  # RUN BACKUP
  # --------------------------------------------------------
  if restic -r "$RESTIC_REPOSITORY" backup $paths --tag "$group_name" 2>&1 | tee -a "$LOG_FILE"; then
    echo "[$(timestamp)] ✓ Backup for [$group_name] successful" | tee -a "$LOG_FILE"
    status="success"
    successful_groups=$((successful_groups + 1))
  else
    echo "[$(timestamp)] ✗ Backup for [$group_name] FAILED" | tee -a "$LOG_FILE"
    status="failed"
    failed_groups=$((failed_groups + 1))
    continue
  fi

  group_end=$(ts_unix)
  duration=$((group_end - group_start))

  # --------------------------------------------------------
  # LOG REMAINING FREE SPACE ON REMOTE SFTP REPO
  # --------------------------------------------------------
  echo "[$(timestamp)] 📦 Checking remote repository free space..." | tee -a "$LOG_FILE"

  repo_free=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
      "$(echo "$RESTIC_REPOSITORY" | sed 's#sftp://##; s#sftp:##; s#:# #')" \
      "df -h . | tail -1 | awk '{print \$4}'" 2>/dev/null || echo "unknown")

  echo "[$(timestamp)]     Repository free space: $repo_free" | tee -a "$LOG_FILE"

  # --------------------------------------------------------
  # APPLY RETENTION
  # --------------------------------------------------------
  retention=$(echo "$group" | jq -r '.retention')
  HOURLY=$(echo "$retention" | jq -r '.keep_hourly // 0')
  DAILY=$(echo "$retention" | jq -r '.keep_daily // 7')
  WEEKLY=$(echo "$retention" | jq -r '.keep_weekly // 4')
  MONTHLY=$(echo "$retention" | jq -r '.keep_monthly // 6')
  YEARLY=$(echo "$retention" | jq -r '.keep_yearly // 1')

  echo "[$(timestamp)] 🧹 Applying retention for [$group_name]" | tee -a "$LOG_FILE"
  echo "[$(timestamp)]    Keep: ${HOURLY}h ${DAILY}d ${WEEKLY}w ${MONTHLY}m ${YEARLY}y" | tee -a "$LOG_FILE"

  restic -r "$RESTIC_REPOSITORY" forget \
    --tag "$group_name" \
    --keep-hourly "$HOURLY" \
    --keep-daily "$DAILY" \
    --keep-weekly "$WEEKLY" \
    --keep-monthly "$MONTHLY" \
    --keep-yearly "$YEARLY" \
    --prune 2>&1 | tee -a "$LOG_FILE" || \
      echo "[$(timestamp)] ⚠  Retention failed (backup OK)" | tee -a "$LOG_FILE"

  # --------------------------------------------------------
  # WRITE METRICS (STRUCTURED JSON)
  # --------------------------------------------------------
  echo "{
    \"timestamp\": \"$(timestamp)\",
    \"group\": \"$group_name\",
    \"duration_sec\": $duration,
    \"result\": \"$status\",
    \"repo_free\": \"$repo_free\"
  }" >> "$METRICS_FILE"

done

# ==========================================================
# FINAL CHECKS & SUMMARY
# ==========================================================

echo "[$(timestamp)] ▶ Running repository integrity check" | tee -a "$LOG_FILE"
restic -r "$RESTIC_REPOSITORY" check --read-data-subset=5% 2>&1 | tee -a "$LOG_FILE" || \
  echo "[$(timestamp)] ⚠  Integrity check reported issues" | tee -a "$LOG_FILE"

# ----------------------------------------------------------
# LOCAL DISK USAGE
# ----------------------------------------------------------
local_free=$(df -h / | tail -1 | awk '{print $4}')
echo "[$(timestamp)] 💽 Local disk free space: $local_free" | tee -a "$LOG_FILE"

# ----------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------
echo "[$(timestamp)] ═════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "[$(timestamp)] BACKUP SUMMARY" | tee -a "$LOG_FILE"
echo "[$(timestamp)]   Groups processed: $total_groups" | tee -a "$LOG_FILE"
echo "[$(timestamp)]   Successful: $successful_groups" | tee -a "$LOG_FILE"
echo "[$(timestamp)]   Failed: $failed_groups" | tee -a "$LOG_FILE"

end_time=$(ts_unix)
total_duration=$((end_time - start_time))

echo "[$(timestamp)]   Total duration: ${total_duration}s" | tee -a "$LOG_FILE"

if [[ -n "$BACKUP_GROUP_FILTER" ]]; then
  echo "[$(timestamp)]   Group filter: [$BACKUP_GROUP_FILTER]" | tee -a "$LOG_FILE"
fi

echo "[$(timestamp)] ═════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

# ----------------------------------------------------------
# SYSLOG SUMMARY (optional but recommended)
# ----------------------------------------------------------
logger -t restic-backup "Backup finished: success=$successful_groups fail=$failed_groups duration=${total_duration}s groups_processed=$total_groups"

# Exit code
if [[ $failed_groups -eq 0 ]]; then
  echo "[$(timestamp)] ✓ All backups completed successfully" | tee -a "$LOG_FILE"
  exit 0
else
  echo "[$(timestamp)] ✗ Some backups failed" | tee -a "$LOG_FILE"
  exit 1
fi