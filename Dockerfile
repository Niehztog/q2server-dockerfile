# TWO TARGETS, ONE FILE.
#
#   --target server      the image both live game servers run: q2pro's engine
#                        plus q2admin, and nothing else.  THE DEFAULT, so a
#                        bare `docker build .` gives you this.
#
#   --target colosseum   the game library those servers load, plus the bot
#                        library, its assets and bspc.  Nothing runs from it in
#                        production: scripts/deploy-colosseum-live.sh copies
#                        the artifacts out of it into the bind-mounted gamedir,
#                        and scripts/make-colosseum-aas.sh runs it as a
#                        throwaway server to compute navigation meshes.
#
# They share the build stage, so the engine is compiled ONCE for both.  Until
# 2026-09-18 the second lived in a separate Dockerfile-colosseum that cloned
# and built q2pro all over again from the same pinned commit.
#
# Merging them costs the server target nothing, and that is the point: the
# colosseum source arrives as a NAMED BUILD CONTEXT rather than a clone,
# because its repository is private, and BuildKit resolves a named context
# only for stages it actually builds.  `--target server` therefore needs no
# colosseum checkout, no extra flag, and is unaffected by anything that
# changes in it -- verified by building it with the context absent.
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
# Switched back to upstream 2026-08-19: both PRs merged (#27
# "fix-required-msg-userinfo-key" on 2026-08-09 as 3c07c62, #28
# "fix-cloud-admin-crashes" on 2026-08-10 as a24e67b) and the fork is gone
# from GitHub entirely (confirmed via `gh repo list` - not renamed, just
# absent), presumably deleted once redundant. Re-verified both fixes'
# actual content against upstream main rather than trusting the merge
# commit messages alone: required_ui_keys[] no longer includes "msg", and
# every CA_WriteString call in g_cloud.c passes userinfo.raw. Pinned commit
# is the merge tip; don't need a fork or an integration branch anymore.
ARG Q2ADMIN_REPO=https://github.com/packetflinger/q2admin
ARG Q2ADMIN_COMMIT=a24e67b032240a1e6df1ce4ae4a6e2a56a86b542

# THE important knob. Controls the i386 struct-return calling convention
# q2pro uses for gi.trace() (it applies
# __attribute__((callee_pop_aggregate_return(0))) plus -mstackrealign).
#
# DISABLED FOR BOTH SERVERS as of 2026-09-18, because both now run colosseum,
# which this project builds with a modern gcc and which therefore expects the
# modern caller-pops convention. Enabling it against such a build drifts the
# stack 4 bytes after every gi.trace() and the mod segfaults dereferencing a
# bogus trace.ent, usually inside its own SV_PushEntity - confirmed via gdb on
# a real core dump on 2026-08-19, when an engine built with 'enabled' by
# mistake met a freshly-compiled game library.
#
# It only ever mattered for ancient binaries: arena ran a 2014
# gamei386.real.so until 2026-08-19 that genuinely needed 'enabled', while
# xatrix's 2017 build needed it off - which is the whole reason there is one
# image per gamedir. With both on colosseum the two images now differ only in
# runtime env and could be collapsed into one; left alone because that means
# recreating both live containers for no functional gain.
#
# UNRELATED to USE_NEW_GAME_API, which q2proded always gets unconditionally:
# q2pro's meson.build hardcodes -DUSE_SERVER=1 for the server target and
# shared.h defines USE_NEW_GAME_API as (USE_CLIENT || USE_SERVER) whenever the
# game DLL does not override it itself. Read out of q2pro's
# meson.build/meson_options.txt/shared.h/game.h directly, not assumed.
#
# It is a whole-binary compile-time switch, so one engine binary cannot serve
# two mods of different vintages. Getting it backwards produces a server that
# starts fine and then dies on the first map.
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
        && \
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

