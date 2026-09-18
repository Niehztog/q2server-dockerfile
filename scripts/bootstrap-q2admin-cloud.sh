#!/bin/bash
#
# bootstrap-q2admin-cloud.sh -- create (or repair) q2admin-cloud's persistent
# state: the host directory docker-compose.yml bind-mounts into the container
# as /data.
#
# WHY THIS EXISTS.  The original 2026-08-05 deployment built that directory by
# hand and wrote none of it down -- Dockerfile-q2admin-cloud only ever built
# the binary.  On 2026-09-17 the directory's contents disappeared (cause never
# established; only that one directory was affected and this account cannot
# read the host's audit trail).  There was no backup, so every keypair, the
# database and config.pb were gone at once and the service crash-looped 320
# times before anyone noticed.  This script is the reproducible version of
# that lost bootstrap: run it against an empty directory and you get a working
# deployment; run it against a populated one and it changes nothing.
#
# WHAT IS AND IS NOT REGENERATED
#
#   - The CLOUD server's own RSA keypair is generated HERE, so it is new on
#     every fresh bootstrap.  Both gamedirs' `cloud-serverkey.pem` -- their
#     copy of that public key -- is rewritten to match.  That one file is the
#     only thing on the game-server side this script ever writes.
#
#   - Each GAME server's own keypair (`cloud-private.pem` / `cloud-public.pem`
#     in its gamedir) is NOT generated here and is never overwritten.  That
#     pair is the game server's identity; this script only reads the public
#     half and registers it in the database.  Those files survived the
#     2026-09-17 loss, which is also why the frontend UUIDs did not have to
#     change -- and the UUID is read straight out of each gamedir's
#     q2a_cloud.cfg rather than repeated here, so the two sides cannot drift.
#
# THE DATABASE SCHEMA IS NOT WRITTEN HERE, DELIBERATELY.  q2admind creates it
# itself the first time it opens the file (database.Open runs its embedded
# schema when `PRAGMA schema_version` is 0).  Copying those CREATE TABLEs into
# this script would be a second copy to keep in step with a pinned upstream --
# and a stale, incomplete schema is exactly what caused two of the seven
# upstream bugs listed at the top of Dockerfile-q2admin-cloud.  So this script
# boots the service once against an empty database, waits for the app to lay
# the schema down, and only then inserts the frontend rows.
#
# sqlite3(1) IS NOT INSTALLED ON THIS HOST and there is no passwordless sudo to
# install it (CLAUDE.md, Known issues).  python3's stdlib sqlite3 module is
# used instead -- same file format, nothing to install.
#
# IDEMPOTENT.  Every step is skipped when its output already exists, so
# re-running is how you repair a half-created directory or register a frontend
# added to the list below.  --force-keys replaces the cloud keypair, which
# also rewrites both gamedirs' cloud-serverkey.pem.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/home/nils/q2admin-cloud}"
QUAKE2_DIR="${QUAKE2_DIR:-/home/nils/quake2}"
COMPOSE_DIR="${COMPOSE_DIR:-/home/nils/projects/q2server-dockerfile}"
COMPOSE_SERVICE="q2admin-cloud"

# The address the frontends are DISPLAYED as in the web UI and teleport lists.
# It is not used for authentication and not matched against the connecting
# socket: HandleConnection() finds a frontend by the UUID in its greeting and
# then verifies an RSA challenge, and overwrites the stored port with the one
# the greeting carries.  Game servers reach the cloud over the compose network
# by service name, so their source address is a 172.x bridge address, not this.
ADVERTISED_IP="${ADVERTISED_IP:-192.168.1.38}"

# name:gamedir:advertised-port.  The UUID and the public key are read out of
# the gamedir, never written here.
FRONTENDS=(
    "arena:arena:27910"
    "xatrix:xatrix:27911"
)

FORCE_KEYS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force-keys) FORCE_KEYS=1 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//; $d'
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '==> %s\n' "$*"; }
skip() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites

