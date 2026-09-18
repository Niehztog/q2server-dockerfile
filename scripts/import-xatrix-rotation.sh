#!/bin/bash
#
# import-xatrix-rotation.sh -- give the colosseum xatrix test server the LIVE
# xatrix server's map rotation, instead of the seven stock Reckoning deathmatch
# maps it starts life with.
#
# WHAT THE LIVE ROTATION ACTUALLY IS, because the names do not match the files
# and that is the whole trick.  `~/quake2/xatrix/mapcfg/maplist.txt` lists 268
# mostly `x`-prefixed names, and almost none of them exist as a `.bsp`.  Each is
# a VIRTUAL MAP built by a `.bsp.override` file in the gamedir's `maps/`:
# q2pro's own feature, `map_override_path` + `CM_LoadOverride`, whose header
# carries an OVERRIDE_NAME field naming the real `.bsp` to load and an
# OVERRIDE_ENTS field carrying a replacement entity string.  So
#
#   x1492annodomini  ->  maps/1492annodomini.bsp   + 52923 bytes of entities
#   xmarics39        ->  maps/marics39.bsp         +  7859
#   xagone           ->  maps/xagone.bsp           + 26457   (self-referencing)
#
# That is an ENGINE feature and not a game-library one, which is what makes this
# portable at all: it behaves identically under colosseum and under the
# openffa-xatrix the live server runs.  The container must pass
# `+set map_override_path maps` or none of these names resolve to anything --
# the colosseum image's CMD does.
#
# THE ROTATION IS maps.txt, NOT sv_maplist.  268 names is roughly 2900
# characters and a `set` line cannot carry that.  Colosseum's `dm` ruleset reads
# OSP Tourney's own map queue first -- `map_file`, default `maps.txt`, in the
# gamedir, one `<map> [min] [max]` per line, `#` comments -- and only falls back
# to `sv_maplist` when that file is absent (it says so on stdout at boot).  The
# queue is realloc'd per entry, so there is no length limit to hit.
#
# COPIES, NOT SYMLINKS, into the test tree's own basedir, for the same reason
# everything else here is copied: the live data must not be reachable from these
# containers at all.  ~380MB.
#
# The 17 names whose `.bsp` is not a loose file are not missing -- they are
# stock Quake II maps (q2dm2, base1, boss1, fact3 ...) inside baseq2's paks,
# which the test tree already has.  Nothing to copy for those.
#
# IDEMPOTENT.  Existing files are left alone.

set -euo pipefail

LIVE="${LIVE:-/home/nils/quake2}"
SERVER_ROOT="${SERVER_ROOT:-/home/nils/quake2-colosseum-server}"
GAMEDIR="${GAMEDIR:-xatrix}"

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$LIVE/$GAMEDIR/mapcfg/maplist.txt" ] || die "no live maplist at $LIVE/$GAMEDIR/mapcfg/maplist.txt"
[ -d "$SERVER_ROOT/$GAMEDIR" ]               || die "no test gamedir at $SERVER_ROOT/$GAMEDIR -- run setup-colosseum-serverdata.sh first"

log "importing the live $GAMEDIR rotation into $SERVER_ROOT/$GAMEDIR"

LIVE="$LIVE" SERVER_ROOT="$SERVER_ROOT" GAMEDIR="$GAMEDIR" python3 - <<'PY'
import os, struct, shutil, sys

LIVE = os.environ['LIVE']; TEST = os.environ['SERVER_ROOT']; GD = os.environ['GAMEDIR']
NAME, CSUM, ENTS = 1, 2, 4

def override_target(path):
    """The .bsp an override redirects to, or None if it names no replacement."""
    with open(path, 'rb') as f:
        d = f.read(72)
    bits, = struct.unpack_from('<i', d, 0)
    if not (bits & NAME):
        return None
    return d[4:68].split(b'\0')[0].decode('latin1')

