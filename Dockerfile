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
#
# Bumped again 2026-08-06 (34888fa -> 96f9b73): the fork owner's own
# follow-up work, not mine - history got rewritten again along the way
# (the two fixes above now live at different hashes than described, same
# content though) so only the tip hash matters. Includes a genuine
# refinement of fix #1 above: motd_framenum/motd_shown moved from
# client_respawn_t (resp) to client_persistant_t (pers), because resp is
# ALSO wiped by ordinary spectator respawns (typing "observe"), not just
# level resets/new connects - under the old placement, switching to
# spectator mid-match re-armed the MOTD auto-show, not just genuine new
# levels. ClientBegin() still explicitly re-arms both fields on every
# level load, so "shows again each map" (matching q2admin's original
# documented intent) is preserved; only the unwanted "also re-arms on any
# spectator toggle" side effect is gone. Plus 5 unrelated fixes to the
# imported xatrix 3.20 weapon/entity code: two real memory-safety bugs
# (a use-after-free in Trap_Think(), an unchecked G_Find() result crash
# in misc_viper_missile_use()), several xatrix entities that were ticking
# every frame or never firing at all because they stored think times as
# level.time (seconds) instead of frame numbers, a trap throw-speed bug
# (same frames-vs-seconds mixup) plus a missing weapon-model index that
# left WEAP_TRAP unreachable and capable of an out-of-bounds inventory
# write if g_weapon_have/g_weapon_initial ever included its bit, xatrix
# weapons (Ionripper/Phalanx/Trap) and DualFire finally wired into the
# accuracy/damage stats and item-ban systems (directly relevant now that
# CONFIG_SQLITE is on), and a build fix for the (unused here, XATRIX is
# unconditionally #define'd in g_local.h) non-xatrix build configuration.
# Bumped again 2026-08-06 (96f9b73 -> 94d1e9c): another forced-update
# rewrite (this fork's history moves routinely now, not just at big
# upstream-merge points - see the project memory on this). The 5 fixes
# above all carried forward under new hashes, same content. 4 new fixes
# on top:
# - Cmd_WeapNext_f/Cmd_WeapPrev_f (g_cmds.c) looped one step too far and
#   could re-select the weapon already held; for the HyperBlaster/Railgun
#   that calls Use_Weapon2() on itself, silently toggling to the
#   Ionripper/Phalanx instead of just cycling normally.
# - SV_Push (g_phys.c) lost the epsilon gi.linkentity() normally pads
#   absmin/absmax with once SV_RealBoundingBox started computing an exact
#   box, so entities sitting exactly flush against a mover (door/plat)
#   could be excluded from its "am I about to crush something" test.
# - G_KillBox's spawn-telefrag trace (g_utils.c) included
#   CONTENTS_PLAYERCLIP|CONTENTS_WINDOW in its mask; ordinary world solid
#   brushes block regardless of mask, so on maps whose spawn points sit
#   flush with the floor the world itself, not the occupying player, was
#   reported as the hit and the telefrag never happened. Narrowed to
#   CONTENTS_MONSTER only.
# - DualFire shared EF_QUAD's glow (p_view.c), making it indistinguishable
#   from real Quad Damage; switched to the already-defined EF_DOUBLE, plus
#   its own firing-cue sound (items/quadfire3.wav, already a precached
#   asset). Also: Pickup_Powerup's dropped-DualFire timeout branch
#   (g_items.c) never ran under DF_INSTANT_ITEMS, a Trap-specific
#   ammo-drop guard, a proper Trap ammo-count floor at zero
#   (weapon_trap_fire, p_weapon.c), a Phalanx attempt-count fix so hit%
#   can't read over 100, missing obituary strings for the 3 trap-related
#   MOD_ constants (all pre-existing, unused until now), and
#   Trap_Think's kill-credit MOD switched from generic MOD_EXPLOSIVE to
#   MOD_TRAP_SPLASH so the trap's owner is actually credited.
ARG OPENFFA_REPO=https://github.com/Niehztog/openffa-xatrix
ARG OPENFFA_COMMIT=94d1e9c0ba3030095955c8ee9ea8cc980d144ae4

# Enables g_sqlite.c (see the ARG comment above for why CONFIG_CURL/
# CONFIG_UDP must stay off if this is on). Needs libsqlite3-dev:i386 here
# and libsqlite3:i386 in the runtime stage - see both apt-get lines below.
ARG OPENFFA_CONFIG_SQLITE=1

