# q2server-dockerfile

Docker setup for three Quake II-engine dedicated servers, managed together via
`docker-compose.yml`.

| Service        | Game           | Engine | Ports                  |
|----------------|----------------|--------|------------------------|
| `q2pro-arena`  | Rocket Arena 2 | q2pro  | 27910 (udp+tcp)        |
| `q2pro-xatrix` | Xatrix OpenFFA | q2pro  | 27911 (udp+tcp)        |
| `daikatana`    | Daikatana coop | dkded  | 27982, 27992 (udp+tcp) |

## Requirements

Docker Engine with the **Compose v2 plugin**.

> **Use `docker compose` (space), not `docker-compose` (hyphen).** The legacy
> v1 tool crashes recreating containers on modern Docker Engine and can take a
> running server down mid-recreate.

## Usage

```
cd ~/projects/q2server-dockerfile
docker compose up -d          # build + start all three
docker compose ps             # status
docker compose logs -f        # tail logs (add a service name for just one)
docker compose restart <svc>  # restart one service
docker compose down           # stop and remove all three
```

Game **data** (`~/quake2`, Daikatana's `data/`) is bind-mounted. The **engine**
is built into the image, so run `docker compose build <svc>` after changing a
`Dockerfile` or bumping the pinned q2pro commit.

> Editing a bind-mounted `.cfg` and running `docker compose up -d` does
> **nothing** — compose sees no image change, reports "Running", and the old
> cvar values stay live in memory. Use `docker compose restart <svc>`.

## Building the engine

The `Dockerfile` clones [q2pro](https://github.com/q2pro/q2pro) at a **pinned
commit** (`Q2PRO_COMMIT`) and cross-compiles a 32-bit `q2proded`. Bump the pin
deliberately and re-test; an unpinned clone would drift upstream on every
rebuild.

The game DLLs are 32-bit, so the engine must be too. `PKG_CONFIG_LIBDIR` is
pinned to the i386 `.pc` directory — without it meson finds the host's 64-bit
zlib and the link fails with `libz.so: file in wrong format`.

### `GAME_ABI_HACK` — the one build arg that matters

`docker-compose.yml` passes this per service. **The two values are not
interchangeable:**

| Service        | `GAME_ABI_HACK` | Why |
|----------------|-----------------|-----|
| `q2pro-arena`  | `enabled`       | its `gamei386.real.so` (2014 build) expects the *old* callee-pops struct-return convention for `gi.trace()` |
| `q2pro-xatrix` | `disabled`      | its 2017 build expects the *modern* convention and crashes if the hack is compiled in |

With the wrong setting the stack drifts 4 bytes after every `gi.trace()` and
the mod dereferences a bogus `trace.ent` — the server starts fine and then
dies on the first map, crashing inside the *mod's* own physics code, so it
looks like a mod bug rather than a build-flag mistake. It is a whole-binary
compile-time switch, so one binary cannot serve both mods; that is why there
are two images. Don't merge them into one.

The build fails fast if the result isn't ELF32 or if `config.h` doesn't match
the requested setting, rather than shipping a silently-wrong engine.

## One-time game data preparation

These touch bind-mounted, operator-owned game data, so they are deliberately
not in the `Dockerfile` — an image can't write a bind mount at build time, and
doing it from an entrypoint would rewrite your game files on every start. Run
them once, by hand. Back up first.

### 1. `gamei386.so` — the Q2Admin wrapper

Built into the image from a pinned commit (`Q2ADMIN_REPO`/`Q2ADMIN_COMMIT` in
the `Dockerfile`), the same way as the engine — no separate build script
needed anymore. Currently pinned to
[Niehztog/q2admin](https://github.com/Niehztog/q2admin) rather than upstream
[packetflinger/q2admin](https://github.com/packetflinger/q2admin): it carries
one fix not yet merged there (upstream's `required_ui_keys[]` hard-requires a
`msg` userinfo key that yquake2 clients never send, rejecting every yquake2
connection outright). See the `Dockerfile` for the full rationale; switch
`Q2ADMIN_REPO` back to `packetflinger/q2admin` once that PR merges.

Unlike the engine it can't live in the image alone — it `dlopen()`s
`<gamedir>/gamei386.real.so` relative to the process CWD, so it has to
physically sit in the bind-mounted game data directory. Install it once per
gamedir after building the image (either service's image works — the build
doesn't depend on `GAME_ABI_HACK`):

```
docker create --name q2admin-extract q2pro-xatrix
docker cp q2admin-extract:/opt/q2admin/gamei386.so ~/quake2/xatrix/
docker cp q2admin-extract:/opt/q2admin/gamei386.so ~/quake2/arena/
docker rm q2admin-extract
```

Confirm via a UDP status query: the reply's `q2admin` key should read the new
`rNNN~<short-hash>` format — a different key name and version format than the
old wrapper's `Q2Admin\1.17.48-tsmod-2`.

Replaced `Niehztog/q2admin-tsmod` (a patched fork of the ~1998 tastyspleen
lineage, previously built by the now-deleted `build-gamei386.sh` script) on
2026-08-05: that wrapper doesn't understand q2pro's `GMF_EXTRA_USERINFO`/
`GMF_IPV6_ADDRESS_AWARE` feature negotiation, rejecting every connecting
client outright once a wrapped mod declares the former, and heap-overflowing
a fixed 40-byte IP buffer for any client connecting over IPv6 once a mod
declares the latter.

### 2. `arena/gamei386.real.so` — `PT_GNU_STACK` patch

Only arena needs this; xatrix's 2017 build already has the header.

Arena's `gamei386.real.so` carries no `PT_GNU_STACK` header, so modern glibc
concludes it wants an **executable stack** and asks the kernel for one at
`dlopen()` time. The kernel refuses, and loading fails outright:

```
dlopen failed: cannot enable executable stack as shared object requires:
Invalid argument
```

Add an explicit non-exec header:

```
./add-gnu-stack.py ~/quake2/arena/gamei386.real.so /tmp/patched.so
install -m755 /tmp/patched.so ~/quake2/arena/gamei386.real.so

readelf -l ~/quake2/arena/gamei386.real.so | grep -A1 GNU_STACK   # RW, no E
readelf -d ~/quake2/arena/gamei386.real.so | grep '(REL)'         # must be 0x9ad4
```

> **Do not use `patchelf --clear-execstack` instead.** It silently corrupts
> this binary, rewriting `DT_REL` into `.text` and relocating `.hash`; the
> loader then reads code as relocation entries and segfaults inside
> `ld-linux.so.2`. `add-gnu-stack.py` appends a fresh program header table at
> end-of-file, touching no existing byte, and refuses an already-patched file.

### 3. Per-gamedir override cfg

This repo holds **reference copies**; the engine reads them from the game data
dir, so install them there:

```
install -m644 q2pro-override-arena.cfg  ~/quake2/arena/
install -m644 q2pro-override-xatrix.cfg ~/quake2/xatrix/
```

They are exec'd from the `CMD` *after* `server1.cfg` so they win. A
command-line `+set` cannot do this: q2pro applies every `+set` in an early
phase, before any `+exec`, so `server1.cfg` would clobber it regardless of
argument order.

## HTTP downloads (`sv_downloadserver`)

Clients request `<sv_downloadserver><gamedir>/<path>`. Xatrix's stock value
serves this content as *baseq2* content, so the custom textures its maps need
(e.g. the 13 `evl/*.wal` used by `marics39`) sit at `baseq2/textures/evl/` and
**404** at `xatrix/textures/evl/`. A client treats a 404 as non-fatal and just
skips the file, so maps render with missing textures.
`q2pro-override-xatrix.cfg` therefore points at that host's `http_linkfarm/`
tree, which exposes the same files under *every* gamedir path. Arena needs no
override.

Downloads cannot be debugged from the server — they go client → HTTP host
directly and never touch it, so its log shows nothing, not even a failure.
Instead, either point `sv_downloadserver` at an HTTP server you control and
read its access log, or on the client set `developer 1`, reproduce, and
`condump`; look for `CL_StartHTTPDownload: Fetching <url>` and
`HTTP download: <file> - OK|File Not Found`. Note `cl_http_downloads` is
`CVAR_ARCHIVE`, so a stale `0` in a client config silently disables HTTP.

## Checking a server is up

All three speak the Quake II UDP query protocol. Daikatana answers a bare
`status` with a short `queryid` acknowledgement instead of a full reply — an
engine difference, not a fault.

```python
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"\xff\xff\xff\xffstatus", ("<host>", 27910))  # 27911 xatrix, 27982 daikatana
print(s.recvfrom(4096)[0].decode(errors="replace"))
```

## Notes

- Logs are capped at 10MB × 3 files per service.
- **Don't strip the `script`/`stty -onlcr` wrapper or `init: true`.** They fix
  real gotchas: `script` allocates a PTY so the game's libc line-buffers
  stdout (otherwise `docker logs` arrives in delayed batches), `stty -onlcr`
  stops the PTY turning `\n` into `\r\n` (which breaks the rcon filter's line
  matching), and `init: true` gives the container a real init so `SIGTERM`
  reaches the game process — without it shutdown takes the full 10s grace
  period and ends in `SIGKILL`.
- `filter-rcon-status.sh` drops the master-server bot's constant `rcon status`
  polls, which the engine prints unconditionally, plus per-match/per-map lines
  that fire on a predictable schedule and carry no signal (timer countdowns,
  and the always-zero `0 entities inhibited` / `0 teams with 0 entities`
  spawn counts — a nonzero count still prints). q2pro prints rcon across
  **two** lines, so the filter matches the pair and suppresses it only when
  the command is exactly `status`; the other lines need no such pairing. It's
  a shell read-loop rather than `awk` because mawk reads stdin in blocks and
  swallowed the log entirely.
- `map_override_path maps` is set in the `CMD` because q2pro requires it to
  honour `.bsp.override` / `.ent` entity overrides, which several xatrix maps
  depend on. Without it such a map fails to load.
- `net_port`, not `port`, controls q2pro's actual listen socket — it binds
  `PORT_SERVER` (27910) regardless of `port`. Both are set; `port` is still
  needed because the game DLL reads it.
- `homedir` is set to the same path as `basedir`/`libdir` (`/opt/quake2`).
  q2pro defaults it to `~/.q2pro` and checks that first for several things;
  for the game library it falls back to `libdir` when not found there, but
  for file reads the game DLL itself makes it doesn't — it fails outright.
  That silently broke xatrix's own map-rotation code (`Couldn't load
  '/home/quake2/.q2pro/xatrix/mapcfg/maplist.txt'` on every map load), so the
  server replayed the same map after every timelimit instead of rotating.
  Pointing `homedir` at the real data directory fixes every such lookup.
- Some legacy admin config directives (`addcvarban`, `addcommandban`,
  `sv_max_packetdup`, ...) log as `Unknown command`. Harmless — extensions
  q2pro doesn't implement.
- No healthcheck, resource limits, or capability restrictions configured yet.
  The `rcon_password` is still shared across all three servers.
