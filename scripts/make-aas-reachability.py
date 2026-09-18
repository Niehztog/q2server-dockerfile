#!/usr/bin/env python3
"""make-aas-reachability.py -- step 2 of building the botlib's navigation
meshes: the REACHABILITY pass, driven against a local win32 q2proded.

Step 1 is scripts/make-aas-geometry.sh (bspc v1.4, off-host).  This is the
other half: one load of each map with the botlib in the game, which computes
reachability and clustering and rewrites the .aas in place -- the geometry mesh
goes IN and a smaller finished one comes OUT.

WHY LOCAL RATHER THAN ON THE GAME HOST.  scripts/make-colosseum-aas.sh does the
same job over rcon against the real test server and works fine, but it is
~30-45s per map there against ~14-20s here: the workstation is far the faster
machine, and there is no container or LAN round trip per map.  Measured across
the 268-map xatrix rotation: 81 minutes here.  The two produce the SAME file --
marics39 came out byte-identical (116664) both ways.

THE BOTLIB READS THE RAW .bsp ITSELF, through its own file search, rather than
using the entity string the engine has loaded.  Two consequences:
  - the .bsp must sit in <basedir>/<gamedir>/maps/, not in baseq2;
  - .bsp.override files are irrelevant here, so maps are loaded by their
    RESOLVED name (marics39, not xmarics39) and the mesh is named for that.
    It also means reachability reflects the original map's items and
    teleporters rather than an override's, on either machine.

THE BOTLIB DISABLES ITSELF FOR THE WHOLE SESSION after the first map it cannot
load a mesh for -- "no AAS file available", then "AAS shutdown", then
"gladiator.so not available", and it never retries.  So this boots ON a map
that already has a mesh and restarts the engine after any failure.  Miss that
and every map after the first bad one silently reports nothing.

RESUMABLE, because a full run is over an hour: completions are recorded in
done.txt.  They cannot be re-derived afterwards, because once the geometry
figure is gone a finished mesh is just a file of some size.

Environment: BUILD (q2proded.exe's directory), GAME (gamedir name under it),
MAPS (that gamedir's maps/), PORT, MAXWAIT, STABLE.
"""
import os, socket, subprocess, sys, time

BUILD = os.environ.get('BUILD', '/mnt/c/Users/nilsg/q2-dev/q2pro/builddir-win32')
MAPS  = os.environ.get('MAPS', os.path.join(BUILD, GAME, 'maps'))
GAME  = os.environ.get('GAME', 'colosseum-aas')
PORT  = int(os.environ.get('PORT', '27930'))
PW    = 'aasgen'
DONEFILE = os.environ.get('DONEFILE', os.path.join(BUILD, GAME, 'aas-done.txt'))
MAXWAIT  = int(os.environ.get('MAXWAIT', '180'))
# How long to give a map to come up.  15s was too short: kitchen, polka and
# wizq2dm4 all exceeded it and were written off as 'noload', and all three
# load perfectly well given longer -- confirmed against the real server.
LOADWAIT = int(os.environ.get('LOADWAIT', '45'))
STABLE   = int(os.environ.get('STABLE', '6'))

def rcon(cmd, timeout=3):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(timeout)
    try:
        s.sendto(b'\xff\xff\xff\xff' + ('rcon %s %s' % (PW, cmd)).encode(), ('127.0.0.1', PORT))
        out = b''
        while True:
            out += s.recvfrom(65536)[0]
    except socket.timeout:
        pass
    finally:
        s.close()
    return out.decode('latin1').replace('\xff\xff\xff\xffprint\n', '')

def mapname():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    try:
        s.sendto(b'\xff\xff\xff\xffstatus', ('127.0.0.1', PORT))
        lines = s.recvfrom(65536)[0].decode('latin1').split('\n')
        f = lines[1].split('\\')
        return dict(zip(f[1::2], f[2::2])).get('mapname', '?')
    except Exception:
        return '?'
    finally:
        s.close()