maps = [l.strip() for l in open('%s/%s/mapcfg/maplist.txt' % (LIVE, GD), encoding='latin1') if l.strip()]

os.makedirs('%s/%s/maps' % (TEST, GD), exist_ok=True)

copied_ov = skipped_ov = 0
copied_bsp = skipped_bsp = 0
in_pak = []
bytes_copied = 0

for m in maps:
    src_ov = '%s/%s/maps/%s.bsp.override' % (LIVE, GD, m)
    if os.path.exists(src_ov):
        dst_ov = '%s/%s/maps/%s.bsp.override' % (TEST, GD, m)
        if os.path.exists(dst_ov):
            skipped_ov += 1
        else:
            shutil.copyfile(src_ov, dst_ov); copied_ov += 1
        target = override_target(src_ov) or 'maps/%s.bsp' % m
    else:
        target = 'maps/%s.bsp' % m

    base = os.path.basename(target)
    # EVERYTHING GOES IN THE GAMEDIR'S maps/, even the .bsp files the live tree
    # keeps in baseq2/maps.  The engine would find them either way -- it
    # searches the gamedir and then baseq2 -- but THE BOTLIB DOES ITS OWN FILE
    # I/O and searches only <basedir>/<gamedir>/.  BotLibLoadMap() opens
    # `maps\<map>.bsp` through that search before it ever looks for the .aas,
    # so a rotation map whose .bsp sits in baseq2 is a map the bots cannot load
    # however good its mesh is.  It never mattered on the live server because
    # that one has no bots.
    for sub in (GD, 'baseq2'):
        src = '%s/%s/maps/%s' % (LIVE, sub, base)
        if os.path.exists(src):
            dst = '%s/%s/maps/%s' % (TEST, GD, base)
            if os.path.exists(dst):
                skipped_bsp += 1
            else:
                shutil.copyfile(src, dst)
                copied_bsp += 1; bytes_copied += os.path.getsize(src)
            break
    else:
        # Not a loose file: a stock map inside baseq2's paks, which the test
        # tree already carries.  Nothing to do.
        in_pak.append(base)

print('    overrides: %d copied, %d already present' % (copied_ov, skipped_ov))
print('    .bsp     : %d copied (%.0f MB), %d already present' % (copied_bsp, bytes_copied/1048576, skipped_bsp))
print('    in paks  : %d (stock maps, nothing to copy)' % len(set(in_pak)))

# maps.txt -- OSP's queue format.  No per-map min/max: the live server does not
# gate its rotation on player count either, and map_nocount defaults to 0 so an
# entry with no bounds is simply never refused for population.
out = '%s/%s/maps.txt' % (TEST, GD)
if os.path.exists(out):
    print('    maps.txt : already present, keeping it')
else:
    with open(out, 'w', encoding='latin1') as f:
        f.write('# The live xatrix server\'s rotation, imported from\n'
                '# %s/%s/mapcfg/maplist.txt by scripts/import-xatrix-rotation.sh\n'
                '#\n'
                '# Read by colosseum\'s `dm` ruleset through the `map_file` cvar (OSP\n'
                '# Tourney\'s own map queue), which takes precedence over sv_maplist.\n'
                '# One `<map> [min] [max]` per line; no bounds here, as the live server\n'
                '# sets none.  Almost every name is a VIRTUAL map resolved by\n'
                '# maps/<name>.bsp.override -- see the script header.\n' % (LIVE, GD))
        for m in maps:
            f.write('%s\n' % m)
    print('    maps.txt : written, %d map(s)' % len(maps))
PY

log "done."
du -sh "$SERVER_ROOT/$GAMEDIR" "$SERVER_ROOT/baseq2" 2>/dev/null || true
echo
echo "    The rotation is live only once the server re-reads it: the maps.txt"
echo "    queue is loaded at level start, so restart the service."
echo "    Bots need one .aas per map, so the new maps have none yet --"
echo "    scripts/make-aas-geometry.sh then scripts/make-colosseum-aas.sh."
