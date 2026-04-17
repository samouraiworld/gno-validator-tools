#!/bin/bash

cd /opt/backup_logs

DIRECTORY="./backup"
CONTAINER="gnoland1-validator-1"
HOST=$(hostname)
RETENTION_DAYS=30

FILENAME="${DIRECTORY}/${HOST}_${CONTAINER}_$(date +%F_%H-%M).log"
ARCHIVE_PATTERN="${DIRECTORY}/${HOST}_${CONTAINER}_*.log.xz"

docker logs $CONTAINER --since 24h > $FILENAME 2>&1
xz $FILENAME

scp "${FILENAME}.xz" root@gno-sentry:/opt/backup_logs/backup

find "$DIRECTORY" -type f -name "$(basename "$ARCHIVE_PATTERN")" -mtime +"$RETENTION_DAYS" -print -delete
