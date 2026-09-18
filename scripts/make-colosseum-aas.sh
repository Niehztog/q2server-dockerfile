#!/bin/bash
#
# make-colosseum-aas.sh <arena|xatrix> [map ...]
#
# Build the botlib's AAS navigation meshes for a Colosseum test server's map
# rotation.  `botfill 1` is set permanently in both test-server.cfg files, but
# the fill can only place a bot on a map that has one of these: without it the
# botlib loads, refuses the map with "no AAS file available" and destroys every
# bot that wanted it -- which on the console reads as no bots at all, with
# nothing naming the mesh as the reason.
#
# ONE MESH PER MAP, AND THERE IS NO WAY AROUND IT.  Only eight precomputed
# meshes have ever been distributed -- q2dm1..q2dm8, which OSP Tourney DM
# shipped in 1999 -- and neither of these servers runs a stock q2dm map.  The
# `autolaunchbspc` libvar looks like the answer and is not: that code path
# exists only on Windows, wants a winbspc.exe in the gamedir, and the rebuilt
# botlib's SpawnProcess is an empty stub.  So it is the two documented steps,
# per map, and this script is those two steps in a loop:
#
#   1. `bspc -bsp2aas <map>.bsp` computes the geometry.
#
#      *** USE bspc.exe v1.4, NOT THE BUNDLED LINUX bspc v1.2. ***
#
#      The submodule ships both, and its own README says the Linux binary is
#      the older of the two: `bspc-linux-x86` is v1.2 of 1999-05-20, `bspc.exe`
#      is v1.4 of 1999-07-18 -- the opposite direction from the botlib, where
#      the Linux drop is the newer.  That version gap is not cosmetic.  v1.2
#      fails `FloodEntities` with "WARNING: entity reached from outside" and
#      "**** leaked ****" on most of these maps and writes no .aas at all:
#      measured at 9 of 28 RA2 maps and 2 of 7 Reckoning maps meshed, and 3 of
#      all 25 maps in The Reckoning's pak.  `-nocsg` rescues almost none of
#      them, and neither does `-noliquids`, `-freetree`, `-nobrushmerge`,
#      `-breath`, reading the .bsp out of the pak the documented way, going via
#      `bsp2map` + `map2aas`, stripping the point entities, or running the
#      binary under buster or stretch glibc instead of trixie.
#
#      It is not the maps.  v1.2 leaks on q2dm1 and q2dm2 -- two maps OSP
#      Tourney DM shipped precomputed meshes for in 1999, made with this same
#      tool, which `.github/aas.sh` still downloads and checksums.  v1.4 meshes
#      q2dm1 in one second with no leak at all, and 35 of 35 maps across both
#      rotations.
#
#      v1.4 is a Windows binary, so THE GEOMETRY STEP RUNS OFF THIS HOST -- on
#      a Windows machine, or WSL, where `bspc.exe -bsp2aas <map>.bsp` runs
#      directly.  Drop the resulting .aas files into <gamedir>/maps/ and this
#      script picks them up: a map that already has a mesh skips bspc entirely
#      and goes straight to step 2.  Only when there is no mesh does it fall
#      back to the bundled v1.2, which is better than nothing and worse than
#      v1.4.
#   2. ONE LOAD OF THAT MAP with the botlib in the game, which computes
#      reachability and clustering itself and rewrites the file.  Minutes, not
#      seconds, and it is why this script drives the running server rather than
#      just shelling out to a tool.
#
# THE MAP LIST COMES FROM THE SERVER'S OWN ROTATION, not from an argument, so
# the meshes built are exactly the maps that will be played: RA2's `maploop:`
# out of arena.cfg for the arena server, `sv_maplist` out of test-server.cfg for
# the xatrix one.  Name maps on the command line to do a subset.
#
# THE .bsp FILES ARE INSIDE THE PAKS and bspc needs a real file, so each one is
# extracted to a scratch directory on the way past.  Nothing is written into the
# gamedir except maps/<map>.aas and the state directory.
#
# IDEMPOTENT, and that matters because a full arena run is 28 maps of "minutes,
# not seconds".  A map whose mesh finished is recorded in .aas-state/ and
# skipped, so an interrupted run resumes instead of starting over.

set -euo pipefail

QUAKE2_DIR="${QUAKE2_DIR:-/home/nils/quake2}"
SERVER_ROOT="${SERVER_ROOT:-/home/nils/quake2-colosseum-server}"
IMAGE="${IMAGE:-colosseum}"

