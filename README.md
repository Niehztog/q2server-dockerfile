# q2server-dockerfile

Docker setup for three Quake II-engine dedicated servers, managed together via
`docker-compose.yml`.

| Service        | Game               | Ports                  |
|----------------|--------------------|------------------------|
| `r1q2-arena`   | Rocket Arena 2     | 27910 (udp+tcp)        |
| `r1q2-xatrix`  | Xatrix OpenFFA     | 27911 (udp+tcp)        |
| `daikatana`    | Daikatana coop     | 27982, 27992 (udp+tcp) |

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
docker compose logs -f        # tail logs (add a service name to tail just one)
docker compose restart <svc>  # restart one service
docker compose down           # stop and remove all three
```

Game data (`~/quake2`, Daikatana's `data/`) is bind-mounted, not baked into the
images — editing a `.cfg` file and restarting is enough, no rebuild needed. A
rebuild (`docker compose build <svc>`) is only needed after changing a
`Dockerfile`.

## Checking a server is up

All three speak the Quake II UDP query protocol:

```python
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"\xff\xff\xff\xffstatus", ("<host>", 27910))  # 27911 xatrix, 27982 daikatana
print(s.recvfrom(4096)[0].decode(errors="replace"))
```

## Notes

- Logs are capped at 10MB × 3 files per service. Arena/xatrix also filter out
  routine master-server-bot rcon polling — see the `Dockerfile` `CMD` to adjust.
- arena/xatrix run 32-bit binaries on a 64-bit base image; if you touch the
  Dockerfile, don't strip the `script`/`stty -onlcr` wrapper or `init: true` —
  both fix real gotchas (log buffering and slow/unclean shutdown), not cruft.
- `Dockerfile-openra2` is unused/unmaintained.
- No healthcheck, resource limits, or capability restrictions configured yet.
