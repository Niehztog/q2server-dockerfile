# Shared image for the arena and xatrix servers, running q2pro.
#
# Builds q2pro from source at a pinned commit, so the image is reproducible
# and the (safety-critical) ABI build flag is explicit rather than baked into
# a mystery binary. See README.md for the full setup story.
#
# Why q2pro and not q2repro (Paril's fork): q2repro was evaluated first and
# made to work, but its newer network protocol isn't understood by legacy
# clients (yquake2, the q2pro client). Plain q2pro speaks the classic
# protocol those clients expect.
#
# NOTE the upstream moved off skullernet/q2pro (which now 404s) to the q2pro
# organisation. q2pro's own version banner still prints the old URL.

# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS build

# Pinned so rebuilds are deterministic. Bump deliberately, then re-test:
# an unpinned clone would look reproducible while silently drifting
# upstream on every rebuild, which is not something a live game server
# should do.
ARG Q2PRO_REPO=https://github.com/q2pro/q2pro
ARG Q2PRO_COMMIT=601a8df8433b0c50dbbe37c0716c3793fff140a7

# q2admin (the Q2Admin/anti-cheat wrapper game module) built the same way:
# pinned commit, cross-compiled to i386, verified before shipping. Replaces
# the old build-gamei386.sh throwaway-container script, which built
# Niehztog/q2admin-tsmod (a patched fork of the ~1998 tastyspleen lineage).
# packetflinger/q2admin is a much more actively maintained rewrite that
# correctly handles q2pro's GMF_EXTRA_USERINFO/GMF_IPV6_ADDRESS_AWARE
# feature negotiation - the old wrapper doesn't understand either and (a)
# kicks every connecting client once the wrapped mod declares
# GMF_EXTRA_USERINFO ("doesn't have a valid IP address" - not IP-specific,
# every client hits it) and (b) heap-overflows a fixed 40-byte IP buffer via
# raw strcpy for any client connecting over IPv6, once the wrapped mod
# declares GMF_IPV6_ADDRESS_AWARE.
# Pinned to Niehztog's fork, not upstream packetflinger/q2admin, because it
# carries two unmerged fixes, developed on separate branches (each its own
# upstream PR) and combined here on a third integration branch,
# combined-pending-fixes, purely for deployment - the individual PR branches
# are NOT based on each other, so each stays independently reviewable:
#
# 1. fix-required-msg-userinfo-key (branched from upstream main @ e8f70e4):
#    upstream's required_ui_keys[] hard-requires a "msg" userinfo key that
#    yquake2 clients never send (confirmed in yquake2's own
#    src/client/cl_main.c - it registers name/skin/rate/hand/fov/gender/
#    password/spectator but not msg), which rejected every yquake2 connection
#    outright.
#    PR: github.com/Niehztog/q2admin/pull/new/fix-required-msg-userinfo-key
#
# 2. fix-cloud-admin-crashes (also branched from upstream main @ e8f70e4):
#    found live in production on 2026-08-05, within minutes of first ever
#    enabling the (until-then-dormant) Cloud Admin client feature - CA_
#    PlayerList()/PlayerConnect()/PlayerUpdate() pass a ~650-byte userinfo_t
#    STRUCT to a variadic "%s" format argument instead of its .raw string
#    field (every other of 40+ usages elsewhere in the codebase correctly
#    uses .raw) - undefined behavior that segfaults the entire game server
#    on essentially the first real player connect, which is exactly what
#    happened: both arena and xatrix crash-looped roughly every 2 minutes
#    until this was found and fixed. Also fixes, found during the same
#    investigation: no bounds-checking at all on 3 of 4 outgoing
#    message-queue writers, a wrong-constant bounds check on the 4th
#    (compared against the 1000-byte scratch-buffer size instead of the
#    real 22015-byte queue capacity, silently disabled by unsigned
#    underflow once triggered), a matching unbounded recv() and an
#    unbounded string-terminator scan on the incoming side, an unvalidated
#    array index driven directly by the peer, and a pre-authentication
#    remotely-reachable stack buffer overflow in the RSA handshake
#    (peer-supplied, unvalidated length passed straight into memcpy).
#    PR: github.com/Niehztog/q2admin/pull/new/fix-cloud-admin-crashes
#
# Switch back to Q2ADMIN_REPO=packetflinger/q2admin (and drop the
# combined-pending-fixes branch entirely) once BOTH fixes are merged
# upstream - don't let this fork drift into a silent permanent one.
ARG Q2ADMIN_REPO=https://github.com/Niehztog/q2admin
ARG Q2ADMIN_COMMIT=cd569b38c89cc5f8a2294e7d208e2a4c7b2dedbb