for tool in openssl ssh-keygen python3 docker; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH ($PATH)"
done
python3 -c 'import sqlite3' 2>/dev/null || die "python3 has no sqlite3 module"
[ -d "$COMPOSE_DIR" ] || die "compose directory not found: $COMPOSE_DIR"

# AUTH_BYPASS_EMAIL lives in the gitignored .env beside docker-compose.yml.  It
# is the account MockLogin() signs the web UI in as, and MockLogin refuses an
# account that is not in users.pb -- which is what made /sign-in fail before,
# so the user row below is written to match rather than left out.
if [ -f "$COMPOSE_DIR/.env" ]; then
    # shellcheck disable=SC1091
    . "$COMPOSE_DIR/.env"
fi
ADMIN_EMAIL="${AUTH_BYPASS_EMAIL:-admin@localhost}"

# ---------------------------------------------------------------- directories

log "creating directory layout under $DATA_DIR"
if [ -e "$DATA_DIR" ] && [ ! -w "$DATA_DIR" ]; then
    die "$DATA_DIR exists but is not writable by $(id -un) -- if docker recreated
       it as root, remove it first: rmdir '$DATA_DIR'"
fi
mkdir -p "$DATA_DIR"/{config,crypto,database,clients}
chmod 700 "$DATA_DIR/crypto"

# ---------------------------------------------------------------- cloud keypair

CLOUD_PRIV="$DATA_DIR/crypto/cloud-private.pem"
CLOUD_PUB="$DATA_DIR/crypto/cloud-public.pem"

if [ "$FORCE_KEYS" = 1 ] && [ -f "$CLOUD_PRIV" ]; then
    log "--force-keys: replacing the existing cloud keypair"
    mv -f "$CLOUD_PRIV" "$CLOUD_PRIV.bak-$(date +%Y-%m-%d-%H%M%S)"
    rm -f "$CLOUD_PUB"
fi

if [ -f "$CLOUD_PRIV" ]; then
    skip "cloud private key already present, keeping it"
else
    # PKCS8 ("BEGIN PRIVATE KEY"), NOT PKCS1 ("BEGIN RSA PRIVATE KEY").
    # crypto.LoadPrivateKey() rejects any other PEM type by name before it ever
    # tries to parse the bytes, so `openssl genrsa` output is refused outright.
    # 2048 bits: crypto.RSAKeyLength is 256 bytes and the wire format sizes its
    # buffers from it.
    log "generating the cloud server's RSA keypair (2048 bit, PKCS8)"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$CLOUD_PRIV" 2>/dev/null
    chmod 600 "$CLOUD_PRIV"
fi

if [ ! -f "$CLOUD_PUB" ]; then
    openssl rsa -in "$CLOUD_PRIV" -pubout -out "$CLOUD_PUB" 2>/dev/null
    chmod 644 "$CLOUD_PUB"
fi

# ---------------------------------------------------------------- ssh host key

SSH_HOSTKEY="$DATA_DIR/crypto/ssh_host_ed25519_key"
if [ -f "$SSH_HOSTKEY" ]; then
    skip "ssh host key already present"
else
    # The admin terminal's listener starts unconditionally whether or not its
    # port is published, and CreateHostKeySigner() is fatal if it cannot parse
    # this file -- so it has to exist even though nothing outside the container
    # can reach the listener.
    log "generating the SSH admin-terminal host key (ed25519)"
    ssh-keygen -t ed25519 -N '' -C 'q2admin-cloud admin terminal' \
        -f "$SSH_HOSTKEY" >/dev/null
fi

# ---------------------------------------------------------------- config.pb

CONFIG_PB="$DATA_DIR/config/config.pb"
if [ -f "$CONFIG_PB" ]; then
    skip "config.pb already present, keeping it"
else
    log "writing config/config.pb"
    # Text-format protobuf (proto/config.proto), NOT YAML or JSON -- prototext
    # parses it, so field names are the proto's own snake_case.  Every path is
    # the container's view, not the host's.
    cat > "$CONFIG_PB" <<'EOF'
