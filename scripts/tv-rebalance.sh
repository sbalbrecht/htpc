#!/bin/bash
# One-shot mergerfs rebalance: moves data/media/tv from disk1 to disk3.
# Stops the compose stack for the duration, verifies the copy before
# deleting the source, and always restarts the stack at the end (even on
# failure) so the media server doesn't stay down unattended.

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SERVER_DIR=/home/steve/server
SRC=/mnt/disk1/data/media/tv
DST=/mnt/disk3/data/media/tv
LOG=/home/steve/server/logs/tv-rebalance-$(date +%Y%m%d-%H%M%S).log

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

log "=== tv rebalance starting ==="

log "Stopping compose stack..."
cd "$SERVER_DIR" && docker compose down >>"$LOG" 2>&1

log "Starting rsync: $SRC -> $DST"
rsync -avh --stats "$SRC/" "$DST/" >>"$LOG" 2>&1
RSYNC_EXIT=$?
log "rsync exited with code $RSYNC_EXIT"

if [[ $RSYNC_EXIT -eq 0 ]]; then
  SRC_SIZE=$(du -sb "$SRC" 2>/dev/null | cut -f1)
  DST_SIZE=$(du -sb "$DST" 2>/dev/null | cut -f1)
  SRC_COUNT=$(find "$SRC" -type f | wc -l)
  DST_COUNT=$(find "$DST" -type f | wc -l)

  log "Source: $SRC_SIZE bytes, $SRC_COUNT files"
  log "Dest:   $DST_SIZE bytes, $DST_COUNT files"

  if [[ "$SRC_SIZE" == "$DST_SIZE" && "$SRC_COUNT" == "$DST_COUNT" ]]; then
    log "Verification passed. Removing source $SRC"
    rm -rf "$SRC"
    log "Source removed."
  else
    log "VERIFICATION MISMATCH - leaving source intact at $SRC for manual review. Nothing deleted."
  fi
else
  log "rsync reported an error - leaving source intact. Nothing deleted."
fi

log "Restarting compose stack..."
cd "$SERVER_DIR" && docker compose up -d >>"$LOG" 2>&1

log "Final disk usage:"
df -h /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/storage >>"$LOG" 2>&1

log "Removing this job's crontab entry (one-shot cleanup)..."
crontab -l 2>/dev/null | grep -v "tv-rebalance.sh" | crontab -

log "=== tv rebalance finished ==="
