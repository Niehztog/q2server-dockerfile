#!/bin/bash
#
# deploy-colosseum-live.sh -- put colosseum behind q2admin in a LIVE gamedir.
#
# WHAT THIS REPLACES AND WHAT IT KEEPS.  The live servers load q2admin as
# `gamei386.so` and the real mod behind it as `gamei386.real.so`.  Only the
# second one changes here: q2admin, the engine, anticheat, cvarban/cmdban and
# the q2admin-cloud link all stay exactly as they are.
#
#   arena   rocketarena2  -> colosseum, g_ruleset arena
#   xatrix  openffa       -> colosseum, g_ruleset dm + the xatrix content layer
#
# WHY A SCRIPT AND NOT A LIST OF COMMANDS.  The last time a gamedir was set up
# by hand, nothing recorded how, and rebuilding it after the 2026-09-17 data
# loss had to start from scratch.  It is also the only way the REHEARSAL can be
# trusted: point Q2_ROOT at a copy of the live tree, run this, and what is
# tested is what will be deployed rather than something resembling it.
#
#   Q2_ROOT=/home/nils/quake2-rehearsal ./scripts/deploy-colosseum-live.sh arena
#
# IDEMPOTENT.  Backups are taken once and never overwritten, the server1.cfg
# edits are matched before they are applied, and re-running installs the same
# files again rather than a second copy of them.
#
# THE BOT STACK IS FOUR THINGS AND ALL FOUR ARE INSTALLED HERE: the library
# itself, `gladiator.so`, `pak7.pak`, and a `.aas` navigation mesh per map.
# The meshes are NOT recomputed -- they are the ones the test rig already
# built, and they are copied rather than regenerated because computing them
# again is hours of work for a byte-identical result.
#
# AND THE MESHES NEED THE .bsp BESIDE THEM.  The botlib does its own file I/O
# and searches ONLY <basedir>/<gamedir>/maps/ -- not baseq2, and not the paks
# the engine would happily load the map from.  On xatrix almost every rotation
# map lives in baseq2 or inside a pak, so each one is installed loose into the
# gamedir.  Verified byte-identical to the live source first; this changes
# which FILE the engine opens, and it must not change WHAT it opens.

set -euo pipefail

Q2_ROOT="${Q2_ROOT:-/home/nils/quake2}"
SERVER_ROOT="${SERVER_ROOT:-/home/nils/quake2-colosseum-server}"
COLOSSEUM_SRC="${COLOSSEUM_SRC:-/home/nils/projects/colosseum}"
IMAGE="${IMAGE:-colosseum}"
HOSTNAME_SUFFIX="${HOSTNAME_SUFFIX:- w/ Gladiator Bots}"
STAMP="$(date +%Y%m%d)"

# The nine rotation entries whose maps produce no AAS geometry at all -- every
# bspc option combination was tried against v1.4 and none produces a file.  They
# are dropped from the ROTATION only; the maps stay installed and can still be
# loaded by hand.  Leaving them in is not a cosmetic loss: the botlib disables
# itself for the whole session on the first map it cannot load a mesh for and
# never retries, so one of these ends the bots until the container restarts.
DEAD_MAPS="xbeachassault xdhouse xexti xfcityre xgxisland xhidden3 xlavatube xmarics44 xsubzero"

# WRITE VIA RENAME, NEVER IN PLACE.  `install` and `cp` open the destination
# with O_TRUNC, which rewrites the very inode a RUNNING server has its game
# library and paks mapped from -- the deployment would be modifying the code
# under the live process minutes before it is restarted.  rename(2) within the
# directory swaps the name onto a NEW inode instead and leaves the old one
# alive for whoever still has it open, which is the whole point.
ainstall() {   # ainstall <mode> <src> <dst>
    install -m "$1" "$2" "$3.new-$$" && mv -f "$3.new-$$" "$3"
}

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $(basename "$0") <arena|xatrix>"
GD="$1"
case "$GD" in
    arena)  RULESET=arena ;;
    xatrix) RULESET=dm ;;
    *) die "gamedir must be 'arena' or 'xatrix', not '$GD'" ;;
