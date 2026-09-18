> ## This repository has moved, and is no longer updated
>
> On 2026-09-18 it was split in two, because it mixed a Docker setup anyone
> could use with one person's deployment of it:
>
> - **The general half — the `Dockerfile`, the engine patches,
>   `filter-rcon-status.sh` and the colosseum deploy and navigation-mesh
>   tooling — is now `server/` in
>   [Niehztog/colosseum](https://github.com/Niehztog/colosseum)**, which is
>   where it is developed from here on. That is where to look for anything
>   below that still interests you.
> - The deployment half — one host's compose file, gamedirs, ports, rotations
>   and override cfgs — moved to a private repository, where it always
>   belonged.
>
> Everything is left in place below, and the history is intact: what was here
> worked, and this is an archive of it rather than a redirect. It is simply
> not where the work continues, and it will drift out of date — the engine
> patch that makes the game library's bots visible to the server browser, for
> one, never reached this copy of the `Dockerfile`.

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

### Engine patches — they live in the colosseum repo

The engine carries patches, and **they are not in this repository**. They live
in `colosseum/server/`, which documents each one and checks it
(`server/enginepatch.sh`). This build copies `server/q2pro/` out of the
`colosseum-src` build context and applies every patch in filename order right
after the checkout.

| Patch | What it does |
|---|---|
| `0001-status-report-game-created-bots.patch` | Makes the engine report the game library's bots as players |

**Why 0001 exists.** Gladiator-derived bots — colosseum's, and every Q2 mod's
descended from Mr. Elusive's game source — live entirely inside the *game*: the
bot gets one of the game's client edicts, but nothing connects, so the engine
holds no `client_t` for it. Both places the engine reports players from walk
`sv_clientlist`, which only `SV_DirectConnect` appends to, so a server with
eight bots playing advertises itself as empty. That is true of id's 1997 server,
yquake2 and q2repro alike, not just q2pro. The patch feeds those bots to the UDP
status reply, the `N/M` count in `info`, and `rcon status` — **that last one is
what WallFly polls** (see `filter-rcon-status.sh`), so it is the one that
decides what the public listing shows. `set sv_status_show_bots 0` reverts every
reply to stock output without a restart.

**This is why `--target server` now needs `colosseum-src`.** It did not before —
that was the point of merging the two Dockerfiles, and it is written down on the
colosseum target. `docker-compose.yml` supplies the context for both services
under `additional_contexts`; a hand-rolled build needs the flag:

```sh
docker build --target server \
    --build-context colosseum-src=/home/nils/projects/colosseum -t q2pro-server .
```

Without it the build fails with `failed to resolve source metadata for
docker.io/library/colosseum-src`, which reads like a missing image and means a
missing flag.

**Bumping `Q2PRO_COMMIT` means refreshing the patches in the same commit** — in
the colosseum repo — because a patch that no longer applies fails the build
rather than being skipped.

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

The build fails fast if the result isn't ELF32, if `config.h` doesn't match the
requested setting, or if the carried patches didn't reach the binary, rather
than shipping a silently-wrong engine.

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

### 2. `gamei386.real.so` — the game library

Both servers run **colosseum**, which this image does not build: its repo is
private, so the pinned `git clone` the main `Dockerfile` uses cannot
authenticate, and its build context has to be a local clone. the same `Dockerfile` builds it under `--target colosseum`, and `scripts/deploy-colosseum-live.sh` installs it — along with
`gladiator.so`, `pak7.pak`, the loose bot list and the `.aas` navigation
meshes — into a live gamedir:

```
docker build --target colosseum --build-context colosseum-src=~/projects/colosseum -t colosseum .
./scripts/deploy-colosseum-live.sh arena
./scripts/deploy-colosseum-live.sh xatrix
docker compose restart q2pro-arena q2pro-xatrix
```

That script is idempotent and parameterised by `Q2_ROOT`, so it can be
rehearsed against a copy of the live tree before it touches `~/quake2`. It
takes one backup per gamedir, which is also the rollback:
`gamei386.real.so.bak-<date>-pre-colosseum` and
`server1.cfg.bak-<date>-pre-colosseum`, plus a restart.

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
