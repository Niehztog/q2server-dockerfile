#!/bin/bash
#
# setup-colosseum-serverdata.sh -- build the self-contained Colosseum gamedir
# tree that the live deployment is fed from.
#
#   ~/quake2-colosseum-server/arena/    g_ruleset arena          -> live q2pro-arena
#   ~/quake2-colosseum-server/xatrix/   g_ruleset dm + xatrix 1  -> live q2pro-xatrix
#
# IT BUILT TWO NON-PUBLIC TEST SERVERS UNTIL 2026-09-18, which is where its
# shape comes from.  Both live servers moved to colosseum that day and the test
# servers were retired; the tree stayed, because it is where the .aas
# navigation meshes are computed and kept.  scripts/make-colosseum-aas.sh
# builds meshes in it and scripts/deploy-colosseum-live.sh copies them out of
# it into the live gamedirs, so it is a working directory now rather than a
# rehearsal of one.
#
# THE GAMEDIRS KEEP THE LIVE NAMES -- `arena` and `xatrix`, NOT the `colosseum`
# that colosseum's own install instructions assume -- because that is what the
# eventual migration has to do.  The gamedir name is not private to the server:
# it is the path clients download content under, the directory the existing
# per-server configs and custom maps live in, and what `sv_downloadserver`
# resolves against.  Renaming it would turn a game-library swap into a content
# migration.  Nothing in colosseum requires the name: `colosseum` appears in the
# source only as GAMEVERSION, the serverinfo string, never as a lookup path.
#
# So they keep the names and get their OWN BASEDIR instead:
# ~/quake2-colosseum-server/ is a self-contained tree with its own baseq2, and
# the live ~/quake2 is not mounted into these containers at all.  That is
# stronger isolation than a differently-named gamedir would have given -- a bug
# in an unreleased game library cannot reach the live servers' data, because it
# cannot see it.
#
# `xatrix` is a CONTENT LAYER in colosseum, not a ruleset: it is orthogonal to
# all seven rulesets and brings The Reckoning's weapons, items and monsters
# into whichever one is running.  So the xatrix server's replacement is the
# `dm` ruleset with that layer switched on, not a ruleset of its own.
#
# COPIES, NOT SYMLINKS, and not the live gamedirs themselves.  This project's
# own testing discipline is to run a test image "against a *copied* data
# directory before touching the real containers", and it is worth the ~390MB:
# a symlink into ~/quake2/arena would mean a change to the live server's data
# silently changed the test server's too, in both directions -- and it would
# undo the isolation the separate basedir above exists to give.
#
# THE PAK NUMBERING IS COLOSSEUM'S, NOT THE LIVE GAMEDIRS'.  Colosseum reads
# every mod's data out of its OWN gamedir and counts from 0 there, with a
# higher number winning where two archives carry the same file.  The order is
# fixed -- mission packs first, then the mods the rulesets come from -- but
# rows you skip close up, and each of these gamedirs installs exactly one mod:
#
#   arena     RA2's three client paks       -> pak0 pak1 pak2
#   xatrix    The Reckoning's pak0          -> pak0
#
# which is why both start at 0 despite being different rows of that table.
# Retail Quake II's own paks are the exception and stay in baseq2/ -- copied
# into this tree's own baseq2, since the live one is not mounted.
#
# NO LOOSE MAPS ARE COPIED.  All 28 `ra2map*` maps the shipped arena.cfg
# rotates through are inside RA2's three paks (verified, 28/28), and xdm1-xdm7
# plus the 25 Reckoning maps are inside The Reckoning's pak0.  q2dm1-q2dm8 come
# from baseq2's own paks.  So neither the ~194MB of loose .bsp in
# ~/quake2/arena nor the ~360MB in ~/quake2/baseq2/maps has to be copied.
#
# NO BOTS.  Colosseum plays Gladiator bots in all six multiplayer rulesets, but
# a bot needs an .aas navigation mesh PER MAP and only q2dm1-q2dm8 have one
# precomputed.  Neither of these servers runs a stock q2dm map, so bots would
# have nothing to navigate: the botlib, its pak7 and bots.cfg are all left out
# rather than installed and silently useless.
#
# NO q2admin.  The live servers load q2admin as gamei386.so and the real mod as
# gamei386.real.so behind it; these load colosseum DIRECTLY.  That is deliberate
# for a first test -- one new variable, not two -- but it does mean these
# servers have no anticheat, no cvarban/cmdban, and no q2admin-cloud link, so
# whether colosseum runs correctly UNDER q2admin is a separate thing to test
# before any live migration.
#
# IDEMPOTENT.  Existing files are left alone; delete a gamedir to rebuild it.