# q2admin-cloud main config -- text-format protobuf, schema proto/config.proto.
# Paths are as seen INSIDE the container: /data is this directory, bind-mounted
# by docker-compose.yml; /opt/q2admin-cloud is baked into the image.
# Written by scripts/bootstrap-q2admin-cloud.sh -- edit here, not there, but
# remember this file is not in git and not backed up anywhere.

# The game-server TCP port.  Reached by arena/xatrix over the compose network
# as "q2admin-cloud:9988" and deliberately never published to the LAN.
address: "0.0.0.0"
port: 9988

database: "/data/database/q2a.sqlite"
private_key: "/data/crypto/cloud-private.pem"
client_directory: "/data/clients"

# The only LAN-facing port of this deployment; docker-compose.yml binds it to
# 192.168.1.38 specifically.  GET /api/GetConnectedServers needs no auth.
api_enabled: true
api_address: "0.0.0.0"
api_port: 8087
web_root: "/opt/q2admin-cloud/api/website"

rule_file: "/data/config/rules.pb"
user_file: "/data/config/users.pb"

# auth_file is deliberately UNSET: no Google/Discord OAuth app is registered
# for this LAN deployment.  Startup logs "unable to read credential file" and
# carries on; the web UI signs in through AUTH_BYPASS_EMAIL instead.

# Seconds between maintenance passes.  MUST NOT BE 0 -- startMaintenance() is
# an unconditional loop whose only pause is a time.Sleep of this many seconds,
# so a zero here is a busy loop that spins a core for the life of the process.
maintenance_time: 60

# Only read when --foreground is absent, and the CMD always passes it.  Set so
# the fallback path writes somewhere persistent rather than into the image.
log_file: "/data/q2admin-cloud.log"

# ssh_address/ssh_port and rpc_address/rpc_port are left unset on purpose.
# Both listeners start unconditionally; unset means they bind :0 (a random
# port, all interfaces) INSIDE the container, and neither is published, so
# this deployment still adds exactly one LAN-facing port.
#
# The host key is required even so: the admin terminal's listener comes up
# whether or not anything can reach it, and an unset key logs an error on
# every single boot.
ssh_hostkey: "/data/crypto/ssh_host_ed25519_key"

debug_mode: false
verbose_level: 0
EOF
    chmod 600 "$CONFIG_PB"
fi

# ---------------------------------------------------------------- rules / users

RULES_PB="$DATA_DIR/config/rules.pb"
if [ -f "$RULES_PB" ]; then
    skip "rules.pb already present"
else
    # Required but may be empty: FetchRules() is fatal when the file cannot be
    # read, and an empty text-format proto unmarshals to an empty message.
    log "writing an empty config/rules.pb (no global rules)"
    : > "$RULES_PB"
fi

USERS_PB="$DATA_DIR/config/users.pb"
if [ -f "$USERS_PB" ]; then
    skip "users.pb already present"
else
    log "writing config/users.pb with the web-UI admin account ($ADMIN_EMAIL)"
    cat > "$USERS_PB" <<EOF
# Web UI accounts -- text-format protobuf, schema proto/user.proto.
# This account exists so AUTH_BYPASS_EMAIL works: MockLogin() looks the address
# up here and answers "you can only mock existing users" when it is absent,
# which is what /sign-in did before this row existed.  User.access is declared
# in the proto but never read anywhere in the codebase, so it is omitted.
user {
  uuid: "$(uuidgen)"
  name: "admin"
  email: "$ADMIN_EMAIL"
  description: "LAN admin, signed in via AUTH_BYPASS_EMAIL"
  disabled: false
}
EOF
    chmod 600 "$USERS_PB"
fi

# ------------------------------------------------- per-frontend dirs + keys