esac

DIR="$Q2_ROOT/$GD"
SRC="$SERVER_ROOT/$GD"

# ------------------------------------------------------------------ preflight
[ -d "$DIR" ]                  || die "no gamedir at $DIR"
[ -f "$DIR/gamei386.so" ]      || die "$DIR/gamei386.so is missing -- that is q2admin, and this deployment goes BEHIND it"
[ -f "$DIR/server1.cfg" ]      || die "no server1.cfg in $DIR"
[ -d "$SRC/maps" ]             || die "no mesh source at $SRC/maps"
command -v docker >/dev/null   || die "docker not found"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "no such image: $IMAGE (build it with: docker build --target colosseum --build-context colosseum-src=$COLOSSEUM_SRC -t $IMAGE .)"

# q2admin must be the thing in front, not colosseum from an earlier run of this
# script: if gamei386.so were colosseum, the engine would load colosseum
# directly and q2admin would be gone from the stack without a word.  q2admin
# exports GetGameAPI only; colosseum exports GetGameAPIEx as well, so the
# presence of the second is the tell.
if readelf --dyn-syms -W "$DIR/gamei386.so" 2>/dev/null | grep -q ' GetGameAPIEx$'; then
    die "$DIR/gamei386.so exports GetGameAPIEx -- that is colosseum, not q2admin. Restore q2admin there first."
fi

log "$GD: colosseum -> $DIR (ruleset $RULESET)"

# ------------------------------------------------- artifacts out of the image
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
docker run --rm -v "$TMP:/out" --entrypoint sh "$IMAGE" -c \
    'cp /opt/colosseum/gamei386.so /opt/colosseum/gladiator.so /opt/colosseum/pak7.pak /opt/colosseum/bots.cfg /opt/colosseum/commit /out/' \
    || die "could not copy the artifacts out of $IMAGE"
COMMIT="$(cat "$TMP/commit")"
info "colosseum $COMMIT"

readelf -h "$TMP/gamei386.so" | grep -q 'ELF32' || die "the image's gamei386.so is not ELF32"
readelf --dyn-syms -W "$TMP/gamei386.so" | grep -q ' GetGameAPI$' || die "the image's gamei386.so does not export GetGameAPI"

# ------------------------------------------------------------------- backups
for f in gamei386.real.so server1.cfg; do
    [ -f "$DIR/$f" ] || continue
    b="$DIR/$f.bak-$STAMP-pre-colosseum"
    if [ -e "$b" ]; then
        info "backup already exists, keeping it: $(basename "$b")"
    else
        cp -p "$DIR/$f" "$b"; info "backed up $f -> $(basename "$b")"
    fi
done

# ------------------------------------------------------------ the game library
# INSTALLED AS gamei386.real.so, which is the name q2admin's own q2admin.cfg
# names in `gamelibrary`.  Writing it to gamei386.so instead would overwrite
# q2admin and silently drop the whole admin layer -- and it would look like it
# worked, because colosseum boots and the bots run.
ainstall 755 "$TMP/gamei386.so"  "$DIR/gamei386.real.so"
ainstall 755 "$TMP/gladiator.so" "$DIR/gladiator.so"
ainstall 644 "$TMP/pak7.pak"     "$DIR/pak7.pak"
mkdir -p "$DIR/botcfg"
ainstall 644 "$TMP/bots.cfg"  "$DIR/botcfg/bots.cfg"
echo "$COMMIT" > "$DIR/colosseum-commit.txt"
info "installed gamei386.real.so, gladiator.so, pak7.pak, botcfg/bots.cfg"

# BEHIND q2admin THE BOT LIST MUST BE A LOOSE FILE.  q2admin does not forward
# the engine's filesystem extension, so colosseum falls back to plain stdio,
# and that arm cannot see inside a pak.  botcfg/bots.cfg above is that loose
# file; pak7.pak still supplies the bot CHARACTERS, which the botlib reads
# through its own file I/O rather than the engine's.
grep -q 'addbot' "$DIR/botcfg/bots.cfg" || die "botcfg/bots.cfg has no addbot lines"