def killstale():
    # A previous run's engine keeps the UDP port and the next start dies with
    # "FATAL: Couldn't open dedicated server UDP port".  It is a Windows
    # process, so Windows has to be the one to end it.
    subprocess.run(['/mnt/c/Windows/System32/taskkill.exe', '/F', '/IM', 'q2proded.exe'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)

def start(first):
    killstale()
    log = open(os.path.join(BUILD, 'q2proded-aas.log'), 'ab')
    p = subprocess.Popen(
        ['./q2proded.exe', '+set', 'dedicated', '1', '+set', 'game', GAME,
         '+set', 'net_port', str(PORT), '+set', 'port', str(PORT),
         '+exec', 'aasgen.cfg', '+map', first],
        cwd=BUILD, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    for _ in range(40):
        time.sleep(1)
        if mapname() != '?':
            return p
    return p

def size(m):
    try:
        return os.path.getsize(os.path.join(MAPS, m + '.aas'))
    except OSError:
        return 0

def compute(m):
    """Returns 'done', 'timeout' or 'noload'."""
    before = size(m)
    rcon('gamemap %s' % m)
    for _ in range(LOADWAIT):
        time.sleep(1)
        if mapname() == m:
            break
    else:
        return 'noload'
    rcon('sv addrandom 1')
    waited = stable = 0; last = before; changed = False
    while waited < MAXWAIT:
        time.sleep(1); waited += 1
        now = size(m)
        if now != last:
            last = now; stable = 0; changed = True
        elif changed:
            stable += 1
            if stable >= STABLE:
                return 'done'
    return 'timeout'

def main():
    maps = [os.path.splitext(f)[0] for f in sorted(os.listdir(MAPS)) if f.endswith('.bsp')]
    have = [m for m in maps if os.path.exists(os.path.join(MAPS, m + '.aas'))]
    todo = sys.argv[1:] or have
    print('%d map(s) with a geometry mesh; doing %d' % (len(have), len(todo)), flush=True)

    # Boot ON a map that already has a mesh: the botlib disables itself for the
    # whole session after the first map it cannot load one for.
    # Resumable: a 250-map run is an hour, and a mesh already through the
    # botlib cannot be told apart from one that is not by size alone once the
    # geometry figure is gone.  So completions are recorded, not inferred.
    try:
        finished = set(l.strip() for l in open(DONEFILE) if l.strip())
    except IOError:
        finished = set()
    if finished:
        print('%d already recorded as done, skipping those' % len(finished), flush=True)
    todo = [m for m in todo if m not in finished]

    # Snapshot the geometry sizes BEFORE the engine runs.  Starting it computes
    # the BOOT MAP immediately, so a pass that only watches for a size CHANGE
    # sits out its whole timeout on that one map -- it was already finished
    # before the loop first looked at it.  A mesh whose size has moved off the
    # figure bspc left it at is a mesh that has been through the botlib.
    geom = {m: size(m) for m in todo}

    proc = start(todo[0])
    if mapname() == '?':
        print('server did not come up -- see %s/q2proded-aas.log' % BUILD); return 1

    t0 = time.time(); done = []; bad = []
    for i, m in enumerate(todo, 1):
        b = size(m); t = time.time()
        if geom[m] and b != geom[m]:
            print('  [%3d/%3d] %-22s %-8s %8d -> %-8d %4s' %
                  (i, len(todo), m, 'boot', geom[m], b, '-'), flush=True)
            done.append(m)
            with open(DONEFILE, 'a') as fh:
                fh.write(m + '\n')
            continue
        r = compute(m)
        a = size(m)
        print('  [%3d/%3d] %-22s %-8s %8d -> %-8d %4.0fs' % (i, len(todo), m, r, b, a, time.time()-t), flush=True)
        if r == 'done':
            done.append(m)
            with open(DONEFILE, 'a') as fh:
                fh.write(m + '\n')
        else:
            bad.append('%s(%s)' % (m, r))
            # The botlib shuts down for the session after a failure; restart.
            try: proc.kill()
            except Exception: pass
            time.sleep(2)
            proc = start(m if r != 'noload' else todo[0])
    try: proc.kill()
    except Exception: pass
    print('\n%d done, %d failed in %.0f min' % (len(done), len(bad), (time.time()-t0)/60))
    if bad: print('failed:', ' '.join(bad))
    return 0

sys.exit(main())