# The throwaway server this drives is started here with `docker run`, not from
# a compose file.  There used to be two long-lived colosseum test servers and
# this drove whichever one matched; they were retired on 2026-09-18 when both
# LIVE servers moved to colosseum, and the compose file went with them.  What
# the reachability pass actually needs is far smaller than a service: one
# container, on the loopback interface, for the length of the run.
# LOOPBACK, because the throwaway server below publishes its port there and
# nowhere else.  It used to be the host's LAN address, back when this drove a
# long-lived compose service that was reachable on it.
HOST_IP="${HOST_IP:-127.0.0.1}"

# How long to let the botlib work before giving up on one map, and how long a
# stable file size means "finished".
MAX_WAIT="${MAX_WAIT:-600}"
STABLE_FOR="${STABLE_FOR:-8}"

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $(basename "$0") <arena|xatrix> [map ...]"
WHICH="$1"; shift

case "$WHICH" in
    arena)  GAMEDIR="$SERVER_ROOT/arena";  CONTAINER=colosseum-aas-arena;  PORT=27920; START_MAP="${START_MAP:-ra2map1}" ;;
    xatrix) GAMEDIR="$SERVER_ROOT/xatrix"; CONTAINER=colosseum-aas-xatrix; PORT=27921; START_MAP="${START_MAP:-xdm1}" ;;
    *) die "first argument must be 'arena' or 'xatrix', not '$WHICH'" ;;
esac

[ -d "$GAMEDIR" ] || die "no such gamedir: $GAMEDIR -- run scripts/setup-colosseum-serverdata.sh first"

# START THE THROWAWAY SERVER.  Bound to the LOOPBACK interface deliberately:
# this thing has bots, no anticheat and a rotation it is about to be driven
# through by hand, and nothing outside this host has any business reaching it.
# It also passes `+set public 0`, so it never registers with a master either.
#
# BOOT IT ON A MAP THAT ALREADY HAS A MESH.  The botlib disables itself for the
# whole session on the first map it cannot load one for, and never retries -- so
# a server that starts on a meshless map is dead for every map after it too.
start_server() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --init --name "$CONTAINER" \
        -e Q2_GAMEDIR="$WHICH" -e Q2_IP=localhost -e Q2_PORT="$PORT" \
        -e Q2_SERVER_CFG=test-server.cfg -e Q2_MAP="$START_MAP" \
        -p "127.0.0.1:$PORT:$PORT/udp" \
        -v "$SERVER_ROOT:/opt/quake2" \
        "$IMAGE" >/dev/null 2>&1 || die "could not start $CONTAINER from $IMAGE"
    sleep 20
}

restart_server() {
    docker restart "$CONTAINER" >/dev/null 2>&1 || true
    sleep 20
}


command -v docker >/dev/null || die "docker not found"
command -v python3 >/dev/null || die "python3 not found"

STATE="$GAMEDIR/.aas-state"
WORK="$GAMEDIR/.aas-work"
mkdir -p "$STATE" "$WORK" "$GAMEDIR/maps"

