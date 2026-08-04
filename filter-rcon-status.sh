#!/bin/sh
# Suppress WallFly's routine "rcon status" polls, and other high-frequency
# expected chatter, from the container log.
#
# The WallFly master-server bot polls arena/xatrix with an authenticated
# "rcon ... status" every few seconds, forever. The engine prints every
# successful rcon unconditionally (no cvar suppresses it), so without this
# filter the log is almost entirely WallFly noise.
#
# q2pro prints it as TWO lines (src/server/main.c, "Rcon from %s:\n%s\n"):
#     Rcon from <ip>:<port>:
#     status
# so a single-line grep pattern cannot match it. This script holds back an
# "Rcon from ...:" line until it sees the following command line and drops
# the pair only when that command is exactly "status". Every other rcon
# command (kick, ban, map change, ...) is printed in full, including the
# originating address - which a blanket grep on the address line would have
# discarded.
#
# Match-timer countdowns and per-map spawn-count lines need no such pairing -
# each is a single self-contained line - so a plain case match drops them.
# Only the exact zero-value spawn lines are dropped ("0 entities inhibited",
# "0 teams with 0 entities"); a nonzero count still prints, since that would
# mean something out of the ordinary actually happened.
#
# Implemented as a shell read-loop rather than awk on purpose: mawk reads
# stdin in blocks, so piping the server through "awk -f" swallowed the log
# entirely until a block filled (the container log came up empty). "read"
# consumes one line at a time, so output streams and "docker logs -f" stays
# live. Needs no packages beyond the base image's /bin/sh.
#
# Relies on the CMD's "stty -onlcr" so lines end in \n and not \r\n -
# otherwise the command line would be "status\r" and never match.

pend=''

while IFS= read -r line; do
    case "$line" in
        'Rcon from '*':')
            [ -n "$pend" ] && printf '%s\n' "$pend"
            pend="$line"
            continue
            ;;
    esac

    if [ -n "$pend" ]; then
        if [ "$line" = 'status' ]; then
            pend=''
            continue
        fi
        printf '%s\n' "$pend"
        pend=''
    fi

    case "$line" in
        [0-9]*' minute remaining in match.'|[0-9]*' minutes remaining in match.'|\
[0-9]*' second remaining in match.'|[0-9]*' seconds remaining in match.'|\
'Timelimit hit.'|'0 entities inhibited'|'0 teams with 0 entities')
            continue
            ;;
    esac

    printf '%s\n' "$line"
done

[ -n "$pend" ] && printf '%s\n' "$pend"
exit 0