# cfg_value <file> <key> -- the value of a `key "value"` line in a q2admin cfg.
cfg_value() {
    sed -n "s/^[[:space:]]*$2[[:space:]]\{1,\}\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

FE_NAMES=() FE_UUIDS=() FE_PORTS=() FE_KEYFILES=()
SERVERKEY_CHANGED=0
GAMEDIRS_TO_RESTART=""

for spec in "${FRONTENDS[@]}"; do
    name="${spec%%:*}"; rest="${spec#*:}"
    gamedir="${rest%%:*}"; port="${rest##*:}"
    gdpath="$QUAKE2_DIR/$gamedir"
    cloudcfg="$gdpath/q2a_cloud.cfg"

    [ -f "$cloudcfg" ] || die "no q2a_cloud.cfg in $gdpath -- is $gamedir really a cloud-enabled gamedir?"

    uuid="$(cfg_value "$cloudcfg" cloud_uuid)"
    [ -n "$uuid" ] || die "cloud_uuid missing from $cloudcfg"

    pubname="$(cfg_value "$cloudcfg" cloud_publickey)"
    [ -n "$pubname" ] || pubname="cloud-public.pem"
    pubfile="$gdpath/$pubname"
    [ -f "$pubfile" ] || die "$gamedir's own public key is missing: $pubfile
       This script does not generate game-server keypairs -- that pair is the
       game server's identity and regenerating it would also mean editing
       q2a_cloud.cfg and re-registering the frontend."

    # Per-frontend log directory.  NewFrontendLogger() opens its log file with
    # O_CREATE but never creates the parent, and this codebase has no panic
    # recovery anywhere -- so a missing directory here takes the WHOLE process
    # down on that frontend's first connect, not just that one connection.
    mkdir -p "$DATA_DIR/clients/$name"

    # The cloud's public key, as the game server knows it.  Rewritten whenever
    # it differs, which is every time the cloud keypair was regenerated.
    servername="$(cfg_value "$cloudcfg" cloud_serverkey)"
    [ -n "$servername" ] || servername="cloud-serverkey.pem"
    serverkey="$gdpath/$servername"
    if [ -f "$serverkey" ] && cmp -s "$CLOUD_PUB" "$serverkey"; then
        skip "$gamedir: $servername already matches the cloud public key"
    else
        log "$gamedir: installing the cloud public key as $servername"
        cp -f "$CLOUD_PUB" "$serverkey"
        chmod 644 "$serverkey"
        SERVERKEY_CHANGED=1
        GAMEDIRS_TO_RESTART="$GAMEDIRS_TO_RESTART $gamedir"
    fi

    FE_NAMES+=("$name"); FE_UUIDS+=("$uuid"); FE_PORTS+=("$port")
    FE_KEYFILES+=("$pubfile")
done

# ------------------------------------------------- let the app create the schema

DB_FILE="$DATA_DIR/database/q2a.sqlite"

schema_ready() {
    python3 - "$DB_FILE" <<'PY' 2>/dev/null
import sqlite3, sys, os
if not os.path.exists(sys.argv[1]):
    sys.exit(1)
c = sqlite3.connect(sys.argv[1])
n = c.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='frontend'").fetchone()[0]
sys.exit(0 if n else 1)
PY
}

if schema_ready; then
    skip "database schema already present"
else
    log "starting $COMPOSE_SERVICE once so q2admind lays down the database schema"
    ( cd "$COMPOSE_DIR" && docker compose up -d "$COMPOSE_SERVICE" >/dev/null )
    for _ in $(seq 1 30); do
        schema_ready && break
        sleep 1
    done
    schema_ready || die "q2admind did not create the database schema -- check:
       cd $COMPOSE_DIR && docker compose logs $COMPOSE_SERVICE"
    log "schema created"
fi

# ------------------------------------------------- register the frontends

log "registering ${#FE_NAMES[@]} frontend(s) in the database"

args=("$DB_FILE" "$ADMIN_EMAIL" "$ADVERTISED_IP")
for i in "${!FE_NAMES[@]}"; do
    args+=("${FE_NAMES[$i]}" "${FE_UUIDS[$i]}" "${FE_PORTS[$i]}" "${FE_KEYFILES[$i]}")
done

python3 - "${args[@]}" <<'PY'
import sqlite3, sys

db, owner, ip = sys.argv[1], sys.argv[2], sys.argv[3]
rest = sys.argv[4:]
if len(rest) % 4:
    sys.exit("frontend arguments are not a multiple of 4")

# MaxInviteTokens / InviteTokenInterval in backend/backend.go.  Stored per
# frontend because the bucket refills from the row.
INVITE_TOKENS, INVITE_FREQ = 3, 300

con = sqlite3.connect(db)
cur = con.cursor()
for i in range(0, len(rest), 4):
    name, uuid, port, keyfile = rest[i], rest[i + 1], int(rest[i + 2]), rest[i + 3]
    with open(keyfile) as fh:
        key = fh.read()

    # `uuid` carries no UNIQUE constraint in the schema, so an upsert is not
    # available -- look it up and branch instead, or re-running this script
    # would silently duplicate every frontend and FindFrontend() would answer
    # with whichever copy sorted first.
    row = cur.execute("SELECT id FROM frontend WHERE uuid = ?", (uuid,)).fetchone()
    if row:
        cur.execute(
            """UPDATE frontend SET name=?, owner=?, enabled=1, ip_address=?,
                   port=?, public_key_data=?, verified=1
               WHERE id=?""",
            (name, owner, ip, port, key, row[0]))
        print(f"    updated {name} (id {row[0]}, uuid {uuid})")
    else:
        cur.execute(
            """INSERT INTO frontend (uuid, name, owner, enabled, description,
                   allow_teleport, allow_invite, ip_address, port,
                   public_key_data, verified, invites_tokens, invites_freq,
                   delete_protect, enable_player_cookies)
               VALUES (?,?,?,1,?,1,1,?,?,?,1,?,?,0,0)""",
            (uuid, name, owner, f"{name} (Dediz)", ip, port, key,
             INVITE_TOKENS, INVITE_FREQ))
        print(f"    added {name} (id {cur.lastrowid}, uuid {uuid})")
con.commit()
con.close()
PY

# enable_player_cookies is inserted as 0 above on purpose: SetupPlayerCookie()
# stuffs a persistent tracking cvar into every connecting player, and the
# player's own client echoes locally-executed stuffed commands into its console,
# which reads as unexplained chat from themselves.  See Dockerfile-q2admin-cloud.

# ------------------------------------------------- restart and report

log "restarting $COMPOSE_SERVICE so it loads the frontends"
( cd "$COMPOSE_DIR" && docker compose restart "$COMPOSE_SERVICE" >/dev/null )

sleep 3
echo
log "startup log:"
( cd "$COMPOSE_DIR" && docker compose logs --tail 20 "$COMPOSE_SERVICE" )
echo
if [ "$SERVERKEY_CHANGED" = 1 ]; then
    echo
    log "ACTION REQUIRED -- the game servers must be restarted."
    echo "    Their copy of the cloud public key changed, and q2admin reads"
    echo "    cloud_serverkey ONCE at init: a running server keeps using the key it"
    echo "    started with, so every reconnect fails the handshake and the cloud"
    echo "    logs 'asymmetric decrypt failed: crypto/rsa: decryption error'."
    echo "    This is not done automatically because it disconnects real players."
    echo
    echo "    Check nobody is playing, then:"
    echo "      cd $COMPOSE_DIR && docker compose restart${GAMEDIRS_TO_RESTART// / q2pro-}"
    echo
    echo "    A bind-mounted file changed and no image did, so 'restart' is right"
    echo "    here and 'up -d' would be wrong."
fi

echo
log "verify with:"
echo "      docker compose logs --tail 20 $COMPOSE_SERVICE   # expect '[name] authenticated'"
echo "      curl -s http://$ADVERTISED_IP:8087/api/GetConnectedServers"
