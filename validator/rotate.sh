#!/bin/bash

cd /opt/backup_logs

DIRECTORY="./validator"
CONTAINER="betanet-validator-1"
RETENTION_DAYS=30
ARCHIVE_PATTERN="${DIRECTORY}/${CONTAINER}_*.log.xz"
FILENAME="${DIRECTORY}/${CONTAINER}_$(date +%F_%H-%M).log"


find "$DIRECTORY" -type f -name "$(basename "$ARCHIVE_PATTERN")" -mtime +"$RETENTION_DAYS" -print -delete
