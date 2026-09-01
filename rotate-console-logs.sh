#!/bin/sh
# Rotates the persistent console.log files the arena/xatrix containers'
# CMD `tee -a`s into (see Dockerfile). Run on the HOST via cron, not inside
# either container - these files already live on the host through the
# bind mount, and rotating them there needs no docker involvement at all.
#
# Not using logrotate: it isn't installed on this host, and this host has
# no passwordless sudo (see project memory), so `apt-get install logrotate`
# isn't a one-line fix. This script covers the same "cap size, keep a few
# old copies" need without adding a package or needing root - every file
# touched here is already owned by nils (same UID the containers run as),
# so nothing here needs privilege.
#
# copytruncate, not rename+recreate: `tee -a` opens the file once, in
# O_APPEND mode, for the life of the container, and nothing tells it to
# reopen a freshly-renamed-away path. Renaming console.log to console.log.1
# would leave tee still writing into the renamed file (now invisible under
# the original name) forever, while a plain rotate-by-rename would expect a
# fresh empty file to appear at the original path - it wouldn't. Instead:
# copy the current content out, then truncate the ORIGINAL file in place
# (same inode). Because the writer uses O_APPEND, the kernel always writes
# at current end-of-file - truncating externally just moves that point back
# to 0, and the very next write lands there correctly, no reopen needed, no
# interruption to the running server. Same technique logrotate's own
# `copytruncate` option uses internally. Small accepted risk: a write
# landing between the copy and the truncate is lost - fine for a console
# log, not something anything here depends on for correctness.

set -eu

MAX_BYTES=$((20 * 1024 * 1024))   # rotate once a file passes this size
KEEP=12                            # rotated copies to keep, per file (~oldest pruned first)

for f in \
    /home/nils/quake2/arena/logs/console.log \
    /home/nils/quake2/xatrix/logs/console.log \
; do
    [ -f "$f" ] || continue

    size=$(stat -c%s "$f")
    if [ "$size" -gt "$MAX_BYTES" ]; then
        ts=$(date +%Y%m%d-%H%M%S)
        cp "$f" "$f.$ts"
        gzip "$f.$ts"
        : > "$f"
    fi

    # shellcheck disable=SC2012
    ls -1t "$f".*.gz 2>/dev/null | tail -n "+$((KEEP + 1))" | while IFS= read -r old; do
        rm -f -- "$old"
    done
done