# --------------------------------------------------------- colosseum's configs
ainstall 644 "$COLOSSEUM_SRC/colosseum/server.cfg" "$DIR/server.cfg"
mkdir -p "$DIR/configs"
for c in "$COLOSSEUM_SRC/colosseum/configs/"*.cfg; do ainstall 644 "$c" "$DIR/configs/$(basename "$c")"; done
info "installed server.cfg and configs/ ($(ls "$DIR/configs" | wc -l) rulesets)"

# ------------------------------------------------------------------- the meshes
mkdir -p "$DIR/maps"
n=0
for m in "$SRC/maps"/*.aas; do
    [ -e "$m" ] || continue
    ainstall 644 "$m" "$DIR/maps/$(basename "$m")"; n=$((n+1))
done
info "installed $n navigation mesh(es)"

# A mesh whose reachability lump is empty is bspc's raw geometry output, and it
# is WORSE than no mesh at all: it loads happily and leaves the bots with no
# navigation data, where a missing file at least fails loudly.
python3 - "$DIR/maps" <<'PY'
import struct, sys, os, glob
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.aas'))):
    d = open(f, 'rb').read(120)
    if len(d) < 120 or struct.unpack_from('<i', d, 0)[0] != 0x53414145:
        bad.append(os.path.basename(f) + ':not-an-aas'); continue
    # lump 9 is reachability; bspc leaves it empty and the botlib fills it in.
    if struct.unpack_from('<ii', d, 8 + 9 * 8)[1] == 0:
        bad.append(os.path.basename(f) + ':geometry-only')
if bad:
    print('error: unusable mesh(es): ' + ', '.join(bad), file=sys.stderr)
    sys.exit(1)
PY
info "every mesh carries a reachability lump"

# ------------------------------------------------- xatrix: the rotation's maps
if [ "$GD" = xatrix ]; then
    copied=0; present=0
    for b in "$SRC/maps"/*.bsp; do
        [ -e "$b" ] || continue
        t="$DIR/maps/$(basename "$b")"
        if [ -f "$t" ] && cmp -s "$b" "$t"; then present=$((present+1)); continue; fi
        ainstall 644 "$b" "$t"; copied=$((copied+1))
    done
    info "rotation .bsp: $copied installed, $present already identical"

    # THE ROTATION IS maps.txt, not mapcfg/maplist.txt.  That one is openffa's
    # and nothing reads it any more; colosseum's dm ruleset reads OSP Tourney's
    # own queue through `map_file`, which takes precedence over sv_maplist and
    # has no length limit to hit at 259 names.
    {
        echo "# The live xatrix rotation, from mapcfg/maplist.txt."
        echo "# Read by colosseum's dm ruleset through the map_file cvar."
        echo "#"
        echo "# Nine entries are deliberately absent -- their maps produce no AAS"
        echo "# geometry, and the botlib disables itself for the rest of the session"
        echo "# on the first map it cannot load a mesh for:"
        echo "#   $DEAD_MAPS"
        grep -vE '^\s*(#|$)' "$Q2_ROOT/$GD/mapcfg/maplist.txt" | awk '{print $1}' | while read -r m; do
            case " $DEAD_MAPS " in *" $m "*) continue ;; esac
            echo "$m"
        done
    } > "$DIR/maps.txt"
    info "maps.txt: $(grep -cvE '^\s*(#|$)' "$DIR/maps.txt") entries (9 dropped)"

    # THE MOTD, and it is NOT the live server's own.  openffa read
    # motd/welcome.txt through `g_motd_file`; colosseum's dm ruleset reads
    # `motd_file` (motd.txt) through OSP's reader, into char[9][33] -- NINE ROWS
    # OF THIRTY-TWO COLUMNS, with anything wider cut at 32 and the rest of that
    # line discarded.  The live text is 8 lines but one of them is 35 columns,
    # and it advertises openffa's `ready`/`commands` which this ruleset does not
    # have.  Written only if absent, so a hand-edited one is never clobbered.
    if [ -f "$DIR/motd.txt" ]; then
        info "motd.txt already present, keeping it"
    else
        cat > "$DIR/motd.txt" <<'MOTD'
Dediz Xatrix OpenFFA
now Colosseum + Gladiator bots
ruleset: dm + Xatrix content
Reckoning weapons and items
vote map <name>
vote timelimit/fraglimit <n>
vote kick <id>
Bots fill to the map's size
MOTD
        long=$(awk 'length($0)>32' "$DIR/motd.txt" | wc -l)
        rows=$(wc -l < "$DIR/motd.txt")
        [ "$long" -eq 0 ] || die "motd.txt has $long row(s) wider than 32 columns"
        [ "$rows" -le 9 ] || die "motd.txt has $rows rows, the reader takes 9"
        info "wrote motd.txt ($rows rows, all within 32 columns)"
    fi

fi

# -------------------------------------------------------------- colosseum.cfg
# EXEC'd EARLY, from server1.cfg, and that is deliberate.  g_ruleset is LATCHED:
# it takes effect at the next map load, and server1.cfg loads the first map
# itself -- so a ruleset set from the override cfg the CMD execs afterwards
# would leave the server running its FIRST map under the wrong ruleset.  Early
# also means this server's own values, further down server1.cfg, still win over
# the ruleset defaults exec'd here.
cat > "$DIR/colosseum.cfg" <<CFG
// colosseum.cfg -- what makes this a colosseum server.  Written by
// scripts/deploy-colosseum-live.sh; exec'd from server1.cfg right after
// master.cfg, BEFORE this server's own gameplay values, which therefore win.
//
// colosseum $COMMIT

// Sets g_ruleset, the ruleset's own defaults, and botfill.  configs/$RULESET.cfg
// execs server.cfg first, which is colosseum's shared default surface.
exec configs/$RULESET.cfg
CFG

if [ "$GD" = xatrix ]; then
    cat >> "$DIR/colosseum.cfg" <<'CFG'

// The Reckoning's weapons, items and monsters.  A CONTENT LAYER, not a
// ruleset: orthogonal to all seven, and latched like g_ruleset.
set xatrix 1

// The rotation, and the MOTD.  Both are OSP Tourney's names under this
// ruleset. motd.txt is read into char[9][33] -- NINE ROWS OF THIRTY-TWO
// COLUMNS -- and anything wider is cut, so this gamedir has its own rather
// than the arena-shaped one colosseum ships.
set map_file "maps.txt"
set motd_file "motd.txt"

// THE BOT FILL, ON, with the flat 1999 count zeroed beside it -- they are
// alternatives, not companions.  NOTE THE NAME: bots_minplayers is the
// authoritative one under dm; `minimumplayers` is registered too and would be
// accepted here and then silently ignored.
set botfill 1
set bots_minplayers 0
CFG
else
    cat >> "$DIR/colosseum.cfg" <<'CFG'

// THE BOT FILL, ON, with the flat 1999 count zeroed beside it -- they are
// alternatives, not companions.  NOTE THE NAME: `minimumplayers` is the
// authoritative one under arena; bots_minplayers is registered too and would
// be accepted here and then silently ignored.
//
// Needs colosseum's "An empty arena server fills itself" or later, without
// which botfill leaves an empty arena server empty.
set botfill 1
set minimumplayers 0

// RA2's arena definitions, this server's own file and not the one colosseum
// ships -- 171 arenas across a rotation that includes three custom maps.
set arenacfg "arena.cfg"
CFG
fi
info "wrote colosseum.cfg"

# ------------------------------------------------------------- server1.cfg edits
# IN PYTHON, BECAUSE THESE FILES ARE CRLF.  `sed -i 's|^exec master.cfg$|...|'`
# matches nothing on a line that really ends `master.cfg\r`, and sed reports no
# error when a substitution does not fire -- so the first version of this script
# announced a hostname change and an exec insertion it had not made, and only a
# read-back of the file caught it.  Each edit below is matched, applied and then
# verified, and the file keeps whatever line ending it arrived with.
CFGF="$DIR/server1.cfg"
python3 - "$CFGF" "$GD" "$HOSTNAME_SUFFIX" <<'EDITS'
import re, sys

path, gd, suffix = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(path, 'rb').read().decode('latin-1')
nl = '\r\n' if '\r\n' in raw else '\n'
lines = raw.split(nl)
changed = []

# 1. exec colosseum.cfg, immediately after master.cfg.
if any(l.strip() == 'exec colosseum.cfg' for l in lines):
    print('    server1.cfg: exec colosseum.cfg already present')
else:
    for i, l in enumerate(lines):
        if l.strip() == 'exec master.cfg':
            lines[i:i+1] = [
                l, '',
                '// Colosseum: ruleset, content layer and bots.  Must come before the',
                '// `map` line below -- g_ruleset is latched and applies at the next',
                '// map load, and server1.cfg loads the first map itself.',
                'exec colosseum.cfg',
            ]
            changed.append('inserted exec colosseum.cfg after exec master.cfg')
            break
    else:
        sys.exit('error: server1.cfg has no "exec master.cfg" line to anchor to')

# 2. the hostname suffix, once.
for i, l in enumerate(lines):
    m = re.match(r'^(set\s+hostname\s+")(.*)(".*)$', l)
    if not m:
        continue
    head, name, tail = m.groups()
    if name.endswith(suffix):
        print('    hostname already suffixed: %s' % name)
    else:
        lines[i] = head + name + suffix + tail
        changed.append('hostname: %s%s' % (name, suffix))
    break
else:
    sys.exit('error: server1.cfg has no "set hostname" line')

# 3. xatrix only: maxclients.  The dm fill's target is the MAP's spawn count and
# 14 rotation maps have 16 or more -- at maxclients 16 the bots take every slot
# and an arrival is refused, because the fill only hands a seat back to a player
# already on the server.  The rotation tops out at 21 spawns, so 24 leaves three.
if gd == 'xatrix':
    for i, l in enumerate(lines):
        m = re.match(r'^(set\s+maxclients\s+"?)(\d+)("?.*)$', l)
        if not m:
            continue
        head, val, tail = m.groups()
        if int(val) >= 24:
            print('    maxclients already %s' % val)
        else:
            lines[i] = head + '24' + tail
            changed.append('maxclients: %s -> 24 (bot fill headroom)' % val)
        break
    else:
        sys.exit('error: server1.cfg has no "set maxclients" line')

if changed:
    open(path, 'wb').write(nl.join(lines).encode('latin-1'))
    for c in changed:
        print('    ' + c)

# Read back rather than trust the write.
back = open(path, 'rb').read().decode('latin-1')
assert 'exec colosseum.cfg' in back, 'exec colosseum.cfg did not survive the write'
assert suffix in back, 'the hostname suffix did not survive the write'
if gd == 'xatrix':
    assert re.search(r'^set\s+maxclients\s+"?24', back, re.M), 'maxclients did not survive the write'
EDITS

# ---------------------------------------------------------------------- report
echo
log "$GD ready"
info "library   $(readelf -h "$DIR/gamei386.real.so" | sed -n 's/.*Class:  *//p') $(du -h "$DIR/gamei386.real.so" | cut -f1)  colosseum $COMMIT"
info "meshes    $(ls "$DIR/maps"/*.aas 2>/dev/null | wc -l)"
info "maps      $(ls "$DIR/maps"/*.bsp 2>/dev/null | wc -l) loose .bsp"
info "hostname  $(tr -d '\r' < "$CFGF" | sed -n 's/^set hostname "\(.*\)".*/\1/p' | head -1)"
echo
info "Restart the container to pick this up (bind-mounted files changed, not the image):"
info "    docker compose restart q2pro-$GD"
