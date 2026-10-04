#!/bin/bash
# Nightly offsite backup of everything on the OS SSD that would be hard to
# redo: app settings and databases (/host), this repo including its
# untracked secrets and notes, and the host's /etc and crontabs. Media
# isn't included; SnapRAID covers that.
#
# restic encrypts everything before it leaves the machine and only uploads
# what changed. On Sundays it also deletes old snapshots and downloads a
# sample of the backup to prove it can be read back.
#
# Reports to a healthchecks.io check: success is silent, a failure alerts
# with the end of this log, and a run that never happens alerts too.
# Runs as root from cron (see HOST-SETUP.md).

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO=/home/steve/server
LOG=$REPO/logs/backup-$(date +%Y%m%d-%H%M%S).log
HC_URL=$(cat /host/healthchecks_backup_url.txt 2>/dev/null)
ENV_FILE=/host/restic.env   # B2 bucket, B2 key and the backup password
PLEX="/host/plex/Library/Application Support/Plex Media Server"

PATHS=(/host "$REPO" /etc /var/spool/cron/crontabs)
# Things that rebuild themselves or are only useful while running.
EXCLUDES=(
  "$PLEX/Cache"
  "$PLEX/Codecs"
  "$PLEX/Crash Reports"
  "$PLEX/Drivers"
  "$PLEX/Logs"
  "$PLEX/Updates"
  "$REPO/logs"
)
# How many snapshots to keep: one a day for a week, one a week for a
# month, one a month for a year.
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 12)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# hc <suffix> [body]: ping healthchecks.io ("" = success, /start, /fail).
# Never lets a healthchecks.io outage fail the run itself.
hc() {
  [[ -n "$HC_URL" ]] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "${2:-}" "$HC_URL$1" || true
}

fail() {
  log "FAILED: $*"
  hc /fail "$(tail -c 10000 "$LOG")"
  exit 1
}

log "=== offsite backup starting ==="
[[ -n "$HC_URL" ]] || log "WARNING: /host/healthchecks_backup_url.txt missing, results won't be reported"
hc /start

[[ -r "$ENV_FILE" ]] || fail "$ENV_FILE missing"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

exclude_args=()
for e in "${EXCLUDES[@]}"; do exclude_args+=(--exclude "$e"); done

log "Backing up ${PATHS[*]}..."
restic backup --retry-lock 30m --no-scan "${exclude_args[@]}" "${PATHS[@]}" >> "$LOG" 2>&1
rc=$?
# 3 = snapshot saved, but some files couldn't be read (usually a temp file
# an app deleted mid-backup). Worth a log line, not an alert.
case $rc in
  0) ;;
  3) log "Some files couldn't be read (listed above). The rest was saved." ;;
  *) fail "restic backup failed (exit $rc)" ;;
esac

if [[ "$(date +%u)" -eq 7 ]]; then
  log "Sunday - deleting old snapshots..."
  restic forget --retry-lock 30m --prune "${KEEP[@]}" >> "$LOG" 2>&1 \
    || fail "restic forget/prune failed"
  log "Sunday - checking a 5% sample of the backup can be read back..."
  restic check --retry-lock 30m --read-data-subset 5% >> "$LOG" 2>&1 \
    || fail "restic check found a problem"
fi

restic snapshots --latest 1 >> "$LOG" 2>&1
log "=== offsite backup finished ==="
hc "" "$(tail -c 10000 "$LOG")"