# openffa-xatrix (the actual game DLL xatrix runs, wrapped by q2admin above -
# q2admin dlopens it as "gamei386.real.so") was, until 2026-08-06, NOT built
# by this Dockerfile at all: ~/quake2/xatrix/gamei386.real.so was a manually
# produced binary dated 2017-05-17, never rebuilt through any tracked
# process. Discovered when enabling g_warmup (a pre-match ready-up/countdown
# feature) had zero effect on the live server despite the cvar taking the
# value fine - `strings` on the actual deployed .so showed zero occurrences
# of g_warmup/g_countdown_time anywhere, because that feature was only added
# upstream on 2022-11-03 (71a3fbf, "Add warmup support"), five years after
# the deployed build. Confirmed the fork's current HEAD genuinely has it
# (`git merge-base --is-ancestor 71a3fbf HEAD`) despite HEAD's own tip commit
# showing an author date of 2017-05-17 - that's just the fork's own last
# local patch before the 2026-08-04 rebase onto a modern upstream base (see
# q2-openffa-xatrix-rebase in project memory); committer date on that same
# commit is 2026-08-04, and it carries 222 total commits, not a handful.
# Built the same way as q2admin above: pinned commit, i386 cross-compile,
# verified before shipping. CONFIG_SQLITE=1 below enables the per-player
# stats database (g_sql_database); CONFIG_CURL and CONFIG_UDP - the two
# *alternative* stats backends - are deliberately left off: g_sqlite.c/
# g_curl.c/g_udp.c all define the same G_LogClient/G_OpenDatabase/etc.
# function names, so more than one of the three enabled at once fails the
# link with duplicate symbols. Also relevant if the engine's sv_fps is ever
# changed from its default: openffa hardcodes its own HZ/FRAMETIME to a
# fixed 10 unless CONFIG_VARIABLE_SERVER_FPS is also set, in which case
# they track the engine's actual tick rate instead - not enabled, nothing
# currently overrides sv_fps from its default.
#
# Bumped 2026-08-06 (9db7aae -> 34888fa, own fork-local fixes, not
# upstream; squashed by hand a couple of times along the way, so don't go
# looking for df9d07b/1256477/etc. on the remote - only this hash matters):
#
# 1. Enabling g_warmup broke the MOTD system four independent, compounding
#    ways, all stemming from ClientBegin()'s g_warmup branch and its
#    downstream effects: (a) it overwrites pers.connected from
#    CONN_PREGAME to CONN_SPECTATOR synchronously, and the auto-show
#    trigger's outer gate only ever checked for CONN_PREGAME; (b) it also
#    does `enter_framenum -= 5*HZ` (a hack for G_SpecRateLimited(),
#    unrelated to MOTD), which corrupted the trigger's exact-equality
#    delta check the same way; (c) the same branch opens the join menu
#    immediately (layout=LAYOUT_MENU), which the trigger deliberately
#    yields to (layout==LAYOUT_NONE required) - but selecting "Enter the
#    game" from that menu never called PMenu_Close() (unlike every other
#    menu selection), so layout stayed stuck at LAYOUT_MENU forever once a
#    player actually joined, permanently blocking the timing check; (d)
#    found after (a)-(c) were deployed and auto-show confirmed working,
#    but manually typing "motd" later did nothing: the 15s dismiss check
#    computed its delta from the same connect-time resp.motd_framenum,
#    never refreshed, so any manual re-trigger a while after connecting
#    got immediately re-dismissed by the very next frame tick, too fast to
#    perceive. Fixed all four: broadened the state check, decoupled the
#    auto-show timer onto its own resp.motd_framenum field, converted both
#    delta checks from exact-equality to >= with a one-shot
#    resp.motd_shown latch, added the missing PMenu_Close() call, and
#    added a second resp.motd_shown_framenum stamped by Cmd_Motd_f itself
#    on every actual display (auto or manual) so the dismiss timer is
#    always relative to the current display, not the original connect.
#
# 2. Added "motd" to Cmd_Commands_f's hardcoded help list - it was never
#    in there (same gap in the README's own client-commands list),
#    unrelated to the g_warmup fixes above, just a pre-existing
#    documentation gap noticed once the feature was actually in use.
ARG OPENFFA_REPO=https://github.com/Niehztog/openffa-xatrix
ARG OPENFFA_COMMIT=34888fac9896c6b062500544e505e89b66409abc