set -euo pipefail

# Where the source data is read FROM (the live tree, read only - this script
# never writes into it) and where the test tree is built.
QUAKE2_DIR="${QUAKE2_DIR:-/home/nils/quake2}"
SERVER_ROOT="${SERVER_ROOT:-/home/nils/quake2-colosseum-server}"
COLOSSEUM_SRC="${COLOSSEUM_SRC:-/home/nils/projects/colosseum}"

log()  { printf '==> %s\n' "$*"; }
skip() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$COLOSSEUM_SRC/colosseum" ] || die "no colosseum config set at $COLOSSEUM_SRC/colosseum"
[ -d "$QUAKE2_DIR/baseq2" ]       || die "no baseq2 at $QUAKE2_DIR/baseq2"
command -v openssl >/dev/null || die "openssl not found"

# Fresh rcon passwords rather than the one all three live servers share.  That
# reuse is a known issue in this project; there is no reason to extend it to
# two new servers, and a test server's password leaking should not hand anyone
# the live ones.
newpass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

# install_config_set <gamedir> <arena|dm>
#
# TWO OF THESE FILES ARE ARENA-ONLY and must not go into a dm gamedir:
#
#   arena.cfg  Rocket Arena 2's own arena-definition file, in its 1999
#              brace/colon format -- a DIFFERENT file from configs/arena.cfg,
#              which is a console script.  Read through the `arenacfg` cvar by
#              load_config(), under the arena ruleset only, so in a dm gamedir
#              it is 21KB of inert clutter that reads like configuration.
#
#   motd.txt   ...and this one is not inert, it is actively wrong, because BOTH
#              rulesets have a message of the day and BOTH default to that one
#              filename.  Under arena it is the arena menu's, read by
#              load_motd() in src/arena/maploop.c, which reads whole lines with
#              no width limit.  Under dm it is OSP Tourney's, read by
#              OSP_setMOTD() in src/tourney/osp_display.c through the
#              `motd_file` cvar -- and that one parses into `char
#              motdpage[9][33]`: NINE LINES OF THIRTY-TWO COLUMNS, and a longer
#              line is cut at 32 with the remainder of it discarded.
#
#              So colosseum's shipped motd.txt, which is written for the arena
#              menu and mentions the arena menu, rendered on the dm server as
#              a truncated "One library, one venue, many rul" -- its second line
#              is 38 characters.  Neither library is at fault; putting an
#              arena-shaped file in a dm gamedir is.
install_config_set() {
    local dst="$1" kind="$2"
    local shared="server.cfg"
    [ "$kind" = arena ] && shared="server.cfg arena.cfg motd.txt"
    mkdir -p "$dst/configs" "$dst/logs" "$dst/botcfg"
    for f in $shared; do
        [ -f "$COLOSSEUM_SRC/colosseum/$f" ] || continue
        if [ -f "$dst/$f" ]; then
            skip "$(basename "$dst")/$f already present, keeping local edits"
        else
            cp "$COLOSSEUM_SRC/colosseum/$f" "$dst/$f"
        fi
    done
    for f in "$COLOSSEUM_SRC"/colosseum/configs/*.cfg; do
        local base; base="$(basename "$f")"
        if [ -f "$dst/configs/$base" ]; then
            skip "$(basename "$dst")/configs/$base already present, keeping local edits"
        else
            cp "$f" "$dst/configs/$base"
        fi
    done
}

copy_pak() {
    local src="$1" dst="$2"
    [ -f "$src" ] || die "missing source pak: $src"
    if [ -f "$dst" ]; then
        skip "$(basename "$(dirname "$dst")")/$(basename "$dst") already present"
    else
        log "copying $(basename "$src") -> $(basename "$(dirname "$dst")")/$(basename "$dst") ($(du -h "$src" | cut -f1))"
        cp "$src" "$dst"
    fi
}

# ---------------------------------------------------------------- baseq2

# Retail Quake II, which every ruleset is played on and nothing works without.
# Only the paks: ~/quake2/baseq2/maps is another ~360MB of community maps that
# neither of these servers rotates through.
BASEQ2="$SERVER_ROOT/baseq2"
log "building $BASEQ2  (retail Quake II)"
mkdir -p "$BASEQ2"
for n in 0 1 2 3; do
    copy_pak "$QUAKE2_DIR/baseq2/pak$n.pak" "$BASEQ2/pak$n.pak"
done

# ---------------------------------------------------------------- arena

ARENA="$SERVER_ROOT/arena"
log "building $ARENA  (g_ruleset arena)"
install_config_set "$ARENA" arena
# RA2's three v2.50 client paks, already sitting in the live arena gamedir as
# pak0/1/2 -- the same numbering colosseum wants, because arena is the only mod
# installed here.
copy_pak "$QUAKE2_DIR/arena/pak0.pak" "$ARENA/pak0.pak"
copy_pak "$QUAKE2_DIR/arena/pak1.pak" "$ARENA/pak1.pak"
copy_pak "$QUAKE2_DIR/arena/pak2.pak" "$ARENA/pak2.pak"

if [ -f "$ARENA/test-server.cfg" ]; then
    skip "arena/test-server.cfg already present, keeping it"
else
    log "writing arena/test-server.cfg (fresh rcon password)"
    cat > "$ARENA/test-server.cfg" <<EOF
// Non-public Colosseum test server -- Rocket Arena 2 ruleset.
// Stands in for the live q2pro-arena server, which runs Niehztog/rocketarena2.
//
// ORDER MATTERS HERE.  configs/arena.cfg execs server.cfg and then sets the
// ruleset and RA2's own defaults, so anything of ours that must win has to come
// AFTER that exec, not before.

// --- identity and access -------------------------------------------------
// NOT public, and this is the whole point of these servers: master.cfg -- the
// file the live servers exec, which sets "public 1" and names three master
// servers -- is deliberately NOT exec'd anywhere in this file.  The container
// also passes +set public 0 on the command line.  Nothing here registers, so
// no server browser lists it and the WallFly bot never finds it to poll.
set public 0
set hostname "Dediz Colosseum TEST - Rocket Arena 2 [non-public]"
set password ""
// A NEW password, not the one all three live servers share.
set rcon_password "$(newpass)"

// Latched, read at map load, and the ceiling on everything else. Matches the
// live arena server.
set maxclients 24

// --- the ruleset ---------------------------------------------------------
// Sets g_ruleset arena, reads arena.cfg for the 171 per-arena blocks, and
// turns botfill on. g_ruleset is latched: it takes effect at the next map load,
// which is why this exec comes before the container's +map.
exec configs/arena.cfg

// --- overrides, after the exec so they win -------------------------------
// The live arena server's own values.
set timelimit 20
set fraglimit 80

// THE BOT FILL, ON. One switch for every ruleset; what is per ruleset is the
// TARGET. Under `arena` the target is taken from the arena the bots are fed
// into: its `playersperteam` where arena.cfg carries one, and that arena's own
// info_player_deathmatch count where it does not -- which is every PICKUP
// arena, because arena_init() replaces playersperteam with 128 there.
//
// THIS NEEDS colosseum's "An empty arena server fills itself" OR LATER.
//
// Named by SUBJECT and not by hash on purpose: that commit has already been
// amended once upstream (3a7f9c0 -> 3936dbb, same subject), and this project's
// colosseum/openffa/rocketarena2 forks rewrite history routinely -- a hash
// written down here goes stale or vanishes. Two revisions of it matter:
//   - the first made `botfill 1` fill a server nobody has joined yet;
//   - the second added the seat guard, so the fill stops ASKING for a bot once
//     `seated + queued` reaches maxclients. Under `arena` the fill's head count
//     is ONE arena's, so a map whose other arenas hold the clients read as
//     short while the server was full, and the console repeated
//     `can't create bot, maxclients = N` every 32 frames. Nothing was created,
//     so nothing ran away; it just asked in the knowledge it could not be met.
//
// Before the first of those, the fill's target under `arena` was 0 whenever
// nobody was in the arena, which on an empty server meant every arena -- so
// `botfill 1` stood the server empty and waited for the first person, while the
// flat `minimumplayers` beside it seats its bots 3.2s into the level and has
// since 1999. Measured here at the time: `botfill 1` gave 0 bots on an empty
// map, and pinning the `arena` cvar did not help because the target is computed
// from who is IN the arena. This config carried `botfill 0` + `minimumplayers
// 6` as the workaround until that landed.
//
// The fix is RA_StagingArena(): with nobody on the map, one arena -- the one
// the bots are already in, else the lowest-numbered pickup arena -- is treated
// as having a target, and it goes back to 0 the moment anybody is on a team
// anywhere, which hands the server straight back to "follow the people".
// `sv ruleset`'s botfill row prints `staging` while that is the target it is
// reporting, which is the one thing its numbers cannot say for themselves: an
// arena with a target and nobody in it looks exactly like the arena a person
// has just walked out of, and the second of those wants nobody.
//
// `minimumplayers` is 1999's flat count and the ALTERNATIVE to botfill, not a
// companion: CheckMinimumPlayers takes the fill's target INSTEAD of this one.
// Zeroed so the fill is unambiguously the mechanism, as colosseum's own
// configs/arena.cfg does. NOTE THE NAME: `minimumplayers` under arena and ctf,
// `bots_minplayers` under the four OSP rulesets. Both are registered under
// every ruleset, so setting the wrong one is accepted and then quietly ignored.
//
// `maxclients` (24 above) is the real ceiling and it is latched. Keep it ABOVE
// the target `sv ruleset` prints: the fill only gives a seat back to a player
// already on the server, so a maxclients at or below the target means bots take
// every slot and somebody arriving finds it full.
set botfill 1
set minimumplayers 0

set allow_download 1
set allow_download_maps 1
set allow_download_players 1
set allow_download_models 1
set allow_download_sounds 1
EOF
    chmod 600 "$ARENA/test-server.cfg"
fi

# ---------------------------------------------------------------- dm

DM="$SERVER_ROOT/xatrix"
log "building $DM  (g_ruleset dm + xatrix 1)"
install_config_set "$DM" dm
# The Reckoning's pak0, which the live xatrix gamedir carries under that same
# name. Verified to be the genuine mission pack: the ionripper and phalanx
# models, sounds and icons, and its 25 maps including xdm1-xdm7.
copy_pak "$QUAKE2_DIR/xatrix/pak0.pak" "$DM/pak0.pak"

# OSP Tourney's MOTD renderer takes NINE LINES OF THIRTY-TWO COLUMNS and cuts
# anything longer, so this one is written to that shape rather than copied from
# colosseum's arena-menu motd.txt (see install_config_set above).
if [ -f "$DM/motd.txt" ]; then
    skip "xatrix/motd.txt already present, keeping it"
else
    log "writing xatrix/motd.txt (<= 9 lines x 32 columns, OSP's limit)"
    cat > "$DM/motd.txt" <<'EOF'
Colosseum TEST - Xatrix DM
NON-PUBLIC, not master-listed
ruleset: dm + xatrix layer
The Reckoning weapons & items
Bots fill to the map's size
Maps: xdm1 - xdm7
EOF
    awk 'length > 32 { print "  WARNING: motd.txt line " NR " is " length " chars, OSP cuts at 32"; }' "$DM/motd.txt"
fi

if [ -f "$DM/test-server.cfg" ]; then
    skip "xatrix/test-server.cfg already present, keeping it"
else
    log "writing xatrix/test-server.cfg (fresh rcon password)"
    cat > "$DM/test-server.cfg" <<EOF
// Non-public Colosseum test server -- free-for-all deathmatch on The
// Reckoning's content.  Stands in for the live q2pro-xatrix server, which runs
// Niehztog/openffa-xatrix.
//
// ORDER MATTERS HERE, and more than on the arena side: configs/dm.cfg execs
// server.cfg, which sets "xatrix 0". Setting the content layer before that exec
// would be silently undone, so it is set after it.

// --- identity and access -------------------------------------------------
// NOT public: master.cfg is deliberately never exec'd here, and the container
// passes +set public 0 as well. See the arena config for the full note.
set public 0
set hostname "Dediz Colosseum TEST - Xatrix DM [non-public]"
set password ""
// A NEW password, and a different one from the arena test server's.
set rcon_password "$(newpass)"

// Latched. Matches the live xatrix server.
set maxclients 16

// --- the ruleset ---------------------------------------------------------
// OSP Tourney DM's RegularDM: plain free-for-all, no ready gate, no teams.
// Latched, so this exec has to come before the container's +map.
exec configs/dm.cfg

// --- overrides, after the exec so they win -------------------------------
// THE CONTENT LAYER, and the reason this server is not just "dm": The
// Reckoning's monsters, weapons and items - the ionripper, the phalanx, the
// trap - in the deathmatch ruleset. Latched like g_ruleset. server.cfg set
// this to 0 a moment ago; this is the line that turns it on.
set xatrix 1

// The live xatrix server's own values.
set timelimit 20
set fraglimit 50

// MAP ROTATION: the live xatrix server's own, all 268 of them, imported by
// scripts/import-xatrix-rotation.sh from ~/quake2/xatrix/mapcfg/maplist.txt.
//
// The list itself is `maps.txt` in this gamedir, NOT `sv_maplist`, and that is
// forced rather than chosen: 268 names is about 2900 characters and a `set`
// line cannot carry it. Colosseum's dm ruleset reads OSP Tourney's own map
// queue first -- the `map_file` cvar, default `maps.txt`, one
// `<map> [min] [max]` per line -- and only falls back to sv_maplist when that
// file is absent, saying so on stdout at boot. The queue is realloc'd per
// entry, so there is no length limit to hit. sv_maplist is deliberately unset:
// two rotations that disagree is the double-rotation hazard colosseum warns
// about under `arena`, and there is no reason to invite it here.
//
// ALMOST EVERY NAME IN THAT LIST IS A VIRTUAL MAP. `x1492annodomini` is not a
// .bsp; it is maps/x1492annodomini.bsp.override, whose OVERRIDE_NAME field
// redirects to maps/1492annodomini.bsp and whose OVERRIDE_ENTS field supplies
// a replacement entity string. That is q2pro's own CM_LoadOverride and not a
// game-library feature, which is why the rotation ports to colosseum at all --
// but it needs `+set map_override_path maps`, which the container passes. With
// that cvar missing the names resolve to nothing whatsoever.
set map_queue 1
set map_file "maps.txt"
// 0 sequential through the queue, 1 random. 1 is the default and what a
// 268-map rotation wants.
set map_random 1
// Use each map once before recycling.
set map_once 1

// THE BOT FILL, ON, and permanently.  One switch for every ruleset; what is per
// ruleset is the target.  Under dm that target is the map's shared spawn pool,
// which is two short of the map's own count because
// SelectRandomDeathmatchSpawnPoint refuses the two spots nearest a player.
//
// NOTE THE NAME: under the four OSP rulesets - dm, dmpro, tdm, duel - the flat
// count is `bots_minplayers`, tourney's own name, NOT the `minimumplayers` that
// arena and ctf use.  Both are registered under every ruleset, so setting the
// wrong one is accepted at the console and then quietly ignored, and an old dm
// config that set `minimumplayers` is no longer read at all.  It is zeroed here
// because it is the ALTERNATIVE to botfill rather than a companion:
// CheckMinimumPlayers takes the fill's target INSTEAD of this one.
//
// `maxclients` above is the real ceiling and it is latched.
//
// This needs the whole bot stack, and three of the four parts arrive on their
// own: the container installs gladiator.so, pak7.pak and botcfg/bots.cfg into
// this gamedir on every start.  The fourth is per map - one .aas navigation
// mesh in maps/, built by scripts/make-colosseum-aas.sh.  Without the mesh the
// botlib loads, refuses the map with "no AAS file available" and destroys
// every bot that wanted it, which reads on the console as no bots at all.
set botfill 1
set bots_minplayers 0

set allow_download 1
set allow_download_maps 1
set allow_download_players 1
set allow_download_models 1
set allow_download_sounds 1
EOF
    chmod 600 "$DM/test-server.cfg"
fi

echo
log "done."
du -sh "$BASEQ2" "$ARENA" "$DM" "$SERVER_ROOT"
echo
echo "    The game library is NOT installed here: the container copies it out of"
echo "    its own image into the gamedir at every start, so the running library is"
echo "    always the one the image was built with. Rebuild and restart is enough;"
echo "    there is no .so to extract by hand the way the live servers need."
echo
echo "    rcon passwords are in each gamedir's test-server.cfg (mode 600)."
