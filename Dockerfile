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
        gcc gcc-multilib libc6-dev-i386 zlib1g-dev:i386 libssl-dev:i386 && \
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
RUN git clone "$Q2PRO_REPO" /src && \
    cd /src && \
    git checkout --detach "$Q2PRO_COMMIT" && \
    PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig PKG_CONFIG_PATH= \
      meson setup build-i386 \
        --cross-file /i386-linux.txt \
        -Dgame-abi-hack="$GAME_ABI_HACK" \
        -Dclient-ui=false \
        -Dclient-gtv=false && \
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

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM debian:trixie-slim

ENV Q2_GAMEDIR="arena"
ENV Q2_IP="localhost"
ENV Q2_PORT="27910"
ENV Q2_OVERRIDE_CFG="q2pro-override-arena.cfg"

# 32-bit runtime libs for the engine and the game DLLs. libssl3t64 is for
# q2admin's dynamically-linked openssl (see the build stage - avoids a
# TEXTREL that vendoring a static openssl produced). util-linux (script,
# stty) is already in the base image and is needed by the CMD below.
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends libc6:i386 zlib1g:i386 libssl3t64:i386 && \
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

# q2admin lands at /opt/q2admin, not directly in a gamedir: unlike q2proded,
# it has to sit *inside* the bind-mounted gamedir at runtime (it dlopens
# "<gamedir>/gamei386.real.so" - or whatever "gamelibrary" names - relative
# to the process CWD), so the image can't deliver it there directly, and
# copying it over the operator's file from an entrypoint on every start
# would silently overwrite a deliberate version choice. Install it into a
# gamedir once, the same "one-time game data preparation" way as before:
#   docker create --name q2admin-extract <image> && \
#   docker cp q2admin-extract:/opt/q2admin/gamei386.so ~/quake2/<gamedir>/ && \
#   docker rm q2admin-extract
COPY --from=build /out/q2proded /opt/q2pro/q2proded
COPY --from=build /out/gamei386.so /opt/q2admin/gamei386.so
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