# arena's own game DLL, Rocket Arena 2 - like openffa-xatrix above, was NOT
# built by this Dockerfile until 2026-08-19: ~/quake2/arena/gamei386.real.so
# was a manually-produced 2014 binary of unknown provenance, never rebuilt
# through any tracked process.
#
# Niehztog/rocketarena2 is the user's own project: a from-scratch source
# reconstruction of RA2 (a 1999 mod whose source was never released),
# recovered from evidence in the shipped binaries (722/730 functions on its
# `main` branch still assemble byte-identical to the original gamex86.dll).
# `q2pro-enhancements` (pinned below) takes that reconstruction and rebases
# the whole of q2pro's baseq2 commit history onto it - 188 commits, done as
# a genuine rebase against the shared id-3.20 root rather than a hand-port -
# bringing in the modern game API, frame-number timers, the rewritten
# savegame system, protocol extensions, and ~20 years of upstream crash/
# overflow/OOB fixes, while keeping all 43 RA2 cvars, 39 client commands, 111
# spawn classnames and the grapple intact. The dead GameSpy stats SDK
# (six vendored files, phoned home to a gamestats.gamespy.com host that's
# been offline for years, retried forever on every failure) is replaced with
# a local one - see the statsfile/statsname cvars. Full writeup:
# doc/q2pro-port.md in that repo.
#
# Per that writeup: this is explicitly NOT battle-tested - "the tree has
# still not been run against a live server, so treat this as materially
# safer than the reconstruction rather than as audited". A post-port
# review (not exhaustive, by the author's own account) already found and
# fixed 15 defects, 3 of them showstoppers that would not have been visible
# to the compiler: game.maxclients was never initialised (client array
# allocated for zero entries), a qboolean->bool retype shrank
# arena_settings_t from 168 to 96 bytes while ra2menus.c still punned it as
# int[42] (4 OOB writes), and four bool[7] arrays were written through a
# stale extern int[] in another translation unit (21 bytes OOB, on every
# map load). Test this at least as thoroughly as any change this project has
# shipped so far - more, if anything, given the above.
#
# Bumped 2026-08-19 (191a101 -> c7d0f3a, same "fix fifteen defects" commit
# amended, not a new one - title unchanged, hash isn't): fixes the
# arena-assignment regression this project's own pre-production testing
# found in 191a101 (see project memory q2-rocketarena2-port) - map entities'
# "arena" key is back in g_spawn.c's spawn_fields[] (FOFS(arena), F_INT),
# confirmed via diff, not just the commit message. Also fixes an unrelated
# second silently-dropped map key found the same way: the classic Quake2
# func_train "pausetime" key (a float, first-time-only extra delay) had been
# mis-keyed in the field table as "pause_framenum" - a real but differently
# named field on monsterinfo_t (monster AI pausing, untouched, still an int)
# - so any map using the standard "pausetime" key on a path_corner-style
# entity silently lost that delay. Renamed back to "pausetime" with its own
# st.pausetime float, matching what real .map files actually contain.
ARG ROCKETARENA2_REPO=https://github.com/Niehztog/rocketarena2
ARG ROCKETARENA2_COMMIT=c7d0f3a27ff830f4f3e619fd82f8f592057a686a

# THE important knob. Controls the i386 struct-return calling convention
# q2pro uses for gi.trace() (it applies
# __attribute__((callee_pop_aggregate_return(0))) plus -mstackrealign).
#
#   arena  -> disabled as of 2026-08-19 (was enabled until then - arena's
#                         old gamei386.real.so was a 2014 binary expecting
#                         the old callee-pops convention; without the hack
#                         the stack drifts 4 bytes after every gi.trace()
#                         and the mod segfaults dereferencing a bogus
#                         trace.ent, crashing in its own SV_PushEntity).
#                         That binary is retired - see the
#                         ROCKETARENA2_COMMIT ARG above - and the
#                         replacement is fresh-compiled with this same
#                         Dockerfile's own modern gcc, same as xatrix's
#                         gamei386.real.so, hence the modern convention.
#                         Confirmed the hard way while testing the switch:
#                         built and ran the new RA2 binary against an
#                         engine still built with 'enabled' by mistake (a
#                         leftover docker-compose.yml value) - immediate
#                         SIGSEGV on server init, right after the MOTD
#                         loads, confirmed via gdb against the actual core
#                         dump. The two must always change together.
#                         This is UNRELATED to the RA2 game DLL's own
#                         USE_NEW_GAME_API=1 (see its config.h) - that
#                         macro only widens GAME_API_VERSION from
#                         GAME_API_VERSION_OLD(3) to _NEW(3302) inside the
#                         shared game.h struct layout (gclient_old_t/
#                         pmove_old_t vs gclient_new_t/pmove_new_t) the game
#                         DLL compiles against, and q2proded (this Dockerfile
#                         only ever builds q2proded, never a client) always
#                         gets USE_NEW_GAME_API=1 unconditionally regardless
#                         of this flag or any meson option - q2pro's own
#                         meson.build hardcodes -DUSE_SERVER=1 for the server
#                         target, and shared.h defines USE_NEW_GAME_API as
#                         (USE_CLIENT || USE_SERVER) whenever the game DLL
#                         doesn't override it itself. Confirmed by reading
#                         q2pro's meson.build/meson_options.txt/shared.h/
#                         game.h directly, not assumed from doc language.
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

