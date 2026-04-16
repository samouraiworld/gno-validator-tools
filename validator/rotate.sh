#!/bin/bash

DIRECTORY="/opt/backup_logs/backup"
RETENTION_DAYS=30

find "$DIRECTORY" -type f -name "*.log.xz" -mtime +"$RETENTION_DAYS" -print -delete