# Enables g_sqlite.c (see the ARG comment above for why CONFIG_CURL/
# CONFIG_UDP must stay off if this is on). Needs libsqlite3-dev:i386 here
# and libsqlite3:i386 in the runtime stage - see both apt-get lines below.
ARG OPENFFA_CONFIG_SQLITE=1

# THE important knob. Controls the i386 struct-return calling convention
# q2pro uses for gi.trace() (it applies
# __attribute__((callee_pop_aggregate_return(0))) plus -mstackrealign).
#
#   arena  -> enabled   : its gamei386.real.so is a 2014 build that expects
#                         the old callee-pops convention. Without this the
#                         stack drifts 4 bytes after every gi.trace() and the
#                         mod segfaults dereferencing a bogus trace.ent
#                         (crash lands in its own SV_PushEntity).
#   xatrix -> disabled  : its 2017 build expects the modern convention and
#                         crashes if this IS enabled.
#
# It is a whole-binary compile-time switch, so one engine binary cannot serve
# both mods - hence one image per gamedir, with this passed per service in
# docker-compose.yml. Getting it backwards produces a server that starts
# fine and then dies on the first map, so do not "simplify" the two images
# into one.
ARG GAME_ABI_HACK=disabled

# q2pro is pure C (no C++), needs meson >= 0.59 - trixie's packaged meson is
# new enough, so no pip needed - and for a dedicated server only zlib.
# gcc-multilib + libc6-dev-i386 provide the 32-bit toolchain.
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        git ca-certificates meson ninja-build pkg-config make \
        gcc gcc-multilib libc6-dev-i386 zlib1g-dev:i386 libssl-dev:i386 \
        libsqlite3-dev:i386 && \
    rm -rf /var/lib/apt/lists/*

# The game DLLs are 32-bit, so the engine must be too.
RUN printf '%s\n' \
    '[binaries]' \
    "c = 'gcc'" \
    "ar = 'ar'" \
    "strip = 'strip'" \
    "pkg-config = 'pkg-config'" \
    '' \
    '[built-in options]' \
    "c_args = ['-m32']" \
    "c_link_args = ['-m32']" \
    '' \
    '[host_machine]' \
    "system = 'linux'" \
    "cpu_family = 'x86'" \
    "cpu = 'i686'" \
    "endian = 'little'" \
    > /i386-linux.txt

# PKG_CONFIG_LIBDIR pins pkg-config to the i386 .pc files. Without it meson
# finds the host's 64-bit zlib and the link fails with
# "libz.so: file in wrong format".
#
# -Danticheat-server=true compiles in src/server/ac.c, q2pro's r1ch.net
# anticheat client. Defaults to false upstream - without this flag, every
# sv_anticheat_* cvar in anticheat.cfg (including sv_anticheat_required) is
# just an unregistered loose cvar with zero effect, silently, since `set`
# never errors on an unknown name. Confirmed via byte-grep of a build
# without this flag: zero occurrences of "ANTICHEAT", "anticheat.r1ch.net",
# or any sv_anticheat_* name anywhere in the resulting q2proded binary.
RUN git clone "$Q2PRO_REPO" /src && \
    cd /src && \
    git checkout --detach "$Q2PRO_COMMIT" && \
    PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig PKG_CONFIG_PATH= \
      meson setup build-i386 \
        --cross-file /i386-linux.txt \
        -Dgame-abi-hack="$GAME_ABI_HACK" \
        -Dclient-ui=false \
        -Dclient-gtv=false \
        -Danticheat-server=true && \
    ninja -C build-i386 q2proded && \
    install -Dm755 build-i386/q2proded /out/q2proded

# Fail the build rather than ship a silently-wrong engine.
RUN set -eu; \
    readelf -h /out/q2proded | grep -q 'ELF32' || { echo 'q2proded is not ELF32'; exit 1; }; \
    if [ "$GAME_ABI_HACK" = 'enabled' ]; then \
        grep -q 'USE_GAME_ABI_HACK 1' /src/build-i386/config.h \
            || { echo 'game-abi-hack requested but not enabled in config.h'; exit 1; }; \
    else \
        grep -q 'USE_GAME_ABI_HACK 1' /src/build-i386/config.h \
            && { echo 'game-abi-hack should be off but is on'; exit 1; } || true; \
    fi; \
    echo "q2proded OK (ELF32, game-abi-hack=$GAME_ABI_HACK)"

# q2admin's own Makefile defaults to its vendored, prebuilt i386 static libs
# (deps/i386/{curl,zlib,openssl}) - convenient, but its openssl archive links
# in one object (libcrypto-lib-v3_san.o) that isn't fully position-independent,
# producing a shared object with a TEXTREL (confirmed via readelf; it still
# loaded and ran fine in testing, but that's a real hardening regression, not
# something to ship deliberately). zlib's vendored archive has the same
# problem (masked the first time around: once a shared object already has one
# non-PIC relocation, the linker doesn't necessarily warn about every other
# one too). Fix: link openssl and zlib dynamically against Debian's own i386
# packages instead - shared libraries are position-independent by
# construction, so this sidesteps the problem entirely rather than papering
# over it, and matches how q2proded itself is linked (dynamic against system
# libc/zlib, nothing vendored). Only curl stays on the vendored static
# archive: it never showed a TEXTREL, and q2admin's Makefile only exposes
# INCLUDES/LIBS as a pair (?= , so both are overridden together below) - no
# need to touch what already links clean.
# CPU=i386 only controls the output filename (game$(CPU)-q2admin-r$(VER).so
# by default) - it does not select a 32-bit target on its own, so CC is
# overridden to force -m32 explicitly, the same reason q2pro gets a full
# cross-file above rather than relying on CPU alone. TARGET is forced to a
# fixed name instead of the default so the runtime stage's COPY doesn't need
# to know the current commit's revision number.
RUN git clone "$Q2ADMIN_REPO" /src-q2admin && \
    cd /src-q2admin && \
    git checkout --detach "$Q2ADMIN_COMMIT" && \
    make CPU=i386 CC="gcc -m32" TARGET=gamei386.so \
        INCLUDES="-Ideps/i386/curl/include" \
        LIBS="deps/i386/curl/lib/libcurl.a -lz -lssl -lcrypto -lpthread -ldl" && \
    install -Dm755 gamei386.so /out/gamei386.so

# Fail the build rather than ship a silently-wrong or non-hardened wrapper.
RUN set -eu; \
    readelf -h /out/gamei386.so | grep -q 'ELF32' || { echo 'q2admin gamei386.so is not ELF32'; exit 1; }; \
    readelf -d /out/gamei386.so | grep -q TEXTREL \
        && { echo 'q2admin gamei386.so has a TEXTREL - dynamic linking of openssl/zlib must have regressed'; exit 1; } || true; \
    echo "q2admin gamei386.so OK (ELF32, no TEXTREL)"

# openffa-xatrix's own Makefile: CPU=i386 alone picks the output filename
# (game$(CPU).so, no revision suffix - unlike q2admin's, no TARGET override
# needed), and REV/VER are derived from git automatically. Its own build
# already runs `ldd -r` on the result as a post-link undefined-symbol check
# (see the LIBTOOL var in its Makefile).
RUN git clone "$OPENFFA_REPO" /src-openffa && \
    cd /src-openffa && \
    git checkout --detach "$OPENFFA_COMMIT" && \
    make CPU=i386 CC="gcc -m32" CONFIG_SQLITE="$OPENFFA_CONFIG_SQLITE" && \
    install -Dm755 gamei386.so /out/gamei386.real.so

# Fail the build rather than silently ship a build missing the one feature
# this whole stage exists for - exactly how the stale 2017 binary went
# unnoticed for years.
RUN set -eu; \
    readelf -h /out/gamei386.real.so | grep -q 'ELF32' || { echo 'openffa gamei386.real.so is not ELF32'; exit 1; }; \
    strings /out/gamei386.real.so | grep -q '^g_warmup$' \
        || { echo 'openffa gamei386.real.so is missing g_warmup - wrong commit pinned?'; exit 1; }; \
    if [ -n "$OPENFFA_CONFIG_SQLITE" ]; then \
        readelf -d /out/gamei386.real.so | grep -q 'libsqlite3\.so' \
            || { echo 'CONFIG_SQLITE was requested but gamei386.real.so is not linked against libsqlite3'; exit 1; }; \
        strings /out/gamei386.real.so | grep -q '^g_sql_database$' \
            || { echo 'CONFIG_SQLITE was requested but g_sql_database cvar is missing from the binary'; exit 1; }; \
    fi; \
    echo "openffa gamei386.real.so OK (ELF32, has g_warmup, sqlite=${OPENFFA_CONFIG_SQLITE:-off})"

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM debian:trixie-slim

ENV Q2_GAMEDIR="arena"
ENV Q2_IP="localhost"
ENV Q2_PORT="27910"
ENV Q2_OVERRIDE_CFG="q2pro-override-arena.cfg"

# Host is Europe/Berlin; without this the container defaults to UTC. Real
# symptom found 2026-08-06: xatrix/openffa's func_clock entity, in its
# default "time of day" mode, calls time(NULL)/localtime() directly and
# displayed exactly 2 hours behind host time (CEST is UTC+2) - the game
# process has no other source of wall-clock time than the container's own.
# tzdata provides the zoneinfo database; the explicit symlink + timezone
# file + dpkg-reconfigure make it authoritative rather than relying on
# tzdata's postinst alone to notice the TZ env var.
ENV TZ=Europe/Berlin

# 32-bit runtime libs for the engine and the game DLLs. libssl3t64 is for
# q2admin's dynamically-linked openssl (see the build stage - avoids a
# TEXTREL that vendoring a static openssl produced). util-linux (script,
# stty) is already in the base image and is needed by the CMD below.
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends libc6:i386 zlib1g:i386 libssl3t64:i386 tzdata libsqlite3-0:i386 && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    dpkg-reconfigure -f noninteractive tzdata && \
    apt-get -y autoclean && \
    apt-get -y autoremove && \
    rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/locale/* \
        /var/cache/debconf/*-old \
        /usr/share/doc/*

# UID 1000 matches the host's real "nils" login so the server can write to
# its bind-mounted game data.
RUN useradd -r -u 1000 -U -s /sbin/nologin -M quake2

RUN mkdir -p /opt/quake2 && chown quake2:quake2 /opt/quake2

# q2admin (and, for xatrix, openffa-xatrix's gamei386.real.so that it wraps)
# land at /opt/q2admin and /opt/openffa, not directly in a gamedir: unlike
# q2proded, they have to sit *inside* the bind-mounted gamedir at runtime
# (q2admin dlopens "<gamedir>/gamei386.real.so" - or whatever "gamelibrary"
# names - relative to the process CWD), so the image can't deliver them
# there directly, and copying over the operator's file from an entrypoint on
# every start would silently overwrite a deliberate version choice. Install
# into a gamedir once, the same "one-time game data preparation" way as
# before:
#   docker create --name q2admin-extract <image> && \
#   docker cp q2admin-extract:/opt/q2admin/gamei386.so ~/quake2/<gamedir>/ && \
#   docker cp q2admin-extract:/opt/openffa/gamei386.real.so ~/quake2/xatrix/ && \
#   docker rm q2admin-extract
COPY --from=build /out/q2proded /opt/q2pro/q2proded
COPY --from=build /out/gamei386.so /opt/q2admin/gamei386.so
COPY --from=build /out/gamei386.real.so /opt/openffa/gamei386.real.so
COPY filter-rcon-status.sh /opt/filter-rcon-status.sh

USER quake2

WORKDIR /opt/quake2

# The engine lives in the image; only game DATA is bind-mounted at
# /opt/quake2. basedir/libdir/homedir are all set explicitly to /opt/quake2
# because q2pro otherwise defaults homedir to ~/.q2pro and checks it before
# basedir/libdir for several lookups. For the game library, that's harmless -
# "Can't access /home/quake2/.q2pro/<gamedir>/gamei386.so", immediately
# followed by a fallback that finds it under libdir. But file reads the game
# DLL itself makes (e.g. xatrix/openffa's own map-rotation code loading
# "mapcfg/maplist.txt" for its random map cycle) only try the homedir path,
# with no fallback - they fail outright ("Couldn't load
# '/home/quake2/.q2pro/xatrix/mapcfg/maplist.txt'"), silently leaving the
# mod's map list empty. Symptom: the server never rotates and instead
# restarts the same map after every timelimit. Pointing homedir at the same
# real directory as basedir/libdir closes the gap for every such lookup, not
# just this one.
#
# net_port, not the classic "port" cvar, controls q2pro's actual listen socket
# (it binds PORT_SERVER=27910 regardless of what "port" says), so both are
# set. "port" is still needed because the game DLL reads it.
#
# map_override_path enables q2pro's .bsp.override / .ent entity-string
# overrides, which several xatrix maps rely on. q2pro requires this cvar to be
# set; without it such a map fails to load entirely.
#
# script -qefc allocates a PTY so the game's libc line-buffers stdout and
# "docker logs" is live rather than arriving in delayed batches; stty -onlcr
# stops the PTY translating \n to \r\n (which would otherwise break the
# rcon filter's line matching).
CMD script -qefc "stty -onlcr; /opt/q2pro/q2proded +set basedir /opt/quake2 +set libdir /opt/quake2 +set homedir /opt/quake2 +set dedicated 1 +set game $Q2_GAMEDIR +set ip $Q2_IP +set port $Q2_PORT +set net_port $Q2_PORT +set map_override_path maps +exec server1.cfg +exec $Q2_OVERRIDE_CFG" /dev/null 2>&1 | /bin/sh /opt/filter-rcon-status.sh