# rocketarena2's Makefile targets a workstation build (native ARCH=x86_64 by
# default, real "make windows" MinGW cross-targets too) - none of its six
# stock configurations produce the i386 Linux .so this project needs. M32=
# -m32 forces every compile+link step to -m32 (same mechanism as q2admin/
# openffa's CC="gcc -m32" above; this Makefile threads the flag through a
# dedicated var instead since it also has to compose with MinGW's CC
# override). ARCH is cosmetic here - it only names the output file
# (game$(ARCH).so) - set to i386 purely so the built filename matches this
# project's convention; nothing reads it besides this install line, since
# the file is renamed on the way out same as q2admin/openffa's builds are.
# Output installed under a name distinct from openffa's above - both mods'
# game DLLs are built into every image (harmless, a few extra seconds), but
# only one is ever actually extracted into a given gamedir at deploy time.
RUN git clone "$ROCKETARENA2_REPO" /src-ra2 && \
    cd /src-ra2 && \
    git checkout --detach "$ROCKETARENA2_COMMIT" && \
    make build_release M32=-m32 ARCH=i386 && \
    install -Dm755 release/gamei386.so /out/ra2-gamei386.real.so

# Fail the build rather than ship a silently-wrong engine, same reasoning as
# every other build-validation step above. statsfile/statsname are cvars
# unique to this port's local JSON stats log (see the ROCKETARENA2_COMMIT
# ARG comment) - a genuinely old/unmodified RA2 binary wouldn't have them,
# so this also catches an accidental wrong-commit/wrong-branch pin, the same
# failure mode the g_warmup check above exists to catch for openffa.
RUN set -eu; \
    readelf -h /out/ra2-gamei386.real.so | grep -q 'ELF32' || { echo 'rocketarena2 gamei386.real.so is not ELF32'; exit 1; }; \
    strings /out/ra2-gamei386.real.so | grep -q '^statsfile$' \
        || { echo 'rocketarena2 gamei386.real.so is missing statsfile - wrong commit/branch pinned?'; exit 1; }; \
    echo "rocketarena2 gamei386.real.so OK (ELF32, has statsfile)"

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

# q2admin (and the real game DLL it wraps - openffa-xatrix for xatrix,
# rocketarena2 for arena) land at /opt/q2admin, /opt/openffa and
# /opt/rocketarena2, not directly in a gamedir: unlike q2proded, they have to
# sit *inside* the bind-mounted gamedir at runtime (q2admin dlopens
# "<gamedir>/gamei386.real.so" - or whatever "gamelibrary" names - relative
# to the process CWD), so the image can't deliver them there directly, and
# copying over the operator's file from an entrypoint on every start would
# silently overwrite a deliberate version choice. Install into a gamedir
# once, the same "one-time game data preparation" way as before:
#   docker create --name q2admin-extract <image> && \
#   docker cp q2admin-extract:/opt/q2admin/gamei386.so ~/quake2/<gamedir>/ && \
#   docker cp q2admin-extract:/opt/openffa/gamei386.real.so ~/quake2/xatrix/ && \
#   docker cp q2admin-extract:/opt/rocketarena2/gamei386.real.so ~/quake2/arena/ && \
#   docker rm q2admin-extract
COPY --from=build /out/q2proded /opt/q2pro/q2proded
COPY --from=build /out/gamei386.so /opt/q2admin/gamei386.so
COPY --from=build /out/gamei386.real.so /opt/openffa/gamei386.real.so
COPY --from=build /out/ra2-gamei386.real.so /opt/rocketarena2/gamei386.real.so
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
