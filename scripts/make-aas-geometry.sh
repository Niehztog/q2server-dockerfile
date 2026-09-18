#!/bin/bash
#
# make-aas-geometry.sh [arena|xatrix|both]
#
# Step 1 of making the botlib's navigation meshes: the GEOMETRY pass, for every
# map in a Colosseum test server's rotation.  Step 2 -- reachability and
# clustering -- is `make-colosseum-aas.sh`, which runs ON THE GAME HOST and
# picks up whatever this leaves in each gamedir's `maps/`.
#
# *** THIS SCRIPT DOES NOT RUN ON THE GAME HOST, AND THAT IS THE POINT. ***
#
# The colosseum submodule ships two builds of bspc and its own README says the
# Linux one is the OLDER: `bspc-linux-x86` is v1.2 of 1999-05-20, `bspc.exe` is
# v1.4 of 1999-07-18 -- the opposite direction from the botlib, where the Linux
# drop is the newer one.  That gap is not cosmetic.  v1.2 fails FloodEntities
# with "WARNING: entity reached from outside" / "**** leaked ****" and writes no
# .aas at all on most of these maps: measured at 9 of 28 RA2 maps meshed, 2 of
# the 7 Reckoning deathmatch maps, and 3 of all 25 maps in The Reckoning's pak.
#
# None of the obvious escapes work on v1.2: not `-nocsg` (which the colosseum
# README suggests and which rescued exactly one map of the 28), not
# `-noliquids`, `-freetree`, `-nobrushmerge` or `-breath`; not reading the .bsp
# out of the pak the documented way; not `bsp2map` followed by `map2aas` (which
# leaks at the same point, and whose decompiled output has corrupted classnames
# -- `ammo_blllets`, `info_plyer_deatthmatch`); not stripping the point entities
# first; and not running the binary under buster or stretch glibc instead of
# trixie, which rules out the modern-libc theory.
#
# AND IT IS NOT THE MAPS.  v1.2 leaks on q2dm1 and q2dm2 -- two maps OSP Tourney
# DM shipped PRECOMPUTED meshes for in 1999, made with this same tool, which
# colosseum's own `.github/aas.sh` still downloads and checksums today.  v1.4
# meshes q2dm1 in about a second with no leak, and 35 of 35 maps across both
# rotations.
#
# v1.4 is a Win32 binary.  Under WSL it runs directly through interop, which is
# why this script lives on the workstation and ships its output to the host.
# Wine would do as well; a Linux build of bspc >= 1.4 would be better than
# either, and does not appear to exist.

set -euo pipefail

HOST="${HOST:-nils@192.168.1.38}"
SERVER_ROOT="${SERVER_ROOT:-/home/nils/quake2-colosseum-server}"
# bspc.exe, v1.4.  In a colosseum checkout it is under the botlib submodule; set
# BSPC to point somewhere else if yours lives elsewhere.
BSPC="${BSPC:-}"
WORK="${WORK:-$(cd "$(dirname "$0")/.." && pwd)/.aas-geometry}"

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

WHICH="${1:-both}"
case "$WHICH" in arena|xatrix) GAMEDIRS="$WHICH" ;; both) GAMEDIRS="arena xatrix" ;;
    *) die "usage: $(basename "$0") [arena|xatrix|both]" ;; esac

