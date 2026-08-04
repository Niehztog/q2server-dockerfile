#!/bin/sh
# Build the Q2Admin-tsmod game DLL wrapper (gamei386.so) for i386.
#
# This is deliberately NOT part of the Dockerfile. gamei386.so has to sit in
# the bind-mounted game data dir next to gamei386.real.so - the wrapper
# dlopen()s "<gamedir>/gamei386.real.so" relative to the process CWD - so an
# image cannot deliver it, and having an entrypoint copy it over the
# operator's game DLL on every container start would be worse. Replacing it
# is also a deliberate version decision (the migration bumped 1.17.44 ->
# 1.17.48), not something that should happen implicitly on a rebuild.
#
# Runs the build in a throwaway Docker container so no i386 toolchain is
# needed on the host. Output is written to ./gamei386.so; install it yourself
# (see README.md "One-time game data preparation").
#
# The branch below carries two fixes required under q2pro; upstream
# tastyspleen/q2admin-tsmod without them will crash on load or fail edict
# bounds checks. See the q2admin-tsmod-issue-*.md write-up.
set -e

REPO="${REPO:-https://github.com/Niehztog/q2admin-tsmod.git}"
BRANCH="${BRANCH:-q2repro-compat-fixes}"
OUT="${OUT:-$(pwd)/gamei386.so}"

echo "Building gamei386.so from $REPO ($BRANCH)"

docker run --rm -v "$(dirname "$OUT")":/out debian:trixie-slim sh -eu -c "
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture i386
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        git ca-certificates make gcc gcc-multilib libc6-dev-i386 util-linux
    git clone --depth 1 --branch '$BRANCH' '$REPO' /src
    cd /src
    # ARCH=i386 makes the makefile add -m32; setarch keeps uname consistent
    setarch i386 make -f GNUmakefile ARCH=i386
    cp gamei386.so /out/$(basename "$OUT")
"

echo
echo "Built: $OUT"
echo "Verify it is 32-bit and has no TEXTREL:"
echo "  readelf -h '$OUT' | grep -E 'Class|Machine'"
echo "  readelf -d '$OUT' | grep TEXTREL || echo '  (no TEXTREL - good)'"