# THE ENGINE PATCHES COME FROM THE COLOSSEUM REPOSITORY, not from this one.
# colosseum/server/ is where they live, where they are documented, and where
# they are checked (its server/enginepatch.sh) -- that is a directory in the
# colosseum tree and has nothing to do with this file's `server` TARGET, which
# happens to share the word. This is only the build that applies them, in
# filename order, straight after the checkout.
#
# 0001 makes the engine report the game library's bots. A Gladiator-derived
# bot holds no client_t, so a stock engine reports a server with eight bots
# playing as empty -- in the browser and in the `rcon status` WallFly polls
# (see filter-rcon-status.sh). That is true of every Q2 engine including id's
# own; the patch header has the detail.
#
# WHAT THIS COSTS: `--target server` now resolves colosseum-src as well, where
# before only `--target colosseum` did, so the live server build needs the
# clone. The comment on that target below used to record the opposite and has
# been corrected. It is a deliberate trade: one copy of a patch, in the
# repository that owns it, beats two copies that drift apart.
#
# A patch that no longer applies fails the build rather than being skipped,
# which is what pins Q2PRO_COMMIT and colosseum/server/ together: bump the pin
# and refresh the patch in the same commit.
COPY --from=colosseum-src server/q2pro/ /patches/

RUN git clone "$Q2PRO_REPO" /src && \
    cd /src && \
    git checkout --detach "$Q2PRO_COMMIT" && \
    for p in /patches/*.patch; do \
        [ -e "$p" ] || continue; \
        echo "applying $(basename "$p")"; \
        git apply --whitespace=nowarn "$p" || exit 1; \
    done && \
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
    grep -qa 'sv_status_show_bots' /out/q2proded \
        || { echo 'bot-status patch did not reach the binary'; exit 1; }; \
    echo "q2proded OK (ELF32, game-abi-hack=$GAME_ABI_HACK, bot-status patched)"

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
# The colosseum game library                                 (--target colosseum)
# ---------------------------------------------------------------------------
# FROM build, so the engine and the toolchain above are REUSED rather than
# compiled a second time.  Until 2026-09-18 this lived in its own
# Dockerfile-colosseum which cloned and built q2pro all over again, from the
# same repo at the same pinned commit, to get an engine for the mesh harness.
#
# THE SOURCE ARRIVES AS A NAMED BUILD CONTEXT, not a `git clone`, because the
# colosseum repository is PRIVATE and the pinned clones above cannot
# authenticate:
#
#   docker build --target colosseum \
#       --build-context colosseum-src=/home/nils/projects/colosseum \
#       -t colosseum .
#
# THAT CONTEXT USED TO BE THIS TARGET'S ALONE, AND IS NOT ANY MORE.  BuildKit
# resolves a named context only when a stage being built references it, so
# `--target server` once built with no colosseum clone present and no extra
# flags -- verified, not assumed -- and that was the whole reason the two
# Dockerfiles could be merged without the live server image growing a
# dependency on a private repo.  The engine patches ended it: the shared build
# stage above reads `server/q2pro/` out of this same context, so BOTH targets
# now need the flag.  Recorded rather than quietly dropped, because the
# property was load-bearing when it was true.
#
# Omitting the flag on this target fails with `failed to resolve source
# metadata for docker.io/library/colosseum-src`, which reads like a missing
# image rather than a missing flag.  It means the --build-context above.
FROM build AS colosseum-build

# python3 for colosseum's own contract audits, which its Makefile runs as part
# of the build; the shim for its CC_LINUX32.  Installed HERE rather than in the
# shared stage above so that stage stays byte-identical for the server target.
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 && \
    rm -rf /var/lib/apt/lists/*

# A one-line i686-linux-gnu-gcc, so colosseum's Makefile finds the compiler it
# names without being told about it.  `make linux32 CC_LINUX32="gcc -m32"` is
# the obvious alternative and DOES NOT WORK: the linux32 recipe passes the
# value on to a recursive make unquoted, as `CC=gcc -m32`, where make parses
# -m32 as its own option and dies with `invalid option -- '3'`.  A shim keeps
# the compiler a single word, which is what that recipe requires.
RUN printf '%s\n' '#!/bin/sh' 'exec gcc -m32 "$@"' > /usr/local/bin/i686-linux-gnu-gcc && \
    chmod 755 /usr/local/bin/i686-linux-gnu-gcc && \
    i686-linux-gnu-gcc --version | head -1

# ---------------------------------------------------------------------------
# The game library
# ---------------------------------------------------------------------------
# The whole clone, `.git` included, so the build can record which commit it is.
#
# --from=colosseum-src, NOT the build context: this file's context is the
# q2server-dockerfile repo, and a bare `COPY .` here silently copies THAT in
# and then fails several layers later inside `make linux32`, which is exactly
# what it did the first time these two Dockerfiles were merged.
COPY --from=colosseum-src . /src-colosseum

# `make linux32` builds debug AND release into separate directories; release is
# the one installed.  The contract audits and the g_ptrs.c freshness check run
# as part of the build (not on request), so a finding fails this layer the way
# a compiler warning does -- warnings are -Werror in that Makefile.
#
# No `--recurse-submodules` is needed and none is available here: the botlib is
# a submodule, and nothing in the game library depends on it at compile time.
# Bots are deliberately not part of these test servers -- see the note further
# down about AAS files.
RUN set -eu; \
    mkdir -p /out-colosseum; \
    cd /src-colosseum; \
    git rev-parse HEAD > /out-colosseum/commit 2>/dev/null \
        || echo 'unknown (context had no .git)' > /out-colosseum/commit; \
    echo "building colosseum $(cat /out-colosseum/commit)"; \
    make linux32; \
    install -Dm755 release-linux32/gamei386.so /out-colosseum/gamei386.so

RUN set -eu; \
    readelf -h /out-colosseum/gamei386.so | grep -q 'ELF32' \
        || { echo 'colosseum gamei386.so is not ELF32'; exit 1; }; \
    readelf --dyn-syms -W /out-colosseum/gamei386.so | grep -q ' GetGameAPI$' \
        || { echo 'colosseum gamei386.so does not export GetGameAPI'; exit 1; }; \
    strings /out-colosseum/gamei386.so | grep -q '^g_ruleset$' \
        || { echo 'colosseum gamei386.so has no g_ruleset cvar - wrong tree built?'; exit 1; }; \
    # One distinctive cvar per donor, rather than the seven ruleset NAMES: four
    # of those are under four characters and `strings` has a four-character
    # minimum, so `dm`, `sp`, `tdm` and `ctf` can never appear in its output
    # however complete the binary is.  These stand in for the same thing --
    # that every merged donor's code is actually linked in: arenacfg is RA2's,
    # bots_minplayers is OSP tourney's and the bot layer's, capturelimit is
    # Threewave's, g_ruleset is the resolution layer's.
    #
    # The two CONTENT LAYER cvars, `xatrix` and `rogue`, are deliberately not
    # in this list: neither appears as a standalone string in the binary (the
    # compiler pools them into longer literals), so asserting on them fails on
    # a perfectly good library.  `sv ruleset` reports the layers at runtime and
    # the boot test is what checks them.
    for sym in g_ruleset arenacfg bots_minplayers capturelimit minimumplayers botfill; do \
        strings /out-colosseum/gamei386.so | grep -qx "$sym" \
            || { echo "cvar '$sym' missing from the binary - a donor did not link in?"; exit 1; }; \
    done; \
    echo '--- shared libraries it needs ---'; \
    readelf -d /out-colosseum/gamei386.so | grep NEEDED; \
    echo "colosseum gamei386.so OK (ELF32, exports GetGameAPI, every donor linked in)"

# ---------------------------------------------------------------------------
# The botlib, its assets, and the map-prep tool
# ---------------------------------------------------------------------------
# The bot AI is NOT part of the game library: it is a separate shared object,
# `gladiator.so`, dlopen'd by name out of the gamedir and entered through
# GetBotAPI.  It comes from colosseum's own submodule, so it is pinned by the
# colosseum checkout rather than by an ARG here, and it must be built for the
# same platform as the game library -- the loader says so when the bitness does
# not match.
#
# YQ2_ARCH=i386 is not optional.  Left alone, that submodule reads the
# architecture off `uname -m`, which on this builder is x86_64, and it would
# emit a 64-bit object the 32-bit game library cannot load.
#
# CC is the shim rather than `gcc -m32` for the same reason the game library
# uses it: `botlib:` re-enters make, and a CC carrying a space does not survive
# that intact.
RUN set -eu; \
    cd /src-colosseum/vendor/gladiator-bot-restored; \
    [ -f Makefile ] || { echo 'the gladiator-bot-restored submodule is not checked out in the build context - run: git -C <clone> submodule update --init'; exit 1; }; \
    make botlib CC=i686-linux-gnu-gcc YQ2_ARCH=i386; \
    install -Dm755 release/gladiator.so /out-colosseum/gladiator.so; \
    install -Dm644 assets/pak7.pak     /out-colosseum/pak7.pak; \
    install -Dm644 assets/bots.cfg     /out-colosseum/bots.cfg; \
    install -Dm755 tools/vendor/bspc/bspc-linux-x86 /out-colosseum/bspc

RUN set -eu; \
    readelf -h /out-colosseum/gladiator.so | grep -q 'ELF32' \
        || { echo 'gladiator.so is not ELF32 - YQ2_ARCH did not take'; exit 1; }; \
    readelf --dyn-syms -W /out-colosseum/gladiator.so | grep -q ' GetBotAPI$' \
        || { echo 'gladiator.so does not export GetBotAPI - the game could dlopen it and find nothing'; exit 1; }; \
    readelf -h /out-colosseum/bspc | grep -q 'ELF32' || { echo 'bspc is not ELF32'; exit 1; }; \
    echo "botlib OK (ELF32, exports GetBotAPI); pak7.pak $(stat -c%s /out-colosseum/pak7.pak) bytes, bots.cfg $(grep -c . /out-colosseum/bots.cfg) lines, bspc staged"

# ---------------------------------------------------------------------------
# The colosseum runtime                                      (--target colosseum)
# ---------------------------------------------------------------------------
# NOT a production server: nothing runs from this image on the live host. It is
# how the game library REACHES production -- scripts/deploy-colosseum-live.sh
# copies the four artifacts below out of it and installs them into the
# bind-mounted gamedir, because q2admin dlopens <gamedir>/gamei386.real.so and
# baking a game library into the server image would silently overwrite the
# operator's deliberate version choice on every container start.
#
# It is also the throwaway server scripts/make-colosseum-aas.sh runs to compute
# navigation meshes, which is why it carries an engine and a CMD at all.
FROM debian:trixie-slim AS colosseum

# Which gamedir under the bind-mounted /opt/quake2 this container runs, which
# config it execs, and where it starts.  Every one of these is set per service
# by the caller at `docker run` time; the defaults here are the arena one.
#
# THE GAMEDIR NAMES ARE THE LIVE ONES -- `arena` and `xatrix`, not the
# `colosseum` colosseum's own install instructions assume.  The name is not
# private to the server: it is the path clients download content under and what
# the existing per-server configs and custom maps sit in, so an eventual
# migration that renamed it would be a content migration rather than a library
# swap.  Isolation comes from the BASEDIR instead: compose mounts
# ~/quake2-colosseum-server here, a self-contained tree with its own baseq2, and
# the live ~/quake2 is never mounted into these containers at all.
ENV Q2_GAMEDIR="arena"
ENV Q2_IP="localhost"
ENV Q2_PORT="27920"
ENV Q2_SERVER_CFG="test-server.cfg"
ENV Q2_MAP="ra2map1"

# Same as the live images: the host runs Europe/Berlin and a container left on
# UTC shows the wrong time in-game (xatrix's func_clock is how that was found).
ENV TZ=Europe/Berlin

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends libc6:i386 zlib1g:i386 tzdata && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    dpkg-reconfigure -f noninteractive tzdata && \
    apt-get -y autoclean && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/locale/* \
           /var/cache/debconf/*-old /usr/share/doc/*

# UID 1000 matches the host's real `nils` login, so the process can write to its
# bind-mounted gamedir (the console log, and the library install below).
RUN useradd -r -u 1000 -U -s /sbin/nologin -M quake2
RUN mkdir -p /opt/quake2 && chown quake2:quake2 /opt/quake2

COPY --from=build /out/q2proded       /opt/q2pro/q2proded
COPY --from=colosseum-build /out-colosseum/gamei386.so    /opt/colosseum/gamei386.so
COPY --from=colosseum-build /out-colosseum/commit /opt/colosseum/commit
# The bot stack.  gladiator.so, pak7.pak and bots.cfg are installed into the
# gamedir on start exactly like the game library is; bspc is a tool, kept here
# so `scripts/make-colosseum-aas.sh` can reach the 1999 map-prep binary without
# anything being installed on the host.
COPY --from=colosseum-build /out-colosseum/gladiator.so   /opt/colosseum/gladiator.so
COPY --from=colosseum-build /out-colosseum/pak7.pak       /opt/colosseum/pak7.pak
COPY --from=colosseum-build /out-colosseum/bots.cfg       /opt/colosseum/bots.cfg
COPY --from=colosseum-build /out-colosseum/bspc           /opt/colosseum/bspc

USER quake2
WORKDIR /opt/quake2

# THE LIBRARY IS INSTALLED INTO THE GAMEDIR AT EVERY START, and that is the one
# real departure from the production Dockerfile.  There, the game library lives
# in the bind-mounted gamedir and has to be re-extracted from a freshly built
# image BY HAND after every rebuild -- `docker compose restart` reuses whatever
# .so is already on disk and does not know the image changed.  Forgetting that
# step crash-looped both live servers once already.  Copying it in on start
# removes the step and the failure mode with it: the running library is always
# the one in the image that started the container.  It is safe here because
# these gamedirs are this test rig's own and nothing else writes them.
#
# No filter-rcon-status.sh: these servers are NOT public, so the WallFly master
# -server bot never polls them and there is no rcon status spam to filter.  The
# per-match timer lines it also drops are worth keeping on a test server.
#
# `map_override_path maps` is what makes `<gamedir>/maps/<name>.bsp.override`
# work, and the live xatrix server's whole map rotation depends on it: those
# files carry an OVERRIDE_NAME field, so a virtual map name redirects to a
# different .bsp and supplies a replacement entity string --
# `x1492annodomini` loads `maps/1492annodomini.bsp` with xatrix's entities in
# it. Without this cvar those names do not resolve to anything at all. It is
# q2pro's own feature (CM_LoadOverride), not a game-library one, so it works
# the same under colosseum as under openffa, and it is inert in a gamedir that
# has no override files -- which is why it is set here for both services
# rather than per service. The production Dockerfile sets it too.
#
# `maps/` is created because that is where the botlib looks for its .aas
# navigation meshes -- through its OWN file search, not the engine's, so a mesh
# inside a pak would not be found.  One per map, made by
# scripts/make-colosseum-aas.sh; without one the botlib loads, refuses the map
# with "no AAS file available" and destroys every bot that wanted it, which
# reads on the console as no bots at all.
# pak7.pak keeps THAT NUMBER whatever else is installed -- it is the one pak in
# colosseum's numbering that is never renumbered, and neither of these gamedirs
# reaches 7 on its own (arena stops at 2, xatrix at 0), so there is no clash.
CMD install -m 755 /opt/colosseum/gamei386.so /opt/quake2/$Q2_GAMEDIR/gamei386.so && \
    install -m 755 /opt/colosseum/gladiator.so /opt/quake2/$Q2_GAMEDIR/gladiator.so && \
    install -m 644 /opt/colosseum/pak7.pak /opt/quake2/$Q2_GAMEDIR/pak7.pak && \
    install -m 644 -D /opt/colosseum/bots.cfg /opt/quake2/$Q2_GAMEDIR/botcfg/bots.cfg && \
    mkdir -p /opt/quake2/$Q2_GAMEDIR/logs /opt/quake2/$Q2_GAMEDIR/maps && \
    echo "colosseum $(cat /opt/colosseum/commit) -> $Q2_GAMEDIR" && \
    script -qefc "stty -onlcr; /opt/q2pro/q2proded \
        +set basedir /opt/quake2 +set libdir /opt/quake2 +set homedir /opt/quake2 \
        +set dedicated 1 +set public 0 \
        +set game $Q2_GAMEDIR \
        +set ip $Q2_IP +set port $Q2_PORT +set net_port $Q2_PORT \
        +set map_override_path maps \
        +exec $Q2_SERVER_CFG +map $Q2_MAP" /dev/null 2>&1 \
    | tee -a /opt/quake2/$Q2_GAMEDIR/logs/console.log

# ---------------------------------------------------------------------------
# The server runtime                             (--target server, the default)
# ---------------------------------------------------------------------------
# This is what the live containers run: the engine, q2admin, and nothing else.
# The game library they load is NOT in here -- see the colosseum stage above.
FROM debian:trixie-slim AS server

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
    apt-get install -y --no-install-recommends libc6:i386 zlib1g:i386 libssl3t64:i386 tzdata && \
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

# q2admin lands at /opt/q2admin rather than in a gamedir: unlike q2proded it
# has to sit *inside* the bind-mounted gamedir at runtime (the engine loads
# "<gamedir>/gamei386.so"), so the image cannot deliver it there directly, and
# copying over the operator's file from an entrypoint on every start would
# silently overwrite a deliberate version choice. Install it into a gamedir
# once:
#   docker create --name q2admin-extract <image> && \
#   docker cp q2admin-extract:/opt/q2admin/gamei386.so ~/quake2/<gamedir>/ && \
#   docker rm q2admin-extract
#
# The game library q2admin then loads as "gamei386.real.so" is NOT built here.
# Both servers run colosseum, which the --target colosseum stage above builds
# (from a named build context, because that repo is private and the pinned
# clones here cannot authenticate) and scripts/deploy-colosseum-live.sh
# installs. openffa-xatrix
# and rocketarena2 were built here until 2026-09-18 and are gone with them.
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
#
# The final `tee -a` persists that same filtered stream into the
# bind-mounted gamedir (/opt/quake2/$Q2_GAMEDIR -> host ~/quake2/<gamedir>),
# independent of Docker's own container-scoped json-file driver. That
# driver's history is lost whenever the CONTAINER is recreated (not just
# restarted) - which happens on every image rebuild/`docker compose up -d`,
# and both arena and xatrix have been recreated several times already, most
# recently 2026-08-19; nothing from before that survived in `docker logs`.
# tee reads after filter-rcon-status.sh, not before, so the persisted file
# carries the same WallFly/timer/spawn-count noise already stripped rather
# than a second, unfiltered copy of it - `docker logs` and this file show
# identical content, one just outlives the container. mkdir -p first since
# tee won't create the parent directory itself, and a fresh bind-mount
# wouldn't have logs/ yet. Rotation is handled outside the container - see
# rotate-console-logs.sh - since tee has no size cap of its own and this
# CMD's shell has no cheap way to enforce one mid-stream.
CMD mkdir -p /opt/quake2/$Q2_GAMEDIR/logs && script -qefc "stty -onlcr; /opt/q2pro/q2proded +set basedir /opt/quake2 +set libdir /opt/quake2 +set homedir /opt/quake2 +set dedicated 1 +set game $Q2_GAMEDIR +set ip $Q2_IP +set port $Q2_PORT +set net_port $Q2_PORT +set map_override_path maps +exec server1.cfg +exec $Q2_OVERRIDE_CFG" /dev/null 2>&1 | /bin/sh /opt/filter-rcon-status.sh | tee -a /opt/quake2/$Q2_GAMEDIR/logs/console.log