# Find bspc.exe if not told.
if [ -z "$BSPC" ]; then
    for c in \
        "$(dirname "$0")/../../colosseum/vendor/gladiator-bot-restored/tools/vendor/bspc/bspc.exe" \
        "$HOME/colosseum/vendor/gladiator-bot-restored/tools/vendor/bspc/bspc.exe" \
        "$(dirname "$0")/bspc.exe"; do
        [ -f "$c" ] && { BSPC="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; break; }
    done
fi
[ -n "$BSPC" ] && [ -f "$BSPC" ] || die "bspc.exe not found. Set BSPC=/path/to/bspc.exe
       It is in a colosseum checkout at
       vendor/gladiator-bot-restored/tools/vendor/bspc/bspc.exe
       Use bspc.exe (v1.4), NOT bspc-linux-x86 (v1.2) -- see the header."

# It has to be reachable as a Windows path, so the work directory has to be on a
# Windows drive.  Under WSL that means somewhere under /mnt/<drive>/.
case "$WORK" in /mnt/[a-z]/*) : ;; *) die "WORK must be under /mnt/<drive>/ so bspc.exe can see it: $WORK" ;; esac
"$BSPC" 2>/dev/null | head -1 >/dev/null || true

mkdir -p "$WORK"
log "bspc: $BSPC"
log "work: $WORK"

# ------------------------------------------------- pull the .bsp files

# The maps live inside the paks on the host, and the rotation is whatever that
# server actually plays: RA2's own `maploop:` out of arena.cfg for the arena
# server, `sv_maplist` out of test-server.cfg for the xatrix one.  Both are read
# there rather than repeated here, so this cannot drift from what is played.
log "extracting the rotation's .bsp files on $HOST"
ssh -A "$HOST" "SERVER_ROOT='$SERVER_ROOT' python3 - $GAMEDIRS" <<'PY' > /dev/null
import struct, os, re, sys, tarfile
TEST = os.environ.get('SERVER_ROOT', '/home/nils/quake2-colosseum-server')
def rotation(gd):
    if gd == 'arena':
        t = open(TEST + '/arena/arena.cfg', encoding='latin1').read().replace('\r', '')
        return re.search(r'^\s*maploop:\s*(.*?);', t, re.M).group(1).split()
    t = open(TEST + '/%s/test-server.cfg' % gd, encoding='latin1').read()
    return re.search(r'^\s*set\s+sv_maplist\s+"([^"]*)"', t, re.M).group(1).split()
def index(d):
    tbl = {}
    for p in sorted(os.listdir(d)):
        if not p.lower().endswith('.pak'): continue
        full = os.path.join(d, p)
        f = open(full, 'rb'); magic, off, size = struct.unpack('<4sii', f.read(12))
        if magic != b'PACK': continue
        f.seek(off)
        for _ in range(size // 64):
            e = f.read(64); n = e[:56].split(b'\0')[0].decode('latin1')
            o, l = struct.unpack('<ii', e[56:64]); tbl[n.lower()] = (full, o, l)
    return tbl
os.system('rm -rf /tmp/bsps && mkdir -p /tmp/bsps')
for gd in sys.argv[1:]:
    tbl, base = index(TEST + '/' + gd), index(TEST + '/baseq2')
    outd = '/tmp/bsps/' + gd; os.makedirs(outd, exist_ok=True)
    for m in rotation(gd):
        hit = tbl.get('maps/%s.bsp' % m.lower()) or base.get('maps/%s.bsp' % m.lower())
        if not hit: print('MISSING', gd, m, file=sys.stderr); continue
        full, o, l = hit
        f = open(full, 'rb'); f.seek(o)
        open(os.path.join(outd, m + '.bsp'), 'wb').write(f.read(l))
os.system('tar czf /tmp/bsps.tgz -C /tmp bsps')
PY
scp -q "$HOST:/tmp/bsps.tgz" "$WORK/bsps.tgz"
rm -rf "$WORK/bsps"; tar xzf "$WORK/bsps.tgz" -C "$WORK"; rm -f "$WORK/bsps.tgz"
ssh -A "$HOST" 'rm -f /tmp/bsps.tgz; rm -rf /tmp/bsps'

# ------------------------------------------------- the geometry pass

total_ok=0; total_bad=0
for gd in $GAMEDIRS; do
    d="$WORK/bsps/$gd"
    [ -d "$d" ] || { info "$gd: nothing extracted"; continue; }
    n=$(ls "$d"/*.bsp 2>/dev/null | wc -l)
    log "$gd: $n map(s)"
    ok=0; bad=""
    for b in "$d"/*.bsp; do
        m="$(basename "$b" .bsp)"
        rm -f "$d/$m.aas"
        ( cd "$d" && "$BSPC" -bsp2aas "$m.bsp" >/dev/null 2>&1 ) || true
        if [ ! -f "$d/$m.aas" ]; then
            # The colosseum README's documented fallback for a leak.  It rescues
            # very little on v1.2 and is rarely needed at all on v1.4.
            ( cd "$d" && "$BSPC" -nocsg -bsp2aas "$m.bsp" >/dev/null 2>&1 ) || true
        fi
        if [ -f "$d/$m.aas" ]; then ok=$((ok + 1)); else bad="$bad $m"; fi
    done
    info "$gd: $ok/$n meshed${bad:+ | FAILED:$bad}"
    total_ok=$((total_ok + ok)); [ -n "$bad" ] && total_bad=$((total_bad + 1)) || true
done

# ------------------------------------------------- ship them

log "installing the geometry meshes into the gamedirs on $HOST"
for gd in $GAMEDIRS; do
    d="$WORK/bsps/$gd"
    ls "$d"/*.aas >/dev/null 2>&1 || continue
    tar czf "$WORK/$gd-aas.tgz" -C "$d" $(cd "$d" && ls *.aas)
    scp -q "$WORK/$gd-aas.tgz" "$HOST:/tmp/$gd-aas.tgz"
    # The .done markers describe the meshes being replaced, so they go with
    # them: otherwise step 2 skips a geometry-only mesh as already finished.
    ssh -A "$HOST" "set -e
        rm -rf '$SERVER_ROOT/$gd/.aas-state'
        mkdir -p '$SERVER_ROOT/$gd/maps'
        rm -f '$SERVER_ROOT/$gd'/maps/*.aas
        tar xzf /tmp/$gd-aas.tgz -C '$SERVER_ROOT/$gd/maps'
        rm -f /tmp/$gd-aas.tgz
        echo \"    $gd: \$(ls '$SERVER_ROOT/$gd'/maps/*.aas | wc -l) geometry meshes installed\""
    rm -f "$WORK/$gd-aas.tgz"
done

echo
log "geometry done: $total_ok mesh(es)"
echo "    Now run step 2 ON THE HOST, which computes reachability and clustering:"
for gd in $GAMEDIRS; do
    echo "      ssh $HOST 'cd ~/projects/q2server-dockerfile && ./scripts/make-colosseum-aas.sh $gd'"
done