RCON_PW="$(sed -n 's/^[[:space:]]*set[[:space:]]\+rcon_password[[:space:]]\+"\([^"]*\)".*/\1/p' \
    "$GAMEDIR/test-server.cfg" | head -1)"
[ -n "$RCON_PW" ] || die "no rcon_password in $GAMEDIR/test-server.cfg"

# ---------------------------------------------------------------- helpers

# The rotation, from whichever file actually drives it for this ruleset.
rotation() {
    if [ "$WHICH" = arena ]; then
        # RA2's own arena.cfg: `maploop: a b c ...;` -- CRLF, as it shipped.
        tr -d '\r' < "$GAMEDIR/arena.cfg" \
            | sed -n 's/^[[:space:]]*maploop:[[:space:]]*\(.*\);.*/\1/p' | head -1 | tr -s ' ' '\n'
    elif [ -f "$GAMEDIR/maps.txt" ]; then
        # OSP Tourney's map queue, which colosseum's dm ruleset reads FIRST and
        # which is what the imported live rotation uses -- 268 names is far more
        # than a `set sv_maplist` line can carry.  `<map> [min] [max]` per line,
        # `#` comments.
        grep -v '^[[:space:]]*#' "$GAMEDIR/maps.txt" | awk '{print $1}'
    else
        # baseq2's sv_maplist, the fallback when there is no maps.txt.
        sed -n 's/^[[:space:]]*set[[:space:]]\+sv_maplist[[:space:]]\+"\([^"]*\)".*/\1/p' \
            "$GAMEDIR/test-server.cfg" | head -1 | tr -s ' ' '\n'
    fi | sed '/^$/d'
}

# THE MESH IS NAMED FOR THE MAP THE ENGINE ENDS UP ON, NOT THE ONE YOU ASK FOR,
# and on the imported live rotation those differ for almost every entry.
# `xmarics39` is a VIRTUAL map: maps/xmarics39.bsp.override redirects to
# maps/marics39.bsp, the engine reports `SpawnServer: marics39`, and the botlib
# -- which does its own file I/O and loads the .bsp itself -- asks for
# maps/marics39.bsp and then marics39.aas.  So `gamemap` takes the virtual name
# and the mesh takes the resolved one.
#
# Read straight out of the override header rather than through a helper
# program: int32 bits, then char[64] name when bits & OVERRIDE_NAME (1).
resolve_bsp() {
    local entry="$1" ov="$GAMEDIR/maps/$1.bsp.override" bits name
    [ -f "$ov" ] || { printf '%s' "$entry"; return; }
    bits=$(od -An -tu4 -N4 "$ov" 2>/dev/null | tr -d ' ')
    [ -n "$bits" ] && [ $((bits & 1)) -ne 0 ] || { printf '%s' "$entry"; return; }
    name=$(dd if="$ov" bs=1 skip=4 count=64 2>/dev/null | tr -d '\0')
    name=${name##*/}; name=${name%.bsp}
    [ -n "$name" ] && printf '%s' "$name" || printf '%s' "$entry"
}

# Pull maps/<name>.bsp out of the gamedir's paks, then baseq2's.  Same order the
# engine searches, so the file found is the file the server will load.
extract_bsp() {
    python3 - "$1" "$WORK" "$GAMEDIR" "$SERVER_ROOT/baseq2" <<'PY'
import struct, sys, os
name, work, gamedir, baseq2 = sys.argv[1:5]
want = 'maps/%s.bsp' % name

def entries(pak):
    with open(pak, 'rb') as f:
        magic, off, size = struct.unpack('<4sii', f.read(12))
        if magic != b'PACK':
            return {}
        f.seek(off)
        out = {}
        for _ in range(size // 64):
            e = f.read(64)
            n = e[:56].split(b'\0')[0].decode('latin1')
            o, l = struct.unpack('<ii', e[56:64])
            out[n.lower()] = (o, l)
        return out

# Higher pak number wins, and the gamedir wins over baseq2 -- the engine's own
# order, so we resolve to the same file it will.
for d in (gamedir, baseq2):
    paks = sorted((p for p in os.listdir(d) if p.lower().startswith('pak') and p.lower().endswith('.pak')),
                  reverse=True)
    for p in paks:
        full = os.path.join(d, p)
        tbl = entries(full)
        hit = tbl.get(want.lower())
        if hit:
            off, ln = hit
            with open(full, 'rb') as f:
                f.seek(off); data = f.read(ln)
            dst = os.path.join(work, '%s.bsp' % name)
            with open(dst, 'wb') as g:
                g.write(data)
            print('%s (%d bytes, from %s)' % (dst, ln, p))
            sys.exit(0)
    # a loose file beside the paks counts too
    loose = os.path.join(d, 'maps', '%s.bsp' % name)
    if os.path.isfile(loose):
        import shutil
        dst = os.path.join(work, '%s.bsp' % name)
        shutil.copyfile(loose, dst)
        print('%s (loose, from %s)' % (dst, d))
        sys.exit(0)
sys.exit('not found in any pak: ' + want)
PY
}

# bspc, out of the image, against the scratch directory only.
run_bspc() {
    local name="$1" extra="${2:-}"
    docker run --rm \
        -v "$WORK:/work" -w /work \
        --entrypoint /opt/colosseum/bspc "$IMAGE" \
        ${extra:+$extra} -bsp2aas "/work/$name.bsp" 2>&1
}

rcon() {
    python3 - "$HOST_IP" "$PORT" "$RCON_PW" "$*" <<'PY'
import socket, sys
ip, port, pw, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
s.sendto(b'\xff\xff\xff\xff' + ('rcon %s %s' % (pw, cmd)).encode(), (ip, port))
out = b''
try:
    while True: out += s.recvfrom(65536)[0]
except socket.timeout: pass
sys.stdout.write(out.decode('latin1').replace('\xff\xff\xff\xffprint\n', ''))
PY
}

current_map() {
    python3 - "$HOST_IP" "$PORT" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
try:
    s.sendto(b'\xff\xff\xff\xffstatus', (sys.argv[1], int(sys.argv[2])))
    lines = [l for l in s.recvfrom(65536)[0].decode('latin1').split('\n') if l.strip()]
    f = lines[1].split('\\')
    print(dict(zip(f[1::2], f[2::2])).get('mapname', '?'))
except Exception:
    print('?')
PY
}

# ---------------------------------------------------------------- the run

# compute_mesh <map> <geometry-size>
# Step 2: one load of the map with the botlib in the game, which computes
# reachability and clustering and rewrites the file.  Returns non-zero if it
# did not finish.
compute_mesh() {
    local name="$1" mesh="$2" geom="$3"
    info "  letting the botlib compute reachability"

    # `gamemap`, NOT `map`: q2pro refuses `map` from rcon with "Using 'map' will
    # cause full server restart. Use 'gamemap' for changing maps." -- it answers
    # in the rcon reply and changes nothing, so a caller that ignores the reply
    # just waits out its whole timeout on a map that never loaded.  `gamemap` is
    # also the right one here regardless: a full restart would re-exec
    # test-server.cfg and undo the pinning above.
    rcon "gamemap $name" >/dev/null 2>&1 || true
    sleep 6
    if [ "$(current_map)" != "$name" ]; then
        info "  the server did not load $name (it is on '$(current_map)')"
        return 1
    fi
    rcon "sv addrandom 1" >/dev/null 2>&1 || true

    # The botlib rewrites the file when it is done.  Wait for the size to move
    # off bspc's geometry-only figure AT ALL and then hold still.
    #
    # NOT "grow past it", which is what this checked first and is wrong: the
    # finished mesh is SMALLER than bspc's output, measurably so -- xdm1 comes
    # out of bspc at 888656 bytes and the botlib rewrites it to 506588.  The
    # geometry pass emits every area it found; the botlib's own pass computes
    # reachability and clustering and drops what it does not need.  Waiting for
    # growth timed xdm1 out at 600s on a mesh that had been finished for most
    # of that.
    local waited=0 stable=0 last=$geom changed=0
    while [ $waited -lt $MAX_WAIT ]; do
        sleep 2; waited=$((waited + 2))
        if [ "$(current_map)" != "$name" ]; then
            info "  the level ended mid-computation (now on '$(current_map)') - re-pinning and reloading"
            rcon "set fraglimit 0" >/dev/null 2>&1 || true
            rcon "set timelimit 0" >/dev/null 2>&1 || true
            rcon "gamemap $name" >/dev/null 2>&1 || true
            sleep 6
        fi
        local now
        now=$(stat -c%s "$GAMEDIR/maps/$mesh.aas" 2>/dev/null || echo 0)
        if [ "$now" != "$last" ]; then
            last=$now; stable=0; changed=1
        elif [ $changed = 1 ]; then
            stable=$((stable + 2))
            if [ $stable -ge $STABLE_FOR ]; then
                touch "$STATE/$name.done"
                built=$((built + 1))
                info "  DONE: $last bytes (geometry was $geom) after ${waited}s"
                return 0
            fi
        fi
    done
    info "  TIMED OUT after ${waited}s at $last bytes (geometry $geom) - not marked done"

    # THE BOTLIB DISABLES ITSELF after a map it cannot load a mesh for: it
    # prints `no AAS file available`, then `AAS shutdown`, and the game reports
    # `gladiator.so not available` -- and it does NOT retry for the rest of the
    # session.  So one bad map does not fail one row, it fails EVERY row after
    # it, silently, because no later map ever asks the botlib for anything
    # again.  That is what made this look unreproducible by hand: every test
    # after a meshless boot map was dead before it started.  Restarting the
    # service is the only way back, so a failure here takes it rather than
    # poisoning the rest of a 268-map run.
    info "  restarting $CONTAINER (the botlib disables itself after a failed map)"
    restart_server
    rcon "set fraglimit 0" >/dev/null 2>&1 || true
    rcon "set timelimit 0" >/dev/null 2>&1 || true
    return 1
}

MAPS=("$@")
if [ ${#MAPS[@]} -eq 0 ]; then
    mapfile -t MAPS < <(rotation)
fi
[ ${#MAPS[@]} -gt 0 ] || die "could not work out the map rotation for $WHICH"

log "$WHICH: ${#MAPS[@]} map(s) in rotation"
log "starting $CONTAINER on $START_MAP (127.0.0.1:$PORT)"
start_server
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

# PIN THE LEVEL, or the map walks out from under the computation.  `botfill 1`
# is permanently on, so the moment a map loads the fill seats bots and they
# start fragging each other -- and a finished fraglimit or timelimit ends the
# LEVEL, which rotates the map and takes the botlib's half-computed mesh with
# it.  Measured, not feared: the first two runs of this script both timed out
# on xdm1 at exactly bspc's byte count, and the server was found sitting on
# xdm2 with `Fatal: no AAS file available` in its log.  Zero means neither
# limit is ever reached, which is the documented way to leave a rotation in
# place with nothing to trigger it.
log "pinning the level (fraglimit 0, timelimit 0) for the duration"
rcon "set fraglimit 0" >/dev/null 2>&1 || true
rcon "set timelimit 0" >/dev/null 2>&1 || true

built=0; skipped=0; failed=()
for name in "${MAPS[@]}"; do
    mesh="$(resolve_bsp "$name")"

    if [ -f "$STATE/$name.done" ] && [ -f "$GAMEDIR/maps/$mesh.aas" ]; then
        skipped=$((skipped + 1)); info "$name: already done, skipping"; continue
    fi

    if [ "$mesh" = "$name" ]; then log "$name"; else log "$name (mesh: $mesh)"; fi

    # A mesh already in maps/ is taken as the geometry pass, done elsewhere --
    # which is the normal case now, because the bundled Linux bspc is v1.2 and
    # leaks on most of these maps (see the header).  Only its ABSENCE makes
    # this script reach for bspc at all.
    if [ -f "$GAMEDIR/maps/$mesh.aas" ]; then
        geom=$(stat -c%s "$GAMEDIR/maps/$mesh.aas")
        info "  geometry mesh already present ($geom bytes) -- skipping bspc"
        compute_mesh "$name" "$mesh" "$geom" || failed+=("$name(compute)")
        continue
    fi

    if ! out="$(extract_bsp "$name" 2>&1)"; then
        info "  cannot extract the .bsp: $out"; failed+=("$name(no-bsp)"); continue
    fi
    info "  $out"

    # A map bspc refuses with "**** leaked ****" usually yields to -nocsg, which
    # skips the brush chopping the leak test runs on. README.md says so; this is
    # that fallback, not a guess.
    if ! bout="$(run_bspc "$name")"; then bout="${bout:-}"; fi
    if [ ! -f "$WORK/$name.aas" ] && printf '%s' "$bout" | grep -q 'leaked'; then
        info "  bspc reported a leak, retrying with -nocsg"
        bout="$(run_bspc "$name" -nocsg || true)"
    fi
    if [ ! -f "$WORK/$name.aas" ]; then
        info "  bspc produced no .aas:"; printf '%s\n' "$bout" | tail -6 | sed 's/^/      /'
        failed+=("$name(bspc)"); rm -f "$WORK/$name.bsp"; continue
    fi

    geom=$(stat -c%s "$WORK/$name.aas")
    install -m 644 "$WORK/$name.aas" "$GAMEDIR/maps/$mesh.aas"
    rm -f "$WORK/$name.bsp" "$WORK/$name.aas"
    info "  geometry mesh: $geom bytes"
    compute_mesh "$name" "$mesh" "$geom" || failed+=("$name(compute)")
    continue
done

# Restart rather than undo.  The run changed fraglimit and timelimit and drove
# the server through a dozen maps; a restart re-execs test-server.cfg and comes
# back on the configured start map with the configured limits, which is a
# smaller thing to get right than putting three cvars back by hand.
log "removing $CONTAINER"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
rmdir "$WORK" 2>/dev/null || true

echo
log "$WHICH: $built built, $skipped already done, ${#failed[@]} failed"
[ ${#failed[@]} -gt 0 ] && printf '    failed: %s\n' "${failed[*]}"
log "meshes now in $GAMEDIR/maps: $(ls "$GAMEDIR/maps"/*.aas 2>/dev/null | wc -l)"
exit 0
