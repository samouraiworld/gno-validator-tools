#!/bin/bash

cd /opt/backup_logs

DIRECTORY="./backup"
CONTAINER="betanet-validator-1"
RETENTION_DAYS=30
ARCHIVE_PATTERN="${DIRECTORY}/${CONTAINER}_*.log.xz"
FILENAME="${DIRECTORY}/${CONTAINER}_$(date +%F_%H-%M).log"

docker logs $CONTAINER --since 24h > $FILENAME
xz $FILENAME
scp $ARCHIVE_PATTERN root@gno-sentry:/opt/backup_logs/validator/

find "$DIRECTORY" -type f -name "$(basename "$ARCHIVE_PATTERN")" -mtime +"$RETENTION_DAYS" -print -delete

