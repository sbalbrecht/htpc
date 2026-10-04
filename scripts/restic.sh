#!/bin/bash
# Runs restic against the offsite backup, with the bucket and password
# loaded from /host/restic.env. Run with sudo. Examples:
#   sudo scripts/restic.sh snapshots
#   sudo scripts/restic.sh restore latest --target /tmp/restore --include /host/sonarr

set -a
. /host/restic.env || exit 1
set +a
exec restic "$@"
